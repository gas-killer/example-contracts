// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {GasKillerSDK} from "gas-killer-sdk/GasKillerSDK.sol";
import {StateChangeHandlerLib, StateUpdateType, CallPolicy} from "gas-killer-sdk/StateChangeHandlerLib.sol";

/// @notice Test-only mixin exposing the SDK's diff applier, shared by every `*Exposed` harness.
/// @dev A hand copy of the SDK's private `_stateChangeHandler`: an SDK bump that changes that handler
///      has to be copied here too. `test_applyDiff_matchesSettlement` checks the two still agree.
abstract contract DiffApplier is GasKillerSDK {
    /// @dev Runs a signed program the way the SDK's private settlement handler does: under this
    ///      contract's protected ranges (or unguarded, if it opts out of the storage guard) and call
    ///      policy, between `_beforeProgram` and `_afterProgram`. It is settlement minus the quorum
    ///      check, the transition counter and the transition latch, so `inTransition()` is false
    ///      while it runs.
    function applyDiff(bytes calldata storageUpdates) external {
        (StateUpdateType[] memory types, bytes[] memory args) = abi.decode(storageUpdates, (StateUpdateType[], bytes[]));
        _beforeProgram();
        CallPolicy memory policy = _callPolicy();
        if (_unsafeDisableStorageGuard()) StateChangeHandlerLib._runStateUpdatesUnguarded(types, args, policy);
        else StateChangeHandlerLib._runStateUpdatesPrevalidated(types, args, _settlementRanges(), policy);
        _afterProgram();
    }
}
