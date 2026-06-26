// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {GuardedVault} from "../../src/examples/guarded-vault/GuardedVault.sol";
import {IBLSSignatureCheckerTypes} from "@eigenlayer-middleware/interfaces/IBLSSignatureChecker.sol";

/// @notice Submit an analyzer-produced storage diff to a GuardedVault via `verifyAndUpdate`.
/// @dev Reads VAULT (address) and DIFF (0x… bytes, the real analyzer output) from the environment.
///      The BLS signature is the empty struct — these e2e demos wire a MockBLSSignatureChecker that
///      passes the quorum check, because the full BLS-signed operator set can't run in a local demo
///      (see SECURITY.md). The point this proves is that the REAL analyzer's diff is byte-for-byte
///      what `verifyAndUpdate` needs.
contract SubmitDiff is Script {
    function run() external {
        address vault = vm.envAddress("VAULT");
        bytes memory diff = vm.envBytes("DIFF");
        GuardedVault v = GuardedVault(vault);

        bytes4 sel = GuardedVault.settle.selector;
        uint256 transitionIndex = v.stateTransitionCount();
        bytes32 msgHash = v.getMessageHash(transitionIndex, sel, diff);
        uint32 referenceBlockNumber = uint32(block.number - 1);
        IBLSSignatureCheckerTypes.NonSignerStakesAndSignature memory nss; // empty; mock ignores it

        vm.startBroadcast();
        v.verifyAndUpdate(msgHash, hex"00", referenceBlockNumber, diff, transitionIndex, sel, nss);
        vm.stopBroadcast();

        console.log("verifyAndUpdate landed the analyzer diff on:", vault);
        console.log("new stateTransitionCount:", v.stateTransitionCount());
    }
}
