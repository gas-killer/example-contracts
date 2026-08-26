# Gas Killer — what it actually buys you

Two example contracts, both deliberately "dumb expensive": the kind of thing you'd sketch on a whiteboard,
realise costs more than a block, and abandon. Gas Killer makes them shippable.

The mechanism in one line: **an operator quorum runs the expensive function off-chain, and submits only the
resulting storage diff.** The chain pays to *apply a result*, never to *compute it*.

**The settlement cost is anchored in a real transaction, not a model.** One of these contracts has
actually settled on Sepolia through the live operator quorum:

> **[`0x865bf3ab…fb7c`](https://eth-sepolia.blockscout.com/tx/0x865bf3ab1d23566bce98261c1096822fb9a7ff8a52fbd07da9b5e804ec17fb7c)**
> — a real `verifyAndUpdate` on our `GuardedVault`, **300,944 gas**, block 11130649. Tracing it
> (`debug_traceTransaction`) splits that into **224,827 gas of BLS signature verification** and 76,117
> for everything else (tx base, calldata, applying the diff, the transition counter).

That **224,827** is the number that used to be a 250,000-gas guess. It is fixed — it does not care how
much computation the operators did off-chain — which is the whole reason the economics work.

Naive figures come from `forge test --match-path 'test/examples/*.bench.t.sol' -vv`; diff-apply figures
from `forge test --match-contract ColdApplyMeasure -vv` (production-shaped storage), SDK `79d3716`.
**Read [Methodology & caveats](#methodology--caveats) before quoting any of them.**

---

## 1. OnchainLife — Conway's Game of Life, fully on-chain

### What it does

A 64×64 toroidal Life board (4,096 cells) packed into `uint256[16]`, one bit per cell. `step(generations)`
recomputes all 8 neighbours of all 4,096 cells, per generation — `O(generations × 4096 × 8)` — then writes
the board back and emits `GenerationStepped`.

### Why you'd never ship it

**One** generation costs **16.9M gas**. **Two** costs **33.6M** — past a 30M mainnet block. The contract is
literally unshippable beyond a single step. This is the autonomous-worlds problem in miniature: on-chain
simulation is the thing everyone wants and nobody can afford.

### Why Gas Killer is the perfect fit

The board is only ever **16 words**. However much compute you pour in, the *result* is 16 words plus a
generation counter plus one log. Compute explodes; the diff doesn't move. That gap is the entire product.

### The numbers

OnchainLife has not itself settled on-chain, so its settlement cost is *built up* from the measured
pieces: real BLS verification (224,827) + tx base (21,000) + calldata (~20k) + its measured diff-apply
(128,915) + the transition counter ≈ **~400,000 gas**.

| Generations | Naive on-chain | Gas Killer settlement | Saving | Factor |
|---:|---:|---:|---:|---:|
| 1  | 16,862,218  | ~400,000 | 16.5M  | **42×** |
| 2  | 33,632,923  | ~400,000 | 33.2M  | **84×** |
| 4  | 67,159,671  | ~400,000 | 66.8M  | **168×** |
| 8  | 134,102,442 | ~400,000 | 133.7M | **335×** |
| 16 | 267,694,767 | ~400,000 | 267.3M | **669×** |

The settlement column is the point: it **does not move at all** as compute grows 16×. The board is 16
words whether the operator ran one generation or sixteen, so settling 16 generations costs the same as
settling one.

Naive grows linearly and forever. Gas Killer is **flat**. So the savings factor isn't a fixed discount —
it *doubles every time you double the work*, without limit.

### The part that isn't about money

At 2 generations the naive path stops being expensive and starts being **impossible** — it cannot fit in a
block at any price. Gas Killer settles 16 generations for ~400k gas, comfortably inside one. The win isn't
"cheaper", it's "possible at all".

---

## 2. GuardedVault — prove the invariant *before* the state lands

### What it does

A share vault with a concentration rule: no depositor may hold more than `maxConcentrationBps` of total
shares. `settle(users, deltas)` rebalances — and re-validates the invariant across **every** depositor, an
`O(N)` sweep, in the same transaction.

### Why you'd never ship it

The guard is the cost. Re-checking the invariant runs **4,659 gas per depositor**:

| Depositors | `checkInvariant` gas |
|---:|---:|
| 1,000 | 4,658,626 |
| 2,000 | 9,307,620 |
| 3,000 | 13,956,620 |
| 8,000 | **37,201,620** ← exceeds a 30M block |

So a real vault faces the usual miserable trade: check the invariant and blow the block, or skip it and
hope. Most protocols skip it, then write an incident report.

### Why Gas Killer is the perfect fit

This is the subtle one, and it's the more interesting example.

The operator runs `settle` off-chain, **applies the diff to simulated state, runs the full invariant on the
result, and only signs if it holds.** A violating settle reverts in simulation, so no valid diff is ever
produced — an honest operator has nothing to sign.

You get the guarantee of an expensive on-chain check while paying only to apply two share slots. The
invariant is enforced *before* anything lands, not verified after.

### The numbers

At 8,000 depositors — a settle moving 200 shares between two accounts:

| | Gas |
|---|---:|
| Naive guarded settle | **37,241,269** (doesn't fit in a block) |
| **Gas Killer settlement (real, measured on Sepolia)** | **300,944** |
| of which: BLS signature verification | 224,827 |
| **Saving** | **36,940,325 — 124×** |

That settlement figure is not modelled — it is the gas a real `verifyAndUpdate` for this contract
actually burned on Sepolia. A 2-account settle writes one more slot than the landed transaction did,
so budget ~306,000; the tables below use that.

Because the diff is always "two share slots + one log", the apply cost is **independent of depositor
count**, while the naive cost scales linearly:

| Depositors | Naive guard | Gas Killer settlement | Factor |
|---:|---:|---:|---:|
| 1,000 | 4,658,626 | ~306,000 | 15.2× |
| 2,000 | 9,307,620 | ~306,000 | 30.4× |
| 3,000 | 13,956,620 | ~306,000 | 45.6× |
| 8,000 | 37,201,620 | ~306,000 | **121.6×** |

**Below ~66 depositors, do not use Gas Killer for this.** The ~300k settlement floor — nearly all of it
signature verification — dominates, and a plain on-chain check is cheaper. The mechanism only starts to
make sense above that crossover, and the advantage then grows linearly with N. We would rather you learn
that here than after integrating.

### The baseline objection — stated before you raise it

A sharp reader will notice that `settle` already reverts unless the deltas net to zero. `totalShares` is
therefore unchanged, so the concentration `cap` is unchanged, conservation holds by construction, and the
solvency check is O(1). It follows that **only the accounts the settle touched can newly breach the cap** —
so this particular invariant is reducible to an `O(K)` check over the K touched accounts, costing on the
order of tens of thousands of gas. That is **cheaper than routing it through Gas Killer.**

So the 137× above is measured against a deliberately naive baseline, and we are not going to pretend
otherwise. What GuardedVault actually demonstrates is the **pattern** — settle only what an operator has
already proven, and keep the proof off-chain — not that this specific invariant needs it.

The pattern pays when the invariant is *genuinely irreducible*: it depends on global state a settle can
change (so the cap moves), or on an aggregate with no incremental form (top-k concentration, a sort, a
graph traversal, a risk model over all positions). If your invariant can be maintained incrementally,
write the `O(K)` version — it will beat this. Treat the GuardedVault numbers as an illustration of the
mechanism's shape, and substitute your own invariant's real cost before drawing a conclusion.

---

## Why this is the right shape of problem

Both winners share one property:

> **Expensive computation that collapses to a small storage diff.**

Life: millions of gas of neighbour-counting → 16 words. GuardedVault: an O(N) invariant sweep → 2 slots
(with the baseline caveat above).
Cost scales with *compute*; settlement scales with *bytes changed*. Gas Killer arbitrages that gap.

The corollary is the honest limit, and it's worth stating plainly. Two other examples were built and
**deliberately removed** from this repo because they measured as losses: a bulk airdrop (25.2M naive →
30.7M via Gas Killer) and a sorted leaderboard (24.5M → 36.8M). Both write a diff proportional to the work
done — there's no compute to collapse, so you pay to write the same words *plus* quorum overhead. Gas Killer
made them **worse**.

If your diff scales with your computation, this is the wrong tool. If your computation dwarfs your diff,
the savings are unbounded.

---

## Verification

Correctness isn't assumed, but the halves are established in different places.

Here, every benchmark asserts **equivalence**: running the naive function and applying the operator's
diff through the **real SDK** `verifyAndUpdate` produce byte-identical storage (slot by slot, via
`vm.load`) and identical events in emission order (`vm.recordLogs`). The diff is hand-built by
`OffchainPayloadBuilder`, so this pins the apply path — the half these gas numbers are about.

That the **real analyzer** derives the same diff is verified from the service repo, which runs these
contracts through the analyzer and a live operator quorum.

`test_blinker_knownOracle` is the independent check on the naive computation itself: a Conway blinker
must rotate after one step, asserted through `getCell` rather than through the diff path.

---

## Methodology & caveats

Stated plainly, because the headline numbers depend on them.

1. **Signature-verification cost is now measured, not estimated.** Earlier drafts added a 250,000-gas
   guess. The figure used here, **224,827**, comes from tracing a real Sepolia `verifyAndUpdate`
   (`0x865bf3ab…fb7c`) and reading the gas of the `BLSSignatureChecker` sub-call — the bulk of which is
   the BN254 pairing precompile (113,000). The repo's test constant `BLS_VERIFY_FIXED_GAS = 250,000`
   remains a deliberately conservative over-estimate for assertions.
2. **One contract's settlement is real; the other's is derived.** GuardedVault's 300,944 is an actual
   on-chain transaction. OnchainLife never settled on-chain (its 16.8M-gas simulation exceeded what the
   operator's tracer could handle at the time), so its ~400,000 is built from measured parts and is
   labelled as such wherever it appears. The Solidity tests themselves use a mock signature checker.
3. **Storage pricing — read this one carefully.** Under EIP-2200/2929 a slot whose value was zero at the
   *start of the transaction* is a "dirty" slot and costs 100 gas to write, versus 5,000 for overwriting a
   committed non-zero word. The `.bench.t.sol` suites deploy the apply target inside the transaction they
   measure, which takes that discount and **understates apply cost by 2.8×** (OnchainLife: 45,915 measured
   in-transaction vs **128,915** production-shaped). The apply/Gas Killer/Saving/Factor figures quoted
   above are the **production-shaped** ones, measured against a target deployed in a prior transaction —
   see `test/ColdApplyMeasure.t.sol`, which pins both numbers side by side. The naive columns come from
   `setUp`-seeded (cold) vaults; the in-transaction warm sweep in `GuardedVault.bench.t.sol` is labelled a
   lower bound for the same reason.
4. **Gas is measured with `gasleft()` deltas**, not snapshot cheatcodes, which proved unreliable here.
5. **The trust model is crypto-economic.** There is no on-chain re-execution, no fraud proof, and no
   slashing. Correctness rests on the honest-supermajority quorum. See [`SECURITY.md`](../SECURITY.md) —
   for GuardedVault in particular, the invariant guarantee is only as good as the operator set.
