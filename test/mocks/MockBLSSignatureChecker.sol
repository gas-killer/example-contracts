// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {
    IBLSSignatureChecker,
    IBLSSignatureCheckerTypes
} from "@eigenlayer-middleware/interfaces/IBLSSignatureChecker.sol";
import {ISlashingRegistryCoordinator} from "@eigenlayer-middleware/interfaces/ISlashingRegistryCoordinator.sol";
import {IBLSApkRegistry} from "@eigenlayer-middleware/interfaces/IBLSApkRegistry.sol";
import {IStakeRegistry, IDelegationManager} from "@eigenlayer-middleware/interfaces/IStakeRegistry.sol";
import {BN254} from "@eigenlayer-middleware/libraries/BN254.sol";

/// @title MockBLSSignatureChecker
/// @notice Test double for EigenLayer's BLS signature checker. It performs **no** cryptography:
///         it simply reports stake totals that pass (or, when configured, fail) GasKillerSDK's
///         66% quorum check. This lets tests exercise the full `verifyAndUpdate` happy path —
///         and its threshold-failure path — without standing up a live AVS, operator set, or
///         real BLS keys.
/// @dev `GasKillerSDK.verifyAndUpdate` only consumes `signedStakeForQuorum[i]` and
///      `totalStakeForQuorum[i]` for `i in [0, quorumNumbers.length)`, so this mock returns
///      arrays sized to `quorumNumbers.length` and ignores the message hash and signature
///      entirely. DO NOT use the apply-diff gas measured against this mock as a production
///      figure: it omits the (fixed, N-independent) cost of real BLS pairing verification.
contract MockBLSSignatureChecker is IBLSSignatureChecker {
    /// @notice Total stake reported per quorum. Constant across quorums for simplicity.
    uint96 public totalStakePerQuorum = 1_000_000;

    /// @notice Fraction of `totalStakePerQuorum` reported as having signed, in basis points.
    /// @dev 10_000 = 100% (default, always passes). With the default million-unit total, 6_600 is
    ///      exactly 66% (passes) and 6_599 fails. The exact boundary holds only when
    ///      `total * bps / 10_000` does not truncate — for tiny totals, integer division rounds the
    ///      signed stake down and 6_600 can fail.
    uint16 public signedBps = 10_000;

    /// @notice Configure the reported signed fraction (basis points) to drive pass/fail paths.
    function setSignedBps(uint16 bps) external {
        signedBps = bps;
    }

    /// @notice Configure the reported total stake per quorum.
    function setTotalStake(uint96 t) external {
        totalStakePerQuorum = t;
    }

    /// @inheritdoc IBLSSignatureChecker
    function checkSignatures(
        bytes32, /* msgHash — ignored: this mock does no crypto */
        bytes calldata quorumNumbers,
        uint32, /* referenceBlockNumber — ignored */
        IBLSSignatureCheckerTypes.NonSignerStakesAndSignature memory /* signature — ignored */
    ) external view returns (IBLSSignatureCheckerTypes.QuorumStakeTotals memory totals, bytes32) {
        uint256 n = quorumNumbers.length; // one stake entry per quorum byte
        totals.signedStakeForQuorum = new uint96[](n);
        totals.totalStakeForQuorum = new uint96[](n);
        for (uint256 i = 0; i < n; i++) {
            totals.totalStakeForQuorum[i] = totalStakePerQuorum;
            totals.signedStakeForQuorum[i] = uint96((uint256(totalStakePerQuorum) * signedBps) / 10_000);
        }
        return (totals, bytes32(0)); // signatoryRecordHash is unused by GasKillerSDK
    }

    /* --- Remaining IBLSSignatureChecker surface: inert stubs to satisfy the interface --- */

    function registryCoordinator() external pure returns (ISlashingRegistryCoordinator) {
        return ISlashingRegistryCoordinator(address(0));
    }

    function stakeRegistry() external pure returns (IStakeRegistry) {
        return IStakeRegistry(address(0));
    }

    function blsApkRegistry() external pure returns (IBLSApkRegistry) {
        return IBLSApkRegistry(address(0));
    }

    function delegation() external pure returns (IDelegationManager) {
        return IDelegationManager(address(0));
    }

    function trySignatureAndApkVerification(bytes32, BN254.G1Point memory, BN254.G2Point memory, BN254.G1Point memory)
        external
        pure
        returns (bool pairingSuccessful, bool siganatureIsValid)
    {
        return (true, true);
    }
}
