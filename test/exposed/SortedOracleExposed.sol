// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {SortedOracle} from "../../src/examples/sorted-oracle/SortedOracle.sol";

/// @notice Test-only subclass exposing the internal diff applier so benchmarks can measure the pure
///         cost of applying a storage diff (raw sstore/log) in isolation from BLS verification.
///         Mirrors the SDK's own `GasKillerSDKExposed.stateChangeHandlerExternal`.
contract SortedOracleExposed is SortedOracle {
    constructor(address avs, address bls) SortedOracle(avs, bls) {}

    function applyDiff(bytes calldata storageUpdates) external {
        _stateChangeHandler(storageUpdates);
    }
}
