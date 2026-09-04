// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Lzss, LzssRunner} from "../../../../src/examples/algo/compress/Lzss.sol";

/// @notice Shared fixtures for the Lzss unit tests and benchmarks: input generators covering the
///         shapes that exercise different parts of the search, plus round-trip assertions.
abstract contract LzssTestKit is Test {
    LzssRunner internal runner;

    function setUp() public virtual {
        runner = new LzssRunner();
    }

    /// @dev Incompressible: no back-reference reaches MIN_MATCH, so every item is a literal.
    function _random(uint256 seed, uint256 n) internal pure returns (bytes memory data) {
        data = new bytes(n);
        for (uint256 i = 0; i < n; i++) {
            data[i] = bytes1(uint8(uint256(keccak256(abi.encode(seed, i)))));
        }
    }

    /// @dev Exactly periodic: every position past the first period has a maximal match available.
    function _repeating(uint256 n, uint256 period) internal pure returns (bytes memory data) {
        bytes memory pattern = new bytes(period);
        for (uint256 i = 0; i < period; i++) {
            pattern[i] = bytes1(uint8(uint256(keccak256(abi.encode("gas-killer-lzss", i)))));
        }
        data = new bytes(n);
        for (uint256 i = 0; i < n; i++) {
            data[i] = pattern[i % period];
        }
    }

    /// @dev A single repeated byte: the case that depends on matches overlapping themselves.
    function _run(uint256 n, uint8 value) internal pure returns (bytes memory data) {
        data = new bytes(n);
        for (uint256 i = 0; i < n; i++) {
            data[i] = bytes1(value);
        }
    }

    /// @dev Values drawn from a small alphabet, so matches are frequent but rarely maximal — the
    ///      mixed literal/match traffic that neither random nor uniform input produces.
    function _lowEntropy(uint256 seed, uint256 n, uint8 alphabet) internal pure returns (bytes memory data) {
        data = new bytes(n);
        for (uint256 i = 0; i < n; i++) {
            data[i] = bytes1(uint8(uint256(keccak256(abi.encode(seed, i))) % alphabet));
        }
    }

    /// @dev The shape a real calldata archive takes: 32-byte words that are mostly zero padding
    ///      around a few significant bytes, with repeated selectors and addresses.
    function _abiLike(uint256 words) internal pure returns (bytes memory data) {
        data = new bytes(words * 32);
        for (uint256 w = 0; w < words; w++) {
            // A left-padded small integer, i.e. 31 zero bytes then a value.
            data[w * 32 + 31] = bytes1(uint8(w % 7));
        }
    }

    function _assertRoundTrip(bytes memory original, string memory label) internal pure {
        bytes memory stream = Lzss.compress(original);
        bytes memory back = Lzss.decompress(stream);
        assertEq(back, original, label);
        assertEq(Lzss.originalLength(stream), original.length, "originalLength disagrees with the input");
    }
}

