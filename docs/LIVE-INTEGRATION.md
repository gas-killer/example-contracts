# Live integration — driving a state transition via the hosted Gas Killer aggregator

A hosted aggregator runs the whole off-chain pipeline for a deployed consumer, so you don't build or run
operators yourself: it simulates the call, computes the storage diff, and has the operator quorum sign it.

The aggregator **renders** a ready-to-sign payload; **the caller submits it**, before the payload's
`valid_until_block`.

**The API contract is maintained in the Gas Killer docs, not here:**

- [Quickstart](https://gaskiller.xyz/docs/quickstart) — the submit / poll / settle flow end to end.
- [API Reference](https://gaskiller.xyz/docs/api/tasks/submitTask) — every request field, status code
  and error, generated from the OpenAPI spec.

Authentication is a per-client API key minted by the operators: `Authorization: Bearer $GK_API_KEY`.
Never commit it.

This document covers only what is specific to this repo: the client script, and how the examples here
are wired to the live AVS.

## Client: `script/live/gk-trigger.sh`

Builds the calldata with `cast`, posts the task, polls until ready, and (with `GK_SUBMIT_KEY`) submits the
rendered payload — otherwise it prints the exact `cast send` for you to run.

```bash
export GK_API_KEY=<your key>

# render + submit automatically
GK_SUBMIT_KEY=0x<funded-sepolia-key> ./script/live/gk-trigger.sh \
  $GUARDED_VAULT "settle(address[],int256[])" "[$A,$B]" "[-200,200]" --watch

# render only (prints the payload to submit yourself)
./script/live/gk-trigger.sh $LIFE "step(uint32)" 1 --watch
```

Env knobs: `GK_API_KEY`, `GK_SUBMIT_KEY`, `GK_BASE_URL`, `GK_FROM`, `GK_RPC`, `GK_BLOCK`,
`GK_TRANSITION_INDEX` (see the script header). The client checks HTTP status and surfaces `.error.code`,
so an auth or rate-limit failure aborts loudly instead of polling forever.

## Wiring our examples to the live AVS

A consumer is "served" when it's deployed on a watched chain **and** wired to the AVS
`BLSSignatureChecker` the operators are registered with. Those addresses are published in
[Configuration](https://gaskiller.xyz/docs/solidity/configuration) — they are deployment properties, so
they are maintained there and not duplicated here.

```bash
export AVS_ADDRESS=...          # from the docs
export SIG_CHECKER_ADDRESS=...  # from the docs
forge script script/DeployGuardedVault.s.sol --rpc-url $SEPOLIA_RPC_URL --private-key $PK --broadcast
```

Settlement is verified from the service repo, whose [`scripts/examples`][harness] harness deploys
these contracts against a running AVS and drives tasks through the router until the transition lands.

[harness]: https://github.com/gas-killer/service/tree/main/scripts/examples

## Status — what is and isn't verified

- ✅ **On-chain application is proven** for both examples: the real SDK applies the operator's diff via
  `verifyAndUpdate`, reproducing naive state and events byte-for-byte (`test/examples/`, offline, with
  a hand-built diff and a mocked quorum).
- ✅ **On-chain wiring and settlement** are verified from the service repo: its `scripts/examples`
  harness deploys these contracts against a running AVS and asserts `stateTransitionCount` advances,
  which is a real `BLSSignatureChecker` accepting a real aggregated signature.
- ⚠️ **No end-to-end run through the hosted service is currently reproducible**, because the credential
  documented previously is retired and we hold no replacement API key. Earlier rounds *did* land under the
  old broadcasting model (e.g. `stateTransitionCount` 0 → 1 on GuardedVault), but those runs predate both
  changes above and should not be presented as reproducible today.
