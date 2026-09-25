// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {MockSchnorrStakeRegistry} from "../test/mocks/MockSchnorrStakeRegistry.sol";

/// @title DeployBase
/// @notice Shared deploy helpers for the example scripts.
/// @dev These scripts are DEMOS. If `SCHNORR_STAKE_REGISTRY_ADDRESS` is not set, a
///      `MockSchnorrStakeRegistry` is deployed so the example is runnable on a fresh anvil — that mock
///      does NO cryptography and must NEVER be used in production. A real deployment must wire the
///      AVS's existing `SchnorrStakeRegistry`, with its operator set already registered (see the SDK's
///      `DeployArraySummation.s.sol`).
abstract contract DeployBase is Script {
    /// @notice The AVS service-manager address the example is scoped to. Demo default if unset.
    function _avs() internal view returns (address) {
        return vm.envOr("AVS_ADDRESS", address(0xA75));
    }

    /// @notice Resolve the Schnorr stake registry: use SCHNORR_STAKE_REGISTRY_ADDRESS, or deploy a local mock.
    /// @dev Must be called inside an active broadcast.
    function _resolveRegistry() internal returns (address registry) {
        registry = vm.envOr("SCHNORR_STAKE_REGISTRY_ADDRESS", address(0));
        if (registry == address(0)) {
            registry = address(new MockSchnorrStakeRegistry());
            console.log(
                "WARNING: no SCHNORR_STAKE_REGISTRY_ADDRESS; deployed MockSchnorrStakeRegistry (LOCAL/DEMO ONLY):",
                registry
            );
        }
    }
}
