// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {GasKillerSDK} from "gas-killer-sdk/GasKillerSDK.sol";
import {IBLSSignatureCheckerTypes} from "@eigenlayer-middleware/interfaces/IBLSSignatureChecker.sol";
import {MockBLSSignatureChecker} from "../mocks/MockBLSSignatureChecker.sol";

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
    ///      Gas Killer tx, which includes BLS quorum verification). The MockBLSSignatureChecker used
    ///      in these tests does NO crypto, so apply-diff gas measured here EXCLUDES this cost — add
    ///      it back when quoting a production figure. It is constant in N, so it does not change the
    ///      shape of the "flat apply-diff vs. super-linear naive" comparison.
    uint256 internal constant BLS_VERIFY_FIXED_GAS = 250_000;

    /// @notice A single-quorum selector (quorum #0). Length drives the mock's stake-array sizing.
    function _quorumNumbers() internal pure returns (bytes memory) {
        return hex"00";
    }

    /// @notice An all-zero NonSignerStakesAndSignature — valid Solidity; the mock ignores it.
    function _emptySignature()
        internal
        pure
        returns (IBLSSignatureCheckerTypes.NonSignerStakesAndSignature memory nss)
    {
        return nss;
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
        returns (
            bytes32 msgHash,
            bytes memory quorumNumbers,
            uint32 referenceBlockNumber,
            uint256 transitionIndex,
            IBLSSignatureCheckerTypes.NonSignerStakesAndSignature memory nss
        )
    {
        if (block.number == 0) {
            vm.roll(1);
        }
        transitionIndex = c.stateTransitionCount();
        msgHash = c.getMessageHash(transitionIndex, targetFunction, storageUpdates);
        quorumNumbers = _quorumNumbers();
        referenceBlockNumber = uint32(block.number - 1);
        nss = _emptySignature();
    }

    /// @notice Apply `storageUpdates` to `c` through the full `verifyAndUpdate` path (mock BLS).
    /// @dev Use this when you just want the diff applied; wrap the inner call yourself with
    ///      `vm.startSnapshotGas`/`vm.stopSnapshotGas` when you specifically want to meter it.
    function _verify(GasKillerSDK c, bytes memory storageUpdates, bytes4 targetFunction) internal {
        (
            bytes32 msgHash,
            bytes memory quorumNumbers,
            uint32 referenceBlockNumber,
            uint256 transitionIndex,
            IBLSSignatureCheckerTypes.NonSignerStakesAndSignature memory nss
        ) = _prepVerify(c, storageUpdates, targetFunction);
        c.verifyAndUpdate(
            msgHash, quorumNumbers, referenceBlockNumber, storageUpdates, transitionIndex, targetFunction, nss
        );
    }

    /// @notice Deploy a fresh mock BLS checker configured to pass the 66% quorum check.
    function _deployPassingBls() internal returns (MockBLSSignatureChecker) {
        return new MockBLSSignatureChecker();
    }

    /// @notice Human-readable label for a sweep size, e.g. "N=5000".
    function _label(uint256 n) internal pure returns (string memory) {
        return string.concat("N=", vm.toString(n));
    }
}
