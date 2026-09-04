// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {LifeTestKit} from "./examples/OnchainLife.t.sol";
import {OnchainLife} from "../src/examples/onchain-life/OnchainLife.sol";
import {OnchainLifeExposed} from "./exposed/OnchainLifeExposed.sol";
import {CompressedArchiveTestKit} from "./examples/CompressedArchive.t.sol";
import {CompressedArchive} from "../src/examples/compressed-archive/CompressedArchive.sol";
import {CompressedArchiveExposed} from "./exposed/CompressedArchiveExposed.sol";

/// @notice Measures apply-diff gas the way PRODUCTION pays it.
///
///         The `.bench.t.sol` suites deploy the apply target inside the same transaction they measure.
///         Under EIP-2200/2929 a slot whose value at transaction start was zero is a "dirty" slot, so
///         each of those SSTOREs is charged 100 gas instead of the 5,000 a real, already-deployed
///         contract pays to overwrite a non-zero word. That understates the apply cost — the one number
///         Gas Killer's pitch rests on.
///
///         Here the apply target is deployed AND seeded in `setUp`, i.e. a prior committed transaction,
///         so its board words are non-zero at the start of the measured call and the writes are charged
///         at production rates. These are the figures docs/GAS-REPORT.md quotes.
contract ColdApplyMeasureTest is LifeTestKit {
    OnchainLife internal computed; // stepped, to source the diff
    OnchainLifeExposed internal target; // deployed+seeded in setUp => production-shaped storage

    function setUpCold(uint32 gens) internal returns (bytes memory diff) {
        uint256[16] memory seed = _randomSeed(42);
        computed = new OnchainLife(avs, address(bls), seed);
        computed.step(gens);
        diff = _buildLifeDiff(computed);
    }

    /// @dev The apply target must be constructed in a DIFFERENT transaction than the measurement.
    ///      `setUp` is exactly that, so anything created here has committed, non-zero storage.
    function _coldTarget() internal returns (OnchainLifeExposed t) {
        uint256[16] memory seed = _randomSeed(42);
        t = new OnchainLifeExposed(avs, address(bls), seed);
    }

    /// @notice Same diff, applied to an in-transaction target vs a prior-transaction target.
    ///         The delta is the EIP-2200 dirty-slot discount the benchmarks were silently taking.
    function test_applyGas_inTxVsProductionShaped() public {
        bytes memory diff = setUpCold(1);

        // (A) target created in THIS transaction — what the .bench suites measure.
        OnchainLifeExposed inTx = _coldTarget();
        uint256 g0 = gasleft();
        inTx.applyDiff(diff);
        uint256 warmish = g0 - gasleft();

        // (B) target created in setUp (prior tx) — production-shaped.
        uint256 g1 = gasleft();
        target.applyDiff(diff);
        uint256 cold = g1 - gasleft();

        emit log_named_uint("apply, target deployed in-tx (bench figure)", warmish);
        emit log_named_uint("apply, target deployed in a prior tx (production)", cold);
        emit log_named_uint("production + BLS_VERIFY estimate", cold + BLS_VERIFY_FIXED_GAS);
        emit log_named_uint("understatement factor x100", (cold * 100) / warmish);

        assertGt(cold, warmish, "a production-shaped apply must cost MORE than the in-tx measurement");
    }

    /// @dev Foundry runs `setUp` in its own transaction before each test, so `target`'s board words are
    ///      already committed and non-zero when the measured call runs — the production shape.
    function setUp() public override {
        super.setUp();
        uint256[16] memory seed = _randomSeed(42);
        target = new OnchainLifeExposed(avs, address(bls), seed);
    }
}

/// @notice The same production-shape question for `CompressedArchive`, which answers it differently.
///
///         OnchainLife overwrites 16 committed board words on every settle, so measuring against an
///         in-transaction target takes the EIP-2200 dirty-slot discount and understates apply cost
///         badly. CompressedArchive is append-only: every settle writes a mapping key that has never
///         held a value, so the zero-to-non-zero `SSTORE` path is what production pays too and there
///         is no discount to hide. The residual gap is the cold-account access, not a slot discount.
///
///         This is pinned as a test rather than argued, because `docs/GAS-REPORT.md` quotes the
///         archive's apply figures and the whole pitch rests on them not being flattering.
contract ColdApplyMeasureCompressedArchiveTest is CompressedArchiveTestKit {
    CompressedArchiveExposed internal target;

    /// @dev Foundry runs `setUp` in its own transaction, so `target` already exists on chain when the
    ///      measured call runs — the production shape.
    function setUp() public override {
        super.setUp();
        target = new CompressedArchiveExposed(avs, address(bls));
    }

    function test_applyGas_inTxVsProductionShaped() public {
        CompressedArchive source = _deployArchive();
        source.archive(_abiLike(40));
        bytes memory diff = _buildArchiveDiff(source, 0);

        // (A) target created in THIS transaction.
        CompressedArchiveExposed inTx = new CompressedArchiveExposed(avs, address(bls));
        uint256 g0 = gasleft();
        inTx.applyDiff(diff);
        uint256 warmish = g0 - gasleft();

        // (B) target created in setUp (prior tx) — production-shaped.
        uint256 g1 = gasleft();
        target.applyDiff(diff);
        uint256 cold = g1 - gasleft();

        emit log_named_uint("apply, target deployed in-tx        ", warmish);
        emit log_named_uint("apply, target deployed in a prior tx", cold);
        emit log_named_uint("production + BLS_VERIFY estimate    ", cold + BLS_VERIFY_FIXED_GAS);
        emit log_named_uint("understatement factor x100          ", (cold * 100) / warmish);

        assertGt(cold, warmish, "a production-shaped apply must cost MORE than the in-tx measurement");
        // An append-only archive writes only virgin slots, so the two measurements must stay within a
        // few percent. A large gap here would mean a diff is overwriting committed state, which for
        // this contract would be a bug rather than a pricing subtlety.
        assertLt(cold * 100, warmish * 110, "append-only writes must not show a dirty-slot discount");
    }
}
