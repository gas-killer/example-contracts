# gk-diff-extractor

A thin wrapper around the real [Gas Killer analyzer](https://github.com/BreadchainCoop/gas-killer-analyzer).
Given a transaction hash and an RPC endpoint, it traces the tx (`debug_traceTransaction`), extracts the
SSTORE / CALL / LOG operations, and prints the ABI-encoded `(StateUpdateType[], bytes[])` payload as
`0x…` — exactly the `storageUpdates` argument `GasKillerSDK.verifyAndUpdate` consumes.

This is the genuine "operator computes the diff" step, used by `script/e2e/run-guarded-vault-e2e.sh`.

## Build

```bash
cargo build --release   # ~1 min; pulls the analyzer (core only, default-features = false)
```

## Use

```bash
# point at a node that supports debug_traceTransaction (anvil MUST be started with --steps-tracing)
RPC_URL=http://localhost:8545 ./target/release/gk-diff-extractor <TX_HASH>
# -> 0x…  (the encoded storageUpdates diff)
```

## Notes

- Depends on the analyzer's always-available `core` extraction (`get_tx_trace` +
  `compute_state_updates` + `encode_state_updates_to_abi`), so the build skips the heavy `evmsketch`
  (reth/sp1) and `anvil` (foundry-evm-traces) gas-estimation features.
- It normalizes one anvil quirk: anvil returns memory words 0x-prefixed (`"0x0000…"`) while the
  analyzer's geth-oriented parser expects bare hex (`"0000…"`); the wrapper strips the prefix before
  extraction.
- The transaction must have **succeeded** (`get_tx_trace` bails on a failed/reverted tx) — which is
  exactly the point for `GuardedVault`: a `settle` that breaks the invariant reverts, so no diff exists.
- It drops the SDK-internal `trackState` counter slot from the diff (`verifyAndUpdate` manages that slot
  itself via its own `trackState`), so the diff is portable across vaults in differing transition state.
- The analyzer dependency is pinned by git `rev` in `Cargo.toml`.
