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
    /// @dev The single address this suite hardcodes. Everything else — AVS, checker, registry
    ///      coordinator, stake registry — is derived from it via `LiveDeployment.resolve`, so a
    ///      redeployment invalidates one constant rather than a table of five that can drift out of
    ///      agreement with each other.
    ///
    ///      A consumer deployed by the hosted service's own target job, wired to the checker that
    ///      job provisioned and with a settled `stateTransitionCount`. Whether it is still the
    ///      *current* deployment is not something these tests can determine — a superseded stack
    ///      stays deployed and keeps its staked operators, so it reads identically. Refresh this
    ///      from the `contracts` block of `GET https://testnet.gaskiller.xyz/avs-metadata`, which is
    ///      the only authoritative answer.
    address constant LIVE_INSTANCE = 0xF143a9D93045474C2B573d21AC1CCe8dB2b06dbD;

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
        LiveDeployment.Wiring memory w = LiveDeployment.resolve(LIVE_INSTANCE);

        assertEq(c.QUORUM_THRESHOLD(), 66, "66% quorum threshold");
        assertGt(w.checker.code.length, 0, "the wired BLSSignatureChecker has code on Sepolia");
        assertGt(w.avs.code.length, 0, "the wired AVS has code on Sepolia");
        assertGt(w.coordinator.code.length, 0, "the checker resolves to a registry coordinator");

        // The stack is complete: operators are registered with stake, not a half-provisioned
        // deployment with empty registries.
        //
        // This deliberately does not claim LIVE_INSTANCE is the *current* deployment. A superseded
        // stack keeps its operators and their stake, so it reads identically here — which stack the
        // hosted service signs for is off-chain information, published as the `contracts` block of
        // `GET /avs-metadata`. The real wiring guard is SepoliaSubmitTest: assembling quorum data
        // from this coordinator and having this checker accept it proves the two agree.
        assertGt(
            LiveDeployment.quorumStake(w, 0),
            0,
            "quorum 0 has no registered stake: LIVE_INSTANCE points at an incomplete AVS stack"
        );

        console.log("live ArraySummation:        ", LIVE_INSTANCE);
        console.log("  getArrayLength:           ", c.getArrayLength());
        console.log("  currentSum:               ", c.currentSum());
        console.log("  stateTransitionCount:     ", c.stateTransitionCount());
        console.log("  avsAddress:               ", w.avs);
        console.log("  blsSignatureChecker:      ", w.checker);
        console.log("  registryCoordinator:      ", w.coordinator);
        console.log("  stakeRegistry:            ", w.stakeRegistry);
        console.log("  quorum 0 total stake:     ", LiveDeployment.quorumStake(w, 0));
    }

    /// @notice Wire OUR GuardedVault to the REAL Sepolia BLSSignatureChecker and show verifyAndUpdate is
    ///         gated by real on-chain verification: an unsigned diff is rejected (we cannot forge a
    ///         quorum signature without the operator keys).
    function test_live_guardedVaultWiredToRealChecker_rejectsUnsignedDiff() public {
        if (!_forkOrSkip()) return;

        LiveDeployment.Wiring memory w = LiveDeployment.resolve(LIVE_INSTANCE);
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
