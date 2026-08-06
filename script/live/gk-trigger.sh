#!/usr/bin/env bash
#
# gk-trigger.sh — drive a Gas Killer state transition through the hosted testnet aggregator.
#
# THE SUBMISSION MODEL CHANGED. The aggregator used to broadcast `verifyAndUpdate` for you. Upstream it
# now RENDERS a ready-to-sign payload and the CALLER submits it (service commit 947901e, "serve
# user-executable payload ... instead of broadcasting"; the broadcast paths are retained but reserved for
# a future auto-execute / account-abstraction tier). The flow is now:
#
#   POST /tasks            -> 202 {"task_id":"…","status":"queued"}      (/trigger is a deprecated alias)
#   GET  /tasks/{task_id}  -> poll until {"status":"ready", "payload":{…}}
#   payload = {to, data, value, chain_id, estimated_gas, valid_until_block}
#   YOU sign + send that transaction (it expires ~50 blocks after rendering)
#
# This client supports BOTH models and detects which one the deployed service is running, because the
# hosted testnet is mid-migration: it already returns the new structured error envelope and the new
# per-key auth, but does not yet expose /tasks.
#
# Usage:
#   GK_API_KEY=… ./gk-trigger.sh <target_address> "<funcSig>" [args...] [--watch]
#
# Examples:
#   GK_API_KEY=gk_… ./gk-trigger.sh 0xMyVault "settle(address[],int256[])" "[]" "[]" --watch
#   GK_API_KEY=gk_… GK_SUBMIT_KEY=0x<funded-sepolia-key> \
#     ./gk-trigger.sh 0xLife "step(uint32)" 1 --watch      # auto-submits the rendered payload
#
# Env:
#   GK_API_KEY           (required) per-client API key. NOTE: the old shared INGRESS_PASSWORD bearer
#                        token no longer works — the testnet now 401s it (verified). Ask the Gas Killer
#                        operators to mint you a key.
#   GK_SUBMIT_KEY        funded Sepolia private key used to SEND the rendered payload. Without it the
#                        payload is printed for you to submit manually.
#   GK_BASE_URL          default https://testnet.gaskiller.xyz
#   GK_FROM              simulated caller (matters for access-controlled fns)
#   GK_RPC               chain RPC for block height + result checks (default Sepolia publicnode)
#   GK_BLOCK             override the simulation block_height
#   GK_TRANSITION_INDEX  override transition_index (default null => aggregator auto-pulls the next)
set -uo pipefail

BASE="${GK_BASE_URL:-https://testnet.gaskiller.xyz}"
RPC="${GK_RPC:-https://ethereum-sepolia.publicnode.com}"
FROM="${GK_FROM:-0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266}"
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1

# GK_PASSWORD/INGRESS_PASSWORD are the retired shared-secret names; accept them but warn loudly.
GK_API_KEY="${GK_API_KEY:-${GK_PASSWORD:-${INGRESS_PASSWORD:-}}}"
: "${GK_API_KEY:?set GK_API_KEY to your per-client aggregator API key}"
if [ -z "${GK_API_KEY_IS_NEW:-}" ] && [ -n "${GK_PASSWORD:-}${INGRESS_PASSWORD:-}" ] && [ -z "${GK_API_KEY_EXPLICIT:-}" ]; then
  case "$GK_API_KEY" in
    gk_*) ;;
    *) echo "WARNING: '$GK_API_KEY' looks like the retired shared INGRESS_PASSWORD. The testnet now" >&2
       echo "         rejects it with 401 UNAUTHORIZED; you need a per-client key (usually 'gk_…')." >&2;;
  esac
fi

