#!/usr/bin/env bash
#
# Validates the --prestate extraction (Approach A: prestateTracer diffMode + callTracer withLog)
# against the authoritative structLogs path (--call), for our live Sepolia example contracts.
#
# Correctness criterion: --prestate must yield the SAME NET storage effect + the SAME logs as --call.
# (structLogs records every intermediate SSTORE; prestate records the net diff — so we compare each
# path's last-write-wins slot map and its log multiset.) Then it proves OnchainLife (16.8M-gas) now
# extracts via --prestate where --call's struct-log trace is infeasible.
#
# Requires: a debug-capable archive RPC in RPC_URL (geth/erigon/reth), cast, python3, the built binary.
set -uo pipefail

EXT="$(cd "$(dirname "$0")" && pwd)/target/release/gk-diff-extractor"
: "${RPC_URL:?set RPC_URL to a debug_traceCall-capable archive RPC}"
FROM=0xff467a85932cF543Df50255f00A8A829c12a3A11

GUARDEDVAULT=0xa44724d3781575d26b1809817f1b4b73d6492b01
LIFE=0x01a8c90963ebe399872c63afe0c885a43c93fa9c

cmp_py() {
python3 - "$1" "$2" <<'PY'
import sys, re
def parse(path):
    stores, logs, expected, raw = {}, [], None, 0
    for line in open(path):
        line = line.strip()
        m = re.match(r'extracted (\d+) state updates', line)
        if m:
            expected = int(m.group(1)); continue
        m = re.match(r'Store\(Store \{ slot: (0x[0-9a-fA-F]+), value: (0x[0-9a-fA-F]+) \}\)', line)
        if m:
            stores[m.group(1).lower()] = m.group(2).lower()   # last-write-wins
            raw += 1; continue
        m = re.match(r'Log(\d)\(Log\d \{ (.*) \}\)', line)
        if m:
            data = re.search(r'data: (0x[0-9a-fA-F]*)', m.group(2))
            topics = tuple(t.lower() for t in re.findall(r'topic\d: (0x[0-9a-fA-F]+)', m.group(2)))
            logs.append((m.group(1), data.group(1).lower() if data else '', topics))
            raw += 1; continue
    return stores, sorted(logs), expected, raw
a_s, a_l, a_n, a_raw = parse(sys.argv[1])
b_s, b_l, b_n, b_raw = parse(sys.argv[2])
# Guard against a vacuous pass: the parser must have consumed exactly the ops the tool said it emitted.
for label, n, raw in (("call", a_n, a_raw), ("prestate", b_n, b_raw)):
    if n is None:
        print(f"   PARSE-FAIL {label}: no 'extracted N' line (tool errored or output changed)"); sys.exit(2)
    if raw != n:
        print(f"   PARSE-FAIL {label}: parsed {raw} ops but tool reported {n} — regex drift, refusing vacuous match"); sys.exit(2)
ok = a_s == b_s and a_l == b_l
print(f"   stores: call={len(a_s)} prestate={len(b_s)}  match={a_s==b_s}   (ops parsed: call={a_raw} prestate={b_raw})")
print(f"   logs:   call={len(a_l)} prestate={len(b_l)}  match={a_l==b_l}")
if not ok:
    for k in sorted(set(a_s) | set(b_s)):
        if a_s.get(k) != b_s.get(k):
            print(f"     STORE DIFF {k}: call={a_s.get(k)} prestate={b_s.get(k)}")
    if a_l != b_l:
        print(f"     LOGS call={a_l}\n          prestate={b_l}")
sys.exit(0 if ok else 1)
PY
}

# Pin ONE block for the whole run so --call and --prestate (and repeat runs) snapshot identical state —
# otherwise a block mined mid-run would make the equivalence comparison flaky and never block-consistent.
BLK=$(cast block-number --rpc-url "$RPC_URL")
echo "pinned block: $BLK"
FAILED=0

equivalence() {
  local name="$1" addr="$2"; shift 2
  local cd ch ph ph2; cd=$(cast calldata "$@")
  echo "== $name =="
  ch=$("$EXT" --call     "$FROM" "$addr" "$cd" "$BLK" 2>/tmp/gk_call.txt) || { echo "   ❌ --call exited non-zero"; FAILED=1; return; }
  ph=$("$EXT" --prestate "$FROM" "$addr" "$cd" "$BLK" 2>/tmp/gk_pre.txt)  || { echo "   ❌ --prestate exited non-zero"; FAILED=1; return; }
  ph2=$("$EXT" --prestate "$FROM" "$addr" "$cd" "$BLK" 2>/dev/null)        || { echo "   ❌ --prestate (rerun) exited non-zero"; FAILED=1; return; }
  [ "$ph" = "$ph2" ] || { echo "   ❌ NON-DETERMINISTIC --prestate hex across runs at the same block"; FAILED=1; }
  if cmp_py /tmp/gk_call.txt /tmp/gk_pre.txt; then echo "   ✅ --prestate net-equivalent to --call (+ byte-identical hex across runs)"; else echo "   ❌ MISMATCH"; FAILED=1; fi
}

echo "############ equivalence: --prestate vs --call (structLogs) ############"
# NOTE the net-zero property: a call that writes a slot then restores it is a no-op, for which
# --prestate correctly emits an EMPTY diff while structLogs emits redundant write-backs — i.e. prestate
# is strictly leaner (and cheaper to apply) on net-zero touches, never less correct.
equivalence "GuardedVault.settle"       "$GUARDEDVAULT" "settle(address[],int256[])" "[]" "[]"

echo
echo "############ heavy case: OnchainLife.step(1) — 16.8M gas ############"
CD=$(cast calldata "step(uint32)" 1)
echo "== --prestate (should succeed cheaply) =="
T0=$(date +%s); "$EXT" --prestate "$FROM" "$LIFE" "$CD" "$BLK" >/tmp/life_pre.hex 2>/tmp/life_pre.err; RC=$?; T1=$(date +%s)
echo "   exit=$RC  elapsed=$((T1-T0))s  updates=$(grep -cE 'Store|Log' /tmp/life_pre.err)  diff_hex_bytes=$(wc -c </tmp/life_pre.hex)"
[ "$RC" = "0" ] || FAILED=1
grep -E 'Store|Log' /tmp/life_pre.err | head -3
echo "== --call (structLogs) — attempt with 90s timeout; expected to choke on the giant trace =="
T0=$(date +%s); ( ulimit -v 4000000 2>/dev/null; timeout 90 "$EXT" --call "$FROM" "$LIFE" "$CD" "$BLK" >/dev/null 2>/tmp/life_call.err ); RC=$?; T1=$(date +%s)
echo "   exit=$RC  elapsed=$((T1-T0))s  (124=timeout, non-0=failed/too-big)"
tail -1 /tmp/life_call.err 2>/dev/null | head -c 200
echo
echo
[ "$FAILED" = "0" ] && echo "==> ✅ ALL EQUIVALENCE + DETERMINISM CHECKS PASSED" || echo "==> ❌ SOME CHECKS FAILED"
exit $FAILED
