// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {StateChangeHandlerLib, StateUpdateType} from "gas-killer-sdk/StateChangeHandlerLib.sol";
import {GuardedVault} from "../../src/examples/guarded-vault/GuardedVault.sol";

/// @notice Test-only subclass exposing the internal diff applier. Used both to measure pure apply-diff
///         gas and, crucially, to let the "operator" apply a candidate diff to a sandbox and run the
///         invariant on the resulting post-state before deciding whether to sign.
contract GuardedVaultExposed is GuardedVault {
    constructor(address avs, address registry, uint256 maxBps) GuardedVault(avs, registry, maxBps) {}

    /// @dev Runs the diff as settlement does, under this contract's protected ranges and call
    ///      policy, without the quorum check. The SDK's own handler is private.
    function applyDiff(bytes calldata storageUpdates) external {
        (StateUpdateType[] memory types, bytes[] memory args) = abi.decode(storageUpdates, (StateUpdateType[], bytes[]));
        _beforeProgram();
        StateChangeHandlerLib._runStateUpdatesPrevalidated(types, args, _settlementRanges(), _callPolicy());
        _afterProgram();
    }
}
