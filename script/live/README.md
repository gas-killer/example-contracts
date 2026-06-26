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

```
AVS / ServiceManager   0x2015983cDd409B1838F4C1cCa9085c946C5A9F81
BLSSignatureChecker    0x22FfcFD8cCCb2e70dbd6FE1DAf951080595E02f2
RegistryCoordinator    0x7aA89B1CBC571a1c6F7E6B262E06e614104Fb56d
StakeRegistry          0xac89f540a78313aE126fd95cc9e1eb82503b824A   (getCurrentTotalStake(0) = 3e16 -> live operators)
BLSApkRegistry         0xaea4c8CFD4dEd036c30182e746C9F024f76AbFEA
IndexRegistry          0x34D0e327d51596a76c88aDd65B5601350aDc7074
```

## Runbook (once the credential arrives)

```bash
export SEPOLIA_RPC_URL=...          # an archive/full node (debug_traceCall for the analyzer)
export PK=...                       # a funded Sepolia deployer key

# 1. Deploy your consumer wired to the REAL AVS + checker.
AVS_ADDRESS=0x2015983cDd409B1838F4C1cCa9085c946C5A9F81 \
SIG_CHECKER_ADDRESS=0x22FfcFD8cCCb2e70dbd6FE1DAf951080595E02f2 \
  forge script script/DeployGuardedVault.s.sol --rpc-url $SEPOLIA_RPC_URL --private-key $PK --broadcast

# 2. Produce the diff for the action you want applied (the analyzer; simulate or trace the call).
#    -> STORAGE_UPDATES = 0x…  (see tools/diff-extractor + script/e2e)

# 3. Ask the EXISTING operator service to sign for (transitionIndex, consumer, targetFunction,
#    storageUpdates). It returns sigma + apkG2 (or the full NonSignerStakesAndSignature, or it submits
#    the tx itself). THIS is what the colleague's credential unlocks. Coordinate the referenceBlockNumber.

# 4. Submit (only needed if the service returns the signature rather than submitting itself):
CONSUMER=0x<your vault> \
STORAGE_UPDATES=0x<diff> \
TARGET_SIGNATURE="settle(address[],int256[])" \
REGISTRY_COORDINATOR=0x7aA89B1CBC571a1c6F7E6B262E06e614104Fb56d \
SIGMA_X=.. SIGMA_Y=.. APKG2_X0=.. APKG2_X1=.. APKG2_Y0=.. APKG2_Y1=.. \
  forge script script/live/SubmitLive.s.sol --rpc-url $SEPOLIA_RPC_URL --private-key $PK --broadcast
```

## The ONE thing to confirm with your colleague

We don't yet know the exact shape of the credential / interface. It is almost certainly one of:

1. **An aggregator endpoint + auth** (URL + password/API key) that, given `(consumer, targetFunction,
   storageUpdates, referenceBlockNumber)`, returns `(sigma, apkG2)` (or the whole struct). → drop the
   values straight into `SubmitLive` (step 4). Easiest.
2. **Access to run the existing router/aggregator client** (repo access at
   `github.com/BreadchainCoop/commonware-avs-router` @ `758552a…`, plus operator coordination) so its
   operators sign for your contract and it submits `verifyAndUpdate` itself. → you may not need
   `SubmitLive` at all; you just deploy + register your consumer.
3. **The `avs_deploy.json` + operator key material** for a self-run quorum. → you'd run the operator
   set yourself; still feeds `(sigma, apkG2)` into `SubmitLive`.

Ask which one it is. In all three, **the client side above is complete and unchanged** — the credential
only fills `(sigma, apkG2)` (or submits for you).

## Honest caveats

- The operator set must actually **sign for your contract's `msgHash`**. The existing service serves the
  contracts it is configured to watch; a brand-new consumer must be made known to it (the request in
  step 3). We cannot forge a signature.
- `referenceBlockNumber` must be one where the signer set's stake/APK indices are valid **and** within
  the consumer's `blockStaleMeasure` (default 300 blocks) of submission — coordinate it with the service.
- The Sepolia stack is real EigenLayer middleware with live stake, but it originated from test deploys
  (sibling instances are mis-wired); treat it as a testnet integration target, not a production SLA. See
  [`../../SECURITY.md`](../../SECURITY.md).
