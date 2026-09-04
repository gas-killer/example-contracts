// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {CompressedArchiveTestKit} from "./CompressedArchive.t.sol";
import {CompressedArchive} from "../../src/examples/compressed-archive/CompressedArchive.sol";
import {CompressedArchiveExposed} from "../exposed/CompressedArchiveExposed.sol";

/// @notice The honest baseline: what an archive costs *today*, with no compression at all. Storage
///         layout is deliberately identical to `CompressedArchive`'s so the two are comparable slot
///         for slot — the only difference is that this one keeps the bytes it was given.
/// @dev Compressing on-chain is not a slower alternative to this, it is an unavailable one: the
///      search passes a 30M mainnet block at roughly 390 bytes. So this, not a naive
///      compress-and-store contract, is what Gas Killer has to beat.
contract RawArchive {
    mapping(uint256 => bytes) private _blobs;
    mapping(uint256 => bytes32) public rawHash;
    mapping(uint256 => uint256) public rawLength;
    uint256 public entryCount;

    function archive(bytes calldata raw) external {
        uint256 index = entryCount;
        _blobs[index] = raw;
        rawHash[index] = keccak256(raw);
        rawLength[index] = raw.length;
        entryCount = index + 1;
    }

    function storedBlob(uint256 index) external view returns (bytes memory) {
        return _blobs[index];
    }
}

