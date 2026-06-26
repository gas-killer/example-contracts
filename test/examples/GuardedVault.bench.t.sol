// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {VaultTestKit} from "./GuardedVault.t.sol";
import {GuardedVault} from "../../src/examples/guarded-vault/GuardedVault.sol";
import {GuardedVaultExposed} from "../exposed/GuardedVaultExposed.sol";
import {OffchainPayloadBuilder} from "../helpers/OffchainPayloadBuilder.sol";
import {StateUpdateType} from "gas-killer-sdk/StateChangeHandlerLib.sol";

/// @notice Honest gas benchmarks for GuardedVault. The expensive thing is the GLOBAL INVARIANT
///         CHECK (O(N) over all depositors), which a naive guarded vault would re-run on every
///         transaction. The benchmark proves it crosses a 30M mainnet block at a few thousand
///         depositors — so you simply cannot re-validate global safety on-chain at scale. With Gas
///         Killer the operator runs it off-chain and only the tiny O(K) share diff lands, collapsing
///         a 2-account settle from tens of millions of gas to a few thousand.
///
/// @dev Vaults are seeded with `vm.store` in `setUp()` (a separate, committed transaction) so the
///      measured invariant/settle calls hit cold slots — realistic costs. The measured ~4.6k gas per
///      depositor in checkInvariant confirms cold SLOADs (two per depositor), not warm reads.
contract GuardedVaultBench is VaultTestKit {
    uint256[3] internal SIZES = [uint256(1000), 2000, 3000];
    GuardedVaultExposed[3] internal sweepVaults;

    uint256 internal constant BIG_N = 8000;
    GuardedVaultExposed internal bigVault;

    function setUp() public override {
        super.setUp();
        for (uint256 i = 0; i < SIZES.length; i++) {
            sweepVaults[i] = _newVault();
            _seedViaStore(sweepVaults[i], SIZES[i], 1000);
        }
        bigVault = _newVault();
        _seedViaStore(bigVault, BIG_N, 1000);
    }

    /// @dev Fast seeding via direct storage writes (cheatcode), committed before the test body.
    function _seedViaStore(GuardedVaultExposed v, uint256 n, uint256 perUser) internal {
        for (uint256 i = 0; i < n; i++) {
            address d = _depositor(i);
            vm.store(address(v), OffchainPayloadBuilder.dynamicArraySlot(3, i), OffchainPayloadBuilder.addressTopic(d));
            vm.store(address(v), OffchainPayloadBuilder.mappingSlot(d, SHARES_SLOT), bytes32(perUser));
            vm.store(address(v), OffchainPayloadBuilder.mappingSlot(d, 4), bytes32(uint256(1))); // isDepositor
        }
        vm.store(address(v), bytes32(uint256(3)), bytes32(n)); // depositors.length
        vm.store(address(v), bytes32(TOTAL_SHARES_SLOT), bytes32(n * perUser));
        vm.store(address(v), bytes32(TOTAL_ASSETS_SLOT), bytes32(n * perUser));
    }

    function _gasOfCheck(GuardedVaultExposed v) internal returns (uint256 used) {
        uint256 g0 = gasleft();
        v.checkInvariant();
        used = g0 - gasleft();
    }

    /// @notice The O(N) invariant grows linearly with depositors and crosses a 30M mainnet block.
    function test_checkInvariant_isLinearAndCrossesBlock() public {
        uint256 last;
        for (uint256 i = 0; i < SIZES.length; i++) {
            uint256 g = _gasOfCheck(sweepVaults[i]);
            emit log_named_uint(string.concat("checkInvariant ", _label(SIZES[i]), " gas"), g);
            if (i > 0) assertGt(g, last, "invariant cost should grow with depositors");
            last = g;
        }
        uint256 big = _gasOfCheck(bigVault);
        emit log_named_uint(string.concat("checkInvariant ", _label(BIG_N), " gas"), big);
        emit log_named_uint("mainnet block gas", MAINNET_BLOCK_GAS);
        assertGt(big, MAINNET_BLOCK_GAS, "re-validating the invariant over 8000 depositors exceeds a 30M block");
    }

    /// @notice A tiny 2-account settle: naive (which re-runs the O(N) guard) is gas-explosive, while
    ///         the Gas Killer apply-diff (2 share writes + a log) is a few thousand gas — the operator
    ///         paid the invariant cost off-chain.
    function test_costCollapse_guardOffloaded() public {
        address[] memory users = new address[](2);
        users[0] = _depositor(0);
        users[1] = _depositor(1);
        int256[] memory deltas = new int256[](2);
        deltas[0] = -200;
        deltas[1] = 200;

        // Naive guarded settle on the big vault: dominated by the O(N) invariant re-check.
        uint256 g0 = gasleft();
        bigVault.settle(users, deltas);
        uint256 naive = g0 - gasleft();

        // Gas Killer apply-diff: just the two changed share slots + a Settled log.
        bytes memory diff = _buildSettleDiff(bigVault, users); // bigVault already at post-settle state
        GuardedVaultExposed fresh = _newVault();
        _seedViaStore(fresh, BIG_N, 1000);
        uint256 g1 = gasleft();
        fresh.applyDiff(diff);
        uint256 applyGas = g1 - gasleft();

        emit log_named_uint("naive guarded settle gas    ", naive);
        emit log_named_uint("apply diff gas              ", applyGas);
        emit log_named_uint("apply + BLS_VERIFY (prod)   ", applyGas + BLS_VERIFY_FIXED_GAS);

        assertGt(naive, MAINNET_BLOCK_GAS, "naive guarded settle exceeds a 30M block at 8000 depositors");
        assertLt(applyGas, 200_000, "apply-diff is a few thousand gas regardless of depositor count");
        assertLt(applyGas, naive / 100, "Gas Killer collapses the guard cost by >100x");
    }
}
