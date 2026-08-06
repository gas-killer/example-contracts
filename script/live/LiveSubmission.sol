// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {OperatorStateRetriever} from "@eigenlayer-middleware/OperatorStateRetriever.sol";
import {ISlashingRegistryCoordinator} from "@eigenlayer-middleware/interfaces/ISlashingRegistryCoordinator.sol";
import {IBLSApkRegistry} from "@eigenlayer-middleware/interfaces/IBLSApkRegistry.sol";
import {IBLSSignatureCheckerTypes} from "@eigenlayer-middleware/interfaces/IBLSSignatureChecker.sol";
import {BN254} from "@eigenlayer-middleware/libraries/BN254.sol";

/// @title LiveSubmission
/// @notice Assembles a `verifyAndUpdate` `NonSignerStakesAndSignature` for the **all-signers** case
///         (no non-signers) entirely from the live EigenLayer registry state — leaving ONLY the two
///         operator-side BLS values, `sigma` and `apkG2`, as inputs.
///
///         This is the deterministic 90% of a Gas Killer submission that a client can compute itself:
///         the indices (`quorumApkIndices`, `totalStakeIndices`, `nonSignerStakeIndices`,
///         `nonSignerQuorumBitmapIndices`) come from `OperatorStateRetriever.getCheckSignaturesIndices`,
///         and the per-quorum aggregate public keys come from `BLSApkRegistry.getApk`. The remaining
///         seam — `(sigma, apkG2)` — is produced by the AVS's EXISTING operator set / aggregator
///         (it requires the operators' BLS keys), and is the only thing this client cannot derive.
///
/// @dev Field-order caveat: `OperatorStateRetriever.CheckSignaturesIndices` and
///      `IBLSSignatureChecker.NonSignerStakesAndSignature` order their members differently, so the
///      retriever output is copied by NAME below, not positionally.
library LiveSubmission {
    /// @notice Build the signature struct for a single-or-multi quorum, all-operators-signed submission.
    /// @param registryCoordinator The AVS RegistryCoordinator the consumer's BLSSignatureChecker uses.
    /// @param retriever Any `OperatorStateRetriever` instance (it is stateless; the coordinator is a param).
    /// @param quorumNumbers The quorum id bytes (e.g. `hex"00"`).
    /// @param referenceBlockNumber Block at which stake/apk are read (must be < current and within
    ///        the consumer's `blockStaleMeasure`).
    /// @param sigma Aggregate G1 signature over `hashToG1(msgHash)` — FROM THE OPERATOR SERVICE.
    /// @param apkG2 Aggregate G2 public key of the signers — FROM THE OPERATOR SERVICE.
    function buildAllSigners(
        ISlashingRegistryCoordinator registryCoordinator,
        OperatorStateRetriever retriever,
        bytes memory quorumNumbers,
        uint32 referenceBlockNumber,
        BN254.G1Point memory sigma,
        BN254.G2Point memory apkG2
    ) internal view returns (IBLSSignatureCheckerTypes.NonSignerStakesAndSignature memory nss) {
        // No non-signers: an empty operator-id list yields empty non-signer indices.
        OperatorStateRetriever.CheckSignaturesIndices memory idx = retriever.getCheckSignaturesIndices(
            registryCoordinator, referenceBlockNumber, quorumNumbers, new bytes32[](0)
        );

        IBLSApkRegistry apkRegistry = registryCoordinator.blsApkRegistry();
        BN254.G1Point[] memory quorumApks = new BN254.G1Point[](quorumNumbers.length);
        for (uint256 i = 0; i < quorumNumbers.length; i++) {
            quorumApks[i] = apkRegistry.getApk(uint8(quorumNumbers[i]));
        }

        // On-chain-derived fields.
        nss.nonSignerQuorumBitmapIndices = idx.nonSignerQuorumBitmapIndices; // empty
        nss.nonSignerPubkeys = new BN254.G1Point[](0); // empty
        nss.quorumApks = quorumApks;
        nss.quorumApkIndices = idx.quorumApkIndices;
        nss.totalStakeIndices = idx.totalStakeIndices;
        nss.nonSignerStakeIndices = idx.nonSignerStakeIndices; // empty inner arrays

        // The seam: produced by the existing AVS operator set / aggregator.
        nss.sigma = sigma;
        nss.apkG2 = apkG2;
    }
}
