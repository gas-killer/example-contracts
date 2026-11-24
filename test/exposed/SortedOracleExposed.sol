// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {StateChangeHandlerLib, StateUpdateType} from "gas-killer-sdk/StateChangeHandlerLib.sol";
import {SortedOracle} from "../../src/examples/sorted-oracle/SortedOracle.sol";

/// @notice Test-only subclass exposing the internal diff applier so benchmarks can measure the pure
///         cost of applying a storage diff (raw sstore/log) in isolation from quorum verification.
///         Mirrors the SDK's own `GasKillerSDKExposed.stateChangeHandlerExternal`.
contract SortedOracleExposed is SortedOracle {
    constructor(address avs, address registry) SortedOracle(avs, registry) {}

    /// @dev Runs the diff as settlement does, under this contract's protected ranges and call
    ///      policy, without the quorum check. The SDK's own handler is private.
    function applyDiff(bytes calldata storageUpdates) external {
        (StateUpdateType[] memory types, bytes[] memory args) = abi.decode(storageUpdates, (StateUpdateType[], bytes[]));
        _beforeProgram();
        StateChangeHandlerLib._runStateUpdatesPrevalidated(types, args, _settlementRanges(), _callPolicy());
        _afterProgram();
    }
}
