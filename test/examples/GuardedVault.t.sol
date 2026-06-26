// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BenchmarkBase} from "../helpers/BenchmarkBase.sol";
import {Vm} from "forge-std/Vm.sol";
import {GuardedVault} from "../../src/examples/guarded-vault/GuardedVault.sol";
import {GuardedVaultExposed} from "../exposed/GuardedVaultExposed.sol";
import {MockBLSSignatureChecker} from "../mocks/MockBLSSignatureChecker.sol";
import {OffchainPayloadBuilder} from "../helpers/OffchainPayloadBuilder.sol";
import {StateUpdateType} from "gas-killer-sdk/StateChangeHandlerLib.sol";
import {IGasKillerSDK} from "gas-killer-sdk/interface/IGasKillerSDK.sol";

/// @notice Shared fixtures + helpers for the GuardedVault unit tests and benchmarks.
abstract contract VaultTestKit is BenchmarkBase {
    MockBLSSignatureChecker internal bls;
    address internal avs = makeAddr("avs");
    uint256 internal constant MAX_BPS = 5000; // 50% concentration cap

    // Slots (verified via `forge inspect`): shares@0, totalShares@1, totalAssets@2, depositors@3.
    uint256 internal constant SHARES_SLOT = 0;
    uint256 internal constant TOTAL_SHARES_SLOT = 1;
    uint256 internal constant TOTAL_ASSETS_SLOT = 2;
    bytes32 internal constant SETTLED_SIG = keccak256("Settled(uint256)");

    function setUp() public virtual {
        bls = _deployPassingBls();
    }

    function _newVault() internal returns (GuardedVaultExposed) {
        return new GuardedVaultExposed(avs, address(bls), MAX_BPS);
    }

    function _depositor(uint256 i) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode("depositor", i)))));
    }

    /// @dev Seed `n` depositors each holding `perUser` shares (1:1 assets). Returns the addresses.
    function _seedEqual(GuardedVaultExposed v, uint256 n, uint256 perUser) internal returns (address[] memory ds) {
        ds = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            address d = _depositor(i);
            ds[i] = d;
            vm.prank(d);
            v.deposit(perUser);
        }
    }

    /// @dev The diff an operator submits for a settle: one balance STORE per touched user (final
    ///      shares) + a Settled LOG1. totalShares is unchanged (conserving settle), so it is omitted.
    function _buildSettleDiff(GuardedVault v, address[] memory users) internal view returns (bytes memory) {
        OffchainPayloadBuilder.Op[] memory ops = new OffchainPayloadBuilder.Op[](users.length + 1);
        for (uint256 i = 0; i < users.length; i++) {
            ops[i] = OffchainPayloadBuilder.Op(
                StateUpdateType.STORE,
                OffchainPayloadBuilder.encodeStore(
                    OffchainPayloadBuilder.mappingSlot(users[i], SHARES_SLOT), bytes32(v.shares(users[i]))
                )
            );
        }
        ops[users.length] = OffchainPayloadBuilder.Op(
            StateUpdateType.LOG1, OffchainPayloadBuilder.encodeLog1(abi.encode(users.length), SETTLED_SIG)
        );
        return OffchainPayloadBuilder.build(ops);
    }

    /// @dev Mimics an honest operator's pre-sign gate: simulate landing `diff`, run the invariant on
    ///      the resulting post-state, then undo the simulation. Returns true iff the invariant holds —
    ///      i.e. iff an honest operator would BLS-sign this diff. This is the example's whole point:
    ///      the (expensive) invariant runs off-chain, during the transaction, before anything lands.
    function _operatorApproves(GuardedVaultExposed v, bytes memory diff) internal returns (bool ok) {
        uint256 snap = vm.snapshotState();
        v.applyDiff(diff);
        try v.checkInvariant() {
            ok = true;
        } catch {
            ok = false;
        }
        vm.revertToState(snap);
    }
}

