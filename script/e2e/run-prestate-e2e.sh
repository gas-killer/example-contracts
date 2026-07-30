#!/usr/bin/env bash
#
# End-to-end correctness proof for the `--prestate` extractor (Approach A), fully local + deterministic.
#
# The Solidity equivalence tests apply HAND-BUILT diffs; the GuardedVault e2e applies a structLogs/tx-hash
# diff. NEITHER feeds the actual `--prestate` HEX (the production artifact verifyAndUpdate consumes)
# through the SDK apply path. This script closes that gap. For each example it:
#
#   1. deploys two identical Exposed instances (A = "naive", B = "operator") + a MockBLS
#   2. runs the REAL extractor `gk-diff-extractor --prestate` against a LOCAL anvil to get the diff HEX
#      (and runs it TWICE, asserting byte-identical output — the operator-determinism / msgHash invariant)
#   3. executes the naive tracked function on A  (the on-chain spec)
#   4. applies the EXTRACTED hex on B via applyDiff -> _stateChangeHandler (raw sstore/log, the apply path)
#   5. asserts A and B end in IDENTICAL state AND emitted IDENTICAL events
#
# If they match, the extracted diff — encoded, then applied through the SDK — reproduces the naive
# computation exactly. This is the end-to-end oracle the audit flagged as missing. anvil 1.6 supports
# prestateTracer(diffMode) + callTracer(withLog), so no external RPC is needed.
#
# Requires: foundry (anvil/cast/forge), jq, python3, and tools/diff-extractor.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RPC="http://localhost:8545"
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
EXTRACTOR="$ROOT/tools/diff-extractor/target/release/gk-diff-extractor"

PK0=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
A0=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
A1=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
A2=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
AVS=0x00000000000000000000000000000000000000A5
FAIL=0

command -v jq >/dev/null || { echo "jq is required"; exit 1; }
[ -x "$EXTRACTOR" ] || { echo "building diff-extractor..."; (cd "$ROOT/tools/diff-extractor" && cargo build --release); }

echo "==> starting anvil"
anvil --silent &
ANVIL_PID=$!
trap 'kill $ANVIL_PID 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 0.2; done
cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 || { echo "anvil did not become ready"; exit 1; }
cd "$ROOT"
forge build >/dev/null 2>&1

send() { cast send "$@" --rpc-url "$RPC" --private-key "$PK0" --json; }
dep()  { forge create "$1" --rpc-url "$RPC" --private-key "$PK0" --broadcast --json --constructor-args "${@:2}" 2>/dev/null | jq -r .deployedTo; }
BLS=$(forge create test/mocks/MockBLSSignatureChecker.sol:MockBLSSignatureChecker --rpc-url "$RPC" --private-key "$PK0" --broadcast --json 2>/dev/null | jq -r .deployedTo)

# Pull the [topics...,data] of every log emitted to $1 from tx receipt $2, normalized (address-independent),
# one log per line IN EMISSION ORDER (NOT sorted) — so we compare A's and B's events both by content AND
# by ordering, without their differing emitter addresses.
logs_of() { cast receipt "$2" --rpc-url "$RPC" --json | jq -r --arg a "$(echo "$1" | tr 'A-Z' 'a-z')" \
  '.logs[] | select((.address|ascii_downcase)==$a) | (.topics|join(",")) + "|" + .data'; }

extract_twice() { # $1 from, $2 to, $3 calldata -> echoes hex; aborts on non-determinism/empty
  local d1 d2
  d1=$(RPC_URL="$RPC" "$EXTRACTOR" --prestate "$1" "$2" "$3" 2>/dev/null)
  d2=$(RPC_URL="$RPC" "$EXTRACTOR" --prestate "$1" "$2" "$3" 2>/dev/null)
  [ -n "$d1" ] && [ "$d1" != "0x" ] || { echo "EXTRACT-EMPTY" >&2; return 1; }
  [ "$d1" = "$d2" ] || { echo "NON-DETERMINISTIC: $d1 != $d2" >&2; return 1; }
  echo "$d1"
}

check() { # $1 label  $2 condition-already-evaluated("OK"/other)  $3 detail
  if [ "$2" = "OK" ]; then echo "    ✅ $1"; else echo "    ❌ $1 — $3"; FAIL=1; fi
}

############################################################################
echo; echo "######## CASE 1: OnchainLife.step(1) — heavy compute (16.8M gas), LOG2 ########"
# Glider seeded entirely in word 0: cells (1,0),(2,1),(0,2),(1,2),(2,2) -> bits {1,66,128,129,130}.
GLIDER=$(python3 -c 'print((1<<1)|(1<<66)|(1<<128)|(1<<129)|(1<<130))')
SEED="[$GLIDER,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]"
LA=$(dep test/exposed/OnchainLifeExposed.sol:OnchainLifeExposed "$AVS" "$BLS" "$SEED")
LB=$(dep test/exposed/OnchainLifeExposed.sol:OnchainLifeExposed "$AVS" "$BLS" "$SEED")
CD=$(cast calldata "step(uint32)" 1)
DIFF=$(extract_twice "$A0" "$LA" "$CD") && check "extract deterministic + non-empty (${#DIFF} chars)" OK || check "extract" FAIL "see above"
NAIVE_TX=$(send "$LA" "step(uint32)" 1 | jq -r .transactionHash)
APPLY_TX=$(send "$LB" "applyDiff(bytes)" "$DIFF" | jq -r .transactionHash)
[ "$(cast receipt "$APPLY_TX" --rpc-url "$RPC" --json | jq -r .status)" = "0x1" ] \
  && check "applyDiff(extracted hex) tx succeeded" OK || check "applyDiff tx" FAIL "reverted"
