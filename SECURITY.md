# Security model & honest caveats

> **Status:** experimental, unaudited example code. Do not use in production.

These examples are designed to be *honest* about what Gas Killer does and does not give you. Read this
before using the pattern for anything real.

## What `verifyAndUpdate` actually checks

When an operator submits a storage diff, `GasKillerSDK.verifyAndUpdate` checks only:

1. the reference block is recent (`referenceBlockNumber < block.number` and within `blockStaleMeasure`,
   default 300 blocks);
2. the transition index is the next one (`transitionIndex + 1 == stateTransitionCount()`);
3. the message hash equals `sha256(transitionIndex, address(this), targetFunction, storageUpdates)`;
4. **≥ 66 % of the relevant EigenLayer quorum stake signed that hash** (BLS aggregate signature);

…and then it applies the diff with raw `sstore` / `call` / `log`.

That is the **entire** check. In particular:

- **There is no on-chain re-execution** of your computation. The chain never recomputes the result to
  see if the operator's diff is correct.
- **There is no fraud proof, no challenge window, and no bisection protocol.** A submission is final and
  instant once a quorum signs.
- **There is no slashing logic in the SDK or the AVS contracts.** Accountability rests entirely on the
  off-chain EigenLayer operator set and whatever slashing the AVS configures out of band.

So the security is **crypto-economic attestation under an honest-supermajority assumption**: if ≥ 66 %
of staked operators sign a wrong diff, the chain applies it and nothing on-chain can prove it was wrong.
This is a different (weaker, in the objective sense) guarantee than an optimistic rollup's fraud proofs
or a validity rollup's zk proofs.

## Three places the block gas limit still bites

A common misconception is "the computation is off-chain, so the block gas limit no longer applies."
That is only partly true. There are three distinct boundaries:

| Boundary | Bounded by the ~30M block limit? | Status today |
|---|---|---|
| On-chain re-execution for **objective slashing** | It *would* be (single-shot re-execution must fit a block; bisection could lift it) | **Not implemented** — there are no on-chain fraud proofs at all |
| **Off-chain simulation** by operators | Yes — the analyzer simulates with `tx.gas_limit = block.gas_limit`, so a function that out-of-gases at 30M can't be simulated/diffed either | Real constraint today |
| On-chain **diff application** | **Always** — applying *K* storage writes costs ≈ *K × 22k* gas plus a ~250k fixed floor, so a large diff must be chunked across multiple `verifyAndUpdate` calls | Hard, permanent |

The upshot: Gas Killer's clean win is **computation that collapses to a small diff** — heavy to compute,
cheap to apply. When the diff is as large as the work (a flat airdrop, a full re-sort), the on-chain
apply cost is comparable to (or worse than) doing it directly, and the value is structural rather than a
raw-gas saving.

## Two regimes, shown honestly

These examples deliberately cover both:

- **Cost-collapse (compute ≫ diff).** `OnchainLife` steps a 64×64 Game of Life board. One generation
  already costs ~17M gas on-chain and two exceed a 30M block, yet the resulting diff is at most 16
  changed words — so the apply cost is **flat (~46k) whether the operator stepped 1 generation or 8**.
  This is where Gas Killer shines.

- **Trust-only, unbounded.** Because nothing on-chain re-checks the result, an operator can submit the
  board at "generation 1,000,000" — a computation that could never run on-chain and that today's
  analyzer (block-gas-limited) could not even simulate. The apply is still ~16 words. The
  `test_trustOnly_unboundedGenerationIsCheapButUnverified` test demonstrates this **and warns**: its
  correctness rests *entirely* on the 66 % quorum being honest. There is no objective recourse if it is
  not.

