// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Vm} from "forge-std/Vm.sol";
import {Lzss} from "../../../../src/examples/algo/compress/Lzss.sol";
import {LzssTestKit} from "./Lzss.t.sol";
import {BenchmarkBase} from "../../../helpers/BenchmarkBase.sol";

/// @notice Gas benchmarks for the pure compressor. Three things are being measured:
///
///         1. `compress` is quadratic and unaffordable — a 30M mainnet block is exhausted somewhere
///            around 390 bytes, on every input shape.
///         2. `decompress` is linear and affordable — a few hundred gas per output byte, so the
///            expansion stays a real on-chain operation at sizes the compressor could never reach.
///         3. The Gas Killer settlement contribution of the algorithm itself is **zero**, because a
///            `pure` function produces no `STORE`, `LOG*` or `CALL` for a payload to carry. What the
///            consumer settles is the compressed output, and that is measured in the
///            `CompressedArchive` benchmarks.
///
///         Gas is measured with `gasleft()` deltas, matching the convention in the other suites.
///         Library calls are metered in place so that neither calldata nor returndata — both of
///         which scale with the blob and neither of which is the algorithm — lands in the number.
contract LzssBench is LzssTestKit, BenchmarkBase {
    function setUp() public override {
        super.setUp();
    }

    function _gasOfCompress(bytes memory data) internal view returns (uint256 used) {
        uint256 g0 = gasleft();
        Lzss.compress(data);
        used = g0 - gasleft();
    }

    function _gasOfDecompress(bytes memory stream) internal view returns (uint256 used) {
        uint256 g0 = gasleft();
        Lzss.decompress(stream);
        used = g0 - gasleft();
    }

    /* ------------------------------------------------------------------ */
    /*                    Compression: quadratic, always                   */
    /* ------------------------------------------------------------------ */

    /// @notice Incompressible input. Every position falls through to a literal, so the search runs
    ///         its full window at every one of N positions. Doubling N quadruples the cost.
    function test_sweep_randomInputIsQuadratic() public {
        uint256[4] memory ns = [uint256(125), 250, 500, 1000];
        uint256 previous;

        for (uint256 i = 0; i < ns.length; i++) {
            uint256 used = _gasOfCompress(_random(1, ns[i]));
            emit log_named_uint(string.concat("random    N=", vm.toString(ns[i])), used);

            if (previous != 0) {
                assertGt(used, previous * 3, "doubling N must roughly quadruple the cost");
                assertLt(used, previous * 6, "growth should be quadratic, not worse");
            }
            previous = used;
        }
    }

    /// @notice Highly compressible input is quadratic too, which is the counter-intuitive half. Each
    ///         candidate comparison runs much further before it fails, but the input is consumed in
    ///         proportionally larger strides, so the two effects cancel and only the constant moves.
    ///         There is no benign regime to fall back on.
    function test_sweep_repetitiveInputIsAlsoQuadratic() public {
        uint256[4] memory ns = [uint256(500), 1000, 2000, 4000];
        uint256 previous;

        for (uint256 i = 0; i < ns.length; i++) {
            uint256 used = _gasOfCompress(_repeating(ns[i], 40));
            emit log_named_uint(string.concat("repeating N=", vm.toString(ns[i])), used);

            if (previous != 0) {
                assertGt(used, previous * 3, "doubling N must roughly quadruple the cost");
            }
            previous = used;
        }
    }

    /// @notice The shape of the input moves the constant by more than an order of magnitude but
    ///         never the exponent. Uniform input is close to the incompressible worst case despite
    ///         compressing best of all — the search does not get to know the answer in advance.
    function test_inputShapeMovesTheConstantNotTheExponent() public {
        uint256 n = 1000;
        uint256 random = _gasOfCompress(_random(1, n));
        uint256 repeating = _gasOfCompress(_repeating(n, 40));
        uint256 uniform = _gasOfCompress(_run(n, 0x00));

        emit log_named_uint("N=1000 random    ", random);
        emit log_named_uint("N=1000 repeating ", repeating);
        emit log_named_uint("N=1000 uniform   ", uniform);

        assertGt(random, MAINNET_BLOCK_GAS, "random input at N=1000 must exceed a 30M block");
        assertGt(uniform, MAINNET_BLOCK_GAS, "uniform input at N=1000 must exceed a 30M block too");
        assertLt(repeating, random, "structured input is cheaper to search than incompressible input");
    }

    /// @notice Where compression stops fitting in a mainnet block. A few hundred bytes is the whole
    ///         budget, which is why compressing on-chain is not a slow option but a missing one.
    function test_naive_exceedsMainnetBlockGas() public {
        uint256 at250 = _gasOfCompress(_random(1, 250));
        uint256 at500 = _gasOfCompress(_random(1, 500));

        emit log_named_uint("random N=250     ", at250);
        emit log_named_uint("random N=500     ", at500);
        emit log_named_uint("mainnet block gas", MAINNET_BLOCK_GAS);

        assertLt(at250, MAINNET_BLOCK_GAS, "250 bytes should still fit a 30M block");
        assertGt(at500, MAINNET_BLOCK_GAS, "500 bytes must exceed a 30M block");
    }

    /* ------------------------------------------------------------------ */
    /*                     Decompression: linear, cheap                    */
    /* ------------------------------------------------------------------ */

    /// @notice Expansion cost tracks the *output* size linearly. Doubling N roughly doubles it, so
    ///         a settled blob stays readable at sizes the compressor could never have reached.
    function test_sweep_decompressIsLinear() public {
        uint256[4] memory ns = [uint256(1000), 2000, 4000, 8000];
        uint256 previous;

        for (uint256 i = 0; i < ns.length; i++) {
            // Built outside the metered region: generating and compressing the fixture is not the
            // cost being measured.
            bytes memory stream = Lzss.compress(_repeating(ns[i], 40));

            uint256 used = _gasOfDecompress(stream);
            emit log_named_uint(string.concat("decompress N=", vm.toString(ns[i])), used);
            emit log_named_uint(string.concat("           gas/byte at N=", vm.toString(ns[i])), used / ns[i]);

            if (previous != 0) {
                assertLt(used, previous * 3, "decompression must not scale quadratically");
            }
            previous = used;
        }
    }

    /// @notice Expanding a blob larger than a block's worth of compression still fits in a block.
    function test_decompress_fitsInAMainnetBlock() public {
        bytes memory stream = Lzss.compress(_repeating(8000, 40));
        uint256 used = _gasOfDecompress(stream);

        emit log_named_uint("decompress 8000 bytes", used);
        assertLt(used, MAINNET_BLOCK_GAS, "expanding 8kB must fit in a 30M block");
    }

    /// @notice The headline of this example: at the same N, the two directions of the same
    ///         transformation differ by orders of magnitude. The expensive one is the one that
    ///         moves off-chain; the cheap one is the one that has to stay.
    function test_compressDecompressAsymmetry() public {
        uint256 n = 2000;
        bytes memory data = _repeating(n, 40);
        bytes memory stream = Lzss.compress(data);

        uint256 forward = _gasOfCompress(data);
        uint256 backward = _gasOfDecompress(stream);

        emit log_named_uint("N=2000 compress  ", forward);
        emit log_named_uint("N=2000 decompress", backward);
        emit log_named_uint("asymmetry factor ", forward / backward);

        assertGt(forward, backward * 20, "compression should cost at least 20x its inverse");
        assertLt(backward, MAINNET_BLOCK_GAS / 10, "decompression should be comfortably affordable");
    }

    /* ------------------------------------------------------------------ */
    /*                      What the compression buys                      */
    /* ------------------------------------------------------------------ */

    /// @notice Compression ratios on the shapes a real archive holds. The stored size is what the
    ///         consumer's diff pays for, so these ratios are settlement discounts, not just stats.
    function test_compressionRatios() public {
        bytes memory uniform = _run(4000, 0x00);
        bytes memory abiLike = _abiLike(125);
        bytes memory periodic = _repeating(4000, 40);
        bytes memory incompressible = _random(1, 500);

        emit log_named_uint("4000 uniform bytes  -> ", Lzss.compress(uniform).length);
        emit log_named_uint("4000 abi-like bytes -> ", Lzss.compress(abiLike).length);
        emit log_named_uint("4000 periodic bytes -> ", Lzss.compress(periodic).length);
        emit log_named_uint("500 random bytes    -> ", Lzss.compress(incompressible).length);

        assertLt(Lzss.compress(abiLike).length, abiLike.length / 4, "abi-like data should shrink >4x");
        assertLt(Lzss.compress(periodic).length, periodic.length / 10, "periodic data should shrink >10x");
    }

    /* ------------------------------------------------------------------ */
    /*                      Settlement contribution: zero                  */
    /* ------------------------------------------------------------------ */

    /// @notice However much the search costs on-chain, it contributes nothing to a Gas Killer
    ///         payload. There is no apply-cost curve to plot for the algorithm itself — the flat
    ///         line is exactly zero at every N. What the *consumer* settles is the compressed blob,
    ///         and that is measured in `CompressedArchive.bench.t.sol`.
    function test_settlementContributionIsZeroAtEveryN() public {
        uint256[3] memory ns = [uint256(250), 500, 1000];

        for (uint256 i = 0; i < ns.length; i++) {
            vm.record();
            vm.recordLogs();

            uint256 used = _gasOfCompress(_repeating(ns[i], 40));

            (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(address(runner));
            Vm.Log[] memory logs = vm.getRecordedLogs();

            emit log_named_uint(string.concat("N=", vm.toString(ns[i]), " on-chain gas"), used);
            emit log_named_uint(string.concat("N=", vm.toString(ns[i]), " payload ops "), writes.length + logs.length);

            assertEq(writes.length, 0, "no STORE op can be produced by a pure compress");
            assertEq(reads.length, 0, "no storage is read by a pure compress");
            assertEq(logs.length, 0, "no LOG op can be produced by a pure compress");
        }
    }
}
