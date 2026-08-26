// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {GuardedVault} from "../../src/examples/guarded-vault/GuardedVault.sol";
import {GuardedVaultExposed} from "../exposed/GuardedVaultExposed.sol";
import {OffchainPayloadBuilder} from "../helpers/OffchainPayloadBuilder.sol";
import {IBLSSignatureCheckerTypes} from "@eigenlayer-middleware/interfaces/IBLSSignatureChecker.sol";
import {ILiveConsumer, LiveDeployment} from "../helpers/LiveDeployment.sol";

/// @title SepoliaLiveTest
/// @notice Integrates against the REAL Gas Killer AVS stack deployed on Sepolia (chain 11155111) —
///         the one backing the hosted service at `https://testnet.gaskiller.xyz`. These tests fork
///         Sepolia, so they only run when `SEPOLIA_RPC_URL` is set; otherwise they skip (default
///         `forge test` is unaffected).
///
///         What this proves: the testnet deployment is real and currently staked (we read a live
///         consumer, walk to the operator set behind it, and check that set has stake), and our own
///         examples integrate with it (we wire `GuardedVault` to the real on-chain checker and show
///         `verifyAndUpdate` is gated by it). What it does NOT do: produce a PASSING signed
///         `verifyAndUpdate` — that requires the operator set to BLS-sign our contract's message
///         hash, and those operator keys are not on disk. Driving a real signature means going
///         through the hosted service; see `docs/LIVE-INTEGRATION.md` and SECURITY.md.
contract SepoliaLiveTest is Test {
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

        // Resolving is itself the existence proof: `LiveDeployment.resolve` walks the reference
        // consumer down to the stake registry and requires code at every hop, naming the broken one
        // if any is missing.
        LiveDeployment.Wiring memory w = LiveDeployment.resolve();
        ILiveConsumer c = ILiveConsumer(w.consumer);
        uint96 quorum0Stake = LiveDeployment.quorumStake(w, 0);

        assertEq(c.QUORUM_THRESHOLD(), 66, "66% quorum threshold");

        // The stack is complete: operators are registered with stake, not a half-provisioned
        // deployment with empty registries.
        //
        // This deliberately does not claim the reference consumer belongs to the *current*
        // deployment. A superseded stack keeps its operators and their stake, so it reads
        // identically here — which stack the hosted service signs for is off-chain information,
        // published as the `contracts` block of `GET /avs-metadata`. The real wiring guard is
        // SepoliaSubmitTest: assembling quorum data from this coordinator and having this checker
        // accept it proves the two agree.
        assertGt(
            quorum0Stake, 0, "quorum 0 has no registered stake: GK_LIVE_INSTANCE points at an incomplete AVS stack"
        );

        console.log("live ArraySummation:        ", w.consumer);
        console.log("  getArrayLength:           ", c.getArrayLength());
        console.log("  currentSum:               ", c.currentSum());
        console.log("  stateTransitionCount:     ", c.stateTransitionCount());
        console.log("  avsAddress:               ", w.avs);
        console.log("  blsSignatureChecker:      ", w.checker);
        console.log("  registryCoordinator:      ", w.coordinator);
        console.log("  stakeRegistry:            ", w.stakeRegistry);
        console.log("  quorum 0 total stake:     ", quorum0Stake);
    }

    /// @notice Wire OUR GuardedVault to the REAL Sepolia BLSSignatureChecker and show verifyAndUpdate is
    ///         gated by real on-chain verification: an unsigned diff is rejected (we cannot forge a
    ///         quorum signature without the operator keys).
    function test_live_guardedVaultWiredToRealChecker_rejectsUnsignedDiff() public {
        if (!_forkOrSkip()) return;

        LiveDeployment.Wiring memory w = LiveDeployment.resolve();
        GuardedVaultExposed v = new GuardedVaultExposed(w.avs, w.checker, 5000);
        assertEq(v.blsSignatureChecker(), w.checker, "our vault is wired to the real checker");

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
