// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {GasKillerSDK} from "gas-killer-sdk/GasKillerSDK.sol";
import {LiveSubmission} from "./LiveSubmission.sol";
import {OperatorStateRetriever} from "@eigenlayer-middleware/OperatorStateRetriever.sol";
import {ISlashingRegistryCoordinator} from "@eigenlayer-middleware/interfaces/ISlashingRegistryCoordinator.sol";
import {IBLSSignatureCheckerTypes} from "@eigenlayer-middleware/interfaces/IBLSSignatureChecker.sol";
import {BN254} from "@eigenlayer-middleware/libraries/BN254.sol";

/// @title SubmitLive
/// @notice Submit a `verifyAndUpdate` to a live Gas Killer consumer. It computes everything
///         deterministically (msgHash + all registry indices + quorum APKs via OperatorStateRetriever
///         and BLSApkRegistry) and plugs in the ONE thing the EXISTING operator service must provide:
///         the aggregate BLS signature `(sigma, apkG2)` over the message hash.
///
///         Run this once the operator service has signed for your (transitionIndex, consumer,
///         targetFunction, storageUpdates). If the service instead returns/submits the whole thing
///         itself, you don't need this script at all.
///
/// @dev Env:
///   CONSUMER                 deployed consumer address (inherits GasKillerSDK)
///   STORAGE_UPDATES          0x… ABI-encoded (StateUpdateType[],bytes[]) diff (from the analyzer)
///   TARGET_SIGNATURE         the tracked function signature, e.g. "settle(address[],int256[])"
///   REGISTRY_COORDINATOR     the AVS RegistryCoordinator
///   OPERATOR_STATE_RETRIEVER (optional) deployed OperatorStateRetriever; a fresh one is deployed if unset
///   QUORUM_NUMBERS           (optional) hex bytes, default 0x00
///   REF_BLOCK                (optional) reference block, default block.number-1
///   --- the seam, from the existing operator service ---
///   SIGMA_X, SIGMA_Y                          aggregate G1 signature over hashToG1(msgHash)
///   APKG2_X0, APKG2_X1, APKG2_Y0, APKG2_Y1    aggregate G2 public key of the signers
contract SubmitLive is Script {
    function run() external {
        GasKillerSDK consumer = GasKillerSDK(vm.envAddress("CONSUMER"));
        bytes memory storageUpdates = vm.envBytes("STORAGE_UPDATES");
        bytes4 targetFunction = bytes4(keccak256(bytes(vm.envString("TARGET_SIGNATURE"))));
        uint256 transitionIndex = consumer.stateTransitionCount();
        bytes32 msgHash = consumer.getMessageHash(transitionIndex, targetFunction, storageUpdates);

        console.log("consumer:        ", address(consumer));
        console.log("transitionIndex: ", transitionIndex);
        console.logBytes32(msgHash);

        vm.startBroadcast();
        _assembleAndSubmit(consumer, storageUpdates, targetFunction, transitionIndex, msgHash);
        vm.stopBroadcast();

        console.log("verifyAndUpdate submitted; new stateTransitionCount:", consumer.stateTransitionCount());
    }

    function _assembleAndSubmit(
        GasKillerSDK consumer,
        bytes memory storageUpdates,
        bytes4 targetFunction,
        uint256 transitionIndex,
        bytes32 msgHash
    ) internal {
        ISlashingRegistryCoordinator rc = ISlashingRegistryCoordinator(vm.envAddress("REGISTRY_COORDINATOR"));
        bytes memory quorumNumbers = vm.envOr("QUORUM_NUMBERS", bytes(hex"00"));
        uint32 refBlock = uint32(vm.envOr("REF_BLOCK", uint256(block.number - 1)));

        IBLSSignatureCheckerTypes.NonSignerStakesAndSignature memory nss =
            LiveSubmission.buildAllSigners(rc, _retriever(), quorumNumbers, refBlock, _sigma(), _apkG2());

        consumer.verifyAndUpdate(msgHash, quorumNumbers, refBlock, storageUpdates, transitionIndex, targetFunction, nss);
    }

    function _retriever() internal returns (OperatorStateRetriever) {
        address a = vm.envOr("OPERATOR_STATE_RETRIEVER", address(0));
        return a == address(0) ? new OperatorStateRetriever() : OperatorStateRetriever(a);
    }

    /// @dev The (sigma, apkG2) seam — produced by the existing AVS operator set / aggregator.
    function _sigma() internal view returns (BN254.G1Point memory) {
        return BN254.G1Point(vm.envUint("SIGMA_X"), vm.envUint("SIGMA_Y"));
    }

    function _apkG2() internal view returns (BN254.G2Point memory) {
        return BN254.G2Point(
            [vm.envUint("APKG2_X0"), vm.envUint("APKG2_X1")], [vm.envUint("APKG2_Y0"), vm.envUint("APKG2_Y1")]
        );
    }
}
