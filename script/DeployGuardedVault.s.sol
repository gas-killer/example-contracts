// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {DeployBase} from "./DeployBase.sol";
import {console} from "forge-std/Script.sol";
import {GuardedVault} from "../src/examples/guarded-vault/GuardedVault.sol";

/// @notice Deploy the GuardedVault.
/// @dev Env: AVS_ADDRESS (optional, demo default), SIG_CHECKER_ADDRESS (optional; mock if unset),
///      MAX_CONCENTRATION_BPS (optional, default 5000 = 50%).
contract DeployGuardedVault is DeployBase {
    function run() external returns (address vault) {
        uint256 maxBps = vm.envOr("MAX_CONCENTRATION_BPS", uint256(5000));

        vm.startBroadcast();
        address checker = _resolveChecker();
        vault = address(new GuardedVault(_avs(), checker, maxBps));
        vm.stopBroadcast();

        console.log("GuardedVault:", vault);
        console.log("AVS:", _avs());
        console.log("BLS checker:", checker);
        console.log("maxConcentrationBps:", maxBps);
    }
}
