// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {LifeTestKit} from "./OnchainLife.t.sol";
import {OnchainLife} from "../../src/examples/onchain-life/OnchainLife.sol";
import {OnchainLifeExposed} from "../exposed/OnchainLifeExposed.sol";

/// @notice Honest gas benchmarks for OnchainLife. The headline: the naive on-chain `step` grows with
///         the number of generations and crosses a 30M mainnet block within ~2 generations, while the
///         Gas Killer apply-diff cost is bounded by a small constant (always <=16 board words + the
///         generation word + one LOG2) regardless of how many generations were computed off-chain.
///
///         Gas is measured with `gasleft()` deltas around the external call — deterministic and easy
///         to reason about. Apply-diff numbers EXCLUDE the fixed BLS_VERIFY_FIXED_GAS (~250k) a
///         production submission adds; that overhead is constant in N, so the shape is unchanged.
contract OnchainLifeBench is LifeTestKit {
    uint256 internal constant APPLY_DIFF_CEILING = 600_000; // generous bound on 16 STOREs + gen + log

    function _gasOfStep(OnchainLife c, uint32 gens) internal returns (uint256 used) {
        uint256 g0 = gasleft();
        c.step(gens);
        used = g0 - gasleft();
    }

    function _gasOfApply(OnchainLifeExposed c, bytes memory diff) internal returns (uint256 used) {
        uint256 g0 = gasleft();
        c.applyDiff(diff);
        used = g0 - gasleft();
    }

    /// @notice Naive cost scales with generations; apply-diff stays bounded and far cheaper.
    function test_costCollapse_applyDiffBoundedVsNaiveGrowing() public {
        uint256[16] memory seed = _randomSeed(42);

        OnchainLife a1 = new OnchainLife(avs, address(bls), seed);
        uint256 naive1 = _gasOfStep(a1, 1);

        OnchainLife a8 = new OnchainLife(avs, address(bls), seed);
        uint256 naive8 = _gasOfStep(a8, 8);

        bytes memory diff1 = _buildLifeDiff(a1);
        bytes memory diff8 = _buildLifeDiff(a8);

        OnchainLifeExposed e1 = new OnchainLifeExposed(avs, address(bls), seed);
        OnchainLifeExposed e8 = new OnchainLifeExposed(avs, address(bls), seed);
        uint256 apply1 = _gasOfApply(e1, diff1);
        uint256 apply8 = _gasOfApply(e8, diff8);

        emit log_named_uint("naive step(1) gas         ", naive1);
        emit log_named_uint("naive step(8) gas         ", naive8);
        emit log_named_uint("apply diff(1 gen) gas     ", apply1);
        emit log_named_uint("apply diff(8 gens) gas    ", apply8);
        emit log_named_uint("apply(8) + BLS_VERIFY (prod)", apply8 + BLS_VERIFY_FIXED_GAS);

        // Naive grows ~linearly with generations.
        assertGt(naive8, naive1 * 6, "naive cost should scale with generations");
        // Apply-diff is bounded by a small constant no matter how many generations were computed.
        assertLt(apply1, APPLY_DIFF_CEILING, "apply-diff(1) should be small");
        assertLt(apply8, APPLY_DIFF_CEILING, "apply-diff(8) should be small");
        // Even one naive generation dwarfs applying the diff.
        assertLt(apply1, naive1 / 10, "apply-diff should be >=10x cheaper than a single naive generation");
        assertLt(apply8, naive8 / 100, "apply-diff of an 8-gen result is >=100x cheaper than computing it");
    }

    /// @notice Two generations of 64x64 Life already exceed a 30M mainnet block — proof this contract
    ///         is unshippable as written, yet trivial to drive via Gas Killer.
    function test_naive_exceedsMainnetBlockGas() public {
        uint256[16] memory seed = _randomSeed(42);
        OnchainLife a = new OnchainLife(avs, address(bls), seed);
        uint256 naive = _gasOfStep(a, 2);
        emit log_named_uint("naive step(2) gas", naive);
        emit log_named_uint("mainnet block gas", MAINNET_BLOCK_GAS);
        assertGt(naive, MAINNET_BLOCK_GAS, "two generations already exceed a 30M mainnet block");
    }
}
