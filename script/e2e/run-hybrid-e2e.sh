#!/usr/bin/env bash
#
# End-to-end proof that the HYBRID extractor (`--auto`) does everything the structLogs version does —
# including the two cases the pure prestate path cannot handle alone — and never emits an unsound diff.
# Fully local + deterministic (anvil 1.6 supports prestateTracer/callTracer; snapshots for CALL replay).
#
#   CASE A  DelegateConsumer.bump   — DELEGATECALL into a storage lib (writes the consumer's slot, emits
#                                     from the consumer). --auto must pick the PRESTATE fast-path; the
#                                     extracted hex, applied via applyDiff AND verifyAndUpdate, reproduces
#                                     state + events.
#   CASE B  CrossConsumer.poke      — writes own storage, emits, then a regular CALL to a Sink. --prestate
#                                     must REFUSE (can't soundly represent it); --auto must FALL BACK to
#                                     structLogs, producing a CALL op. Applied (snapshot/revert), it
#                                     reproduces BOTH the consumer's and the Sink's state + all events.
#
# Requires: foundry (anvil/cast/forge), jq, tools/diff-extractor.
set -uo pipefail   # NOT -e: --prestate is EXPECTED to fail in CASE B

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RPC="http://localhost:8545"
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
EXT="$ROOT/tools/diff-extractor/target/release/gk-diff-extractor"

PK0=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
A0=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
AVS=0x00000000000000000000000000000000000000A5
FAIL=0

command -v jq >/dev/null || { echo "jq is required"; exit 1; }
[ -x "$EXT" ] || { echo "building diff-extractor..."; (cd "$ROOT/tools/diff-extractor" && cargo build --release); }

echo "==> starting anvil"
anvil --silent &
ANVIL_PID=$!
trap 'kill $ANVIL_PID 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 0.2; done
cd "$ROOT"; forge build >/dev/null 2>&1

send() { cast send "$@" --rpc-url "$RPC" --private-key "$PK0" --json; }
dep0() { forge create "$1" --rpc-url "$RPC" --private-key "$PK0" --broadcast --json 2>/dev/null | jq -r .deployedTo; }
dep()  { forge create "$1" --rpc-url "$RPC" --private-key "$PK0" --broadcast --json --constructor-args "${@:2}" 2>/dev/null | jq -r .deployedTo; }
req()  { case "$1" in 0x????????????????????????????????????????) ;; *) echo "FATAL: deploy of $2 failed (got '$1')"; exit 1;; esac; }
# logs emitted to $1 in tx $2, in emission order, address-normalized
logs_of() { cast receipt "$2" --rpc-url "$RPC" --json | jq -r --arg a "$(echo "$1" | tr 'A-Z' 'a-z')" \
  '.logs[] | select((.address|ascii_downcase)==$a) | (.topics|join(",")) + "|" + .data'; }
check() { if [ "$2" = "OK" ]; then echo "    ✅ $1"; else echo "    ❌ $1 — $3"; FAIL=1; fi; }
sval()  { cast call "$1" "$2" --rpc-url "$RPC"; }

BLS=$(forge create test/mocks/MockBLSSignatureChecker.sol:MockBLSSignatureChecker --rpc-url "$RPC" --private-key "$PK0" --broadcast --json 2>/dev/null | jq -r .deployedTo); req "$BLS" MockBLS
FX=test/fixtures/HybridFixtures.sol