- **Invariant guard (validation ≫ diff).** `GuardedVault` re-validates an expensive O(N) global
  invariant (conservation + solvency + per-depositor concentration cap) on every state transition.
  Honest operators run `checkInvariant()` on the *simulated post-state* before BLS-signing, so the 66%
  quorum is an attestation that *this transition preserves the invariant* — a whole class of exploits
  (anything that breaks a global invariant the contract can't afford to re-check on-chain) can never
  land. **But this inherits the trust model above:** there is no on-chain re-check, so the guarantee is
  only as strong as the honest-supermajority assumption. A ≥66% malicious quorum could sign an
  invariant-violating diff and nothing on-chain would stop it. The on-chain `checkInvariant()` exists
  as the spec/oracle and to *prove the guard is load-bearing* (the tests apply a bad diff and show the
  state is then detectably corrupt); production `verifyAndUpdate` does not call it. Note also that an
  invariant is only as complete as the state it enumerates: `checkInvariant` sums only addresses in
  `depositors[]`, so a diff that writes shares to a never-registered address escapes the conservation
  check (shown by `test_guard_limitation_phantomOnNonDepositorEscapes`). Honest operators never build
  such a diff, but it is a reminder to design invariants to cover all reachable state.

- **Write-bound / structural (compute ≈ diff).** `MegaDrop` (bulk airdrop) and `OnchainLeaderboard`
  (sorted ranking) have O(N) diffs. Their naive loops cross a 30M block at ~1.2k and ~1.8k entries
  respectively — so you can't ship them as one transaction — but applying the diff is *also* O(N) and is
  **not** cheaper than the naive work (MegaDrop's apply is a bit *more* expensive due to per-op decode
  overhead). Their value is structural: one attested batch instead of N user claim transactions, no
  Merkle infrastructure, offloaded eligibility/ordering computation, and large updates chunked across
  multiple `verifyAndUpdate` calls.

## Marketing vs. code

Gas Killer's landing page advertises "objective on-chain slashing" and "infinite computation? no
problem!". As of the SDK revision these examples pin (`gas-killer/solidity-sdk@7e4289c`), the code backs
**neither**: there is no on-chain slashing or fraud proof, and the off-chain analyzer simulates within a
block's gas. Treat the unbounded-computation framing as the *trust-only* regime above, not as a
verified guarantee.

## Benchmark honesty

- Apply-diff gas in the tests is measured against `MockBLSSignatureChecker`, which does **no**
  cryptography. Those numbers therefore **exclude** the fixed cost of real BLS quorum verification.
  Add `BLS_VERIFY_FIXED_GAS` (~250k, seeded from the analyzer's `TURETZKY_UPPER_GAS_LIMIT`) for a
  production estimate. It is constant in N, so it does not change the shape of any comparison.
- Gas is measured with `gasleft()` deltas around the external call (deterministic), not the
  `vm.startSnapshotGas` cheatcode, which returned unreliable numbers on the pinned Foundry nightly.

## The live Sepolia deployment (`test/live/`)

A real Gas Killer AVS stack exists on Sepolia (a live `BLSSignatureChecker` + `RegistryCoordinator` +
`StakeRegistry` with recorded operator stake, reachable from the live `ArraySummationFactory`). The
`SepoliaLiveTest` forked tests read it and wire `GuardedVault` to the real on-chain checker. Be precise
about what this is: it is **ephemeral test infrastructure** from earlier deploy runs (each ArraySummation
instance has its own checker/coordinator; several are even mis-wired to the operator-state-retriever and
revert) — **not a hosted service with operators signing on demand**. Consequently the live test
demonstrates only that (a) the deployment is real and (b) the real checker *gates* submissions (it
rejects an unsigned diff). It does **not** and cannot produce a passing signed `verifyAndUpdate` for a
new contract, because that needs the operator set to BLS-sign that contract's message hash — i.e. a
running operator network, which is not on disk here. Do not read the live test as "the hosted service
works"; read it as "our integration is real and the on-chain gate is enforced."

## The real-analyzer end-to-end (`script/e2e/`)

The `script/e2e/run-guarded-vault-e2e.sh` demo uses the **real** Gas Killer analyzer to produce the
storage diff from a traced `settle` transaction, then lands it via `verifyAndUpdate`. What is real
there: the analyzer-produced `(StateUpdateType[], bytes[])` diff and its on-chain application. What is
mocked: the BLS quorum signature — the full operator set + EigenLayer deployment cannot run in a local
demo. So the e2e demonstrates the *data path* faithfully, not the cryptographic signing. Do not read it
as evidence that the trust model is stronger than described above.
