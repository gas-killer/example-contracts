// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @title Lzss
/// @notice Lossless LZ77/LZSS compression, written **greedily on purpose**: finding the longest
///         back-reference at a position means comparing that position against *every* earlier byte
///         of the input, one byte at a time, with no hash chains, no match-length cutoff and no
///         early exit. It touches no storage, emits no logs and makes no external calls, so it is
///         `pure` in the strict Solidity sense and — more importantly here — invisible to Gas
///         Killer's cost model.
///
///         WHY THAT MATTERS. A Gas Killer payload is a list of `STORE` / `LOG*` / `CALL` / `CREATE`
///         operations, and the analyzer prices exactly those. Memory traffic, comparisons and jumps
///         are not representable in a payload and are therefore never paid for on-chain: they are
///         the work the operator quorum absorbs off-chain. So the search costs the chain nothing,
///         however long it runs.
///
///         THE ASYMMETRY IS THE POINT. Compression and decompression are the same transformation
///         read in two directions, and they cost wildly different amounts:
///
///           - `compress` is O(N^2): N positions, each scanning a window that grows to N.
///           - `decompress` is O(N): parse a token, copy its bytes, advance.
///
///         The expensive direction is the one that moves off-chain. The cheap direction stays
///         on-chain and remains genuinely affordable, so a settled blob is not write-only — any
///         contract can expand it on demand. That is the difference between compressing *for* the
///         chain and merely compressing *elsewhere*.
///
///         AND THE OUTPUT IS THE DIFF. The other examples in this repo collapse unbounded compute
///         into a diff of fixed size. This one does something else: what settles is the compressed
///         blob itself, so the algorithm's own output *is* the settlement cost. Better compression
///         is directly a cheaper `verifyAndUpdate`. See `CompressedArchive`, which stores blobs
///         through this library and pays storage proportional to the compressed size.
///
/// @dev COST IS QUADRATIC ON EVERY INPUT SHAPE, which is worth stating because the intuitive guess
///      is wrong. Highly repetitive input extends each candidate comparison much further (up to
///      `MAX_MATCH` bytes instead of the ~1 byte a random-input comparison survives), but it also
///      consumes the input in far larger strides, so it needs proportionally fewer searches. The
///      two effects cancel: random and repetitive input are both Theta(N^2), within a constant
///      factor. There is no "benign input is cheap" regime here, and no adversarial shape is needed
///      to trigger the bad one — a large blob is enough.
///
///      A production compressor would replace the linear window scan with a hash chain keyed on the
///      first few bytes, stop extending once a "good enough" length is reached, and compare 32 bytes
///      at a time with word loads instead of one byte at a time. All three are deliberately absent.
library Lzss {
    /// @notice Stream is the original bytes verbatim, after the mode byte.
    uint8 internal constant MODE_STORED = 0x00;
    /// @notice Stream is an LZSS token stream, after the mode byte and the length header.
    uint8 internal constant MODE_LZSS = 0x01;

    /// @notice Shortest back-reference worth encoding.
    /// @dev A match token costs 3 bytes plus one flag bit, so a 3-byte match would break even at
    ///      best and a shorter one would lose. Four is the smallest length that always wins.
    uint256 internal constant MIN_MATCH = 4;
    /// @notice Longest back-reference the 8-bit length field can express (`0xff + MIN_MATCH`).
    uint256 internal constant MAX_MATCH = 259;
    /// @notice How far back a match may reach, bounded by the 16-bit offset field.
    /// @dev Larger than any input these examples compress, so the search window is effectively
    ///      unbounded and the scan is genuinely quadratic rather than linear-with-a-big-constant.
    uint256 internal constant WINDOW = 65_535;

    /// @notice The stream is empty, so it does not even carry a mode byte.
    error EmptyStream();
    /// @notice The mode byte is neither `MODE_STORED` nor `MODE_LZSS`.
    error UnknownMode(uint8 mode);
    /// @notice The stream ended in the middle of a header, a token, or a literal.
    error TruncatedStream();
    /// @notice A match reaches back past the start of the output produced so far.
    error InvalidOffset(uint256 offset, uint256 produced);
    /// @notice A match would write past the declared original length.
    error OverlongMatch(uint256 produced, uint256 length, uint256 rawLength);
    /// @notice The declared original length was satisfied before the stream was consumed.
    error TrailingBytes(uint256 cursor, uint256 length);
    /// @notice Input longer than the 32-bit length header can describe.
    error InputTooLarge(uint256 length);

    /* --------------------------------------------------------------------- */
    /*                              Compression                               */
    /* --------------------------------------------------------------------- */

    /// @notice Compress `data` into a self-describing stream that `decompress` inverts exactly.
    /// @dev Compresses first and compares afterwards: LZSS is used only when its stream is strictly
    ///      smaller than the stored form, so the result never exceeds `data.length + 1`. Ties go to
    ///      the stored form, which is cheaper to expand. This means incompressible input still costs
    ///      the full O(N^2) search before falling back — you cannot know a blob is incompressible
    ///      without looking.
    /// @param data The bytes to compress.
    /// @return A newly allocated stream; `decompress(compress(x)) == x` for every `x`.
    function compress(bytes memory data) internal pure returns (bytes memory) {
        bytes memory packed = _pack(data);
        if (packed.length < data.length + 1) return packed;

        bytes memory stored = new bytes(data.length + 1);
        stored[0] = bytes1(MODE_STORED);
        for (uint256 i = 0; i < data.length; i++) {
            stored[i + 1] = data[i];
        }
        return stored;
    }

    /// @notice Build the LZSS form of `data`, whether or not it turns out to be smaller than `data`.
    /// @dev Wire format, all integers big-endian:
    ///
    ///        stream := 0x01 || rawLength (4 bytes) || chunk*
    ///        chunk  := flagByte || item{1..8}
    ///        item   := literal (1 byte) | match (3 bytes)
    ///        match  := offset (2 bytes) || lengthCode (1 byte)
    ///
    ///      Bit `i` of a flag byte, counted from the least significant, describes item `i` of that
    ///      chunk: 0 for a literal, 1 for a match. `offset` is how far back to reach (1..WINDOW) and
    ///      the true length is `lengthCode + MIN_MATCH`.
    ///
    ///      A final chunk may hold fewer than eight items, leaving trailing flag bits set to zero.
    ///      Those bits are never interpreted, because decoding is terminated by `rawLength` rather
    ///      than by running out of flag bits — which is what the length header is for.
    function _pack(bytes memory data) private pure returns (bytes memory out) {
        uint256 n = data.length;
        // The length header is four bytes wide, so the format cannot describe a longer input.
        // Unreachable for any blob the EVM can hold in memory, but it is what makes the byte
        // extractions below provably lossless rather than merely lossless in practice.
        if (n > type(uint32).max) revert InputTooLarge(n);

        // Worst case is an all-literal stream: one byte per input byte, plus one flag byte per eight
        // of them, after the mode byte and the 4-byte length header. Matches cannot beat that bound
        // (eight match tokens cost 25 bytes and consume at least 32 input bytes), so this allocation
        // is always sufficient and the buffer is shrunk to its true length at the end.
        out = new bytes(5 + n + (n + 7) / 8);
        out[0] = bytes1(MODE_LZSS);
        out[1] = bytes1(uint8(n >> 24));
        out[2] = bytes1(uint8(n >> 16));
        out[3] = bytes1(uint8(n >> 8));
        out[4] = bytes1(uint8(n));

        uint256 outLen = 5;
        uint256 pos;

        while (pos < n) {
            // The flag byte describes items that have not been emitted yet, so its slot is reserved
            // and filled in once the chunk is complete.
            uint256 flagIndex = outLen++;
            uint256 flags;

            for (uint256 item = 0; item < 8 && pos < n; item++) {
                (uint256 offset, uint256 length) = _longestMatch(data, pos);

                if (length >= MIN_MATCH) {
                    // Both fields are bounded by construction: `_longestMatch` never returns an
                    // offset above WINDOW (16 bits) or a length above MAX_MATCH, so the length code
                    // fits in 8 bits. The truncations below are the intended byte extractions.
                    flags |= uint256(1) << item;
                    out[outLen++] = bytes1(uint8(offset >> 8));
                    out[outLen++] = bytes1(uint8(offset));
                    out[outLen++] = bytes1(uint8(length - MIN_MATCH));
                    pos += length;
                } else {
                    out[outLen++] = data[pos++];
                }
            }

            out[flagIndex] = bytes1(uint8(flags));
        }

        // Shrink to the bytes actually written. The tail of the over-allocation stays allocated and
        // unreferenced, which is why this does not disturb the free memory pointer.
        assembly ("memory-safe") {
            mstore(out, outLen)
        }
    }

    /// @notice Longest back-reference to `data[pos]` available within the window, by exhaustive scan.
    /// @dev THIS IS THE EXPENSIVE HALF, and it is written to stay that way. Every candidate position
    ///      in the window is tried, every trial extends one byte at a time, and the loop does not
    ///      stop early when a maximal match is already in hand.
    ///
    ///      Candidate comparisons are allowed to read at or past `pos` — `data[candidate + run]` can
    ///      cross into the region being encoded. That is what makes a match overlap itself, and it is
    ///      how a long run collapses to one token (a thousand zero bytes become `offset = 1`,
    ///      `length = 259` repeated four times). The decoder must therefore copy byte by byte rather
    ///      than as a block; see `decompress`.
    /// @return offset Distance back to the best match, or 0 if none reaches `MIN_MATCH`.
    /// @return length Length of that match, or 0 if none reaches `MIN_MATCH`.
    function _longestMatch(bytes memory data, uint256 pos) private pure returns (uint256 offset, uint256 length) {
        uint256 remaining = data.length - pos;
        uint256 maxLen = remaining > MAX_MATCH ? MAX_MATCH : remaining;
        if (maxLen < MIN_MATCH) return (0, 0);

        uint256 windowStart = pos > WINDOW ? pos - WINDOW : 0;

        for (uint256 candidate = windowStart; candidate < pos; candidate++) {
            uint256 run;
            while (run < maxLen && data[candidate + run] == data[pos + run]) {
                run++;
            }
            if (run > length) {
                length = run;
                offset = pos - candidate;
            }
        }

        if (length < MIN_MATCH) return (0, 0);
    }

    /* --------------------------------------------------------------------- */
    /*                             Decompression                              */
    /* --------------------------------------------------------------------- */

    /// @notice Expand a stream produced by `compress` back to the exact original bytes.
    /// @dev O(N) in the *output* size: each token is read once and contributes its bytes once. This
    ///      is the direction that stays affordable on-chain, which is what makes a settled blob
    ///      readable rather than merely stored.
    ///
    ///      Every structural assumption is checked rather than assumed, because this is reachable
    ///      with arbitrary caller-supplied bytes: a malformed stream reverts with a named error
    ///      instead of reading out of bounds or silently producing the wrong plaintext.
    /// @param stream A stream in either supported mode.
    /// @return out The original bytes.
    function decompress(bytes memory stream) internal pure returns (bytes memory out) {
        if (stream.length == 0) revert EmptyStream();

        uint8 mode = uint8(stream[0]);
        if (mode == MODE_STORED) {
            out = new bytes(stream.length - 1);
            for (uint256 i = 0; i < out.length; i++) {
                out[i] = stream[i + 1];
            }
            return out;
        }
        if (mode != MODE_LZSS) revert UnknownMode(mode);
        if (stream.length < 5) revert TruncatedStream();

        uint256 rawLength = (uint256(uint8(stream[1])) << 24) | (uint256(uint8(stream[2])) << 16)
            | (uint256(uint8(stream[3])) << 8) | uint256(uint8(stream[4]));

        out = new bytes(rawLength);

        uint256 cursor = 5;
        uint256 produced;
        uint256 flags;
        // Forces a flag byte to be read before the first item of the stream.
        uint256 item = 8;

        while (produced < rawLength) {
            if (item == 8) {
                if (cursor >= stream.length) revert TruncatedStream();
                flags = uint8(stream[cursor++]);
                item = 0;
            }

            if (flags & (uint256(1) << item) != 0) {
                if (cursor + 3 > stream.length) revert TruncatedStream();
                uint256 offset = (uint256(uint8(stream[cursor])) << 8) | uint256(uint8(stream[cursor + 1]));
                uint256 length = uint256(uint8(stream[cursor + 2])) + MIN_MATCH;
                cursor += 3;

                if (offset == 0 || offset > produced) revert InvalidOffset(offset, produced);
                if (produced + length > rawLength) revert OverlongMatch(produced, length, rawLength);

                // Byte by byte, deliberately: when `offset < length` the source region overlaps the
                // destination and each copied byte feeds the next comparison. A block copy would
                // read stale bytes and expand a run incorrectly.
                uint256 from = produced - offset;
                for (uint256 k = 0; k < length; k++) {
                    out[produced + k] = out[from + k];
                }
                produced += length;
            } else {
                if (cursor >= stream.length) revert TruncatedStream();
                out[produced++] = stream[cursor++];
            }

            item++;
        }

        if (cursor != stream.length) revert TrailingBytes(cursor, stream.length);
    }

    /* --------------------------------------------------------------------- */
    /*                               Inspection                               */
    /* --------------------------------------------------------------------- */

    /// @notice Original length declared by an LZSS stream, or the true length of a stored one.
    /// @dev O(1), so a consumer can size the expansion without paying to perform it.
    function originalLength(bytes memory stream) internal pure returns (uint256) {
        if (stream.length == 0) revert EmptyStream();

        uint8 mode = uint8(stream[0]);
        if (mode == MODE_STORED) return stream.length - 1;
        if (mode != MODE_LZSS) revert UnknownMode(mode);
        if (stream.length < 5) revert TruncatedStream();

        return (uint256(uint8(stream[1])) << 24) | (uint256(uint8(stream[2])) << 16) | (uint256(uint8(stream[3])) << 8)
            | uint256(uint8(stream[4]));
    }

    /// @notice Whether `stream` fell back to storing its input verbatim.
    function isStored(bytes memory stream) internal pure returns (bool) {
        if (stream.length == 0) revert EmptyStream();
        return uint8(stream[0]) == MODE_STORED;
    }
}