############################################################################
echo; echo "######## CASE A: DelegateConsumer.bump — DELEGATECALL → PRESTATE fast-path ########"
LIB=$(dep0 "$FX:StorageLib"); req "$LIB" StorageLib
DA=$(dep "$FX:DelegateConsumer" "$AVS" "$BLS" "$LIB"); req "$DA" DelegateConsumer
DB=$(dep "$FX:DelegateConsumer" "$AVS" "$BLS" "$LIB"); req "$DB" DelegateConsumer
DC=$(dep "$FX:DelegateConsumer" "$AVS" "$BLS" "$LIB"); req "$DC" DelegateConsumer
CD=$(cast calldata "bump(uint256)" 7)
AUTO=$(RPC_URL="$RPC" "$EXT" --auto "$A0" "$DA" "$CD" 2>/tmp/da_auto.err)
grep -q "prestate fast-path" /tmp/da_auto.err && check "--auto chose the prestate fast-path (eligible)" OK || check "--auto path" FAIL "$(tail -1 /tmp/da_auto.err)"
PRE=$(RPC_URL="$RPC" "$EXT" --prestate "$A0" "$DA" "$CD" 2>/dev/null)
[ -n "$PRE" ] && [ "$PRE" = "$AUTO" ] && check "--prestate succeeds and equals --auto hex" OK || check "--prestate" FAIL "pre=$PRE auto=$AUTO"
NTX=$(send "$DA" "bump(uint256)" 7 | jq -r .transactionHash)
ATX=$(send "$DB" "applyDiff(bytes)" "$AUTO" | jq -r .transactionHash)
[ "$(sval "$DA" 'value()(uint256)')" = "7" ] && check "naive actually changed state (value=7, non-vacuous)" OK || check "naive" FAIL "value=$(sval "$DA" 'value()(uint256)')"
[ "$(sval "$DA" 'value()(uint256)')" = "$(sval "$DB" 'value()(uint256)')" ] && check "state: naive(DA) == applyDiff(DB)" OK || check "state" FAIL "value differs"
[ "$(logs_of "$DA" "$NTX")" = "$(logs_of "$DB" "$ATX")" ] && check "events identical (Bumped emitted via delegatecall)" OK || check "events" FAIL "log mismatch"
# verifyAndUpdate path on a 3rd instance:
TARGET="$DC" DIFF="$AUTO" SIG="bump(uint256)" forge script script/e2e/SubmitDiffGeneric.s.sol:SubmitDiffGeneric \
  --rpc-url "$RPC" --private-key "$PK0" --broadcast >/tmp/da_vau.log 2>&1
grep -q "verifyAndUpdate landed" /tmp/da_vau.log && check "verifyAndUpdate accepted the prestate hex" OK || check "verifyAndUpdate" FAIL "$(tail -2 /tmp/da_vau.log|tr '\n' ' ')"
[ "$(sval "$DA" 'value()(uint256)')" = "$(sval "$DC" 'value()(uint256)')" ] && check "state: naive(DA) == verifyAndUpdate(DC)" OK || check "vau state" FAIL "value differs"

############################################################################
echo; echo "######## CASE B: CrossConsumer.poke — regular CALL → structLogs FALLBACK (CALL replay) ########"
SINK=$(dep0 "$FX:Sink"); req "$SINK" Sink
CC=$(dep "$FX:CrossConsumer" "$AVS" "$BLS" "$SINK"); req "$CC" CrossConsumer
CD=$(cast calldata "poke(uint256)" 5)
# (1) --prestate must REFUSE rather than emit an unsound diff
if RPC_URL="$RPC" "$EXT" --prestate "$A0" "$CC" "$CD" >/dev/null 2>/tmp/cc_refuse.err; then
  check "--prestate REFUSES the cross-contract call" FAIL "it did not refuse"
else
  grep -q "cannot soundly represent" /tmp/cc_refuse.err && check "--prestate REFUSES (cannot soundly represent)" OK || check "--prestate refuse-reason" FAIL "$(tail -1 /tmp/cc_refuse.err)"
fi
# (2) --auto falls back to structLogs and produces a CALL op
DIFF=$(RPC_URL="$RPC" "$EXT" --auto "$A0" "$CC" "$CD" 2>/tmp/cc_auto.err)
grep -q "structLogs fallback" /tmp/cc_auto.err && check "--auto fell back to structLogs (regular CALL detected)" OK || check "--auto fallback" FAIL "$(tail -1 /tmp/cc_auto.err)"
grep -qi "Call" /tmp/cc_auto.err && check "fallback diff contains a CALL op" OK || check "CALL op" FAIL "no Call in $(grep -c . /tmp/cc_auto.err) lines"

# (3) snapshot → naive → record → revert → apply, twice (verifyAndUpdate + applyDiff)
S0=$(cast rpc evm_snapshot --rpc-url "$RPC" | tr -d '"')
NTX=$(send "$CC" "poke(uint256)" 5 | jq -r .transactionHash)
LC_N=$(sval "$CC" 'localCount()(uint256)'); ST_N=$(sval "$SINK" 'total()(uint256)')
CLOGS_N=$(logs_of "$CC" "$NTX"); SLOGS_N=$(logs_of "$SINK" "$NTX")
{ [ "$LC_N" = "5" ] && [ "$ST_N" = "5" ]; } && check "naive changed BOTH contracts (localCount=5, sink.total=5, non-vacuous)" OK || check "naive" FAIL "localCount=$LC_N sink.total=$ST_N"
cast rpc evm_revert "$S0" --rpc-url "$RPC" >/dev/null

