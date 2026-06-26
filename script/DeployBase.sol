// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {MockBLSSignatureChecker} from "../test/mocks/MockBLSSignatureChecker.sol";

/// @title DeployBase
/// @notice Shared deploy helpers for the example scripts.
/// @dev These scripts are DEMOS. If `SIG_CHECKER_ADDRESS` is not set, a `MockBLSSignatureChecker`
///      is deployed so the example is runnable on a fresh anvil — that mock does NO cryptography and
///      must NEVER be used in production. A real deployment must wire a real EigenLayer
///      `BLSSignatureChecker` bound to a registry coordinator (see the SDK's `ArraySummation.s.sol`).
abstract contract DeployBase is Script {
    /// @notice The AVS service-manager address (scopes the Gas Killer namespace). Demo default if unset.
    function _avs() internal view returns (address) {
        return vm.envOr("AVS_ADDRESS", address(0xA75));
    }

    /// @notice Resolve the BLS signature checker: use SIG_CHECKER_ADDRESS, or deploy a local mock.
    /// @dev Must be called inside an active broadcast.
    function _resolveChecker() internal returns (address checker) {
        checker = vm.envOr("SIG_CHECKER_ADDRESS", address(0));
        if (checker == address(0)) {
            checker = address(new MockBLSSignatureChecker());
            console.log("WARNING: no SIG_CHECKER_ADDRESS; deployed MockBLSSignatureChecker (LOCAL/DEMO ONLY):", checker);
        }
    }
}
