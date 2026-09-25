// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {MockSchnorrStakeRegistry} from "../test/mocks/MockSchnorrStakeRegistry.sol";

/// @notice Deploy a stand-alone MockSchnorrStakeRegistry (LOCAL/DEMO ONLY — performs no cryptography).
/// @dev Useful for wiring up the example contracts on a local anvil. Set SCHNORR_STAKE_REGISTRY_ADDRESS
///      to its address when deploying the examples to reuse one registry.
contract DeployMockRegistry is Script {
    function run() external returns (address registry) {
        vm.startBroadcast();
        registry = address(new MockSchnorrStakeRegistry());
        vm.stopBroadcast();
        console.log("MockSchnorrStakeRegistry:", registry);
    }
}
