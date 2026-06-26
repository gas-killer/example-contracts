// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {OnchainLeaderboard} from "../../src/examples/onchain-leaderboard/OnchainLeaderboard.sol";

/// @notice Test-only subclass exposing the internal diff applier for isolated gas measurement and for
///         cheaply seeding a large board (one O(N) applyDiff instead of N naive submits).
contract OnchainLeaderboardExposed is OnchainLeaderboard {
    constructor(address avs, address bls) OnchainLeaderboard(avs, bls) {}

    function applyDiff(bytes calldata storageUpdates) external {
        _stateChangeHandler(storageUpdates);
    }
}
