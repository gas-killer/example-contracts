// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Vm} from "forge-std/Vm.sol";

/// @notice Minimal view surface of a deployed Gas Killer consumer (GasKillerSDK getters, plus the
///         ArraySummation example's own state so a test can show it has really been computed).
interface ILiveConsumer {
    function avsAddress() external view returns (address);
    function blsSignatureChecker() external view returns (address);
    function stateTransitionCount() external view returns (uint256);
    function QUORUM_THRESHOLD() external view returns (uint8);
    function getArrayLength() external view returns (uint256);
    function currentSum() external view returns (uint256);
}

/// @notice The one getter needed to walk from a signature checker to the operator set it verifies
///         against.
interface ILiveSignatureChecker {
    function registryCoordinator() external view returns (address);
}

interface ILiveRegistryCoordinator {
    function stakeRegistry() external view returns (address);
}

interface ILiveStakeRegistry {
    function getCurrentTotalStake(uint8 quorumNumber) external view returns (uint96);
}

/// @notice Resolves the live AVS wiring from a single reference consumer, on chain.
///
///         Everything except that one address is derived rather than written down, because a
///         written-down set goes stale silently. The testnet stack is redeployed periodically and
///         each deployment provisions its own `BLSSignatureChecker`, so a consumer wired to a
///         superseded checker passes every off-chain check, is handed a signed payload, and then
///         reverts `InvalidQuorumApkHash` on submission — the router computes quorum APK indices
///         against the live registry while the contract checks them against the old one.
///
///         Deriving turns five addresses that can rot into one, and that one is an environment
///         input (`GK_LIVE_INSTANCE`) so following a redeployment is a config change rather than an
///         edit to test source. `resolve` checks every hop for code, so a reference that has rotted
///         names the broken hop instead of failing as a bare revert.
library LiveDeployment {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice Reference consumer used when `GK_LIVE_INSTANCE` is unset.
    ///
    ///         A consumer deployed by the hosted service's own target job: wired to the checker that
    ///         job provisioned, with a settled `stateTransitionCount`. Whether it is still the
    ///         *current* deployment cannot be determined on chain — a superseded stack stays
    ///         deployed and keeps its staked operators, so it reads identically to a current one.
    ///         The authoritative answer is the `contracts` block of
    ///         `GET https://testnet.gaskiller.xyz/avs-metadata`; point `GK_LIVE_INSTANCE` at what
    ///         that returns rather than editing this default, so a CI job can track redeployments
    ///         without a code change.
    address internal constant DEFAULT_LIVE_INSTANCE = 0xF143a9D93045474C2B573d21AC1CCe8dB2b06dbD;

    struct Wiring {
        address consumer;
        address avs;
        address checker;
        address coordinator;
        address stakeRegistry;
    }

    /// @notice The reference consumer every other address is derived from: `GK_LIVE_INSTANCE` if
    ///         set, otherwise `DEFAULT_LIVE_INSTANCE`.
    ///
    ///         Sole home of this address — a second copy in a test contract is the drift this
    ///         library exists to prevent, one order of magnitude smaller.
    function liveInstance() internal view returns (address) {
        return VM.envOr("GK_LIVE_INSTANCE", DEFAULT_LIVE_INSTANCE);
    }

    /// @notice Walks consumer → checker → coordinator → stake registry.
    ///
    ///         Every hop is checked for code before it is used. Without that, an address with no
    ///         code — a torn-down deployment, or a mistyped `GK_LIVE_INSTANCE` — trips Solidity's
    ///         extcodesize guard on the first high-level call and surfaces as a bare
    ///         `EvmError: Revert` at ~7k gas, before any assertion runs and naming neither the hop
    ///         nor the input responsible. `avs` is checked too even though nothing here calls it,
    ///         because callers wire contracts to it and a codeless AVS would go unnoticed.
    function resolve(address consumer) internal view returns (Wiring memory wiring) {
        require(consumer.code.length > 0, "LiveDeployment: no code at GK_LIVE_INSTANCE; refresh it from /avs-metadata");
        ILiveConsumer c = ILiveConsumer(consumer);
        wiring.consumer = consumer;

        wiring.avs = c.avsAddress();
        require(wiring.avs.code.length > 0, "LiveDeployment: no code at the consumer's avsAddress");

        wiring.checker = c.blsSignatureChecker();
        require(wiring.checker.code.length > 0, "LiveDeployment: no code at the consumer's blsSignatureChecker");

        wiring.coordinator = ILiveSignatureChecker(wiring.checker).registryCoordinator();
        require(wiring.coordinator.code.length > 0, "LiveDeployment: no code at the checker's registryCoordinator");

        wiring.stakeRegistry = ILiveRegistryCoordinator(wiring.coordinator).stakeRegistry();
        require(wiring.stakeRegistry.code.length > 0, "LiveDeployment: no code at the coordinator's stakeRegistry");
    }

    /// @notice Resolves the wiring from `liveInstance()`.
    function resolve() internal view returns (Wiring memory) {
        return resolve(liveInstance());
    }

    /// @notice Total stake registered in a quorum.
    ///
    ///         Non-zero means the stack has operators registered with stake, i.e. it is a complete
    ///         deployment rather than a half-provisioned one whose registries are empty.
    ///
    ///         It does **not** say the stack is the one the hosted service currently uses. A
    ///         superseded deployment keeps its registered operators and its stake — nothing
    ///         deregisters them — so every on-chain reading looks identical to a current one. Which
    ///         stack is current is off-chain information, held in the router's `avs_deploy.json` and
    ///         published as the `contracts` block of `GET /avs-metadata`; no assertion here can
    ///         substitute for it.
    function quorumStake(Wiring memory wiring, uint8 quorumNumber) internal view returns (uint96) {
        return ILiveStakeRegistry(wiring.stakeRegistry).getCurrentTotalStake(quorumNumber);
    }
}
