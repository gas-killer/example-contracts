# Gas Killer — what it actually buys you

Two example contracts, both deliberately "dumb expensive": the kind of thing you'd sketch on a whiteboard,
realise costs more than a block, and abandon. Gas Killer makes them shippable.

The mechanism in one line: **an operator quorum runs the expensive function off-chain, and submits only the
resulting storage diff.** The chain pays to *apply a result*, never to *compute it*.

Every number below is measured — `forge test --match-path 'test/examples/*.bench.t.sol' -vv`, SDK `79d3716`.
Read [Methodology & caveats](#methodology--caveats) before quoting them.

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
| 1  | 16,862,218  | 46,386 | 296,386 | 16.6M  | **57×** |
| 2  | 33,632,923  | 46,514 | 296,514 | 33.3M  | **113×** |
| 4  | 67,159,671  | 46,642 | 296,642 | 66.9M  | **226×** |
| 8  | 134,102,442 | 46,769 | 296,769 | 133.8M | **451×** |
| 16 | 267,694,767 | 46,896 | 296,896 | 267.4M | **901×** |

Look at the apply column: **46,386 → 46,896 across a 16× increase in compute.** That's +510 gas total, and
it's just the generation counter holding a bigger number. The cost of settling 16 generations is
indistinguishable from settling 1.

Naive grows linearly and forever. Gas Killer is **flat**. So the savings factor isn't a fixed discount —
it *doubles every time you double the work*, without limit.

### The part that isn't about money

At 2 generations the naive path stops being expensive and starts being **impossible** — it cannot fit in a
block at any price. Gas Killer settles 16 generations for ~297k gas, comfortably inside one. The win isn't
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
| Apply diff | 15,517 |
| **Gas Killer (prod. est.)** | **265,517** |
| **Saving** | **36,975,752 — 140×** |

Because the diff is always "two share slots + one log", the apply cost is **independent of depositor
count**, while the naive cost scales linearly:

| Depositors | Naive guard | Gas Killer | Factor |
|---:|---:|---:|---:|
| 1,000 | 4,658,626 | 265,517 | 17.5× |
| 2,000 | 9,307,620 | 265,517 | 35.1× |
| 3,000 | 13,956,620 | 265,517 | 52.6× |
| 8,000 | 37,201,620 | 265,517 | **140.1×** |

**Break-even is ~57 depositors.** Below that the ~265k fixed quorum cost dominates and you should just do it
on-chain. Above it, the advantage compounds linearly and never stops.

---

## Why this is the right shape of problem

Both winners share one property:

> **Expensive computation that collapses to a small storage diff.**

Life: millions of gas of neighbour-counting → 16 words. GuardedVault: an O(N) invariant sweep → 2 slots.
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
3. **Cold vs warm storage matters enormously.** All figures quoted here use vaults seeded in `setUp` — a
   separate transaction — so reads are cold (2,100 gas), matching a real transaction. Seeding in the same
   transaction makes reads warm (100 gas) and *understates* naive cost by ~7×. The warm-seeded sweep in
   `GuardedVault.bench.t.sol` is labelled as a lower bound for that reason.
4. **Gas is measured with `gasleft()` deltas**, not snapshot cheatcodes, which proved unreliable here.
5. **The trust model is crypto-economic.** There is no on-chain re-execution, no fraud proof, and no
   slashing. Correctness rests on the honest-supermajority quorum. See [`SECURITY.md`](../SECURITY.md) —
   for GuardedVault in particular, the invariant guarantee is only as good as the operator set.
