// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {DeployBase} from "./DeployBase.sol";
import {console} from "forge-std/Script.sol";
import {OnchainLife} from "../src/examples/onchain-life/OnchainLife.sol";

/// @notice Deploy OnchainLife seeded with a glider near the top-left corner.
/// @dev Env: AVS_ADDRESS (optional, demo default), SIG_CHECKER_ADDRESS (optional; mock if unset).
contract DeployOnchainLife is DeployBase {
    function run() external returns (address life) {
        uint256[16] memory seed = _gliderSeed();

        vm.startBroadcast();
        address checker = _resolveChecker();
        life = address(new OnchainLife(_avs(), checker, seed));
        vm.stopBroadcast();

        console.log("OnchainLife:", life);
        console.log("AVS:", _avs());
        console.log("BLS checker:", checker);
    }

    /// @dev A standard glider at the top-left: cells (1,0),(2,1),(0,2),(1,2),(2,2). All in word 0.
    function _gliderSeed() internal pure returns (uint256[16] memory seed) {
        _set(seed, 1, 0);
        _set(seed, 2, 1);
        _set(seed, 0, 2);
        _set(seed, 1, 2);
        _set(seed, 2, 2);
    }

    function _set(uint256[16] memory b, uint256 x, uint256 y) internal pure {
        uint256 idx = y * 64 + x;
        b[idx >> 8] |= (uint256(1) << (idx & 255));
    }
}