# 3a: through the real verifyAndUpdate entrypoint (exercises the CALL op on-chain)
S1=$(cast rpc evm_snapshot --rpc-url "$RPC" | tr -d '"')
TARGET="$CC" DIFF="$DIFF" SIG="poke(uint256)" forge script script/e2e/SubmitDiffGeneric.s.sol:SubmitDiffGeneric \
  --rpc-url "$RPC" --private-key "$PK0" --broadcast >/tmp/cc_vau.log 2>&1
grep -q "verifyAndUpdate landed" /tmp/cc_vau.log && check "verifyAndUpdate accepted the fallback diff (with CALL op)" OK || check "vau" FAIL "$(tail -2 /tmp/cc_vau.log|tr '\n' ' ')"
[ "$(sval "$CC" 'localCount()(uint256)')" = "$LC_N" ] && check "consumer state reproduced (localCount)" OK || check "consumer state" FAIL "got $(sval "$CC" 'localCount()(uint256)') want $LC_N"
[ "$(sval "$SINK" 'total()(uint256)')" = "$ST_N" ] && check "CROSS-CONTRACT state reproduced via CALL replay (sink.total)" OK || check "sink state" FAIL "got $(sval "$SINK" 'total()(uint256)') want $ST_N"
cast rpc evm_revert "$S1" --rpc-url "$RPC" >/dev/null

# 3b: through applyDiff (clean tx → compare ALL events across both contracts, in order)
ATX=$(send "$CC" "applyDiff(bytes)" "$DIFF" | jq -r .transactionHash)
[ "$(logs_of "$CC" "$ATX")" = "$CLOGS_N" ] && check "consumer events reproduced (Poked)" OK || check "consumer events" FAIL "log mismatch"
[ "$(logs_of "$SINK" "$ATX")" = "$SLOGS_N" ] && check "CROSS-CONTRACT events reproduced (Sink.Recorded)" OK || check "sink events" FAIL "log mismatch"

############################################################################
echo; echo "######## CASE C: OrderConsumer.go — log,DELEGATECALL-log,log interleaving (ordering) ########"
OLIB=$(dep0 "$FX:OrderLib"); req "$OLIB" OrderLib
OA=$(dep "$FX:OrderConsumer" "$AVS" "$BLS" "$OLIB"); req "$OA" OrderConsumer
OB=$(dep "$FX:OrderConsumer" "$AVS" "$BLS" "$OLIB"); req "$OB" OrderConsumer
CD=$(cast calldata "go(uint256)" 9)
DIFF=$(RPC_URL="$RPC" "$EXT" --auto "$A0" "$OA" "$CD" 2>/tmp/oc.err)
grep -q "prestate fast-path" /tmp/oc.err && check "--auto chose prestate (delegatecall transparent)" OK || check "--auto path" FAIL "$(tail -1 /tmp/oc.err)"
NTX=$(send "$OA" "go(uint256)" 9 | jq -r .transactionHash)
ATX=$(send "$OB" "applyDiff(bytes)" "$DIFF" | jq -r .transactionHash)
NLOGS=$(logs_of "$OA" "$NTX"); ALOGS=$(logs_of "$OB" "$ATX")
NCOUNT=$(printf '%s\n' "$NLOGS" | grep -c .)
[ "$NCOUNT" = "3" ] && check "naive emitted 3 logs (First, Mid, Last — non-vacuous)" OK || check "naive logs" FAIL "got $NCOUNT"
[ "$NLOGS" = "$ALOGS" ] && check "events identical AND IN ORDER (First, Mid-via-delegatecall, Last)" OK || check "ordering" FAIL "naive=[$NLOGS] apply=[$ALOGS]"

echo
[ "$FAIL" = "0" ] && { echo "==> ✅ HYBRID E2E PASSED: --auto dispatches correctly and reproduces state + events in BOTH regimes"; exit 0; } \
                  || { echo "==> ❌ HYBRID E2E FAILED (see ❌ above)"; exit 1; }
