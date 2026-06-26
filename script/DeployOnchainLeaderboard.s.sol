// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {DeployBase} from "./DeployBase.sol";
import {console} from "forge-std/Script.sol";
import {OnchainLeaderboard} from "../src/examples/onchain-leaderboard/OnchainLeaderboard.sol";

/// @notice Deploy the OnchainLeaderboard.
/// @dev Env: AVS_ADDRESS (optional, demo default), SIG_CHECKER_ADDRESS (optional; mock if unset).
contract DeployOnchainLeaderboard is DeployBase {
    function run() external returns (address leaderboard) {
        vm.startBroadcast();
        address checker = _resolveChecker();
        leaderboard = address(new OnchainLeaderboard(_avs(), checker));
        vm.stopBroadcast();

        console.log("OnchainLeaderboard:", leaderboard);
        console.log("AVS:", _avs());
        console.log("BLS checker:", checker);
    }
}
