# Gas Killer — what it actually buys you

Three worked examples, all deliberately "dumb expensive": the kind of thing you'd sketch on a whiteboard,
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

Naive figures come from `forge test --match-path 'test/**/*.bench.t.sol' -vv` (the `algo/` suites sit in a
nested directory, so a single-level glob misses them); OnchainLife's diff-apply figure from
`forge test --match-contract ColdApplyMeasure -vv` (production-shaped storage), SDK `79d3716`.
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

## 3. Quicksort + SortedOracle — pure computation, priced at zero

### What it does

[`Quicksort`](../src/examples/algo/sort/Quicksort.sol) is a `pure` in-memory quicksort: an iterative
Lomuto implementation with an explicit stack and a last-element pivot. It touches no storage, emits no
logs and makes no external calls. [`SortedOracle`](../src/examples/sorted-oracle/SortedOracle.sol) is
the consumer that gives it something to settle: reporters push observations on-chain, and `commit()`
reads all N back, sorts them, and writes **six words** — a commitment to the sorted order plus min,
median, p95, max and an epoch counter — then emits one event.

### Why you'd never ship it

Two reasons, and the second is the interesting one.

**Size.** Sorting is superlinear, so the cost runs away on its own. 8,000 random values cost **44.9M
gas** to sort — before any storage is involved. Through `SortedOracle`, where each observation also
costs a cold 2,100-gas `SLOAD` to read back, a commit stops fitting in a 30M block just past **4,000
observations**.

**Input order.** A last-element pivot degrades to O(N²) on input that is already ascending. That is not
an exotic adversarial construction — *a steadily rising price feed produces it*. The same 400
observations cost **2.4M gas** in random order and **34.9M** in ascending order: the second does not fit
in a block. On-chain, that is a denial-of-service surface a reporter can trigger without submitting
anything that looks anomalous. A production on-chain sort would need median-of-three and an
insertion-sort cutoff purely to defend itself.

### Why Gas Killer is the perfect fit

This is the cleanest case in the repo, because the expensive part is not merely *small* in the diff —
it is **absent** from it.

A Gas Killer payload can carry only `STORE`, `LOG*`, `CALL` and `CREATE` operations, and the analyzer
prices exactly those (`gas-analyzer/crates/core/src/heuristic.rs`). Memory traffic, arithmetic,
comparisons and jumps have no representation in a payload at all. A pure algorithm therefore has a
settlement cost of **zero** — not a small constant, zero. `test_settlementContributionIsZeroAtEveryN`
asserts it directly: sorting 4,000 values burns ~21M gas on-chain and produces zero payload operations.

So the pivot's worst case stops being a security problem and becomes a scheduling detail. The operator
quorum absorbs 209M gas of work at N=1,000 on ordered input; the chain sees the same six-word diff it
would have seen for random input, byte for byte.

### The numbers

**The pure sort — on-chain cost vs. settlement contribution:**

| N | random input | ascending input | payload ops | settlement |
|---:|---:|---:|---:|---:|
| 250 | 823,893 | — | 0 | 0 |
| 500 | 1,834,442 | 52,739,483 | 0 | 0 |
| 1,000 | 4,023,329 | 209,737,475 | 0 | 0 |
| 2,000 | 8,880,539 | — | 0 | 0 |
| 4,000 | 20,950,162 | — | 0 | 0 |
| 8,000 | 44,940,960 | — | 0 | 0 |

Ascending input crosses a 30M block at **N=400** (33,850,939). Random input does not cross until somewhere
between 4,000 and 8,000 — an order of magnitude larger N, from nothing but the order the data arrived in.

**SortedOracle — the commit that settles it.** Observations are seeded in a prior transaction, so the
naive column pays production-rate cold reads; the apply column is measured against a target that had
already committed once, so its six words are overwrites rather than first-ever writes:

| Observations | Naive commit | Apply diff | + BLS (est.) | Factor |
|---:|---:|---:|---:|---:|
| 250 | 1,504,581 | 41,288 | 291,288 | 5× |
| 500 | 2,932,317 | 41,312 | 291,312 | 10× |
| 1,000 | 6,426,141 | 41,337 | 291,337 | 22× |
| 2,000 | 13,782,897 | 41,362 | 291,362 | 47× |
| 4,000 | 29,284,997 | — | — | — |
| 5,000 | 36,102,123 (**> 30M block**) | 41,286 | 291,286 | 124× |

The 4,000-observation row is a naive-only measurement, included because it brackets the block limit from
below; no apply was metered at that size.

And the same table for input order rather than size, at a fixed N=400:

| Input order | Naive commit | Apply diff |
|---|---:|---:|
| random | 2,396,231 | 41,310 |
| ascending | 34,923,914 (**> 30M block**) | 41,119 |

The apply column is the point. It does not move with N, and it does not move with how hard the sort
was. `test_applyCostIsIdenticalAcrossN` pins the strong form of that claim: payloads built from a
250-observation commit and a 2,000-observation commit apply for **41,119 gas each — identical to the
unit**, not merely similar. The encoded payload is 1,376 bytes in every case, because every argument
in it is fixed-width.

**Production settlement, derived.** SortedOracle has not settled on-chain, so — as with OnchainLife —
its figure is built from measured parts: real BLS verification (224,827) + tx base (21,000) + calldata
for the 1,376-byte payload and `verifyAndUpdate`'s other arguments (~12,000) + the measured
production-shaped apply (41,119) + the transition counter (~5,000) ≈ **~305,000 gas**.

On "six words": that is the *consumer's* contribution to the diff, and it is what the payload carries. The
settlement transaction writes one slot more — the SDK's own `trackState` transition counter, in its
ERC-7201 namespace — which is why the derivation above has a separate line for it.

