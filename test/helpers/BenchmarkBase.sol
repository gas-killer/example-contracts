// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {GasKillerSDK} from "gas-killer-sdk/GasKillerSDK.sol";
import {MockSchnorrStakeRegistry} from "../mocks/MockSchnorrStakeRegistry.sol";

/// @title BenchmarkBase
/// @notice Shared base for the example tests/benchmarks. Centralizes the (fiddly) `verifyAndUpdate`
///         plumbing so every call site gets it right, and pins down the honest gas-accounting
///         conventions used across the suite.
abstract contract BenchmarkBase is Test {
    /// @notice The real Ethereum mainnet block gas limit we measure naive computations against.
    /// @dev Deliberately separate from Foundry's (much larger) configured `block_gas_limit`, which
    ///      only exists so a naive function can *execute* inside a test long enough to be measured.
    uint256 internal constant MAINNET_BLOCK_GAS = 30_000_000;

    /// @notice Documented, **N-independent** fixed overhead of a real Gas Killer submission.
    /// @dev Seeded from the analyzer's `TURETZKY_UPPER_GAS_LIMIT` (the ~250k floor for executing a
    ///      Gas Killer tx, including quorum verification). The MockSchnorrStakeRegistry used in these
    ///      tests does NO crypto, so apply-diff gas measured here EXCLUDES this cost — add it back when
    ///      quoting a production figure. It is constant in N, so it does not change the shape of the
    ///      "flat apply-diff vs. super-linear naive" comparison. It is a conservative ceiling: it was
    ///      sized for BLS verification, and the SDK measures aggregate Schnorr verification at ~17k
    ///      cold at full participation.
    uint256 internal constant QUORUM_VERIFY_FIXED_GAS = 250_000;

    /// @notice A placeholder aggregate Schnorr signature with no non-signers; the mock ignores it.
    function _placeholderSignature() internal pure returns (uint256 s, address rAddr, address[] memory nonSigners) {
        return (1, address(0x5C), new address[](0));
    }

    /// @notice Compute the correct `verifyAndUpdate` arguments for applying `storageUpdates` to `c`.
    /// @dev Handles the two classic traps:
    ///       - transition-index off-by-one: `verifyAndUpdate` is itself `trackState`, so it
    ///         increments the counter *before* its body checks `transitionIndex + 1 == count`.
    ///         The correct `transitionIndex` is therefore the count read *now*, before the call.
    ///       - block staleness: `referenceBlockNumber` must be `< block.number` and within
    ///         `blockStaleMeasure` (300) blocks. `block.number - 1` always satisfies both for
    ///         `block.number >= 1`.
    ///      `msgHash` is always derived via the SDK's own `getMessageHash` so the encoding can't drift.
    function _prepVerify(GasKillerSDK c, bytes memory storageUpdates, bytes4 targetFunction)
        internal
        returns (bytes32 msgHash, uint32 referenceBlockNumber, uint256 transitionIndex)
    {
        if (block.number == 0) {
            vm.roll(1);
        }
        transitionIndex = c.stateTransitionCount();
        msgHash = c.getMessageHash(transitionIndex, targetFunction, storageUpdates);
        referenceBlockNumber = uint32(block.number - 1);
    }

    /// @notice Apply `storageUpdates` to `c` through the full `verifyAndUpdate` path (mock registry).
    /// @dev Use this when you just want the diff applied; wrap the inner call yourself with
    ///      `vm.startSnapshotGas`/`vm.stopSnapshotGas` when you specifically want to meter it.
    function _verify(GasKillerSDK c, bytes memory storageUpdates, bytes4 targetFunction) internal {
        (bytes32 msgHash, uint32 referenceBlockNumber, uint256 transitionIndex) =
            _prepVerify(c, storageUpdates, targetFunction);
        (uint256 s, address rAddr, address[] memory nonSigners) = _placeholderSignature();
        c.verifyAndUpdate(
            msgHash, referenceBlockNumber, storageUpdates, transitionIndex, targetFunction, s, rAddr, nonSigners
        );
    }

    /// @notice Deploy a fresh mock registry reporting full participation, so every quorum passes.
    function _deployPassingRegistry() internal returns (MockSchnorrStakeRegistry) {
        return new MockSchnorrStakeRegistry();
    }

    /// @notice Human-readable label for a sweep size, e.g. "N=5000".
    function _label(uint256 n) internal pure returns (string memory) {
        return string.concat("N=", vm.toString(n));
    }
}
