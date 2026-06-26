// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {GuardedVault} from "../../src/examples/guarded-vault/GuardedVault.sol";
import {GuardedVaultExposed} from "../exposed/GuardedVaultExposed.sol";
import {OffchainPayloadBuilder} from "../helpers/OffchainPayloadBuilder.sol";
import {IBLSSignatureCheckerTypes} from "@eigenlayer-middleware/interfaces/IBLSSignatureChecker.sol";

/// @notice Minimal view surface of a deployed Gas Killer consumer (GasKillerSDK getters).
interface ILiveConsumer {
    function avsAddress() external view returns (address);
    function blsSignatureChecker() external view returns (address);
    function stateTransitionCount() external view returns (uint256);
    function QUORUM_THRESHOLD() external view returns (uint8);
    function getArrayLength() external view returns (uint256);
    function currentSum() external view returns (uint256);
}

/// @title SepoliaLiveTest
/// @notice Integrates against the REAL Gas Killer AVS stack deployed on Sepolia (chain 11155111),
///         discovered on-chain via the live `ArraySummationFactory` (0xf7ded7…). These tests fork
///         Sepolia, so they only run when `SEPOLIA_RPC_URL` is set; otherwise they skip (default
///         `forge test` is unaffected).
///
///         What this proves: the testnet deployment is real (we read a live consumer + its wired
///         BLSSignatureChecker), and our own examples integrate with it (we wire `GuardedVault` to the
///         real on-chain checker and show `verifyAndUpdate` is gated by it). What it does NOT do:
///         produce a PASSING signed `verifyAndUpdate` — that requires the operator set to BLS-sign our
///         contract's message hash, and those operator keys are not on disk (the AVS stacks found are
///         ephemeral test deployments, not a hosted service). See SECURITY.md.
contract SepoliaLiveTest is Test {
    // Real, complete AVS stack on Sepolia (instance 0x0cBf63… via ArraySummationFactory 0xf7ded7…).
    address constant LIVE_INSTANCE = 0x0cBf633E948E005d58a0B7623D4e14d5Ba015F52;
    address constant LIVE_AVS = 0x2015983cDd409B1838F4C1cCa9085c946C5A9F81;
    address constant LIVE_BLS_CHECKER = 0x22FfcFD8cCCb2e70dbd6FE1DAf951080595E02f2;

    function _forkOrSkip() internal returns (bool) {
        string memory rpc = vm.envOr("SEPOLIA_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return false;
        }
        vm.createSelectFork(rpc);
        return true;
    }

    /// @notice Read the live deployed Gas Killer consumer on Sepolia — proof the testnet deployment exists.
    function test_live_readsRealSepoliaDeployment() public {
        if (!_forkOrSkip()) return;

        ILiveConsumer c = ILiveConsumer(LIVE_INSTANCE);
        assertEq(c.blsSignatureChecker(), LIVE_BLS_CHECKER, "wired to the real checker");
        assertEq(c.avsAddress(), LIVE_AVS, "wired to the real AVS");
        assertEq(c.QUORUM_THRESHOLD(), 66, "66% quorum threshold");
        assertGt(LIVE_BLS_CHECKER.code.length, 0, "real BLSSignatureChecker has code on Sepolia");

        console.log("live ArraySummation:        ", LIVE_INSTANCE);
        console.log("  getArrayLength:           ", c.getArrayLength());
        console.log("  currentSum:               ", c.currentSum());
        console.log("  stateTransitionCount:     ", c.stateTransitionCount());
        console.log("  blsSignatureChecker:      ", c.blsSignatureChecker());
        console.log("  avsAddress:               ", c.avsAddress());
    }

    /// @notice Wire OUR GuardedVault to the REAL Sepolia BLSSignatureChecker and show verifyAndUpdate is
    ///         gated by real on-chain verification: an unsigned diff is rejected (we cannot forge a
    ///         quorum signature without the operator keys).
    function test_live_guardedVaultWiredToRealChecker_rejectsUnsignedDiff() public {
        if (!_forkOrSkip()) return;

        GuardedVaultExposed v = new GuardedVaultExposed(LIVE_AVS, LIVE_BLS_CHECKER, 5000);
        assertEq(v.blsSignatureChecker(), LIVE_BLS_CHECKER, "our vault is wired to the real checker");

        address d0 = address(0xD0);
        address d1 = address(0xD1);
        vm.prank(d0);
        v.deposit(1000);
        vm.prank(d1);
        v.deposit(1000);

        // A well-formed payload; only the BLS signature is missing.
        bytes memory diff =
            OffchainPayloadBuilder.store(OffchainPayloadBuilder.mappingSlot(d0, 0), bytes32(uint256(900)));
        uint256 transitionIndex = v.stateTransitionCount();
        bytes32 msgHash = v.getMessageHash(transitionIndex, GuardedVault.settle.selector, diff);
        IBLSSignatureCheckerTypes.NonSignerStakesAndSignature memory nss; // empty: no operator signed

        bool succeeded = true;
        try v.verifyAndUpdate(
            msgHash, hex"00", uint32(block.number - 1), diff, transitionIndex, GuardedVault.settle.selector, nss
        ) {
            succeeded = true;
        } catch {
            succeeded = false;
        }
        assertFalse(succeeded, "the REAL Sepolia BLSSignatureChecker must reject an unsigned diff");
        console.log("OK: real Sepolia BLSSignatureChecker rejected the unsigned verifyAndUpdate");
    }
}