contract LzssTest is LzssTestKit {
    /* ------------------------------------------------------------------ */
    /*                     Wire format — known answers                     */
    /* ------------------------------------------------------------------ */

    /// @notice Pin the exact bytes of a stream, so a change to the format is caught even if the
    ///         change is self-consistent and still round-trips.
    /// @dev Forty copies of 'a' encode as: mode 0x01, length 0x00000028, one flag byte 0x02 (item 0
    ///      literal, item 1 match), the literal 0x61, then a match of offset 0x0001 and length code
    ///      0x23 (35 + MIN_MATCH = 39). The single-byte offset is a self-overlapping match.
    function test_format_knownStream() public pure {
        bytes memory data = _run(40, 0x61);
        assertEq(Lzss.compress(data), hex"01000000280261000123", "stream bytes drifted from the format");
    }

    /// @notice Input too small to compress falls back to the stored form: a 0x00 mode byte then the
    ///         input verbatim.
    function test_format_knownStoredStream() public pure {
        assertEq(Lzss.compress(hex"00"), hex"0000", "single byte should be stored verbatim");
        assertEq(Lzss.compress(hex"deadbeef"), hex"00deadbeef", "short input should be stored verbatim");
    }

    /* ------------------------------------------------------------------ */
    /*                            Degenerate sizes                         */
    /* ------------------------------------------------------------------ */

    function test_empty() public pure {
        bytes memory stream = Lzss.compress("");
        assertEq(stream.length, 1, "an empty input is just a mode byte");
        assertEq(Lzss.decompress(stream).length, 0);
    }

    function test_singleByte() public pure {
        _assertRoundTrip(hex"7f", "single byte");
    }

    /// @notice Every length from 0 to 40 crosses the short/long boundaries in both the flag-chunk
    ///         packing (8 items) and the stored/LZSS decision.
    function test_everySmallLength() public pure {
        for (uint256 n = 0; n <= 40; n++) {
            _assertRoundTrip(_run(n, 0x41), "run round-trip");
            _assertRoundTrip(_random(n, n), "random round-trip");
        }
    }

    /* ------------------------------------------------------------------ */
    /*                       Input shapes that matter                      */
    /* ------------------------------------------------------------------ */

    function test_roundTrip_random() public pure {
        _assertRoundTrip(_random(1, 300), "random");
    }

    function test_roundTrip_repeating() public pure {
        _assertRoundTrip(_repeating(600, 40), "repeating");
    }

    function test_roundTrip_lowEntropy() public pure {
        _assertRoundTrip(_lowEntropy(2, 400, 4), "low entropy");
    }

    function test_roundTrip_abiLike() public pure {
        _assertRoundTrip(_abiLike(20), "abi-like");
    }

    /// @notice A run longer than MAX_MATCH must be split across several maximal tokens and still
    ///         reassemble exactly.
    function test_roundTrip_runLongerThanMaxMatch() public pure {
        _assertRoundTrip(_run(1000, 0x00), "1000 zero bytes");
        _assertRoundTrip(_run(1000, 0xff), "1000 0xff bytes");
    }

    /// @notice All 256 byte values must survive, including 0x00 and 0xff at the edges of a word.
    function test_roundTrip_allByteValues() public pure {
        bytes memory data = new bytes(256);
        for (uint256 i = 0; i < 256; i++) {
            data[i] = bytes1(uint8(i));
        }
        _assertRoundTrip(data, "every byte value");
    }

    /* ------------------------------------------------------------------ */
    /*                       Does it actually compress?                    */
    /* ------------------------------------------------------------------ */

    /// @notice Repetitive input must shrink substantially — this is the property the whole example
    ///         rests on, since the compressed size *is* the settlement cost.
    function test_compressesRepetitiveInput() public {
        bytes memory data = _repeating(2000, 40);
        uint256 packed = Lzss.compress(data).length;
        emit log_named_uint("repeating 2000 -> ", packed);
        assertLt(packed, data.length / 10, "periodic input should compress by more than 10x");
    }

    /// @notice A long run is the best case: thousands of bytes collapse to a handful of tokens.
    function test_compressesRunsHard() public {
        bytes memory data = _run(4000, 0x00);
        uint256 packed = Lzss.compress(data).length;
        emit log_named_uint("4000 zero bytes -> ", packed);
        assertLt(packed, 100, "a uniform run should collapse to a few tokens");
    }

    /// @notice Zero-padded ABI words are the realistic archive input, and they compress well.
    function test_compressesAbiLikeCalldata() public {
        bytes memory data = _abiLike(40);
        uint256 packed = Lzss.compress(data).length;
        emit log_named_uint("1280 abi-like bytes -> ", packed);
        assertLt(packed, data.length / 4, "zero-padded words should compress by more than 4x");
    }

    /// @notice Incompressible input falls back to the stored form, so the output never blows up.
    function test_incompressibleInputFallsBackToStored() public pure {
        bytes memory data = _random(5, 300);
        bytes memory stream = Lzss.compress(data);
        assertTrue(Lzss.isStored(stream), "random input should use the stored form");
        assertEq(stream.length, data.length + 1, "stored form costs exactly one extra byte");
    }

    /// @notice The bound that makes `compress` safe to apply unconditionally: output is never more
    ///         than one byte larger than input, whatever the input is.
    function test_neverExpandsByMoreThanOneByte() public pure {
        for (uint256 seed = 0; seed < 8; seed++) {
            bytes memory data = _random(seed, 64 * seed);
            assertLe(Lzss.compress(data).length, data.length + 1, "compress must not expand");
        }
    }

    /* ------------------------------------------------------------------ */
    /*                        Malformed stream handling                    */
    /* ------------------------------------------------------------------ */

    function test_revert_emptyStream() public {
        vm.expectRevert(Lzss.EmptyStream.selector);
        runner.decompress("");
    }

    function test_revert_unknownMode() public {
        vm.expectRevert(abi.encodeWithSelector(Lzss.UnknownMode.selector, uint8(0x02)));
        runner.decompress(hex"02ffffffff");
    }

    /// @notice An LZSS stream that ends inside its 4-byte length header.
    function test_revert_truncatedHeader() public {
        vm.expectRevert(Lzss.TruncatedStream.selector);
        runner.decompress(hex"010000");
    }

    /// @notice A stream that promises more output than its tokens can supply.
    function test_revert_truncatedBody() public {
        vm.expectRevert(Lzss.TruncatedStream.selector);
        runner.decompress(hex"0100000010");
    }

    /// @notice A stream that ends part-way through a 3-byte match token.
    function test_revert_truncatedMatchToken() public {
        // length 16, flag byte 0x01 (item 0 is a match), then only two of the token's three bytes.
        vm.expectRevert(Lzss.TruncatedStream.selector);
        runner.decompress(hex"0100000010010001");
    }

    /// @notice A match cannot reach back before the start of the output.
    function test_revert_offsetPastStart() public {
        // length 16, flag 0x01 (match), offset 0x0005 with nothing produced yet.
        vm.expectRevert(abi.encodeWithSelector(Lzss.InvalidOffset.selector, uint256(5), uint256(0)));
        runner.decompress(hex"010000001001000503");
    }

    /// @notice A zero offset is not a valid back-reference.
    function test_revert_zeroOffset() public {
        vm.expectRevert(abi.encodeWithSelector(Lzss.InvalidOffset.selector, uint256(0), uint256(0)));
        runner.decompress(hex"010000001001000003");
    }

    /// @notice A match may not write past the declared original length.
    function test_revert_overlongMatch() public {
        // length 6: one literal, then a match of 4+1=5 bytes, which would produce 6... but the
        // length code 0xff asks for 259 bytes and overruns.
        vm.expectRevert(abi.encodeWithSelector(Lzss.OverlongMatch.selector, uint256(1), uint256(259), uint256(6)));
        runner.decompress(hex"010000000602610001ff");
    }

    /// @notice A stream whose declared length is satisfied before its bytes run out is rejected
    ///         rather than silently ignoring the tail.
    function test_revert_trailingBytes() public {
        bytes memory good = Lzss.compress(_run(40, 0x61));
        bytes memory padded = bytes.concat(good, hex"00");
        vm.expectRevert(abi.encodeWithSelector(Lzss.TrailingBytes.selector, good.length, padded.length));
        runner.decompress(padded);
    }

    function test_revert_originalLengthOnEmpty() public {
        vm.expectRevert(Lzss.EmptyStream.selector);
        this.callOriginalLength("");
    }

    function callOriginalLength(bytes calldata stream) external pure returns (uint256) {
        return Lzss.originalLength(stream);
    }

    /* ------------------------------------------------------------------ */
    /*                              Inspection                             */
    /* ------------------------------------------------------------------ */

    function test_originalLength_bothModes() public pure {
        bytes memory compressible = _run(500, 0x41);
        bytes memory incompressible = _random(9, 200);

        assertFalse(Lzss.isStored(Lzss.compress(compressible)), "run should be LZSS-coded");
        assertTrue(Lzss.isStored(Lzss.compress(incompressible)), "random should be stored");

        assertEq(Lzss.originalLength(Lzss.compress(compressible)), 500);
        assertEq(Lzss.originalLength(Lzss.compress(incompressible)), 200);
    }

    /* ------------------------------------------------------------------ */
    /*         The property the Gas Killer framing depends on              */
    /* ------------------------------------------------------------------ */

    /// @notice The claim that the search settles for zero rests on the algorithm touching none of
    ///         the state a Gas Killer payload can carry. Assert that directly: compressing 400
    ///         bytes performs no storage writes, no storage reads, and emits no logs, so there is
    ///         nothing for an operator to put in a diff.
    function test_pure_touchesNoStorageAndEmitsNoLogs() public {
        vm.record();
        vm.recordLogs();

        runner.compressRepeating(400, 40);

        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(address(runner));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(writes.length, 0, "a pure compress must perform no SSTORE");
        assertEq(reads.length, 0, "a pure compress must perform no SLOAD");
        assertEq(logs.length, 0, "a pure compress must emit no logs");
    }

    /* ------------------------------------------------------------------ */
    /*                                Fuzz                                 */
    /* ------------------------------------------------------------------ */

    /// @notice Arbitrary bytes must round-trip exactly.
    /// @dev Truncated because compression is O(N^2); this mostly exercises the literal path, since
    ///      random bytes almost never produce a match.
    function testFuzz_roundTrip(bytes memory raw) public pure {
        uint256 n = raw.length > 256 ? 256 : raw.length;
        bytes memory input = new bytes(n);
        for (uint256 i = 0; i < n; i++) {
            input[i] = raw[i];
        }
        _assertRoundTrip(input, "fuzz round-trip");
    }

    /// @notice The same, projected onto a four-symbol alphabet so matches are dense.
    /// @dev This is where the match, overlap and chunk-boundary paths actually get exercised —
    ///      unprojected random bytes hardly ever match, so they would leave that half untested.
    function testFuzz_roundTrip_lowEntropy(bytes memory raw) public pure {
        uint256 n = raw.length > 256 ? 256 : raw.length;
        bytes memory input = new bytes(n);
        for (uint256 i = 0; i < n; i++) {
            input[i] = bytes1(uint8(raw[i]) % 4);
        }
        _assertRoundTrip(input, "low-entropy fuzz round-trip");
    }

    /// @notice Compression is deterministic: the same bytes always produce the same stream. The
    ///         operator quorum depends on this — nodes must agree on the diff byte for byte.
    function testFuzz_deterministic(bytes memory raw) public pure {
        uint256 n = raw.length > 128 ? 128 : raw.length;
        bytes memory input = new bytes(n);
        for (uint256 i = 0; i < n; i++) {
            input[i] = bytes1(uint8(raw[i]) % 6);
        }
        assertEq(Lzss.compress(input), Lzss.compress(input), "compression must be deterministic");
    }

    /// @notice `compress` never expands by more than the one-byte mode marker, for any input.
    function testFuzz_neverExpands(bytes memory raw) public pure {
        uint256 n = raw.length > 192 ? 192 : raw.length;
        bytes memory input = new bytes(n);
        for (uint256 i = 0; i < n; i++) {
            input[i] = bytes1(uint8(raw[i]) % 3);
        }
        assertLe(Lzss.compress(input).length, input.length + 1, "compress must not expand");
    }

    /// @notice The deployed wrapper agrees with the library.
    function testFuzz_runnerMatchesLibrary(bytes memory raw) public view {
        uint256 n = raw.length > 128 ? 128 : raw.length;
        bytes memory input = new bytes(n);
        for (uint256 i = 0; i < n; i++) {
            input[i] = bytes1(uint8(raw[i]) % 5);
        }
        assertEq(runner.compress(input), Lzss.compress(input), "runner and library disagree");
        assertEq(runner.decompress(Lzss.compress(input)), input, "runner decompress disagrees");
    }
}
