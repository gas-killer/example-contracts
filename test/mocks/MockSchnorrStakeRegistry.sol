// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ISchnorrStakeRegistry} from "gas-killer-sdk/interface/ISchnorrStakeRegistry.sol";

/// @title MockSchnorrStakeRegistry
/// @notice Test double for the SDK's `SchnorrStakeRegistry`. It performs **no** cryptography: it
///         reports a configurable signed weight against a fixed total and applies the real
///         registry's stake-threshold rule, so tests can drive both the `verifyAndUpdate` happy path
///         and its below-threshold failure (`GasKillerSDK.InvalidQuorumSignature`) without an
///         operator set or secp256k1 keys.
/// @dev `GasKillerSDK` calls only `isValidSignature`, and only its boolean result reaches the SDK,
///      so the message, signature and non-signer arguments are ignored here. DO NOT use apply-diff gas
///      measured against this mock as a production figure: it omits the fixed, N-independent cost of
///      real aggregate Schnorr verification.
contract MockSchnorrStakeRegistry is ISchnorrStakeRegistry {
    /// @notice Threshold as a fraction of total weight, matching the registry's `thresholdNum/Den`.
    uint256 public constant THRESHOLD_NUM = 2;
    uint256 public constant THRESHOLD_DEN = 3;

    /// @notice Total registered weight. Divisible by `THRESHOLD_DEN` so the boundary is exact.
    uint256 public constant TOTAL_WEIGHT = 3_000_000;

    /// @notice Weight reported as having signed. Defaults to full participation (always passes).
    uint256 public signedWeight = TOTAL_WEIGHT;

    /// @notice Configure the reported signed weight to drive pass/fail paths.
    function setSignedWeight(uint256 w) external {
        signedWeight = w;
    }

    /// @notice The smallest signed weight that passes: exactly `TOTAL_WEIGHT * 2/3`.
    function thresholdWeight() external pure returns (uint256) {
        return (TOTAL_WEIGHT * THRESHOLD_NUM) / THRESHOLD_DEN;
    }

    /// @inheritdoc ISchnorrStakeRegistry
    function isValidSignature(bytes32, uint256, address, address[] calldata, uint256) external view returns (bool) {
        // Same inclusive rule as SchnorrStakeRegistry: signed/total >= num/den.
        return signedWeight * THRESHOLD_DEN >= TOTAL_WEIGHT * THRESHOLD_NUM;
    }
}
