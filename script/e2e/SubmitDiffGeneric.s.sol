// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {IBLSSignatureCheckerTypes} from "@eigenlayer-middleware/interfaces/IBLSSignatureChecker.sol";

/// @dev Minimal surface of any GasKillerSDK consumer (verifyAndUpdate is on IGasKillerSDK; getMessageHash
///      and stateTransitionCount live on GasKillerSDK/StateTracker, so we re-declare them here).
interface IConsumer {
    function stateTransitionCount() external view returns (uint256);
    function getMessageHash(uint256, bytes4, bytes calldata) external view returns (bytes32);
    function verifyAndUpdate(
        bytes32,
        bytes calldata,
        uint32,
        bytes calldata,
        uint256,
        bytes4,
        IBLSSignatureCheckerTypes.NonSignerStakesAndSignature calldata
    ) external;
}

/// @notice Route ANY consumer's extracted diff through the real `verifyAndUpdate` entrypoint (mock BLS).
/// @dev Reads TARGET (address), DIFF (0x… bytes from the extractor), SIG (e.g. "step(uint32)"). The BLS
///      signature is the empty struct — the e2e wires a MockBLSSignatureChecker that passes the quorum,
///      because the full operator set can't run locally (see SECURITY.md). What this proves is that the
///      extractor's exact diff bytes are accepted and applied by `verifyAndUpdate`.
contract SubmitDiffGeneric is Script {
    function run() external {
        IConsumer c = IConsumer(vm.envAddress("TARGET"));
        bytes memory diff = vm.envBytes("DIFF");
        bytes4 sel = bytes4(keccak256(bytes(vm.envString("SIG"))));
        uint256 ti = c.stateTransitionCount();
        bytes32 msgHash = c.getMessageHash(ti, sel, diff);
        uint32 referenceBlockNumber = uint32(block.number - 1);
        IBLSSignatureCheckerTypes.NonSignerStakesAndSignature memory nss; // empty; mock ignores it

        vm.startBroadcast();
        c.verifyAndUpdate(msgHash, hex"00", referenceBlockNumber, diff, ti, sel, nss);
        vm.stopBroadcast();

        console.log("verifyAndUpdate landed the extracted diff; new stateTransitionCount:", c.stateTransitionCount());
    }
}
