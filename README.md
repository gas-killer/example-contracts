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

> 📖 **Integrating the SDK into your own contract?** The guide is the
> [Solidity Reference](https://gaskiller.xyz/docs/solidity/integrate) in the Gas Killer docs —
> installation, the addresses to configure, `trackState` semantics, storage-layout rules, and a
> revert-selector lookup table. This repo is its worked-examples companion, and defers to it rather
> than restating it.

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

## The three examples

All share the one property Gas Killer actually rewards: **expensive computation that collapses to a
small storage diff.** Cost scales with compute; settlement scales with bytes changed.

| Example | What it does | SDK features |
|---|---|---|
| [`OnchainLife`](./src/examples/onchain-life/OnchainLife.sol) | Conway's Game of Life on a 64×64 board, fully on-chain. One generation costs 16.9M gas; two exceed a block. | packed-bitmap `STORE`, `LOG2` |
| [`GuardedVault`](./src/examples/guarded-vault/GuardedVault.sol) | Vault that re-validates an expensive **global invariant** on every transition — proven off-chain *before* the state lands | mapping `STORE`, `LOG1`, invariant guard |
| [`Quicksort`](./src/examples/algo/sort/Quicksort.sol) + [`SortedOracle`](./src/examples/sorted-oracle/SortedOracle.sol) | A `pure` sort that touches no storage at all, and the oracle that settles its result as six words. Ordered input drives it to O(N²) — 400 values exceed a block. | zero-op `pure` compute, 6× `STORE`, `LOG2`, commitment + calldata witness |

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

**Quicksort + SortedOracle — the compute doesn't just shrink in the diff, it disappears from it:**

A Gas Killer payload carries only `STORE` / `LOG*` / `CALL` / `CREATE` ops, so a `pure` function
contributes **zero** to settlement — not a small constant, zero, at every N. What settles is the
consumer's six-word commit:

| observations | naive commit | Gas Killer settlement | factor |
|---|---|---|---|
| 250 | 1.5M | ~305k | 5× |
| 1,000 | 6.4M | ~305k | 22× |
| 5,000 | 36.1M (**> 30M block**) | ~305k | 124× |

The sharper number is about *input order*, not size. `Quicksort` uses a last-element pivot, so an
already-ascending array degrades to O(N²) — and a steadily rising price feed produces exactly that. At
N=400 the same commit costs **2.4M gas** in random order and **34.9M** in ascending order, which does not
fit in a block. The settlement is byte-identical either way. On-chain, the algorithm's worst case is a
denial-of-service surface reachable with ordinary data; off-chain it is a scheduling detail.

**Below ~30 observations, don't use Gas Killer for this** — the settlement floor dominates. (For
GuardedVault the same crossover sits at ~66 depositors; the sort's is earlier because its naive side is
superlinear.)

**Below ~66 depositors, don't use Gas Killer for this** — the ~300k settlement floor dominates and a plain
on-chain check is cheaper. Two further caveats stated up front: this settle conserves total shares, so the
invariant is reducible to an `O(K)` check over the touched accounts (also cheaper), and GuardedVault
therefore illustrates the *pattern* rather than proving this invariant needs it. See the report.

> **The honest limit.** A bulk airdrop and a sorted leaderboard were also built here and **removed** after
> measuring as *losses* (25.2M → 30.7M and 24.5M → 36.8M). Both write a diff proportional to the work, so
> there's no compute to collapse and you pay quorum overhead on top. If your diff scales with your
> computation, this is the wrong tool.
>
> **And yes — a sorted leaderboard was removed, then a sort was added.** That is the lesson, not a
> contradiction. `OnchainLeaderboard` *stored the sorted array*, so its diff was O(N) and Gas Killer made
> it worse. `SortedOracle` runs the same class of computation and stores a **commitment** to the sorted
> order plus four order statistics — six words, whatever N is. Identical algorithm, opposite verdict,
> decided entirely by what you choose to write. If you need the full order on-chain, hand it back as a
> calldata witness and check it against the commitment (`isCommittedOrder`) rather than storing it.

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

## Using the REAL Gas Killer analyzer

The Solidity tests build the diff in Solidity (`OffchainPayloadBuilder`) so `forge test` stays fast and
offline. That pins the *apply* path; it says nothing about extraction.

