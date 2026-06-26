// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {OnchainLife} from "../../src/examples/onchain-life/OnchainLife.sol";

/// @notice Test-only subclass exposing the internal diff applier so benchmarks can measure the
///         pure cost of applying a storage diff (raw sstore/log) in isolation from BLS verification.
///         Mirrors the SDK's own `GasKillerSDKExposed.stateChangeHandlerExternal`.
contract OnchainLifeExposed is OnchainLife {
    constructor(address avs, address bls, uint256[16] memory seed) OnchainLife(avs, bls, seed) {}

    function applyDiff(bytes calldata storageUpdates) external {
        _stateChangeHandler(storageUpdates);
    }
}