[ $# -ge 2 ] || { sed -n '2,40p' "$0"; exit 1; }
TARGET="$1"; SIG="$2"; shift 2
WATCH=0; ARGS=()
for a in "$@"; do [ "$a" = "--watch" ] && WATCH=1 || ARGS+=("$a"); done

BLOCK="${GK_BLOCK:-$(cast block-number --rpc-url "$RPC")}"
CALLDATA=$(cast calldata "$SIG" "${ARGS[@]}")
TI_JSON="${GK_TRANSITION_INDEX:-null}"

BODY=$(python3 - "$TARGET" "$FROM" "$CALLDATA" "$BLOCK" "$TI_JSON" <<'PY'
import sys, json
target, frm, cd, blk, ti = sys.argv[1:6]
print(json.dumps({"body": {
    "target_address": target,
    "from_address": frm,
    "call_data": list(bytes.fromhex(cd[2:])),
    "transition_index": (None if ti == "null" else int(ti)),
    "value": "0",
    "block_height": int(blk),
}}))
PY
)

post() { # $1 path -> sets HTTP/RESP
  RESP=$(curl -sS -m 120 -o /tmp/gk_resp.$$ -w '%{http_code}' -X POST "$BASE$1" \
    -H "Content-Type: application/json" -H "Authorization: Bearer $GK_API_KEY" -d "$BODY")
  HTTP="$RESP"; RESP=$(cat /tmp/gk_resp.$$); rm -f /tmp/gk_resp.$$
}

jqv() { python3 -c "import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
for k in sys.argv[1].split('.'):
    if not isinstance(d,dict) or k not in d: sys.exit(1)
    d=d[k]
print(d if not isinstance(d,(dict,list)) else json.dumps(d))" "$1" 2>/dev/null; }

echo "==> POST $BASE/tasks   (target=$TARGET fn=$SIG block=$BLOCK transition_index=$TI_JSON)"
post /tasks
if [ "$HTTP" = "404" ]; then
  echo "    /tasks not exposed (older deployment) — falling back to the deprecated /trigger alias"
  post /trigger
fi
echo "    HTTP $HTTP: $RESP"

# Surface the new structured error envelope {"error":{"code","message"}} instead of failing silently.
case "$HTTP" in
  2*) ;;
  401) echo "ERROR: UNAUTHORIZED — the shared password was retired; you need a per-client API key." >&2; exit 1;;
  429) echo "ERROR: RATE_LIMITED — per-key rate limit hit; honor Retry-After and retry." >&2; exit 1;;
  503) echo "ERROR: QUEUE_FULL — ingress backpressure; retry shortly." >&2; exit 1;;
  *)   echo "ERROR: $(echo "$RESP" | jqv error.code || echo "HTTP $HTTP")" >&2; exit 1;;
esac

TASK_ID=$(echo "$RESP" | jqv task_id)

# ---------------------------------------------------------------------------------------------------
# NEW MODEL: a task id means the service renders a payload we must submit ourselves.
# ---------------------------------------------------------------------------------------------------
if [ -n "$TASK_ID" ]; then
  echo "==> task_id=$TASK_ID — polling GET $BASE/tasks/$TASK_ID until ready"
  for _ in $(seq 1 60); do
    S=$(curl -sS -m 30 "$BASE/tasks/$TASK_ID" -H "Authorization: Bearer $GK_API_KEY")
    ST=$(echo "$S" | jqv status)
    case "$ST" in
      ready)
        TO=$(echo "$S" | jqv payload.to); DATA=$(echo "$S" | jqv payload.data)
        VAL=$(echo "$S" | jqv payload.value); GASL=$(echo "$S" | jqv payload.estimated_gas)
        UNTIL=$(echo "$S" | jqv payload.valid_until_block)
        echo "    READY — payload to=$TO value=${VAL:-0} gas=${GASL:-?} valid_until_block=${UNTIL:-?}"
        if [ -n "${GK_SUBMIT_KEY:-}" ]; then
          echo "==> submitting the rendered payload (expires at block ${UNTIL:-?})"
          cast send "$TO" "$DATA" --value "${VAL:-0}" ${GASL:+--gas-limit "$GASL"} \
            --rpc-url "$RPC" --private-key "$GK_SUBMIT_KEY"
        else
          echo "    Set GK_SUBMIT_KEY to auto-send, or submit manually before it expires:"
          echo "      cast send $TO $DATA --value ${VAL:-0} --rpc-url \$RPC --private-key \$KEY"
        fi
        break;;
      failed|error)
        echo "ERROR: task $TASK_ID $ST: $(echo "$S" | jqv error)" >&2; exit 1;;
      *) printf '.' ;;
    esac
    sleep 5
  done
  echo
fi

# ---------------------------------------------------------------------------------------------------
# Result check. Under the OLD model this is how a round was observed landing; under the NEW model it
# confirms the payload WE submitted took effect.
# ---------------------------------------------------------------------------------------------------
if [ "$WATCH" = "1" ]; then
  echo "==> watching $TARGET.stateTransitionCount()"
  BEFORE=$(cast call "$TARGET" 'stateTransitionCount()(uint256)' --rpc-url "$RPC" 2>/dev/null || echo "?")
  echo "    before: $BEFORE"
  for _ in $(seq 1 40); do
    sleep 15
    NOW=$(cast call "$TARGET" 'stateTransitionCount()(uint256)' --rpc-url "$RPC" 2>/dev/null || echo "?")
    if [ "$NOW" != "$BEFORE" ]; then echo "    LANDED: stateTransitionCount $BEFORE -> $NOW"; exit 0; fi
  done
  echo "    no on-chain change after 10m."
  [ -z "$TASK_ID" ] && echo "    NOTE: this deployment returned no task_id. If it renders payloads rather" \
    && echo "    than broadcasting, nothing lands until the payload is submitted (see GK_SUBMIT_KEY)."
fi
