// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

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
///         Deriving turns five addresses that can rot into one, and makes the rot surface as a
///         clear assertion failure rather than a revert selector at submission time.
library LiveDeployment {
    struct Wiring {
        address consumer;
        address avs;
        address checker;
        address coordinator;
        address stakeRegistry;
    }

    /// @notice Walks consumer → checker → coordinator → stake registry.
    function resolve(address consumer) internal view returns (Wiring memory wiring) {
        ILiveConsumer c = ILiveConsumer(consumer);
        wiring.consumer = consumer;
        wiring.avs = c.avsAddress();
        wiring.checker = c.blsSignatureChecker();
        wiring.coordinator = ILiveSignatureChecker(wiring.checker).registryCoordinator();
        wiring.stakeRegistry = ILiveRegistryCoordinator(wiring.coordinator).stakeRegistry();
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