Extraction belongs to [gas-analyzer](https://github.com/gas-killer/gas-analyzer) and is tested there —
`crates/core/src/prestate.rs` holds the net-diff encoding the service signs. The two halves meet in the
service repo, whose [`scripts/examples`][harness] harness builds a manifest of these contracts, deploys
them against a running AVS, and drives tasks through the router: the analyzer produces the diff, a real
operator quorum signs it, and `verifyAndUpdate` lands it on chain. That manifest names `OnchainLife`
and `GuardedVault`; `SortedOracle` is not in it yet.

## Live on Sepolia testnet

A real Gas Killer AVS stack is deployed on **Sepolia (chain 11155111)**.

**The addresses live in [Configuration](https://gaskiller.xyz/docs/solidity/configuration).** They
belong to a particular AVS deployment rather than to this repo, and a target wired to a superseded
`BLSSignatureChecker` produces payloads that cannot settle — so they are maintained in one place, with a
`cast call` recipe there for checking a value is still current. Export them before running anything below:

```bash
export AVS_ADDRESS=...          # from the docs
export SIG_CHECKER_ADDRESS=...  # from the docs
```

These examples are exercised against a real AVS from the service repo, not from here. Its
[`scripts/examples`][harness] harness builds this repo's artifacts, deploys them wired to a running
AVS, and drives real tasks through the router until `stateTransitionCount` advances on chain, checked
in that repo's CI on every push. `forge test` here is offline and deterministic.

Which examples that covers is set by the harness manifest — see
[Using the REAL Gas Killer analyzer](#using-the-real-gas-killer-analyzer) above.

[harness]: https://github.com/gas-killer/service/tree/main/scripts/examples

Of the values a `verifyAndUpdate` call carries, only the aggregate signature `(sigma, apkG2)` needs
operator keys. Everything else anyone can produce: the storage diff from an off-chain trace of the
tracked function, the remainder from public on-chain reads. [Where each argument comes
from](https://gaskiller.xyz/docs/solidity/reference#where-each-argument-comes-from) has the breakdown.

To deploy an example wired to the real checker:

```bash
forge script script/DeployGuardedVault.s.sol --rpc-url $SEPOLIA_RPC_URL --private-key $PK --broadcast
```

### Driving it via the hosted aggregator

A hosted operator service at `https://testnet.gaskiller.xyz` runs the whole pipeline for a deployed
consumer: simulate the call, compute the diff, and have the operator quorum BLS-sign it. It returns a
ready-to-sign `verifyAndUpdate` transaction, which **you** submit.

**The API contract is in the docs** — [Quickstart](https://gaskiller.xyz/docs/quickstart) for the
submit/poll/settle flow, and the [API Reference](https://gaskiller.xyz/docs/api/tasks/submitTask) for
every field, status code and error. Requests are authenticated with a per-client API key minted by the
operators.

### Status — what is and isn't verified

- ✅ **On-chain application is proven** for all three examples: the real SDK applies the operator's
  diff via `verifyAndUpdate`, reproducing naive state and events byte-for-byte (`test/examples/`,
  offline, with a hand-built diff and a mocked quorum).
- ✅ **On-chain wiring and settlement** are verified from the service repo: its `scripts/examples`
  harness deploys the examples its manifest names — `OnchainLife` and `GuardedVault` — against a
  running AVS and asserts `stateTransitionCount` advances, which is a real `BLSSignatureChecker`
  accepting a real aggregated signature. `SortedOracle` is not in that manifest yet.
- ⚠️ **No end-to-end run through the hosted service is currently reproducible**, because the
  credential documented previously is retired and we hold no replacement API key. Earlier rounds
  *did* land under the old broadcasting model (e.g. `stateTransitionCount` 0 → 1 on GuardedVault),
  but those runs predate both points above and should not be presented as reproducible today.

## Finding storage slots

The crux of building a diff is targeting the right slot. Never guess — read the layout and verify it
(see also [Tracked functions](https://gaskiller.xyz/docs/solidity/tracked-functions) on why layout is
part of your interface with a signed payload):

```bash
forge inspect src/examples/onchain-life/OnchainLife.sol:OnchainLife storage-layout
```

`OffchainPayloadBuilder` provides the slot math (`simpleSlot`, `mappingSlot`, `dynamicArraySlot`,
`dynamicArrayLengthSlot`, bit-packing helpers), and its self-test round-trips each helper against real
Solidity layout with `vm.store` / `vm.load`. In your own tests, verify a computed slot with
`vm.load(addr, slot)` before trusting it.

## Layout

```
src/examples/<name>/         the example contracts
src/examples/algo/<kind>/    reusable algorithm primitives (pure, no storage, no SDK)
test/helpers/                OffchainPayloadBuilder (slot math + payload), BenchmarkBase
test/mocks/                  MockBLSSignatureChecker (passes/fails the 66% quorum; no crypto)
test/exposed/                per-example subclasses exposing the diff applier for gas isolation
test/examples/               *.t.sol (unit + equivalence + verifyAndUpdate) and *.bench.t.sol
script/                      Deploy<Example>.s.sol + DeployMockBLS.s.sol
```
