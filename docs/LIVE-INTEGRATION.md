# Live integration — driving `verifyAndUpdate` via the hosted Gas Killer aggregator

This is the production path: a hosted aggregator runs the whole off-chain pipeline for a deployed
consumer, so you don't build or run operators yourself. You make **one authenticated HTTP request** and
the service simulates the call, computes the storage diff, has the operator quorum BLS-sign it, and
submits `verifyAndUpdate` on-chain.

```
your client ──POST /trigger──▶ testnet.gaskiller.xyz
                                   │  simulate call at block_height (from from_address)
                                   │  analyzer → storage diff (StateUpdateType[],bytes[])
                                   │  operator quorum BLS-signs sha256(transitionIndex,target,selector,diff)
                                   │  aggregate → NonSignerStakesAndSignature
                                   ▼
                            verifyAndUpdate(...) on your consumer  (on-chain)
```

## The API (reverse-engineered + verified)

`POST https://testnet.gaskiller.xyz/trigger`

Headers: `Content-Type: application/json`, `Authorization: Bearer $GK_PASSWORD`.

Body:

```json
{
  "body": {
    "target_address":   "0x… consumer contract (must be a deployed Gas Killer consumer)",
    "from_address":     "0x… simulated caller (matters only for access-controlled fns)",
    "call_data":        [/* u8 bytes of the tracked-function calldata: selector + abi-encoded args */],
    "transition_index": null,        // null => aggregator auto-pulls the next index
    "value":            "0x0",
    "block_height":     11130341      // block to simulate the call at
  }
}
```

Observed responses:

| Status | Body | Meaning |
|---|---|---|
| `200` | `{"success":true,"message":"Task queued"}` | accepted; round runs async |
| `400` | `{"success":false,"message":"Task rejected: no contract found at target_address on any chain"}` | target isn't a known consumer |
| `422` | validation error | malformed body |

Auth is enforced (a valid bearer token is required to queue a task). The token is the value your
colleague provides — keep it in `GK_PASSWORD`, never commit it.

## Client: `script/live/gk-trigger.sh`

Builds the `call_data` with `cast`, posts the request, and (optionally) watches the consumer's
`stateTransitionCount()` for the landed `verifyAndUpdate`.

```bash
export GK_PASSWORD=…   # from your colleague

# sum-all on the live Sepolia ArraySummation demo consumer
GK_PASSWORD=$GK_PASSWORD ./script/live/gk-trigger.sh \
  0x0cBf633E948E005d58a0B7623D4e14d5Ba015F52 "sum(uint256[])" "[]" --watch

# a state-changing call
GK_PASSWORD=$GK_PASSWORD ./script/live/gk-trigger.sh \
  0x0cBf633E948E005d58a0B7623D4e14d5Ba015F52 "setArrayElement(uint256,uint256)" 0 9999 --watch

# one of OUR examples once it's deployed + wired (see below)
GK_PASSWORD=$GK_PASSWORD ./script/live/gk-trigger.sh \
  $GUARDED_VAULT "settle(address[],int256[])" "[$A,$B]" "[-200,200]" --watch
```

Env knobs: `GK_TRIGGER_URL`, `GK_FROM`, `GK_RPC`, `GK_BLOCK`, `GK_TRANSITION_INDEX` (see the script header).

## Wiring OUR examples to the live service

A consumer is "served" by the aggregator when it's deployed on a chain the operators watch **and**
wired to the AVS BLSSignatureChecker the operators are registered with. The live Sepolia stack:

| Component | Address (Sepolia, 11155111) |
|---|---|
| AVS / ServiceManager | `0x2015983cDd409B1838F4C1cCa9085c946C5A9F81` |
| BLSSignatureChecker | `0x22FfcFD8cCCb2e70dbd6FE1DAf951080595E02f2` |
| RegistryCoordinator | `0x7aA89B1CBC571a1c6F7E6B262E06e614104Fb56d` |
| StakeRegistry (live stake) | `0xac89f540a78313aE126fd95cc9e1eb82503b824A` |

Deploy an example wired to it (needs a funded Sepolia key):

```bash
AVS_ADDRESS=0x2015983cDd409B1838F4C1cCa9085c946C5A9F81 \
SIG_CHECKER_ADDRESS=0x22FfcFD8cCCb2e70dbd6FE1DAf951080595E02f2 \
  forge script script/DeployGuardedVault.s.sol --rpc-url $SEPOLIA_RPC_URL --private-key $PK --broadcast
```

Then `gk-trigger.sh <deployed-address> "<trackedFn>" …`. The fork test `test/live/SepoliaLiveTest`
already proves our contracts wire to (and are gated by) the real on-chain checker.

## Status / what's verified

- ✅ API integration: authenticated `POST /trigger` against the live hosted aggregator works; it
  recognizes real deployed consumers and queues the task (`200 Task queued`).
- ✅ Client (`gk-trigger.sh`) builds correct calldata and submits.
- ✅ On-chain wiring: our examples deploy + wire to the real Sepolia checker (fork-tested).
- ✅ **End-to-end landing CONFIRMED.** Triggering the current served target `0xdA8Ca8…` with
  `sum([1,2,3])` produced a real signed `verifyAndUpdate` on Sepolia
  (tx `0x96fbbdaab6e4aa695d0b7f4d2a9222af1e869c1c96725949f08583eda417e1d6`, relayer
  `0x5DD2e7db86…`); `stateTransitionCount` went 14 → 15. The whole pipeline — client → operator quorum
  → on-chain submission — works.