contract GuardedVaultTest is VaultTestKit {
    function test_deposit_establishesInvariant() public {
        GuardedVaultExposed v = _newVault();
        _seedEqual(v, 5, 1000);
        assertEq(v.totalShares(), 5000);
        assertEq(v.totalAssets(), 5000);
        assertEq(v.depositorCount(), 5);
        v.checkInvariant(); // must not revert
        assertTrue(v.isHealthy());
    }

    /* ------------------------------------------------------------------ */
    /*       Valid settle: naive spec == operator diff (verifyAndUpdate)   */
    /* ------------------------------------------------------------------ */

    function test_validSettle_equivalence() public {
        GuardedVaultExposed A = _newVault();
        GuardedVaultExposed B = _newVault();
        _seedEqual(A, 5, 1000);
        _seedEqual(B, 5, 1000);

        // A conserving redistribution: move 200 shares from d0 to d1.
        address[] memory users = new address[](2);
        users[0] = _depositor(0);
        users[1] = _depositor(1);
        int256[] memory deltas = new int256[](2);
        deltas[0] = -200;
        deltas[1] = 200;

        // Operator simulates the spec on a sandbox (here, vault B); the on-chain guard inside settle
        // passes, so a diff can be produced.
        vm.recordLogs();
        B.settle(users, deltas);
        Vm.Log[] memory bLogs = vm.getRecordedLogs();
        bytes memory diff = _buildSettleDiff(B, users);

        // Honest operator re-checks the diff against vault A's state before signing.
        assertTrue(_operatorApproves(A, diff), "operator should approve a conserving, in-cap settle");

        // Land it via the full verifyAndUpdate path (mock BLS) and capture logs.
        uint256 countBefore = A.stateTransitionCount();
        vm.recordLogs();
        _verify(A, diff, GuardedVault.settle.selector);
        Vm.Log[] memory aLogs = vm.getRecordedLogs();

        // A now matches B, slot-by-slot, and the invariant still holds on-chain.
        assertEq(A.shares(_depositor(0)), 800);
        assertEq(A.shares(_depositor(1)), 1200);
        for (uint256 i = 0; i < 5; i++) {
            bytes32 slot = OffchainPayloadBuilder.mappingSlot(_depositor(i), SHARES_SLOT);
            assertEq(vm.load(address(A), slot), vm.load(address(B), slot), "share slot mismatch");
        }
        assertEq(A.totalShares(), B.totalShares());
        assertEq(A.stateTransitionCount(), countBefore + 1);
        A.checkInvariant();

        // Settled log matches.
        assertEq(_findSettledLog(aLogs).topics[0], _findSettledLog(bLogs).topics[0]);
        assertEq(keccak256(_findSettledLog(aLogs).data), keccak256(_findSettledLog(bLogs).data));
    }

    /* ------------------------------------------------------------------ */
    /*   The guard: honest operators reject diffs that break the invariant */
    /* ------------------------------------------------------------------ */

    /// @notice A diff that mints phantom shares (without updating totalShares) breaks conservation.
    ///         The operator's off-chain check catches it; the diff is never signed. We also prove the
    ///         check is load-bearing: applying it WOULD corrupt the vault (checkInvariant reverts).
    function test_guard_rejectsPhantomShares() public {
        GuardedVaultExposed v = _newVault();
        _seedEqual(v, 5, 1000); // total 5000, cap 2500

        // Bump d0 by 100 (stays under cap, but breaks Σshares == totalShares).
        bytes memory bad = OffchainPayloadBuilder.store(
            OffchainPayloadBuilder.mappingSlot(_depositor(0), SHARES_SLOT), bytes32(uint256(1100))
        );

        assertFalse(_operatorApproves(v, bad), "operator must reject a conservation-breaking diff");

        // Prove it is load-bearing: without the guard, the bad state lands and is detectably corrupt.
        v.applyDiff(bad);
        vm.expectRevert(abi.encodeWithSelector(GuardedVault.ConservationBroken.selector, uint256(5100), uint256(5000)));
        v.checkInvariant();
    }

    /// @notice A conserving diff that over-concentrates one depositor breaks the O(N) cap invariant.
    function test_guard_rejectsOverConcentration() public {
        GuardedVaultExposed v = _newVault();
        _seedEqual(v, 5, 1000); // total 5000, cap 2500

        // Conserving redistribution: pull 1600 into d0 (-> 2600 > 2500 cap), 400 out of each other.
        OffchainPayloadBuilder.Op[] memory ops = new OffchainPayloadBuilder.Op[](5);
        ops[0] = OffchainPayloadBuilder.Op(
            StateUpdateType.STORE,
            OffchainPayloadBuilder.encodeStore(
                OffchainPayloadBuilder.mappingSlot(_depositor(0), SHARES_SLOT), bytes32(uint256(2600))
            )
        );
        for (uint256 i = 1; i < 5; i++) {
            ops[i] = OffchainPayloadBuilder.Op(
                StateUpdateType.STORE,
                OffchainPayloadBuilder.encodeStore(
                    OffchainPayloadBuilder.mappingSlot(_depositor(i), SHARES_SLOT), bytes32(uint256(600))
                )
            );
        }
        bytes memory bad = OffchainPayloadBuilder.build(ops);

        assertFalse(_operatorApproves(v, bad), "operator must reject over-concentration");

        v.applyDiff(bad);
        vm.expectRevert(
            abi.encodeWithSelector(
                GuardedVault.ConcentrationExceeded.selector, _depositor(0), uint256(2600), uint256(2500)
            )
        );
        v.checkInvariant();
    }

    /// @notice A diff that inflates shares AND totalShares (conservation OK) but not assets breaks solvency.
    function test_guard_rejectsInsolvency() public {
        GuardedVaultExposed v = _newVault();
        _seedEqual(v, 5, 1000); // total 5000, assets 5000, cap 2500

        OffchainPayloadBuilder.Op[] memory ops = new OffchainPayloadBuilder.Op[](2);
        ops[0] = OffchainPayloadBuilder.Op(
            StateUpdateType.STORE,
            OffchainPayloadBuilder.encodeStore(
                OffchainPayloadBuilder.mappingSlot(_depositor(0), SHARES_SLOT), bytes32(uint256(1100))
            )
        );
        ops[1] = OffchainPayloadBuilder.Op(
            StateUpdateType.STORE,
            OffchainPayloadBuilder.encodeStore(bytes32(TOTAL_SHARES_SLOT), bytes32(uint256(5100)))
        );
        bytes memory bad = OffchainPayloadBuilder.build(ops);

        assertFalse(_operatorApproves(v, bad), "operator must reject an insolvent post-state");

        v.applyDiff(bad);
        vm.expectRevert(abi.encodeWithSelector(GuardedVault.InsolventVault.selector, uint256(5000), uint256(5100)));
        v.checkInvariant();
    }

    /// @notice LIMITATION (honest): the invariant only enumerates `depositors[]`, so a diff that gives
    ///         shares to an address never registered as a depositor ESCAPES the conservation sum. An
    ///         honest operator never builds such a diff (settle only touches isDepositor users), so this
    ///         is subsumed by the >=66%-malicious-quorum trust model — but it shows an invariant is only
    ///         as complete as the state it covers. See the COMPLETENESS CAVEAT in GuardedVault.sol.
    function test_guard_limitation_phantomOnNonDepositorEscapes() public {
        GuardedVaultExposed v = _newVault();
        _seedEqual(v, 5, 1000); // total 5000; depositors = d0..d4
        address ghost = makeAddr("ghost"); // never deposited; not in depositors[]

        // Give ghost 1000 unbacked shares without touching totalShares or depositors[].
        bytes memory sneaky = OffchainPayloadBuilder.store(
            OffchainPayloadBuilder.mappingSlot(ghost, SHARES_SLOT), bytes32(uint256(1000))
        );

        // The guard does NOT catch this — checkInvariant never sees `ghost`.
        assertTrue(_operatorApproves(v, sneaky), "invariant cannot see un-enumerated state (documented limitation)");

        // The unbacked shares really are present, and checkInvariant still passes.
        v.applyDiff(sneaky);
        assertEq(v.shares(ghost), 1000, "ghost holds shares the guard missed");
        v.checkInvariant(); // does NOT revert, despite ghost's unbacked shares
    }

    /// @notice The naive on-chain spec also reverts on a non-conserving settle (defense in depth).
    function test_settleSpec_revertsOnNonConserving() public {
        GuardedVaultExposed v = _newVault();
        _seedEqual(v, 3, 1000);
        address[] memory users = new address[](2);
        users[0] = _depositor(0);
        users[1] = _depositor(1);
        int256[] memory deltas = new int256[](2);
        deltas[0] = -200;
        deltas[1] = 300; // net +100 -> not conserving
        vm.expectRevert(abi.encodeWithSelector(GuardedVault.NonConservingSettle.selector, int256(100)));
        v.settle(users, deltas);
    }

    function test_verifyAndUpdate_revertsBelowThreshold() public {
        GuardedVaultExposed A = _newVault();
        GuardedVaultExposed B = _newVault();
        _seedEqual(A, 5, 1000);
        _seedEqual(B, 5, 1000);
        address[] memory users = new address[](2);
        users[0] = _depositor(0);
        users[1] = _depositor(1);
        int256[] memory deltas = new int256[](2);
        deltas[0] = -200;
        deltas[1] = 200;
        B.settle(users, deltas);
        bytes memory diff = _buildSettleDiff(B, users);

        bls.setSignedBps(6599);
        if (block.number == 0) vm.roll(1);
        uint256 ti = A.stateTransitionCount();
        bytes32 h = A.getMessageHash(ti, GuardedVault.settle.selector, diff);
        vm.expectRevert(IGasKillerSDK.InsufficientQuorumThreshold.selector);
        A.verifyAndUpdate(
            h, _quorumNumbers(), uint32(block.number - 1), diff, ti, GuardedVault.settle.selector, _emptySignature()
        );
    }

    function _findSettledLog(Vm.Log[] memory logs) internal pure returns (Vm.Log memory) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length >= 1 && logs[i].topics[0] == SETTLED_SIG) {
                return logs[i];
            }
        }
        revert("Settled log not found");
    }
}