# state: board words 0..15 + generation slot 16 (tracker slot is ERC-7201, excluded by construction)
SDIFF=""
for s in $(seq 0 16); do
  va=$(cast storage "$LA" "$s" --rpc-url "$RPC"); vb=$(cast storage "$LB" "$s" --rpc-url "$RPC")
  [ "$va" = "$vb" ] || SDIFF="$SDIFF slot$s(A=$va B=$vb)"
done
[ -z "$SDIFF" ] && check "state identical: naive(A) == applied-extracted-diff(B)" OK || check "state" FAIL "$SDIFF"
[ "$(logs_of "$LA" "$NAIVE_TX")" = "$(logs_of "$LB" "$APPLY_TX")" ] \
  && check "events identical + in-order (GenerationStepped LOG2)" OK || check "events" FAIL "log mismatch"

# Also route the SAME extracted hex through the REAL verifyAndUpdate entrypoint (mock BLS quorum), not
# just applyDiff — a third instance LC must end identical to the naive A.
LC=$(dep test/exposed/OnchainLifeExposed.sol:OnchainLifeExposed "$AVS" "$BLS" "$SEED")
TARGET="$LC" DIFF="$DIFF" SIG="step(uint32)" forge script script/e2e/SubmitDiffGeneric.s.sol:SubmitDiffGeneric \
  --rpc-url "$RPC" --private-key "$PK0" --broadcast >/tmp/vau.log 2>&1
grep -q "verifyAndUpdate landed" /tmp/vau.log && check "verifyAndUpdate accepted the extracted hex" OK \
  || check "verifyAndUpdate" FAIL "$(tail -2 /tmp/vau.log | tr '\n' ' ')"
VDIFF=""
for s in $(seq 0 16); do
  va=$(cast storage "$LA" "$s" --rpc-url "$RPC"); vc=$(cast storage "$LC" "$s" --rpc-url "$RPC")
  [ "$va" = "$vc" ] || VDIFF="$VDIFF slot$s(A=$va C=$vc)"
done
[ -z "$VDIFF" ] && check "state identical: naive(A) == verifyAndUpdate(extracted-diff)(C)" OK || check "verifyAndUpdate state" FAIL "$VDIFF"

############################################################################
echo; echo "######## CASE 2: GuardedVault.settle — invariant-guarded rebalance (mapping STOREs + LOG) ########"
GA=$(dep test/exposed/GuardedVaultExposed.sol:GuardedVaultExposed "$AVS" "$BLS" 5000)
GB=$(dep test/exposed/GuardedVaultExposed.sol:GuardedVaultExposed "$AVS" "$BLS" 5000)
for V in "$GA" "$GB"; do
  for PK in "$PK0" 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d \
            0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a; do
    cast send "$V" "deposit(uint256)" 1000 --rpc-url "$RPC" --private-key "$PK" >/dev/null
  done
done
CD=$(cast calldata "settle(address[],int256[])" "[$A0,$A1]" "[-200,200]")
DIFF=$(extract_twice "$A0" "$GA" "$CD") && check "extract deterministic + non-empty (${#DIFF} chars)" OK || check "extract" FAIL "see above"
NAIVE_TX=$(send "$GA" "settle(address[],int256[])" "[$A0,$A1]" "[-200,200]" | jq -r .transactionHash)
APPLY_TX=$(send "$GB" "applyDiff(bytes)" "$DIFF" | jq -r .transactionHash)
[ "$(cast receipt "$APPLY_TX" --rpc-url "$RPC" --json | jq -r .status)" = "0x1" ] \
  && check "applyDiff(extracted hex) tx succeeded" OK || check "applyDiff tx" FAIL "reverted"
SHDIFF=""
for acct in "$A0" "$A1" "$A2"; do
  sa=$(cast call "$GA" "shares(address)(uint256)" "$acct" --rpc-url "$RPC")
  sb=$(cast call "$GB" "shares(address)(uint256)" "$acct" --rpc-url "$RPC")
  [ "$sa" = "$sb" ] || SHDIFF="$SHDIFF $acct(A=$sa B=$sb)"
done
[ "$(cast call "$GA" 'shares(address)(uint256)' "$A0" --rpc-url "$RPC")" != "1000" ] \
  && check "naive settle actually moved shares (non-vacuous)" OK || check "naive settle" FAIL "shares unchanged"
[ -z "$SHDIFF" ] && check "shares identical: naive(A) == applied-extracted-diff(B)" OK || check "shares" FAIL "$SHDIFF"
[ "$(logs_of "$GA" "$NAIVE_TX")" = "$(logs_of "$GB" "$APPLY_TX")" ] \
  && check "events identical + in-order (Settled)" OK || check "events" FAIL "log mismatch"

echo
[ "$FAIL" = "0" ] && { echo "==> ✅ PRESTATE E2E PASSED: extracted hex, applied through the SDK, reproduces naive state + events"; exit 0; } \
                  || { echo "==> ❌ PRESTATE E2E FAILED (see ❌ above)"; exit 1; }
