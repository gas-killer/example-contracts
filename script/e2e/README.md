# End-to-end with the REAL Gas Killer analyzer

The Solidity tests build the storage diff in Solidity (`OffchainPayloadBuilder`) so they run fast in
CI. This directory wires up the **actual** off-chain engine instead: the
[Gas Killer analyzer](https://github.com/BreadchainCoop/gas-killer-analyzer) traces a real transaction
and emits the exact `(StateUpdateType[], bytes[])` diff that `verifyAndUpdate` consumes.

## What `run-guarded-vault-e2e.sh` does

Against a local anvil (`--steps-tracing`):

1. deploys a `MockBLSSignatureChecker` + two `GuardedVault`s (a **sandbox** and a **target**), seeded equally;
2. an operator **simulates** a `settle` by sending it to the sandbox (a mined tx — the on-chain guard runs);
3. the **real analyzer** (`tools/diff-extractor`) traces that tx and prints the storage diff;
4. that exact diff is submitted to the **target** via `verifyAndUpdate` (`SubmitDiff.s.sol`);
5. it asserts the target now matches the sandbox — the analyzer's diff reproduced the settle;
6. it shows the **guard**: an over-concentrating `settle` reverts on-chain, so an honest operator can
   never produce a signable diff for an invariant-violating transition.

```
bash script/e2e/run-guarded-vault-e2e.sh
```

Expected tail:

```
==> REAL analyzer: extracting the storage diff from the settle trace
    diff bytes: 0x00000000…0040… (1666 chars)
==> submitting the analyzer diff to the TARGET via verifyAndUpdate (mock BLS)
  verifyAndUpdate landed the analyzer diff on: 0x9fE4…
==> verifying the target matches the sandbox
    0xf39F…  sandbox=800  target=800
    …
    ✅ analyzer-produced diff reproduced the settle on the target vault
==> GUARD demo: an over-concentrating settle must REVERT (so no diff can be produced)
    ✅ over-concentration reverted on-chain in the spec; an honest operator gets no signable diff
```

## Two subtleties this demo gets right

- **The diff is applied to a *different* contract than it was traced on** (sandbox → target). That is
  sound because STORE slots are derived from the storage *layout* and key values
  (`keccak256(depositor, 0)` for a balance), **not** the contract address — so the same diff is valid on
  any contract with an identical layout *and* identical pre-state. The script guarantees both: both are
  `GuardedVault` and both are seeded identically before the settle.
- **The SDK state-transition counter is filtered out of the diff.** The traced `settle` bumps the
  `trackState` counter, so the raw trace contains a STORE to it. `tools/diff-extractor` drops that slot,
  because `verifyAndUpdate` is itself `trackState` and manages the counter — keeping the trace's value
  would only be correct when source and target are in lockstep. Filtering it makes the diff portable.

## What's real and what's mocked

| Piece | Real or mocked |
|---|---|
| Storage diff (the `storageUpdates`) | **Real** — produced by the actual analyzer from a real trace |
| `verifyAndUpdate` application on-chain | **Real** |
| BLS quorum signature | **Mocked** (`MockBLSSignatureChecker`) — the full operator set + EigenLayer deployment can't run in a local demo; see [`../../SECURITY.md`](../../SECURITY.md) |

## Requirements

- Foundry (`anvil`, `cast`, `forge`) and `jq`.
- The analyzer wrapper built once: `cd tools/diff-extractor && cargo build --release` (see
  [`../../tools/diff-extractor/README.md`](../../tools/diff-extractor/README.md)). The script builds it
  automatically if missing.

This e2e is intentionally **not** part of `forge test` (it needs a node, a Rust build, and `jq`). It's
the authenticity check that the fast Solidity equivalence tests model correctly.
