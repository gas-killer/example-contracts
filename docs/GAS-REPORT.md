# Gas Killer — what it actually buys you

Two example contracts, both deliberately "dumb expensive": the kind of thing you'd sketch on a whiteboard,
realise costs more than a block, and abandon. Gas Killer makes them shippable.

The mechanism in one line: **an operator quorum runs the expensive function off-chain, and submits only the
resulting storage diff.** The chain pays to *apply a result*, never to *compute it*.

Every number below is measured on SDK `79d3716`. Naive figures come from
`forge test --match-path 'test/examples/*.bench.t.sol' -vv`; apply figures come from
`forge test --match-contract ColdApplyMeasure -vv`, which measures against production-shaped storage.
**Read [Methodology & caveats](#methodology--caveats) before quoting any of them** — caveat 3 in
particular explains why the two commands disagree by 2.8×.

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

| Generations | Naive on-chain | Apply diff | Gas Killer (prod. est.) | Saving | Factor |
|---:|---:|---:|---:|---:|---:|
| 1  | 16,862,218  | 128,915 | 378,915 | 16.5M  | **44×** |
| 2  | 33,632,923  | 128,915 | 378,915 | 33.3M  | **89×** |
| 4  | 67,159,671  | 128,915 | 378,915 | 66.8M  | **177×** |
| 8  | 134,102,442 | 128,915 | 378,915 | 133.7M | **354×** |
| 16 | 267,694,767 | 128,915 | 378,915 | 267.3M | **706×** |

The apply column is the point: it **does not move at all** as compute grows 16×. The board is 16 words
whether the operator ran one generation or sixteen, so settling 16 generations costs the same as settling
one.

Naive grows linearly and forever. Gas Killer is **flat**. So the savings factor isn't a fixed discount —
it *doubles every time you double the work*, without limit.

### The part that isn't about money

At 2 generations the naive path stops being expensive and starts being **impossible** — it cannot fit in a
block at any price. Gas Killer settles 16 generations for ~379k gas, comfortably inside one. The win isn't
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
| Apply diff | 21,396 |
| **Gas Killer (prod. est.)** | **271,396** |
| **Saving** | **36,969,873 — 137×** |

Because the diff is always "two share slots + one log", the apply cost is **independent of depositor
count**, while the naive cost scales linearly:

| Depositors | Naive guard | Gas Killer (prod. est.) | Factor |
|---:|---:|---:|---:|
| 1,000 | 4,658,626 | 271,396 | 17.2× |
| 2,000 | 9,307,620 | 271,396 | 34.3× |
| 3,000 | 13,956,620 | 271,396 | 51.4× |
| 8,000 | 37,201,620 | 271,396 | **137.1×** |

**Break-even is ~58 depositors.** Below that the fixed quorum cost dominates and you should just do it
on-chain. Above it, the advantage compounds linearly.

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

Correctness isn't assumed. For both examples the pipeline is proven end-to-end:

- The **real analyzer** extracts the diff from a live trace.
- The extracted hex goes through the **real SDK** `verifyAndUpdate`.
- The result is asserted **byte-identical** to running the naive function — storage slot by slot, and
  events in emission order.

`script/e2e/run-prestate-e2e.sh` does exactly this on a local anvil for both contracts. On-chain state and
event streams match the naive execution exactly.

---

## Methodology & caveats

Stated plainly, because the headline numbers depend on them.

1. **`+250,000 gas` for BLS verification is an estimate, not a measurement.** The tests use a mock
   signature checker that does no cryptography. It's a documented constant (`BLS_VERIFY_FIXED_GAS`) added to
   every apply-diff figure to approximate production. It is **constant in N**, so it shifts the absolute
   numbers but never the shape of the curves.
2. **Not measured against the live hosted service.** These are local runs against the real SDK and real
   analyzer with a mocked quorum. Real operator signature verification is not included.
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
