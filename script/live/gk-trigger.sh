#!/usr/bin/env bash
#
# gk-trigger.sh — drive a real Gas Killer `verifyAndUpdate` through the hosted testnet aggregator.
#
# The aggregator at https://testnet.gaskiller.xyz/trigger does the whole off-chain pipeline for a
# deployed consumer contract: it simulates the tracked-function call, computes the storage diff, has
# the operator quorum BLS-sign it, and submits `verifyAndUpdate` on-chain. This client just builds the
# request and POSTs it — so the only thing you provide is the access token (the colleague's "password").
#
# Usage:
#   GK_PASSWORD=… ./gk-trigger.sh <target_address> "<funcSig>" [args...] [--watch]
#
# Examples:
#   GK_PASSWORD=… ./gk-trigger.sh 0x0cBf63…F52 "sum(uint256[])" "[]" --watch
#   GK_PASSWORD=… ./gk-trigger.sh 0xMyVault   "settle(address[],int256[])" "[0xA,0xB]" "[-200,200]"
#
# Env:
#   GK_PASSWORD          (required) bearer token for the aggregator
#   GK_TRIGGER_URL       default https://testnet.gaskiller.xyz/trigger
#   GK_FROM              simulated caller (default anvil[0]); matters for access-controlled fns
#   GK_RPC               chain RPC, used to read the current block + (with --watch) the result
#                        default https://ethereum-sepolia.publicnode.com
#   GK_BLOCK             override the simulation block_height (default: current block from GK_RPC)
#   GK_TRANSITION_INDEX  override transition_index (default: null => aggregator auto-pulls the next)
set -euo pipefail

URL="${GK_TRIGGER_URL:-https://testnet.gaskiller.xyz/trigger}"
RPC="${GK_RPC:-https://ethereum-sepolia.publicnode.com}"
FROM="${GK_FROM:-0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266}"
# Accept GK_PASSWORD or the service's own env name INGRESS_PASSWORD.
GK_PASSWORD="${GK_PASSWORD:-${INGRESS_PASSWORD:-}}"
: "${GK_PASSWORD:?set GK_PASSWORD (or INGRESS_PASSWORD) to the aggregator bearer token}"

[ $# -ge 2 ] || { sed -n '2,30p' "$0"; exit 1; }
TARGET="$1"; SIG="$2"; shift 2

WATCH=0
ARGS=()
for a in "$@"; do [ "$a" = "--watch" ] && WATCH=1 || ARGS+=("$a"); done

BLOCK="${GK_BLOCK:-$(cast block-number --rpc-url "$RPC")}"
CALLDATA=$(cast calldata "$SIG" "${ARGS[@]}")
TI_JSON="${GK_TRANSITION_INDEX:+${GK_TRANSITION_INDEX}}"; TI_JSON="${TI_JSON:-null}"

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

echo "==> POST $URL"
echo "    target=$TARGET  fn=$SIG  block=$BLOCK  transition_index=$TI_JSON"
RESP=$(curl -sS -m 120 -X POST "$URL" \
  -H "Content-Type: application/json" -H "Authorization: Bearer $GK_PASSWORD" -d "$BODY")
echo "    response: $RESP"

if [ "$WATCH" = "1" ]; then
  echo "==> watching $TARGET.stateTransitionCount() for the landed verifyAndUpdate"
  BEFORE=$(cast call "$TARGET" 'stateTransitionCount()(uint256)' --rpc-url "$RPC" 2>/dev/null || echo "?")
  echo "    before: $BEFORE"
  for _ in $(seq 1 40); do
    sleep 15
    NOW=$(cast call "$TARGET" 'stateTransitionCount()(uint256)' --rpc-url "$RPC" 2>/dev/null || echo "?")
    if [ "$NOW" != "$BEFORE" ]; then echo "    LANDED: stateTransitionCount $BEFORE -> $NOW"; exit 0; fi
  done
  echo "    (no on-chain change yet after 10m — the round may still be in flight; re-check later)"
fi