/// @notice Gas benchmarks for the archive. The comparison this example turns on is three-way:
///
///         1. **Compress on-chain** — impossible past a few hundred bytes. Not a cost, a wall.
///         2. **Store raw** (`RawArchive`) — what everyone does today: ~690 gas per byte, forever.
///         3. **Gas Killer** — the operator compresses off-chain for free and settles the compressed
///            blob, so the storage bill is cut by the compression ratio.
///
///         Note what is different about this example. Everywhere else in this repo the settlement
///         cost is *flat* in the work performed. Here it is not, and deliberately so: the diff is
///         the compressed output, so the algorithm's quality shows up directly in the gas. The claim
///         is not "settlement is constant", it is "settlement is smaller, by the ratio".
///
/// @dev Apply-diff gas measured here EXCLUDES BLS verification (the mock does no crypto). Add
///      `BLS_VERIFY_FIXED_GAS` back when quoting a production figure; it is constant in N.
contract CompressedArchiveBench is CompressedArchiveTestKit {
    /// @dev Enough targets for the widest sweep below; each measurement consumes a fresh one.
    uint256 internal constant TARGETS = 6;

    CompressedArchiveExposed[TARGETS] internal applyTargets;
    RawArchive[TARGETS] internal rawTargets;
    uint256 internal nextTarget;

    /// @dev EVERY measurement target is deployed HERE, in `setUp`, which Foundry runs as its own
    ///      transaction. That is what makes the apply and baseline figures production-shaped: a
    ///      contract deployed inside the measured transaction is charged differently under
    ///      EIP-2200/2929 than one that already exists on chain. The gap is small for this example
    ///      because the archive only ever writes fresh keys — see
    ///      `test/ColdApplyMeasure.t.sol`, which pins both figures side by side — but it is measured
    ///      rather than assumed.
    function setUp() public override {
        super.setUp();
        for (uint256 i = 0; i < TARGETS; i++) {
            applyTargets[i] = new CompressedArchiveExposed(avs, address(bls));
            rawTargets[i] = new RawArchive();
        }
    }

    /// @dev Hand out a target that was deployed in a prior transaction. Each is used at most once, so
    ///      every measured apply writes a mapping key that has never held a value — which is exactly
    ///      what an append-only archive does in production.
    function _applyTarget() internal returns (CompressedArchiveExposed) {
        return applyTargets[nextTarget++];
    }

    function _rawTarget() internal returns (RawArchive) {
        return rawTargets[nextTarget];
    }

    /* ------------------------------------------------------------------ */
    /*              The naive path: compressing on-chain                   */
    /* ------------------------------------------------------------------ */

    /// @notice Archiving with on-chain compression exits a mainnet block at a blob size that is
    ///         trivially small for an archive. This is the function operators run off-chain.
    function test_naive_exceedsMainnetBlockGas() public {
        CompressedArchive a = _deployArchive();
        bytes memory raw = _abiLike(40);

        uint256 g0 = gasleft();
        a.archive(raw);
        uint256 used = g0 - gasleft();

        emit log_named_uint("naive archive of 1280 bytes", used);
        emit log_named_uint("mainnet block gas          ", MAINNET_BLOCK_GAS);

        assertGt(used, MAINNET_BLOCK_GAS, "compressing 1280 bytes on-chain must exceed a 30M block");
    }

    /// @notice The naive cost grows faster than the blob does, so on-chain compression does not
    ///         become practical at any size worth archiving — it gets worse the more there is to
    ///         gain from it.
    /// @dev The growth factor climbs towards 4x per doubling rather than starting there. Below a few
    ///      multiples of `MAX_MATCH` a compressible blob is swallowed in a handful of strides, so the
    ///      search count is too small for the window growth to dominate yet; the asymptotic quadratic
    ///      only appears once the blob is much longer than a single match can cover. These sizes sit
    ///      in that regime, where each doubling more than doubles the cost.
    function test_sweep_naiveGrowsSuperLinearly() public {
        uint256[3] memory words = [uint256(40), 80, 160];
        uint256 previous;

        for (uint256 i = 0; i < words.length; i++) {
            CompressedArchive a = _deployArchive();
            bytes memory raw = _abiLike(words[i]);

            uint256 g0 = gasleft();
            a.archive(raw);
            uint256 used = g0 - gasleft();

            emit log_named_uint(string.concat("naive archive, bytes=", vm.toString(raw.length)), used);
            if (previous != 0) {
                assertGt(used, previous * 2, "doubling the blob must more than double the naive cost");
            }
            previous = used;
        }
    }

    /* ------------------------------------------------------------------ */
    /*         Settlement vs. the baseline everyone actually uses          */
    /* ------------------------------------------------------------------ */

    /// @notice The headline. At the same raw size, storing the blob compressed via a settled diff
    ///         costs a fraction of storing it verbatim, because storage is charged per slot and
    ///         compression removes slots.
    function test_settledCompressed_beatsStoringRaw() public {
        bytes memory raw = _abiLike(40);

        // Gas Killer: the operator compressed off-chain; only the diff lands.
        CompressedArchive source = _deployArchive();
        source.archive(raw);
        bytes memory diff = _buildArchiveDiff(source, 0);

        // Baseline: keep the bytes as they arrived.
        RawArchive baseline = _rawTarget();
        uint256 g0 = gasleft();
        baseline.archive(raw);
        uint256 rawCost = g0 - gasleft();

        CompressedArchiveExposed target = _applyTarget();
        g0 = gasleft();
        target.applyDiff(diff);
        uint256 applyCost = g0 - gasleft();
        uint256 settledCost = applyCost + BLS_VERIFY_FIXED_GAS;

        emit log_named_uint("raw bytes                    ", raw.length);
        emit log_named_uint("stored (compressed) bytes    ", source.storedBlob(0).length);
        emit log_named_uint("store raw, no compression    ", rawCost);
        emit log_named_uint("apply diff (excl. BLS)       ", applyCost);
        emit log_named_uint("settled total (incl. BLS)    ", settledCost);

        assertLt(settledCost, rawCost, "settling the compressed blob must beat storing it raw");
        assertEq(target.expand(0), raw, "the settled blob must still expand to the original");
    }

    /// @notice Where the crossover sits. Below a few hundred bytes the fixed BLS floor dominates and
    ///         storing raw is cheaper; above it the per-slot saving takes over and keeps growing.
    ///         Stating the losing end explicitly is the point — this is not a win at every size.
    function test_crossover_smallBlobsAreCheaperStoredRaw() public {
        uint256[4] memory words = [uint256(4), 8, 16, 40];

        for (uint256 i = 0; i < words.length; i++) {
            bytes memory raw = _abiLike(words[i]);

            CompressedArchive source = _deployArchive();
            source.archive(raw);
            bytes memory diff = _buildArchiveDiff(source, 0);

            RawArchive baseline = _rawTarget();
            uint256 g0 = gasleft();
            baseline.archive(raw);
            uint256 rawCost = g0 - gasleft();

            CompressedArchiveExposed target = _applyTarget();
            g0 = gasleft();
            target.applyDiff(diff);
            uint256 settledCost = (g0 - gasleft()) + BLS_VERIFY_FIXED_GAS;

            emit log_named_uint(string.concat("bytes=", vm.toString(raw.length), " store raw  "), rawCost);
            emit log_named_uint(string.concat("bytes=", vm.toString(raw.length), " gas killer "), settledCost);

            // 128 bytes sits below the crossover and 1280 above it; the pair between straddles it.
            if (raw.length == 128) {
                assertLt(rawCost, settledCost, "small blobs must be cheaper stored raw");
            }
            if (raw.length == 1280) {
                assertLt(settledCost, rawCost / 2, "large blobs must settle for under half the raw cost");
            }
        }
    }

    /// @notice Settlement scales with the *compressed* size, so two blobs of identical raw size
    ///         settle at very different prices. That is the axis this example adds to the repo:
    ///         elsewhere the diff is flat in the work, here it is proportional to the output.
    function test_settlementTracksCompressedSize() public {
        bytes memory structured = _abiLike(40);
        bytes memory noise = _random(1, 1280);
        assertEq(structured.length, noise.length, "same raw size on both sides");

        uint256 structuredCost = _settlementCostOf(structured);
        uint256 noiseCost = _settlementCostOf(noise);

        emit log_named_uint("1280 structured bytes -> apply gas", structuredCost);
        emit log_named_uint("1280 random bytes     -> apply gas", noiseCost);

        assertLt(structuredCost * 3, noiseCost, "a compressible blob should settle far cheaper");
    }

    function _settlementCostOf(bytes memory raw) internal returns (uint256 used) {
        CompressedArchive source = _deployArchive();
        source.archive(raw);
        bytes memory diff = _buildArchiveDiff(source, 0);

        CompressedArchiveExposed target = _applyTarget();
        uint256 g0 = gasleft();
        target.applyDiff(diff);
        used = g0 - gasleft();
    }

    /* ------------------------------------------------------------------ */
    /*                  The read path stays affordable                     */
    /* ------------------------------------------------------------------ */

    /// @notice A settled blob is readable, not merely stored: expanding it from storage is linear
    ///         and fits comfortably in a block at sizes far beyond what could ever be compressed
    ///         on-chain. Without this the storage saving would be worthless.
    function test_expandFromStorage_isAffordable() public {
        CompressedArchive a = _deployArchive();
        bytes memory raw = _repeating(4000, 40);
        a.archive(raw);

        uint256 g0 = gasleft();
        bytes memory back = a.expand(0);
        uint256 used = g0 - gasleft();

        emit log_named_uint("expand 4000 bytes from storage", used);
        emit log_named_uint("gas per expanded byte         ", used / raw.length);

        assertEq(back, raw, "expansion must be exact");
        assertLt(used, MAINNET_BLOCK_GAS, "expanding must fit in a 30M block");
    }

    /// @notice The full asymmetry in one place: the blob could never have been compressed on-chain,
    ///         yet expanding it on-chain is routine.
    function test_asymmetry_compressImpossibleExpandRoutine() public {
        bytes memory raw = _abiLike(40);

        CompressedArchive a = _deployArchive();
        uint256 g0 = gasleft();
        a.archive(raw);
        uint256 compressCost = g0 - gasleft();

        g0 = gasleft();
        a.expand(0);
        uint256 expandCost = g0 - gasleft();

        emit log_named_uint("compress 1280 bytes on-chain", compressCost);
        emit log_named_uint("expand   1280 bytes on-chain", expandCost);
        emit log_named_uint("asymmetry factor            ", compressCost / expandCost);

        assertGt(compressCost, MAINNET_BLOCK_GAS, "compression must be out of reach");
        assertLt(expandCost, MAINNET_BLOCK_GAS, "expansion must be in reach");
    }
}
