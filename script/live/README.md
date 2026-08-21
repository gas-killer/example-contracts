# Going live against the real Gas Killer AVS — integration runbook

This wires the **client side** of a real `verifyAndUpdate` submission against the live EigenLayer AVS on
**Sepolia**, to the point where the only missing input is the operator BLS signature — which is produced
by the AVS's **existing** operator set / aggregator (we do **not** build that here).

## The one fact that makes this tractable

Every argument to `verifyAndUpdate` is derivable by us from public on-chain state **except** the
operator BLS signature. For the all-signers case the seam is exactly two values:

- `sigma` — the aggregate G1 signature over `hashToG1(msgHash)`
- `apkG2` — the aggregate G2 public key of the signers

Everything else (`quorumApks`, `quorumApkIndices`, `totalStakeIndices`, `nonSignerStakeIndices`,
`nonSignerQuorumBitmapIndices`, `msgHash`) is assembled by [`LiveSubmission.sol`](./LiveSubmission.sol)
from `OperatorStateRetriever.getCheckSignaturesIndices` + `BLSApkRegistry.getApk`.

**This is proven against the live chain.** `test/live/SepoliaSubmit.t.sol` forks Sepolia, assembles the
full struct from the real registry, and submits with a placeholder signature — the real on-chain
`BLSSignatureChecker` accepts every field and reverts **only** at `InvalidBLSSignature()` (0xab1b236b),
not at `InvalidQuorumApkHash()`. i.e. our assembly is correct; only `(sigma, apkG2)` is missing.

```bash
SEPOLIA_RPC_URL=https://ethereum-sepolia.publicnode.com forge test --match-contract SepoliaSubmitTest -vvv
```

## Provenance of every `verifyAndUpdate` argument

| Argument | Source | Who provides |
|---|---|---|
| `storageUpdates` | the analyzer (`tools/diff-extractor`) traces the tracked call | **us** |
| `transitionIndex` | `consumer.stateTransitionCount()` | **us** |
| `targetFunction` | `bytes4(keccak256("settle(address[],int256[])"))` | **us** |
| `msgHash` | `consumer.getMessageHash(transitionIndex, targetFunction, storageUpdates)` | **us** |
| `referenceBlockNumber` | a recent block (< current, within `blockStaleMeasure`) | **us** (coordinate with the service) |
| `quorumNumbers` | the AVS quorum bytes (`0x00`) | **us** |
| `quorumApks`, `*Indices` | `OperatorStateRetriever` + `BLSApkRegistry` at `referenceBlockNumber` | **us** |
| `nonSigner*` | empty (all-signers case) | **us** |
| **`sigma`**, **`apkG2`** | aggregate BLS signature over `msgHash` by the operator set | **the existing service** ⬅ the seam |

## Live Sepolia addresses (chain 11155111)

Published in [Configuration](https://gaskiller.xyz/docs/solidity/configuration), together with a
`cast call` recipe for confirming a checker is still bound to the live operator set. They are properties
of an AVS deployment rather than constants, so they are maintained in one place — a consumer wired to a
superseded checker reverts `InvalidQuorumApkHash` on every settlement.

The registry addresses the assembler reads (`RegistryCoordinator`, `StakeRegistry`, `BLSApkRegistry`,
`IndexRegistry`) are all reachable from the checker, so nothing here needs them hardcoded.

## Runbook

```bash
export SEPOLIA_RPC_URL=...          # an archive/full node (debug_traceCall for the analyzer)
export PK=...                       # a funded Sepolia deployer key

# 1. Deploy your consumer wired to the REAL AVS + checker (addresses: see the docs link above).
export AVS_ADDRESS=... SIG_CHECKER_ADDRESS=...
forge script script/DeployGuardedVault.s.sol --rpc-url $SEPOLIA_RPC_URL --private-key $PK --broadcast

# 2. Produce the diff for the action you want applied (the analyzer; simulate or trace the call).
#    -> STORAGE_UPDATES = 0x…  (see tools/diff-extractor + script/e2e)

# 3. Have the operator quorum sign for (transitionIndex, consumer, targetFunction, storageUpdates),
#    which yields sigma + apkG2. The hosted service does this and returns a ready-to-sign transaction
#    -- see "Where the signature comes from" below. Coordinate the referenceBlockNumber.

# 4. Submit (only needed if the service returns the signature rather than submitting itself):
CONSUMER=0x<your vault> \
STORAGE_UPDATES=0x<diff> \
TARGET_SIGNATURE="settle(address[],int256[])" \
REGISTRY_COORDINATOR=$(cast call $SIG_CHECKER_ADDRESS "registryCoordinator()(address)" --rpc-url $SEPOLIA_RPC_URL) \
SIGMA_X=.. SIGMA_Y=.. APKG2_X0=.. APKG2_X1=.. APKG2_Y0=.. APKG2_Y1=.. \
  forge script script/live/SubmitLive.s.sol --rpc-url $SEPOLIA_RPC_URL --private-key $PK --broadcast
```

## Where the signature comes from

The hosted operator service produces it. You submit a task describing the call you want performed, poll
until it is `ready`, and it hands back a complete `verifyAndUpdate` transaction — so in the common case
steps 2–4 above collapse into that one flow and you never assemble the arguments yourself.

- [Quickstart](https://gaskiller.xyz/docs/quickstart) — submit, poll, settle.
- [API Reference](https://gaskiller.xyz/docs/api/tasks/submitTask) — every field and error.

Access is a per-client API key minted by the operators. `script/live/gk-trigger.sh` wraps the flow; see
[`../../docs/LIVE-INTEGRATION.md`](../../docs/LIVE-INTEGRATION.md).

The assembler in this directory stays useful for the case the service does *not* cover: producing every
`verifyAndUpdate` argument yourself from the live registry, leaving only `(sigma, apkG2)` to be filled by
a quorum you coordinate directly.

## Honest caveats

- The operator set must actually **sign for your contract's `msgHash`**. A consumer has to be a valid
  target first — inheriting the SDK and wired to the live checker, see
  [Integrate the SDK](https://gaskiller.xyz/docs/solidity/integrate). We cannot forge a signature.
- `referenceBlockNumber` must be one where the signer set's stake/APK indices are valid **and** within
  the consumer's `blockStaleMeasure` (default 300 blocks) of submission — coordinate it with the service.
- The Sepolia stack is real EigenLayer middleware with live stake, but it originated from test deploys
  (sibling instances are mis-wired); treat it as a testnet integration target, not a production SLA. See
  [`../../SECURITY.md`](../../SECURITY.md).
