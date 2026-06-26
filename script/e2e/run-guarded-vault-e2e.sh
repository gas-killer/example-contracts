#!/usr/bin/env bash
#
# End-to-end demo wiring the REAL Gas Killer analyzer into the GuardedVault flow against a local anvil:
#
#   1. start anvil with --steps-tracing (so debug_traceTransaction returns step logs)
#   2. deploy a MockBLSSignatureChecker + two GuardedVaults (a "sandbox" and a "target"), seeded equally
#   3. an operator SIMULATES a settle by sending it to the sandbox (a mined tx; the on-chain guard runs)
#   4. the REAL analyzer (tools/diff-extractor) traces that tx -> the (StateUpdateType[],bytes[]) diff
#   5. submit that exact diff to the target vault via verifyAndUpdate (mock BLS quorum)
#   6. assert the target now matches the sandbox -> the analyzer's diff reproduced the settle
#   7. show the GUARD: a settle that breaks the O(N) invariant REVERTS, so no diff can ever be produced
#
# The BLS signature is mocked (the full operator set can't run locally; see SECURITY.md). What is REAL
# here is the analyzer-produced storage diff.
#
# Requires: foundry (anvil/cast/forge), jq, and a built tools/diff-extractor.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RPC="http://localhost:8545"
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
EXTRACTOR="$ROOT/tools/diff-extractor/target/release/gk-diff-extractor"

# anvil deterministic accounts [0..2]
PK0=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
PK1=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
PK2=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a
A0=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
A1=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
A2=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
AVS=0x00000000000000000000000000000000000000A5

command -v jq >/dev/null || { echo "jq is required"; exit 1; }
[ -x "$EXTRACTOR" ] || { echo "building diff-extractor..."; (cd "$ROOT/tools/diff-extractor" && cargo build --release); }

echo "==> starting anvil --steps-tracing"
anvil --steps-tracing --silent &
ANVIL_PID=$!
trap 'kill $ANVIL_PID 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 0.2; done
cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 || { echo "anvil did not become ready"; exit 1; }
cd "$ROOT"
forge build >/dev/null 2>&1 # pre-compile so `forge create --json` emits clean JSON on stdout

# NOTE: --constructor-args is variadic/greedy, so it MUST come last.
dep() { forge create "$1" --rpc-url "$RPC" --private-key "$PK0" --broadcast --json --constructor-args "${@:2}" 2>/dev/null | jq -r .deployedTo; }

echo "==> deploying MockBLS + two GuardedVaults (maxBps=5000)"
BLS=$(forge create test/mocks/MockBLSSignatureChecker.sol:MockBLSSignatureChecker --rpc-url "$RPC" --private-key "$PK0" --broadcast --json 2>/dev/null | jq -r .deployedTo)
SANDBOX=$(dep src/examples/guarded-vault/GuardedVault.sol:GuardedVault "$AVS" "$BLS" 5000)
TARGET=$(dep src/examples/guarded-vault/GuardedVault.sol:GuardedVault "$AVS" "$BLS" 5000)
echo "    BLS=$BLS  sandbox=$SANDBOX  target=$TARGET"

echo "==> seeding 3 depositors (1000 each) into BOTH vaults"
for V in "$SANDBOX" "$TARGET"; do
  cast send "$V" "deposit(uint256)" 1000 --rpc-url "$RPC" --private-key "$PK0" >/dev/null
  cast send "$V" "deposit(uint256)" 1000 --rpc-url "$RPC" --private-key "$PK1" >/dev/null
  cast send "$V" "deposit(uint256)" 1000 --rpc-url "$RPC" --private-key "$PK2" >/dev/null
done

echo "==> operator simulates settle on the SANDBOX (move 200 shares A0 -> A1)"
SETTLE_TX=$(cast send "$SANDBOX" "settle(address[],int256[])" "[$A0,$A1]" "[-200,200]" \
  --rpc-url "$RPC" --private-key "$PK0" --json | jq -r .transactionHash)
echo "    settle tx: $SETTLE_TX"

echo "==> REAL analyzer: extracting the storage diff from the settle trace"
DIFF=$(RPC_URL="$RPC" "$EXTRACTOR" "$SETTLE_TX")
echo "    diff bytes: ${DIFF:0:80}... (${#DIFF} chars)"

echo "==> submitting the analyzer diff to the TARGET via verifyAndUpdate (mock BLS)"
VAULT="$TARGET" DIFF="$DIFF" forge script script/e2e/SubmitDiff.s.sol:SubmitDiff \
  --rpc-url "$RPC" --private-key "$PK0" --broadcast 2>&1 | grep -E "verifyAndUpdate|stateTransitionCount" || true

echo "==> verifying the target matches the sandbox"
for A in "$A0" "$A1" "$A2"; do
  S=$(cast call "$SANDBOX" "shares(address)(uint256)" "$A" --rpc-url "$RPC")
  T=$(cast call "$TARGET"  "shares(address)(uint256)" "$A" --rpc-url "$RPC")
  echo "    $A  sandbox=$S  target=$T"
  [ "$S" = "$T" ] || { echo "MISMATCH"; exit 1; }
done
echo "    ✅ analyzer-produced diff reproduced the settle on the target vault"

echo "==> GUARD demo: an over-concentrating settle must REVERT (so no diff can be produced)"
if cast send "$SANDBOX" "settle(address[],int256[])" "[$A0,$A1,$A2]" "[1000,-500,-500]" \
     --rpc-url "$RPC" --private-key "$PK0" >/dev/null 2>&1; then
  echo "    UNEXPECTED: over-concentrating settle did not revert"; exit 1
else
  echo "    ✅ over-concentration reverted on-chain in the spec; an honest operator gets no signable diff"
fi

echo "==> e2e complete"
