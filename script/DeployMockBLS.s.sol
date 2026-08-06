// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {MockBLSSignatureChecker} from "../test/mocks/MockBLSSignatureChecker.sol";

/// @notice Deploy a stand-alone MockBLSSignatureChecker (LOCAL/DEMO ONLY — performs no cryptography).
/// @dev Useful for wiring up the example contracts on a local anvil. Set SIG_CHECKER_ADDRESS to its
///      address when deploying the examples to reuse one checker.
contract DeployMockBLS is Script {
    function run() external returns (address checker) {
        vm.startBroadcast();
        checker = address(new MockBLSSignatureChecker());
        vm.stopBroadcast();
        console.log("MockBLSSignatureChecker:", checker);
    }
}
