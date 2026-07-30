# Approach A — hybrid prestate/structLogs diff extraction

## The problem it fixes

The production analyzer (EVMSketch) extracts the diff by running `debug_traceCall` with **struct logs**
and walking every executed step (`compute_state_updates`). Cost is `O(execution steps)`. For a
heavy-compute tracked function this trace is enormous even when the resulting diff is tiny:

| Tracked call | Diff size | structLog trace | Outcome on a real node |
|---|---|---|---|
| `MegaDrop.airdrop([r],[1000])` | 4 ops | small | fine |
| `OnchainLeaderboard.submitScore` | 5 ops | small | fine |
| **`OnchainLife.step(1)`** | **3 ops** | **306 MB / 16.8M gas** | **`-32000 execution timeout`** — node refuses |

The diff is 3 ops; the *trace* is what kills it. Any function whose value is "expensive compute → small
diff" (exactly Gas Killer's sweet spot) is the worst case for a step-based extractor.

## The op model (what "everything the other version does" means)

The analyzer's `StateUpdate` universe is exactly **STORE, CALL, LOG0–4** — there is *no* CREATE/CREATE2
variant. `compute_state_updates` is a *replay-script* builder, not a storage snapshotter:

- **STORE / LOG / CALL** are recorded only at **target depth** (the consumer's frame).
- **DELEGATECALL / CALLCODE** are **transparent** — target depth advances through them, so their writes
  (which land in the consumer's storage context) and logs *are* captured.
- A regular **CALL** at target depth becomes a **CALL op**; its internals are **filtered out** because
  they re-execute when the CALL op replays. **Cross-contract storage is reproduced by that replay**, not
  by extracting another account's slots.
- **CREATE / CREATE2 / SELFDESTRUCT** are **skipped** (surfaced as `skipped_opcodes`).
- **STATICCALL** is read-only and ignored.

To "do everything the other version does," the extractor must reproduce this exact model.

## The approach: a hybrid dispatcher (`--auto`)

Two cheap, node-native tracers are fetched for every call:

1. **`prestateTracer` in `diffMode`** → per-account `pre`/`post` storage. `O(changed slots)`.
2. **`callTracer` with `withLog`** → the call tree (frame types) + events. `O(calls+logs)`.

From these the extractor **classifies** whether the prestate fast-path is *sound*, then dispatches:

- **Eligible** → **prestate fast-path**: the consumer's net storage diff → STORE (slot-sorted), and the
  target-depth logs → LOG (in global execution order). This is the cheap path that survives heavy compute.
- **Not eligible** → **structLogs fallback**: run the proven `compute_state_updates` path verbatim. This
  is *identical to the other version* — same STORE/CALL/LOG ops, same CALL-replay semantics, same
  skipped-opcode surfacing.

The fast-path is sound only when the consumer makes **no state-affecting regular CALL**, **no
CREATE/SELFDESTRUCT**, and touches **only its own storage** — because a *net* diff cannot separate the
consumer's top-level writes from writes induced by a sub-call, so emitting both STORE-snapshots and a
CALL-replay would double-apply. The classifier checks exactly this from the two tracer outputs:

```
classify(callFrame, prestateDiff, consumer):
  if any non-consumer account's STORAGE changed            → fallback (needs CALL replay)
  walk target-depth context (root + DELEGATECALL/CALLCODE):
    child is a regular CALL                                → fallback (needs CALL replay)
    child is CREATE / CREATE2 / SELFDESTRUCT               → fallback (not representable)
    child is STATICCALL                                    → ignore (read-only)
  otherwise                                                → eligible
```

`--auto` never emits an unsound diff. `--prestate` forces the fast-path but **refuses** (errors) when
not eligible; `--call` forces the structLogs path. (`--auto` is the production-recommended mode.)

### A correctness bonus: net-zero touches

`prestateTracer` reports the **net** diff. A slot written then restored to its original value (e.g.
re-submitting an identical leaderboard entry) shows `pre == post` and is correctly **omitted**. The
structLog path emits redundant write-backs for the same case. So on the fast path the diff is not just
cheaper to *produce* — it can be strictly **leaner to apply**, and never less correct.

## Where it slots into the service

The dispatch wraps the existing extraction seam. The structLogs path (`compute_state_updates`,
`encode_state_updates_to_abi`, gas estimation, msgHash, signing, quorum) is **reused unchanged** and
remains the fallback; the new code is the two-tracer fetch + classifier + prestate assembly. Operator
**determinism** holds: every operator runs the same tracers at the same block, classifies identically,
and derives a byte-identical diff → identical msgHash → quorum forms. (Verified: byte-identical hex
across repeated runs, locally and against a live node.)

## Reference implementation

`tools/diff-extractor/src/main.rs`:

- `--auto <FROM> <TO> <CD> [BLK]` — hybrid dispatch (recommended)
- `--prestate …` — force fast-path, refuse if not eligible
- `--call …` / `<TX_HASH>` — structLogs path
- `classify` / `scan_target_depth` / `account_storage_changed` — eligibility
- `build_updates_from_prestate` + `ordered_target_depth_logs` / `collect_target_depth_logs` — fast-path
  assembly (delegatecall-transparent, regular-CALL/STATICCALL-excluded). Logs are put in true emission
  order by **interleaving each frame's logs with its sub-calls via the `position` field** (always
  populated by callTracer), with the global `index` applied as an authoritative override when present —
  so a "consumer log → delegatecall log → consumer log" topology orders correctly even on nodes that
  omit `index`. (This closed the one soundness gap an adversarial audit found.)

## Test coverage

| Layer | Artifact | What it proves |
|---|---|---|
| Unit (16) | `tools/diff-extractor/src/main.rs` `#[cfg(test)]` | storage diffing (changed/zeroing/net-zero/empty/consumer-only); LOG0–4 mapping; delegatecall-transparent + STATICCALL/regular-CALL-excluded log collection; ordering by global index AND by `position` without an index; **classifier** (eligible vs fallback for regular CALL, CREATE, CALL-nested-in-delegatecall, cross-contract storage, balance-only); tracker-slot filter |
| Hybrid e2e | `script/e2e/run-hybrid-e2e.sh` (+ `test/fixtures/HybridFixtures.sol`) | `--auto` dispatches correctly and the applied diff reproduces state + events in BOTH regimes: a DELEGATECALL consumer (fast-path) and a cross-contract CALL consumer (fallback, CALL-op replay reproducing **both** contracts), through `applyDiff` **and** `verifyAndUpdate`; a log/delegatecall-log/log consumer proving **event ordering**; `--prestate` **refuses** the cross-contract case |
| Self-compute e2e | `script/e2e/run-prestate-e2e.sh` | the real extracted hex, applied via `applyDiff` + `verifyAndUpdate`, reproduces naive state + in-order events — OnchainLife (heavy) and MegaDrop (LOG3) |
| Equivalence | `tools/diff-extractor/test-prestate.sh` | fast-path net-equals the structLogs path on the live examples; block-pinned; byte-identical hex across runs; parser count-guard refuses vacuous matches |
| Ground-truth | `test/live/PrestateOracle.t.sol` | the heavy-case storage **and** LOG2 equals what the EVM produces for naive `step(1)` |

## Does it do everything the structLogs version does?

| Capability | structLogs (`--call`) | hybrid (`--auto`) |
|---|---|---|
| STORE (consumer storage) | ✅ | ✅ (fast-path) / ✅ (fallback) |
| LOG0–4, correct topics/order | ✅ | ✅ index-ordered (fast-path) / ✅ (fallback) |
| DELEGATECALL/CALLCODE transparency | ✅ | ✅ (captured on the fast-path) |
| Regular CALL → CALL op (cross-contract replay) | ✅ | ✅ (fallback) |
| CREATE/CREATE2/SELFDESTRUCT | ⏭️ skipped + surfaced | ⏭️ skipped + surfaced (matched) |
| Heavy compute (e.g. `OnchainLife.step`) | ❌ node timeout | ✅ fast-path |
| Never emits an unsound diff | ✅ | ✅ (`--prestate` refuses; `--auto` falls back) |

## Honest residual notes

- **Heavy-compute *and* cross-contract at once.** A function that is both pathologically heavy *and*
  makes state-affecting external calls falls back to structLogs and therefore inherits the structLogs
  trace-size limit. This is **the same limitation the other version already has** — the hybrid is never
  *worse*, and it strictly improves the (common) heavy-self-compute case. Such functions are rare in
  practice; splitting the external call into its own tracked transaction sidesteps it.
- **Cross-client determinism.** All operators must run the same tracer on byte-compatible clients. The
  prestateTracer/callTracer JSON is stable across geth/erigon/reth, but we cannot exercise three clients
  in CI; determinism is verified run-to-run on one node. (The structLogs path has the same assumption.)
- **Tracker-slot constant.** The ERC-7201 counter slot is overridable via `GK_TRACKER_SLOT` so an SDK
  namespace change doesn't require a rebuild.
