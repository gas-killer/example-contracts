// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {SortedOracleTestKit} from "./SortedOracle.t.sol";
import {SortedOracle} from "../../src/examples/sorted-oracle/SortedOracle.sol";
import {SortedOracleExposed} from "../exposed/SortedOracleExposed.sol";

/// @notice Honest gas benchmarks for SortedOracle. The headline: the naive on-chain `commit` grows
///         with the observation count *and* with how badly ordered the observations happen to be —
///         crossing a 30M mainnet block just past N=4,000 on random input and at N=400 on ascending
///         input —
///         while the Gas Killer apply-diff cost is a constant six stores and one log in every case.
///
///         TWO MEASUREMENT RULES, both learned the hard way and both about EIP-2929/2200 warmth:
///
///         1. **Observations are seeded in `setUp`.** A real oracle's observations were reported in
///            earlier transactions, so `commit` pays a cold 2,100-gas SLOAD for each one. Seeding them
///            inside the measured transaction would leave them warm at 100 gas and understate the
///            naive path by millions.
///         2. **Every apply measurement gets its own target, pre-committed in `setUp`.** Applying the
///            same diff twice to one target makes the second write warm and dirty (100 gas instead of
///            5,000), which would fake a "flat" curve that is really just a warmth artifact. Each
///            target here is committed in a prior transaction and then used exactly once.
///
///         Gas is measured with `gasleft()` deltas around the external call. Apply-diff numbers
///         EXCLUDE the fixed BLS_VERIFY_FIXED_GAS (~250k) a production submission adds; that overhead
///         is constant in N, so the shape is unchanged.
contract SortedOracleBench is SortedOracleTestKit {
    /// @notice Oracles seeded in `setUp` so their observations are cold when a commit reads them.
    SortedOracle[4] internal sweepOracles;
    SortedOracle internal randomAt400;
    SortedOracle internal ascendingAt400;
    SortedOracle internal randomAt5000;

    /// @notice Pool of production-shaped apply targets: deployed AND committed in `setUp`, so their
    ///         six words are non-zero and untouched at the start of any measured call. Handed out one
    ///         per measurement by `_nextTarget`.
    SortedOracleExposed[10] internal targets;
    uint256 internal cursor;

    function sweepSizes() internal pure returns (uint256[4] memory) {
        return [uint256(250), 500, 1000, 2000];
    }

    function setUp() public override {
        super.setUp();

        uint256[4] memory ns = sweepSizes();
        for (uint256 i = 0; i < ns.length; i++) {
            sweepOracles[i] = _deployOracle();
            _seed(sweepOracles[i], _randomObservations(11, ns[i]));
        }

        randomAt400 = _deployOracle();
        _seed(randomAt400, _randomObservations(5, 400));
        ascendingAt400 = _deployOracle();
        _seed(ascendingAt400, _ascendingObservations(400));
        randomAt5000 = _deployOracle();
        _seed(randomAt5000, _randomObservations(13, 5000));

        uint256[] memory warmup = _randomObservations(999, 8);
        for (uint256 i = 0; i < targets.length; i++) {
            targets[i] = new SortedOracleExposed(avs, address(bls));
            targets[i].reportBatch(warmup);
            targets[i].commit();
        }
    }

    /// @dev A production-shaped apply target that has not been written to in this transaction.
    function _nextTarget() internal returns (SortedOracleExposed t) {
        t = targets[cursor];
        cursor++;
    }

    function _gasOfCommit(SortedOracle o) internal returns (uint256 used) {
        uint256 g0 = gasleft();
        o.commit();
        used = g0 - gasleft();
    }

    function _gasOfApply(bytes memory diff) internal returns (uint256 used) {
        SortedOracleExposed t = _nextTarget();
        uint256 g0 = gasleft();
        t.applyDiff(diff);
        used = g0 - gasleft();
    }

    /// @notice The headline curve: sweep the observation count and show the naive commit climbing
    ///         while the apply cost stays pinned at a constant. These are the numbers quoted in
    ///         docs/GAS-REPORT.md.
    function test_sweep_naiveGrowsApplyStaysFlat() public {
        uint256[4] memory ns = sweepSizes();
        uint256 firstApply;

        for (uint256 i = 0; i < ns.length; i++) {
            uint256 naive = _gasOfCommit(sweepOracles[i]);
            uint256 applied = _gasOfApply(_buildOracleDiff(sweepOracles[i]));
            uint256 production = applied + BLS_VERIFY_FIXED_GAS;

            emit log_named_uint("observations             ", ns[i]);
            emit log_named_uint("  naive commit gas       ", naive);
            emit log_named_uint("  apply-diff gas         ", applied);
            emit log_named_uint("  apply + BLS (prod est) ", production);
            emit log_named_uint("  savings factor         ", naive / production);

            if (i == 0) firstApply = applied;
            // The whole point: apply cost does not grow with the compute that produced the diff.
            // Identical payloads apply for an identical cost to the gas — proven exactly by
            // `test_applyCostIsIdenticalAcrossN`. The few tens of gas of spread across this sweep are
            // harness noise from per-call memory allocation, not growth with N.
            assertApproxEqAbs(applied, firstApply, 200, "apply-diff must stay flat across N");
            assertLt(production, naive, "Gas Killer must be cheaper than committing on-chain");
        }
    }

    /// @notice Same observation count, two input orders. The off-chain work differs by more than an
    ///         order of magnitude; the settlement is identical because the payload is identical.
    function test_inputOrderChangesComputeNotSettlement() public {
        uint256 naiveRandom = _gasOfCommit(randomAt400);
        uint256 naiveAscending = _gasOfCommit(ascendingAt400);

        bytes memory diffRandom = _buildOracleDiff(randomAt400);
        bytes memory diffAscending = _buildOracleDiff(ascendingAt400);

        uint256 applyRandom = _gasOfApply(diffRandom);
        uint256 applyAscending = _gasOfApply(diffAscending);

        emit log_named_uint("N=400 naive, random order   ", naiveRandom);
        emit log_named_uint("N=400 naive, ascending order", naiveAscending);
        emit log_named_uint("N=400 apply, random order   ", applyRandom);
        emit log_named_uint("N=400 apply, ascending order", applyAscending);
        emit log_named_uint("compute penalty factor      ", naiveAscending / naiveRandom);

        assertGt(naiveAscending, naiveRandom * 10, "ordered input must cost far more to compute");
        // Each external call in a transaction allocates fresh memory to encode its calldata, so two
        // apply measurements taken in sequence differ by a couple of hundred gas in whichever
        // direction the allocator happens to fall. The exact claim — identical payloads costing an
        // identical number of gas — is pinned in `test_applyCostIsIdenticalAcrossN`, where both
        // payloads are built up front and the two measurements agree to the unit.
        assertApproxEqAbs(applyAscending, applyRandom, 500, "settlement must not depend on the sort's difficulty");
        assertGt(naiveAscending, MAINNET_BLOCK_GAS, "ascending input at N=400 must exceed a 30M block");
    }

    /// @notice At 5,000 observations even well-behaved random input cannot be committed on-chain,
    ///         while the settled cost is unchanged from the 250-observation case.
    function test_naive_exceedsMainnetBlockGas() public {
        uint256 naive = _gasOfCommit(randomAt5000);
        uint256 applied = _gasOfApply(_buildOracleDiff(randomAt5000));

        emit log_named_uint("naive commit, N=5000", naive);
        emit log_named_uint("apply-diff          ", applied);
        emit log_named_uint("apply + BLS (prod)  ", applied + BLS_VERIFY_FIXED_GAS);
        emit log_named_uint("mainnet block gas   ", MAINNET_BLOCK_GAS);

        assertGt(naive, MAINNET_BLOCK_GAS, "5,000 observations must exceed a 30M mainnet block");
        assertLt(applied + BLS_VERIFY_FIXED_GAS, MAINNET_BLOCK_GAS, "settlement must fit comfortably in a block");
    }

    /// @notice The apply cost measured against a target whose six words were already committed in a
    ///         prior transaction — the figure a production settlement actually pays, and the one
    ///         docs/GAS-REPORT.md quotes. A never-committed oracle pays more, because its first write
    ///         to each word takes the zero-to-non-zero path.
    function test_applyGas_firstCommitVsSteadyState() public {
        SortedOracle source = _deployOracle();
        _seed(source, _randomObservations(17, 500));
        source.commit();
        bytes memory diff = _buildOracleDiff(source);

        SortedOracleExposed fresh = new SortedOracleExposed(avs, address(bls));
        uint256 g0 = gasleft();
        fresh.applyDiff(diff);
        uint256 firstEver = g0 - gasleft();

        uint256 steadyState = _gasOfApply(diff);

        emit log_named_uint("apply, first commit ever (zero slots)", firstEver);
        emit log_named_uint("apply, steady state (production)     ", steadyState);
        emit log_named_uint("steady state + BLS_VERIFY (prod est) ", steadyState + BLS_VERIFY_FIXED_GAS);

        assertLt(steadyState, firstEver, "overwriting committed words must cost less than first-ever writes");
        assertEq(COMMIT_OPS, 7, "a commit is always six stores and one log");
    }

    /// @notice The claim the whole example rests on, asserted exactly rather than approximately: two
    ///         payloads built from wildly different amounts of off-chain work — a 250-observation
    ///         commit and a 2,000-observation one — apply for the *same number of gas*, to the unit.
    /// @dev The payloads are built before the measurement starts. Building one costs a few thousand
    ///      gas of view calls, and folding that into the measured span is what makes an otherwise
    ///      identical cost look like it drifts with N.
    function test_applyCostIsIdenticalAcrossN() public {
        SortedOracle small = _deployOracle();
        _seed(small, _randomObservations(21, 250));
        small.commit();
        bytes memory smallDiff = _buildOracleDiff(small);

        SortedOracle large = _deployOracle();
        _seed(large, _randomObservations(21, 2000));
        large.commit();
        bytes memory largeDiff = _buildOracleDiff(large);

        uint256 appliedSmall = _gasOfApply(smallDiff);
        uint256 appliedLarge = _gasOfApply(largeDiff);

        emit log_named_uint("apply, diff from N=250 ", appliedSmall);
        emit log_named_uint("apply, diff from N=2000", appliedLarge);

        assertEq(appliedLarge, appliedSmall, "settlement cost must be identical, not merely similar");
    }
}