/// @title LzssRunner
/// @notice Deployable wrapper around the `Lzss` library, so the algorithm's on-chain cost can be
///         measured as a real transaction rather than only inside a test harness. Every entry point
///         is `pure`: this contract has no storage, and a call to it can never produce a Gas Killer
///         payload operation. Its whole cost is the work Gas Killer prices at zero.
/// @dev The sweep helpers generate their own input instead of taking it as calldata. Calldata is
///      charged per byte on both the naive and the settled path, so including it would inflate both
///      sides of a benchmark with a cost that has nothing to do with compressing, and would cap N at
///      whatever fits in a transaction. They return the compressed length rather than the stream for
///      the same reason: ABI-encoding the result back to the caller is measurable work that is not
///      the search.
contract LzssRunner {
    /// @notice Compress a caller-supplied blob.
    function compress(bytes calldata data) external pure returns (bytes memory) {
        return Lzss.compress(data);
    }

    /// @notice Expand a caller-supplied stream.
    function decompress(bytes calldata stream) external pure returns (bytes memory) {
        return Lzss.decompress(stream);
    }

    /// @notice Compressed size of `n` pseudorandom bytes derived from `seed`.
    /// @dev Incompressible input: no back-reference ever reaches `MIN_MATCH`, so every position
    ///      falls through to a literal and the stored fallback wins. The search still runs in full —
    ///      proving a blob incompressible costs exactly as much as compressing it.
    function compressRandom(uint256 seed, uint256 n) external pure returns (uint256) {
        return Lzss.compress(_random(seed, n)).length;
    }

    /// @notice Compressed size of `n` bytes built by repeating a `period`-byte pattern.
    /// @dev Highly compressible input, and the shape real calldata archives take — repeated
    ///      addresses, selectors and zero-padded words. Matches run to `MAX_MATCH`, so the input is
    ///      consumed in large strides; the per-candidate comparison grows by the same factor the
    ///      search count shrinks, which is why this costs the same order as random input.
    function compressRepeating(uint256 n, uint256 period) external pure returns (uint256) {
        return Lzss.compress(_repeating(n, period)).length;
    }

    /// @notice Generate `n` pseudorandom bytes; the input generator used by `compressRandom`.
    /// @dev Exposed so a benchmark can build an input without metering its construction.
    function random(uint256 seed, uint256 n) external pure returns (bytes memory) {
        return _random(seed, n);
    }

    /// @notice Generate `n` bytes of a repeating `period`-byte pattern.
    function repeating(uint256 n, uint256 period) external pure returns (bytes memory) {
        return _repeating(n, period);
    }

    function _random(uint256 seed, uint256 n) private pure returns (bytes memory data) {
        data = new bytes(n);
        for (uint256 i = 0; i < n; i++) {
            data[i] = bytes1(uint8(uint256(keccak256(abi.encode(seed, i)))));
        }
    }

    /// @dev Byte `i` is `keccak(seed-free pattern)[i % period]`, so the blob is exactly periodic and
    ///      every position beyond the first period has a maximal-length back-reference available.
    function _repeating(uint256 n, uint256 period) private pure returns (bytes memory data) {
        if (period == 0) period = 1;
        bytes memory pattern = new bytes(period);
        for (uint256 i = 0; i < period; i++) {
            pattern[i] = bytes1(uint8(uint256(keccak256(abi.encode("gas-killer-lzss", i)))));
        }
        data = new bytes(n);
        for (uint256 i = 0; i < n; i++) {
            data[i] = pattern[i % period];
        }
    }
}
