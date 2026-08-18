// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Vm} from "forge-std/Vm.sol";
import {QuicksortTestKit} from "./Quicksort.t.sol";
import {BenchmarkBase} from "../../../helpers/BenchmarkBase.sol";

/// @notice Gas benchmarks for the pure sort. Two things are being measured, and they point in
///         opposite directions:
///
///         1. The on-chain cost, which is real, super-linear, and crosses a 30M mainnet block at
///            N=8,000 on random input — or at N=400 if the input happens to arrive in order.
///         2. The Gas Killer settlement contribution, which is **zero**, because the algorithm
///            produces no `STORE`, `LOG*` or `CALL` operation for a payload to carry. There is no
///            "apply cost" curve to plot here; the flat line is exactly zero at every N.
///
///         Gas is measured with `gasleft()` deltas around the external call, matching the convention
///         in the other benchmark suites.
contract QuicksortBench is QuicksortTestKit, BenchmarkBase {
    function setUp() public override {
        super.setUp();
    }

    function _gasOfRandom(uint256 n) internal view returns (uint256 used) {
        uint256 g0 = gasleft();
        runner.sortRandom(1, n);
        used = g0 - gasleft();
    }

    function _gasOfAdversarial(uint256 n) internal view returns (uint256 used) {
        uint256 g0 = gasleft();
        runner.sortAdversarial(n);
        used = g0 - gasleft();
    }

    /// @notice The average case: random input keeps partitions balanced, so cost tracks O(N log N).
    ///         Even so, 8,000 values do not fit in a mainnet block.
    function test_sweep_randomInputIsLinearithmic() public {
        uint256[6] memory ns = [uint256(250), 500, 1000, 2000, 4000, 8000];
        uint256 previous;

        for (uint256 i = 0; i < ns.length; i++) {
            uint256 used = _gasOfRandom(ns[i]);
            emit log_named_uint(string.concat("random  N=", vm.toString(ns[i])), used);

            // Doubling N under O(N log N) roughly doubles the cost; it must not quadruple.
            if (previous != 0) {
                assertLt(used, previous * 3, "random input should not scale quadratically");
            }
            previous = used;
        }
    }

    /// @notice The worst case: already-ascending input defeats a last-element pivot, so each pass
    ///         peels off one element and cost tracks O(N^2). Doubling N roughly quadruples the gas.
    function test_sweep_ascendingInputIsQuadratic() public {
        uint256[5] memory ns = [uint256(100), 200, 300, 400, 500];
        uint256 previousAtHalf;

        for (uint256 i = 0; i < ns.length; i++) {
            uint256 used = _gasOfAdversarial(ns[i]);
            emit log_named_uint(string.concat("ascending N=", vm.toString(ns[i])), used);

            // ns[1] is 2x ns[0], and ns[3] is 2x ns[1]: both doublings must show ~4x growth.
            if (i == 1 || i == 3) {
                assertGt(used, previousAtHalf * 3, "doubling N must roughly quadruple the cost");
            }
            if (i == 0 || i == 1) {
                previousAtHalf = used;
            }
        }
    }

    /// @notice The headline comparison: at the same N, sorting values that arrive in order costs
    ///         dramatically more than sorting the same count of random values. Nothing about the
    ///         input is malformed — a steadily rising price feed produces it — so on-chain this is a
    ///         denial-of-service surface that ordinary data can trigger.
    function test_inputOrderDominatesCost() public {
        uint256 random = _gasOfRandom(1000);
        uint256 ascending = _gasOfAdversarial(1000);

        emit log_named_uint("N=1000 random input    ", random);
        emit log_named_uint("N=1000 ascending input ", ascending);
        emit log_named_uint("penalty factor         ", ascending / random);

        assertGt(ascending, random * 20, "ordered input should cost at least 20x random input");
        assertGt(ascending, MAINNET_BLOCK_GAS, "ordered input at N=1000 must exceed a 30M block");
    }

    /// @notice Where each input shape stops fitting in a mainnet block. Ordered input crosses 20x
    ///         earlier than random input does.
    function test_naive_exceedsMainnetBlockGas() public {
        uint256 randomAt8k = _gasOfRandom(8000);
        uint256 ascendingAt400 = _gasOfAdversarial(400);

        emit log_named_uint("random     N=8000", randomAt8k);
        emit log_named_uint("ascending  N=400 ", ascendingAt400);
        emit log_named_uint("mainnet block gas", MAINNET_BLOCK_GAS);

        assertGt(randomAt8k, MAINNET_BLOCK_GAS, "8,000 random values must exceed a 30M block");
        assertGt(ascendingAt400, MAINNET_BLOCK_GAS, "400 ordered values must exceed a 30M block");
    }

    /// @notice The other half of the benchmark, and the reason this example exists: however much the
    ///         sort costs on-chain, it contributes nothing to a Gas Killer payload. Sorting 4,000
    ///         values burns ~21M gas here and produces zero payload operations, so its settlement
    ///         cost is zero at every N — there is no curve to flatten because there is no curve.
    function test_settlementContributionIsZeroAtEveryN() public {
        uint256[3] memory ns = [uint256(500), 2000, 4000];

        for (uint256 i = 0; i < ns.length; i++) {
            vm.record();
            vm.recordLogs();

            uint256 used = _gasOfRandom(ns[i]);

            (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(address(runner));
            Vm.Log[] memory logs = vm.getRecordedLogs();

            emit log_named_uint(string.concat("N=", vm.toString(ns[i]), " on-chain gas "), used);
            emit log_named_uint(string.concat("N=", vm.toString(ns[i]), " payload ops  "), writes.length + logs.length);

            assertEq(writes.length, 0, "no STORE op can be produced by a pure sort");
            assertEq(reads.length, 0, "no storage is read by a pure sort");
            assertEq(logs.length, 0, "no LOG op can be produced by a pure sort");
        }
    }
}