## Verified against the service repo (`gas-killer/service`)

Reading `scripts/send_request.rs`, the scenario TOMLs, and `helm/.../testnet-overrides.yaml` confirms:

- **Chain = Sepolia.** The testnet's EigenLayer core (`allocationManager 0x42583067…`,
  `delegationManager 0xD4A7E1…`) is on Sepolia; quorum is **2/3** with up to 4 operators.
- **Request format matches our client exactly** — `{body:{target_address, call_data(bytes[]),
  transition_index("auto"→null), from_address, value, block_height}}`, block resolved client-side,
  bearer `INGRESS_PASSWORD`.
- **Canonical call** is `sum(uint256[])` on an `ArraySummation` target, e.g. `sum([1,2,3])`
  (`0194db8e…`), from `0xff467a85…`. Smoke targets are **ephemeral**: redeployed each run via the
  `deploy-target-job` (ArraySummation, arraySize 10) through the factory `0xf7ded7…` and published to
  the `gas-killer-smoke-target` ConfigMap (so the *current* target address requires kubectl access).

## Proven working — the one-command end-to-end

```bash
INGRESS_PASSWORD=<token> GK_FROM=0xff467a85932cF543Df50255f00A8A829c12a3A11 \
  ./script/live/gk-trigger.sh 0xdA8Ca87C3243775b522f5F8fEc1E255Fdf186367 "sum(uint256[])" "[1,2,3]" --watch
# … response: {"success":true,"message":"Task queued"}
# … LANDED: stateTransitionCount 14 -> 15
```

### Our examples, run live through the AVS (2026-06-24)

| Example | Tracked call | Sim gas | Result |
|---|---|---|---|
| `GuardedVault` | `settle([],[])` | 36k | ✅ landed (`stc 0→1`, relayer `0x5DD2e7db86…`) |
| `OnchainLeaderboard` | `submitScore(addr,100)` | 52k | ✅ landed (`stc 0→1`) |
| `OnchainLife` | `step(1)` | **16.8M** | ❌ **Proven via local stack** → ✅ **fix implemented + tested in this repo.** EVMSketch runs `debug_traceCall` structLogs, and for `step(1)` that trace is **306 MB** (28s on a fast archive node) — it saturates/DoSes the node (the local anvil went unresponsive; the router spammed "failed to read chain head"). The resulting diff is only **3 ops**. The trace is the killer, not the diff. **Approach A** (`prestateTracer` `diffMode` + `callTracer` `withLog`) is now implemented as a reference in `tools/diff-extractor --prestate` and validated against the QuikNode archive RPC: it returns the same diff in **~0s / 1.4 KB** where the structLog path (`--call`) gets `-32000 execution timeout` from the node. Correctness is double-proven — net-equivalent to the authoritative `--call` path on the three light examples, and (since `--call` can't run here) byte-checked against the EVM itself: `test/live/PrestateOracle.t.sol` forks Sepolia, runs naive `step(1)` (16.5M gas) on the real deployed contract, and confirms board word 0 + generation exactly match the extracted diff. See [`docs/APPROACH-A-PRESTATE.md`](APPROACH-A-PRESTATE.md). |
| `MegaDrop` | `airdrop([r],[1000])` | 94k | ❌ no submission, reproducible across 3 attempts — yet tiny and doesn't revert. **Verified with the real analyzer (`gk-diff-extractor --call`):** extraction produces a clean, valid 4-op diff *including* the `Transfer` LOG3, and our equivalence test proves a LOG3 diff *applies* correctly through `verifyAndUpdate`. So the diff is valid end-to-end — the failure is **downstream of extraction** (the operator's gas-estimation / signing / submission), not the diff. **Resolved via local stack:** the *current* operator images (`node-latest`/`router-latest`) process MegaDrop's LOG3 diff through the **entire** off-chain pipeline cleanly — EVMSketch analysis (`state_update_count=5`), node validation, signing, and 3-operator aggregation — identical to the LOG1/LOG2 examples and the canonical ArraySummation. So the current code has **no** LOG3 bug; the testnet failure is a **version mismatch** (the testnet runs an older build). Fix: redeploy the testnet operators from latest. (Locally, on-chain submission reverts `0x` for *every* consumer because the local `blsSigCheck` isn't a standard checker — an env artifact, confirmed with the canonical ArraySummation control.) |

So **2 of 4 of our own examples run live end-to-end** — proving the operators serve arbitrary consumers (not just their smoke target). The two failures are an operator-side trace/LOG limitation, not a flaw in our contracts or client.

**The critical input is the *currently served* target.** Targets are ephemeral (the smoke job
redeploys an `ArraySummation` each run and publishes the new address to the `gas-killer-smoke-target`
ConfigMap). The active target as of this writing is `0xdA8Ca87C3243775b522f5F8fEc1E255Fdf186367`
(arrayLen 10, checker `0x4B0fc77f…`, relayer `0x5DD2e7db86…`, active 2026-06). Older demo instances
(`0x0cBf63…`, `0x7ab9c4…`) belong to earlier deployments whose relayers (`0x8CaDd5Dd65…` 2025-12,
`0xb2137FF042…` 2026-02) are dormant — triggering those just queues forever. **Always trigger the
current ConfigMap target.**

To run one of OUR examples through the live service, deploy it wired to the active AVS
(`avsAddress`/`blsSignatureChecker` of the current target) so the operators serve it, then `gk-trigger.sh`
it the same way.
