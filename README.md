# Gas Killer — Example Contracts

Example [Foundry](https://book.getfoundry.sh) contracts that show off the **Gas Killer SDK** — an
EigenLayer AVS where operators run an expensive *state-changing* computation **off-chain**, BLS-sign
the resulting storage diff, and submit it through `verifyAndUpdate`, which verifies a 66 % operator
quorum and then applies the diff with raw `sstore` / `call` / `log`. The on-chain cost is signature
verification + applying the diff — **not** the computation.

The pitch: **write the dumb, brute-force, gas-explosive contract you'd never normally ship**, and let
operators do the heavy lifting off-chain.

> ⚠️ Experimental, unaudited example code. **Read [`SECURITY.md`](./SECURITY.md) first** — it explains
> the (crypto-economic, no-fraud-proof) trust model and exactly where the block gas limit still bites.
> These examples are deliberately honest about when Gas Killer is a real win and when it is not.

## How it works

```
            NAIVE (today)                         GAS KILLER
   ┌───────────────────────────┐      ┌────────────────────────────────────┐
   │ every caller runs the      │      │ operator runs the expensive fn      │
   │ expensive fn on-chain      │      │ OFF-CHAIN, gets the storage diff     │
   │  → O(N) gas, blows past a  │      │  → BLS-signs it (66% quorum)         │
   │    30M block at modest N   │      │  → verifyAndUpdate applies the diff  │
   └───────────────────────────┘      │    (sstore/log) for ~225k + the diff │
                                       └────────────────────────────────────┘
```

A consumer contract:

1. inherits `GasKillerSDK` and wires the AVS + BLS checker in its constructor;
2. marks the expensive state-changing function with the `trackState` modifier (the function body is the
   *spec*; in production operators reproduce its result off-chain);
3. operators submit the resulting `(StateUpdateType[], bytes[])` diff through `verifyAndUpdate`.

## The two examples

Both share the one property Gas Killer actually rewards: **expensive computation that collapses to a
small storage diff.** Cost scales with compute; settlement scales with bytes changed.

| Example | What it does | SDK features |
|---|---|---|
| [`OnchainLife`](./src/examples/onchain-life/OnchainLife.sol) | Conway's Game of Life on a 64×64 board, fully on-chain. One generation costs 16.9M gas; two exceed a block. | packed-bitmap `STORE`, `LOG2` |
| [`GuardedVault`](./src/examples/guarded-vault/GuardedVault.sol) | Vault that re-validates an expensive **global invariant** on every transition — proven off-chain *before* the state lands | mapping `STORE`, `LOG1`, invariant guard |

### Measured gas → [**full report: `docs/GAS-REPORT.md`**](./docs/GAS-REPORT.md)

Settlement cost is anchored in a **real Sepolia transaction**: our GuardedVault settled for **300,944 gas**
([`0x865bf3ab…`](https://eth-sepolia.blockscout.com/tx/0x865bf3ab1d23566bce98261c1096822fb9a7ff8a52fbd07da9b5e804ec17fb7c)),
of which **224,827 is BLS signature verification** — measured by tracing it, not estimated. That cost is
fixed regardless of how much compute the operators did. See [`SECURITY.md`](./SECURITY.md).

**OnchainLife — the apply cost does not move as compute explodes:**

| generations | naive on-chain | Gas Killer settlement | factor |
|---|---|---|---|
| 1 | 16.9M | ~400k | **42×** |
| 2 | 33.6M (**> 30M block**) | ~400k | **84×** |
| 8 | 134.1M | ~400k | **335×** |
| 16 | 267.7M | ~400k | **669×** |

Settlement does not move at all across that range — the board is 16 words however much compute produced
it. Naive grows without bound, Gas Killer is flat, so the factor **doubles every time the work doubles**.

**GuardedVault — the O(N) invariant runs off-chain; the diff is always 2 slots + a log:**

| depositors | naive guard | Gas Killer settlement | factor |
|---|---|---|---|
| 1,000 | 4.7M | ~306k | 15.2× |
| 3,000 | 14.0M | ~306k | 45.6× |
| 8,000 | 37.2M (**> 30M block**) | ~306k | **122×** |

**Below ~66 depositors, don't use Gas Killer for this** — the ~300k settlement floor dominates and a plain
on-chain check is cheaper. Two further caveats stated up front: this settle conserves total shares, so the
invariant is reducible to an `O(K)` check over the touched accounts (also cheaper), and GuardedVault
therefore illustrates the *pattern* rather than proving this invariant needs it. See the report.

> **The honest limit.** A bulk airdrop and a sorted leaderboard were also built here and **removed** after
> measuring as *losses* (25.2M → 30.7M and 24.5M → 36.8M). Both write a diff proportional to the work, so
> there's no compute to collapse and you pay quorum overhead on top. If your diff scales with your
> computation, this is the wrong tool.

## Quickstart

```bash
# clone with submodules (the SDK pulls in the EigenLayer middleware tree)
git clone --recurse-submodules <this repo>
# or, after a plain clone:
git submodule update --init --recursive

forge build          # compiles against the real GasKillerSDK + EigenLayer middleware (solc 0.8.27)
forge test           # unit, equivalence, verifyAndUpdate, canonical-encoding, benchmarks
forge test --match-path 'test/examples/*.bench.t.sol' -vv   # see the gas numbers
```

Deploy a demo locally (auto-deploys a mock BLS checker if `SIG_CHECKER_ADDRESS` is unset):

```bash
anvil &
forge script script/DeployOnchainLife.s.sol --rpc-url http://localhost:8545 --broadcast \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

## Anatomy of an example

```solidity
contract MyExample is GasKillerSDK {
    uint256 public result;                 // slot 0 (GasKillerSDK uses ERC-7201 namespaces)

    constructor(address avs, address bls) {
        _setAvsAddress(avs);
        _setBlsSignatureChecker(bls);
    }

    function expensiveThing(/* ... */) external trackState {  // the naive spec
        // ... gas-explosive logic that sets `result` ...
    }
}
```

An operator (mimicked in tests by [`OffchainPayloadBuilder`](./test/helpers/OffchainPayloadBuilder.sol))
computes the result off-chain and builds the diff:

```solidity
bytes memory diff = OffchainPayloadBuilder.store(
    OffchainPayloadBuilder.simpleSlot(0),   // slot of `result`
    bytes32(computedResult)
);
// → verifyAndUpdate(msgHash, quorumNumbers, refBlock, diff, transitionIndex, selector, signature)
```

Every test proves **equivalence**: running the naive function and applying the operator's diff produce
byte-identical storage (checked with `vm.load`) and identical logs (checked with `vm.recordLogs`).

## Using the REAL Gas Killer analyzer (end-to-end)

The Solidity tests build the diff in Solidity (`OffchainPayloadBuilder`) so CI stays fast. To prove the
examples work with the **actual** off-chain engine, [`script/e2e/`](./script/e2e/) wires in the real
[Gas Killer analyzer](https://github.com/BreadchainCoop/gas-killer-analyzer) via a thin wrapper
([`tools/diff-extractor`](./tools/diff-extractor/)): it traces a real `settle` transaction on a local
anvil and emits the exact `(StateUpdateType[], bytes[])` diff that `verifyAndUpdate` applies.

```bash
cd tools/diff-extractor && cargo build --release && cd -
bash script/e2e/run-guarded-vault-e2e.sh
```

The operator simulates a `settle` on a sandbox vault, the analyzer extracts the diff, and it lands on a
separate target vault via `verifyAndUpdate` — reproducing the settle exactly. The BLS signature is
mocked (the full operator set can't run locally); the **diff is real**. See
[`script/e2e/README.md`](./script/e2e/README.md).

## Live on Sepolia testnet

A real Gas Killer AVS stack is deployed on **Sepolia (chain 11155111)** — discovered on-chain via the
live `ArraySummationFactory` (`0xf7ded769418ec1db4da3bd2d47ab72ce2296a032`), which records every consumer
it deployed. The most complete stack:

| Component | Address (Sepolia) |
|---|---|
| ArraySummation (live consumer; `currentSum` already computed) | `0x0cBf633E948E005d58a0B7623D4e14d5Ba015F52` |
| AVS / ServiceManager | `0x2015983cDd409B1838F4C1cCa9085c946C5A9F81` |
| BLSSignatureChecker | `0x22FfcFD8cCCb2e70dbd6FE1DAf951080595E02f2` |
| RegistryCoordinator | `0x7aA89B1CBC571a1c6F7E6B262E06e614104Fb56d` |
| StakeRegistry | `0xac89f540a78313aE126fd95cc9e1eb82503b824A` |

Run the live integration tests (they fork Sepolia; they **skip** unless `SEPOLIA_RPC_URL` is set, so
default `forge test` is unaffected):

```bash
SEPOLIA_RPC_URL=https://ethereum-sepolia.publicnode.com \
  forge test --match-contract SepoliaLiveTest -vv
```

They read the live consumer and wire `GuardedVault` to the **real on-chain** `BLSSignatureChecker`,
showing `verifyAndUpdate` is gated by it.

**Full submission, wired to the real AVS.** [`script/live/`](./script/live/) assembles every
`verifyAndUpdate` argument from the live EigenLayer registry (`OperatorStateRetriever` +
`BLSApkRegistry`) — leaving only the operator BLS signature `(sigma, apkG2)`, which the AVS's existing
operator set produces. `test/live/SepoliaSubmit.t.sol` proves this against the live chain: with a
placeholder signature, the real checker accepts every assembled field and reverts **only** at
`InvalidBLSSignature` (not `InvalidQuorumApkHash`). See the integration runbook in
[`script/live/README.md`](./script/live/README.md) for how to plug in the signature and go live.

To deploy an example wired to the real checker:

```bash
AVS_ADDRESS=0x2015983cDd409B1838F4C1cCa9085c946C5A9F81 \
SIG_CHECKER_ADDRESS=0x22FfcFD8cCCb2e70dbd6FE1DAf951080595E02f2 \
  forge script script/DeployGuardedVault.s.sol --rpc-url $SEPOLIA_RPC_URL --private-key $PK --broadcast
```

### Driving it via the hosted aggregator

There **is** a hosted operator service at `https://testnet.gaskiller.xyz`, which runs the whole
pipeline for a deployed consumer: simulate the call, compute the diff, and have the operator quorum
BLS-sign it. The client [`script/live/gk-trigger.sh`](./script/live/gk-trigger.sh) wraps it:

```bash
GK_API_KEY=<your key> ./script/live/gk-trigger.sh \
  0xa44724d3781575d26b1809817f1b4b73d6492b01 "settle(address[],int256[])" "[]" "[]" --watch
```

**Two upstream changes make older instructions wrong — both re-verified against the live service:**

1. **Auth changed.** The shared `INGRESS_PASSWORD` bearer token is retired; ingress now takes a
   per-client API key. The old token is rejected exactly like no credential at all
   (`401 {"error":{"code":"UNAUTHORIZED"}}`), so you must ask the operators to mint you a key.
2. **Submission changed.** The aggregator no longer broadcasts `verifyAndUpdate` for you. Upstream it
   **renders a ready-to-sign payload** (`POST /tasks` → poll `GET /tasks/{id}` → `{to, data, value,
   estimated_gas, valid_until_block}`) and **the caller submits it**, within roughly a 50-block
   expiry. `gk-trigger.sh` implements that flow (set `GK_SUBMIT_KEY` to auto-send) and falls back to
   the deprecated `/trigger` alias when a deployment predates it.

The hosted testnet is currently **mid-migration**: it already serves the new error envelope and the new
per-key auth, but does not yet expose `/tasks`. It also remains **BLS**, not Schnorr. Earlier
"`stateTransitionCount` 14 → 15" results in this repo were produced under the old broadcasting model and
are not reproducible with the retired credential. The full API contract and the deploy-and-wire steps
are in [`docs/LIVE-INTEGRATION.md`](./docs/LIVE-INTEGRATION.md).

## Finding storage slots

The crux of building a diff is targeting the right slot. Never guess — read the layout and verify it:

```bash
forge inspect src/examples/onchain-life/OnchainLife.sol:OnchainLife storage-layout
```

`OffchainPayloadBuilder` provides the slot math (`simpleSlot`, `mappingSlot`, `dynamicArraySlot`,
`dynamicArrayLengthSlot`, bit-packing helpers), and its self-test round-trips each helper against real
Solidity layout with `vm.store` / `vm.load`. In your own tests, verify a computed slot with
`vm.load(addr, slot)` before trusting it.

## Layout

```
src/examples/<name>/         the two example contracts
test/helpers/                OffchainPayloadBuilder (slot math + payload), BenchmarkBase
test/mocks/                  MockBLSSignatureChecker (passes/fails the 66% quorum; no crypto)
test/exposed/                per-example subclasses exposing the diff applier for gas isolation
test/examples/               *.t.sol (unit + equivalence + verifyAndUpdate) and *.bench.t.sol
script/                      Deploy<Example>.s.sol + DeployMockBLS.s.sol
script/e2e/                  real-analyzer end-to-end (run-guarded-vault-e2e.sh + SubmitDiff.s.sol)
tools/diff-extractor/        Rust wrapper around the real Gas Killer analyzer (tx -> encoded diff)
```