A never-committed oracle pays more for its *first* settlement — 144,021 to apply instead of 41,119 —
because each of the six words takes the zero-to-non-zero `SSTORE` path once. Steady state is the figure
above.

**Where the crossover is.** Measured against that ~305,000 floor, a plain on-chain commit is cheaper up
to about **30 observations** (N=25 costs 289,702; N=50 costs 403,311). Above that the advantage grows
superlinearly, because the naive side is superlinear and the settlement side is flat. This is a much
earlier crossover than GuardedVault's ~66 depositors, for exactly that reason.

### The part that isn't about money

At N=400 with ordered input, and at N=5,000 with random input, the naive path stops being expensive and
becomes impossible — it cannot fit in a block at any gas price. More pointedly, the *first* of those is
reachable by ordinary well-behaved data. Gas Killer settles either one for ~305,000 gas, and the
algorithm's worst case becomes something the operator set schedules around rather than something an
attacker exploits.


---

## Why this is the right shape of problem

All three winners share one property:

> **Expensive computation that collapses to a small storage diff.**

Life: millions of gas of neighbour-counting → 16 words. GuardedVault: an O(N) invariant sweep → 2 slots
(with the baseline caveat above). SortedOracle: an O(N log N) sort — or O(N²) on ordered input — → 6 words.
Cost scales with *compute*; settlement scales with *bytes changed*. Gas Killer arbitrages that gap.

Quicksort sharpens the point to its limit. The other two examples collapse their computation into a *small*
diff; a `pure` function collapses it into **no diff at all**. Nothing an algorithm does in memory can appear
in a payload, so its settlement cost is not a small constant to be amortised — it is zero, at every N, for
every input. That is the ceiling of what this mechanism buys, and it is worth knowing where the ceiling is
before you design against it.

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
`OffchainPayloadBuilder`, so this pins the apply path — the half these gas numbers are about. That
holds for all three examples.

The naive computations have independent checks that do not run through the diff path:
`test_blinker_knownOracle` (a Conway blinker must rotate after one step, asserted via `getCell`),
`testFuzz_matchesReferenceSort` (Quicksort against a reference sort), and
`test_commit_knownOrderStatistics` (hand-computed order statistics).

That the **real analyzer** derives the same diff, and that a real operator quorum signs it, is verified
from the service repo. Its `scripts/examples/examples.toml` manifest names `OnchainLife` and
`GuardedVault`. `SortedOracle` is not in it, so the sort's settlement numbers rest on the Solidity
equivalence test alone; adding it to that manifest is outstanding work.

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
   committed non-zero word. The OnchainLife and GuardedVault `.bench.t.sol` suites deploy the apply target
   inside the transaction they measure, which takes that discount and **understates apply cost by 2.8×** (OnchainLife: 45,915 measured
   in-transaction vs **128,915** production-shaped). The apply/Gas Killer/Saving/Factor figures quoted
   above are the **production-shaped** ones, measured against a target deployed in a prior transaction —
   see `test/ColdApplyMeasure.t.sol`, which pins both numbers side by side. The naive columns come from
   `setUp`-seeded (cold) vaults; the in-transaction warm sweep in `GuardedVault.bench.t.sol` is labelled a
   lower bound for the same reason.
4. **Gas is measured with `gasleft()` deltas**, not snapshot cheatcodes, which proved unreliable here.
5. **SortedOracle's naive column is cold; its apply column is steady-state.** Its observations are
   seeded in `setUp` — a prior transaction — so `commit` pays the 2,100-gas cold `SLOAD` per observation
   a live oracle pays. Seeding them inside the measured transaction would leave them warm at 100 gas and
   understate the naive path by millions. Symmetrically, each apply measurement uses its own target that
   was deployed *and* committed in `setUp`: applying two diffs to one target would make the second write
   warm and dirty (100 gas instead of 5,000) and fake a flat curve out of a warmth artifact.
6. **Two apply measurements taken in sequence differ by a couple of hundred gas.** Every external call in
   a transaction allocates fresh memory to encode its calldata, so successive `gasleft()`-delta
   measurements carry allocation noise in either direction. It does not scale with N — with both payloads
   built before either is applied, a 250-observation diff and a 2,000-observation diff cost **41,119 gas
   each, identical to the unit** (`test_applyCostIsIdenticalAcrossN`). Where this report quotes a flat
   apply cost, that test is the claim; the sweep tables show the noise.
7. **The above-block-limit rows need a simulation profile that is not the default.** Any figure here
   whose *naive* cost exceeds ~30M — Quicksort at 209M on ordered input, the 36.1M `SortedOracle` commit,
   OnchainLife past one generation — can only be analyzed under `GK_SIM_PROFILE=unbounded`. The default is
   `GK_SIM_PROFILE=chain`, which simulates at the real block limit and cannot extract a diff from those
   calls at all. `unbounded` additionally requires a cap-lifted `debug_traceCall` RPC, pairs with
   `STATE_ENCODING=prestate-net`, is a coordinated fleet-wide flip (it changes the task digest), and has
   three open preconditions tracked in `gas-killer/service#356` — including an SP1 guest that would
   otherwise judge honest payloads invalid. Read these rows as what the mechanism buys once that profile
   ships. See [`SECURITY.md`](../SECURITY.md#what-gk_sim_profileunbounded-actually-requires).
8. **The trust model is crypto-economic.** There is no on-chain re-execution, no fraud proof, and no
   slashing. Correctness rests on the honest-supermajority quorum. See [`SECURITY.md`](../SECURITY.md) —
   for GuardedVault in particular, the invariant guarantee is only as good as the operator set.
