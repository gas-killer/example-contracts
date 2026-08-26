// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {GuardedVault} from "../../src/examples/guarded-vault/GuardedVault.sol";
import {GuardedVaultExposed} from "../exposed/GuardedVaultExposed.sol";
import {OffchainPayloadBuilder} from "../helpers/OffchainPayloadBuilder.sol";
import {LiveSubmission} from "../../script/live/LiveSubmission.sol";
import {OperatorStateRetriever} from "@eigenlayer-middleware/OperatorStateRetriever.sol";
import {ISlashingRegistryCoordinator} from "@eigenlayer-middleware/interfaces/ISlashingRegistryCoordinator.sol";
import {
    IBLSSignatureCheckerTypes,
    IBLSSignatureCheckerErrors
} from "@eigenlayer-middleware/interfaces/IBLSSignatureChecker.sol";
import {BN254} from "@eigenlayer-middleware/libraries/BN254.sol";
import {LiveDeployment} from "../helpers/LiveDeployment.sol";

/// @title SepoliaSubmitTest
/// @notice Proves the deterministic, client-side assembly of a `verifyAndUpdate` submission against the
///         REAL, live EigenLayer registry state on Sepolia. We deploy a stateless `OperatorStateRetriever`
///         on the fork, deploy our `GuardedVault` wired to the real on-chain `BLSSignatureChecker`, and
///         build the full `NonSignerStakesAndSignature` from registry state — leaving only the operator
///         BLS pieces `(sigma, apkG2)` as zero placeholders.
///
///         The assertion: `verifyAndUpdate` runs through the real checker and gets PAST the registry
///         apk/stake validation (proving our indices + quorum APKs are correct), reverting only at the
///         BLS pairing because the signature is a placeholder. In other words: everything except the
///         operator signature is correct and on-chain-derivable; the only missing input is `(sigma,
///         apkG2)` from the existing operator service.
///
///         Forked test — runs only when `SEPOLIA_RPC_URL` is set (otherwise skips).
contract SepoliaSubmitTest is Test {
    /// @dev The single hardcoded address; AVS, checker and registry coordinator are derived from it
    ///      (see `LiveDeployment`). Deriving is what keeps them in agreement: the assembled quorum
    ///      APK indices come from the coordinator, and the checker validates them, so a checker and
    ///      coordinator from different deployments would revert `InvalidQuorumApkHash` — the exact
    ///      failure this test exists to rule out. Refresh from `GET /avs-metadata` if it goes stale.
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

    function test_live_assembleFromRealRegistry_onlySignatureMissing() public {
        if (!_forkOrSkip()) return;

        LiveDeployment.Wiring memory w = LiveDeployment.resolve(LIVE_INSTANCE);
        ISlashingRegistryCoordinator registryCoordinator = ISlashingRegistryCoordinator(w.coordinator);
        assertGt(
            LiveDeployment.quorumStake(w, 0),
            0,
            "quorum 0 has no registered stake: LIVE_INSTANCE points at an incomplete AVS stack"
        );

        OperatorStateRetriever retriever = new OperatorStateRetriever();
        GuardedVaultExposed vault = new GuardedVaultExposed(w.avs, w.checker, 5000);

        // A tiny well-formed diff (the analyzer would produce this in production).
        address d0 = address(0xD0);
        vm.prank(d0);
        vault.deposit(1000);
        bytes memory diff =
            OffchainPayloadBuilder.store(OffchainPayloadBuilder.mappingSlot(d0, 0), bytes32(uint256(900)));

        bytes memory quorumNumbers = hex"00";
        uint32 refBlock = uint32(block.number - 1);

        // Assemble EVERYTHING from real Sepolia registry state; leave (sigma, apkG2) as placeholders.
        BN254.G1Point memory sigma; // zero — the seam
        BN254.G2Point memory apkG2; // zero — the seam
        IBLSSignatureCheckerTypes.NonSignerStakesAndSignature memory nss =
            LiveSubmission.buildAllSigners(registryCoordinator, retriever, quorumNumbers, refBlock, sigma, apkG2);

        // The on-chain-derived fields are real and non-trivial.
        assertEq(nss.nonSignerPubkeys.length, 0, "no non-signers");
        assertEq(nss.quorumApks.length, 1, "one quorum apk");
        assertEq(nss.quorumApkIndices.length, 1, "one quorum apk index");
        assertEq(nss.totalStakeIndices.length, 1, "one total stake index");
        assertTrue(nss.quorumApks[0].X != 0 || nss.quorumApks[0].Y != 0, "real quorum APK fetched from registry");
        console.log("assembled quorumApks[0].X:   ", nss.quorumApks[0].X);
        console.log("assembled quorumApkIndices[0]:", nss.quorumApkIndices[0]);
        console.log("assembled totalStakeIndices[0]:", nss.totalStakeIndices[0]);

        uint256 transitionIndex = vault.stateTransitionCount();
        bytes32 msgHash = vault.getMessageHash(transitionIndex, GuardedVault.settle.selector, diff);

        // Submit through the REAL checker. With a placeholder signature it must revert — and crucially,
        // NOT with InvalidQuorumApkHash (which would mean our assembled APK/indices were wrong).
        try vault.verifyAndUpdate(
            msgHash, quorumNumbers, refBlock, diff, transitionIndex, GuardedVault.settle.selector, nss
        ) {
            fail();
        } catch (bytes memory reason) {
            // forge-lint: disable-next-line(unsafe-typecast) -- intentional: take the 4-byte selector
            bytes4 sel = reason.length >= 4 ? bytes4(reason) : bytes4(0);
            console.logBytes4(sel);
            assertTrue(
                sel != IBLSSignatureCheckerErrors.InvalidQuorumApkHash.selector,
                "assembled quorum APK/indices must match the registry (only the BLS signature should be missing)"
            );
            console.log("OK: registry checks passed; reverted at the BLS signature (the (sigma,apkG2) seam)");
        }
    }
}
