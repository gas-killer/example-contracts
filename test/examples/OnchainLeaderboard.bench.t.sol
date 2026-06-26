// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {LeaderboardTestKit} from "./OnchainLeaderboard.t.sol";
import {OnchainLeaderboard} from "../../src/examples/onchain-leaderboard/OnchainLeaderboard.sol";
import {OnchainLeaderboardExposed} from "../exposed/OnchainLeaderboardExposed.sol";

/// @notice Honest gas benchmarks for OnchainLeaderboard. A single worst-case (new highest score)
///         submission shifts the entire board and crosses a 30M mainnet block as the board grows —
///         so a fully sorted on-chain leaderboard of a couple thousand entries is unmaintainable the
///         naive way. Like MegaDrop (and unlike OnchainLife), the operator apply-diff is O(N) in the
///         shifted suffix and is NOT a raw-gas win: rewriting the board carries the SDK's per-op
///         decode overhead, so the value here is STRUCTURAL (you get a sorted on-chain board at all,
///         maintained by operators, with very large reshuffles chunked across verifyAndUpdate calls).
///
/// @dev Boards are seeded in `setUp()`; Foundry resets storage warmth and commits state before the
///      test body, so the measured submissions pay realistic cold/clean write costs. Empirically this
///      is ~9x the artificially cheap warm/dirty writes you'd get from seeding inside the test
///      function (~16k vs ~1.7k gas per shifted entry), which is why the sweep is run this way. Exact
///      production cost still depends on prior storage-access patterns in the real transaction.
contract OnchainLeaderboardBench is LeaderboardTestKit {
    uint256[4] internal SIZES = [uint256(500), 1000, 1500, 2000];
    OnchainLeaderboardExposed[4] internal sweepBoards;

    // Dedicated boards for the apply-vs-naive comparison at a fixed size.
    uint256 internal constant CMP_N = 1500;
    OnchainLeaderboardExposed internal cmpNaive;
    OnchainLeaderboardExposed internal cmpDiff;

    function setUp() public override {
        super.setUp();
        for (uint256 i = 0; i < SIZES.length; i++) {
            sweepBoards[i] = new OnchainLeaderboardExposed(avs, address(bls));
            sweepBoards[i].applyDiff(_buildSeedDiff(SIZES[i]));
        }
        cmpNaive = new OnchainLeaderboardExposed(avs, address(bls));
        cmpNaive.applyDiff(_buildSeedDiff(CMP_N));
        cmpDiff = new OnchainLeaderboardExposed(avs, address(bls));
        cmpDiff.applyDiff(_buildSeedDiff(CMP_N));
    }

    function _gasOfSubmit(OnchainLeaderboard c, address p, uint256 s) internal returns (uint256 used) {
        uint256 g0 = gasleft();
        c.submitScore(p, s);
        used = g0 - gasleft();
    }

    function _gasOfApply(OnchainLeaderboardExposed c, bytes memory diff) internal returns (uint256 used) {
        uint256 g0 = gasleft();
        c.applyDiff(diff);
        used = g0 - gasleft();
    }

    /// @notice A worst-case front insertion grows linearly with the board and crosses a 30M block.
    function test_sweep_frontInsertionCrossesBlockLimit() public {
        uint256 last;
        for (uint256 i = 0; i < SIZES.length; i++) {
            // A fresh newcomer (not on the board) with the highest score -> shifts every entry.
            address nc = address(uint160(uint256(keccak256(abi.encode("nc", i)))));
            uint256 naive = _gasOfSubmit(sweepBoards[i], nc, 1_000_000_000);
            emit log_named_uint(string.concat("naive front-insert ", _label(SIZES[i]), " gas"), naive);
            if (i > 0) assertGt(naive, last, "naive should grow with board size");
            last = naive;
        }
        assertGt(last, MAINNET_BLOCK_GAS, "a front insertion on a 2000-entry board exceeds a 30M block");
    }

    /// @notice Apply-diff for a full reshuffle is O(N) and in the same ballpark as the naive sort —
    ///         NOT a gas collapse. MegaDrop/Leaderboard are the write-bound regime; OnchainLife (heavy
    ///         compute, tiny diff) is where Gas Killer collapses gas. The win here is structural.
    function test_applyDiff_isLinearNotAGasCollapse() public {
        address nc = address(uint160(uint256(keccak256("cmp-newcomer"))));
        uint256 hi = 1_000_000_000;

        uint256 naive = _gasOfSubmit(cmpNaive, nc, hi);
        bytes memory diff = _buildLeaderboardDiff(cmpNaive, nc, hi);
        uint256 applyGas = _gasOfApply(cmpDiff, diff);

        emit log_named_uint("naive front-insert(1500) gas", naive);
        emit log_named_uint("apply full-board diff gas   ", applyGas);
        emit log_named_uint("apply + BLS_VERIFY (prod)   ", applyGas + BLS_VERIFY_FIXED_GAS);

        // Both are O(N), same order of magnitude (write-bound). Assert they are within ~4x of each
        // other rather than claiming a collapse.
        assertLt(applyGas, naive * 4, "apply-diff is the same order as the naive sort (write-bound)");
        assertGt(applyGas * 4, naive, "apply-diff is not negligible vs naive (it is O(N), not a tiny diff)");
        // Confirm the diff path reproduced the exact ordering.
        assertEq(cmpDiff.boardLength(), cmpNaive.boardLength(), "length matches");
        assertEq(cmpDiff.getEntry(0).player, nc, "newcomer at top via diff");
    }
}
