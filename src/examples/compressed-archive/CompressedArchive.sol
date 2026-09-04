// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {GasKillerSDK} from "gas-killer-sdk/GasKillerSDK.sol";
import {Lzss} from "../algo/compress/Lzss.sol";

/// @title CompressedArchive
/// @notice An append-only archive of byte blobs that stores every entry **compressed**, running the
///         full LZSS search on each one. It is the consumer half of the `Lzss` example: the
///         algorithm supplies unbounded, storage-free compute, and this contract turns that compute
///         into a permanently smaller storage bill.
///
///         A DIFFERENT SHAPE FROM THE OTHER EXAMPLES. `OnchainLife`, `GuardedVault` and
///         `SortedOracle` all collapse unbounded computation into a diff of *fixed* size — the work
///         grows, the settlement stays flat. This one does not, and that is the point. Here the
///         algorithm's output **is** the diff: what settles is the compressed blob, so the payload
///         is `ceil(compressedLength / 32) + 3` stores and one log. Gas Killer does not make
///         settlement constant, it makes it smaller *by the compression ratio*, and it does so on
///         top of making the search free. Better compression is literally a cheaper
///         `verifyAndUpdate`.
///
///         THE BASELINE IS "STORE IT RAW", NOT "COMPRESS IT ON-CHAIN". Compressing on-chain is not a
///         slower option, it is not an option: the search is O(N^2) and passes a 30M mainnet block at
///         roughly 390 bytes. So the honest comparison is against a contract that skips compression
///         and writes the blob verbatim, which is what everyone actually does today. Against that
///         baseline this wins once a blob is a few hundred bytes, because raw storage costs ~690 gas
///         per byte and the compressed form costs that only for the bytes that survive.
///
///         THE EXPANSION STAYS ON-CHAIN. `Lzss.decompress` is O(N) — about 345 gas per output byte —
///         so a settled blob is readable, not merely stored. `expand` and `verifyIntegrity` are real
///         on-chain read paths, which is what separates this from compressing somewhere else and
///         hoping nobody needs the data back.
///
/// @dev Storage layout (verify with `forge inspect ... storage-layout`): `_blobs` mapping @ slot 0
///      — DECLARED FIRST so its base slot is 0 — then `rawHash` @ 1, `rawLength` @ 2 and
///      `entryCount` @ 3. GasKillerSDK's own state lives in ERC-7201 namespaces.
///
///      ENTRIES ARE KEYED BY INDEX AND NEVER OVERWRITTEN. A `bytes` value that is replaced by a
///      shorter one leaves stale non-zero data slots behind, which Solidity clears on assignment but
///      an operator-built diff would have to reproduce explicitly. Writing each blob to a fresh key
///      removes that hazard entirely: every slot a diff touches goes from zero to its final value,
///      so the payload is exactly the bytes of the new entry and nothing else.
contract CompressedArchive is GasKillerSDK {
    /// @notice Compressed stream per entry index. DECLARED FIRST so the mapping base slot is 0.
    /// @dev Private because the generated getter for a `bytes` mapping is awkward to call; use
    ///      `storedBlob` for the raw stream and `expand` for the original bytes.
    mapping(uint256 => bytes) private _blobs;

    /// @notice `keccak256` of the original, uncompressed bytes of each entry. Slot 1.
    mapping(uint256 => bytes32) public rawHash;
    /// @notice Length in bytes of the original, uncompressed input of each entry. Slot 2.
    mapping(uint256 => uint256) public rawLength;
    /// @notice Number of entries archived so far; the next entry's index. Slot 3.
    uint256 public entryCount;

    /// @notice Emitted by each archive with the entry index and what it cost to keep.
    /// @dev One indexed param => the EVM log has 2 topics (sig + index), so the operator's equivalent
    ///      diff uses a LOG2 op: data = abi.encode(rawHash, rawLength, storedLength),
    ///      topics = [sig, index].
    event Archived(uint256 indexed index, bytes32 rawHash, uint256 rawLength, uint256 storedLength);

    error EmptyBlob();
    error UnknownEntry(uint256 index);

    /// @param _avsAddress AVS service-manager address (scopes the Gas Killer namespace).
    /// @param _blsSigChecker BLS signature checker used by `verifyAndUpdate`.
    constructor(address _avsAddress, address _blsSigChecker) {
        _setAvsAddress(_avsAddress);
        _setBlsSignatureChecker(_blsSigChecker);
    }

    /// @notice Compress `raw` and append it to the archive.
    /// @dev THIS IS THE NAIVE, GAS-EXPLOSIVE SPEC. It is what tests execute to derive the expected
    ///      post-state and what the benchmarks measure; in production the operator quorum runs it
    ///      off-chain and submits the resulting diff via `verifyAndUpdate`. Nothing here is traded
    ///      away for a cheaper shape: the exhaustive search runs in full on every call, which is
    ///      precisely the work that costs nothing once it moves off-chain.
    ///
    ///      Note what this means for the settled path — `raw` never reaches the chain at all. The
    ///      blob is handed to the operators, who reproduce this function off-chain; the transaction
    ///      that lands carries the *compressed* diff. So compression saves the per-byte calldata
    ///      charge as well as the per-slot storage charge.
    /// @param raw The bytes to archive.
    function archive(bytes calldata raw) external trackState {
        if (raw.length == 0) revert EmptyBlob();

        bytes memory packed = Lzss.compress(raw);
        bytes32 digest = keccak256(raw);
        uint256 index = entryCount;

        _blobs[index] = packed;
        rawHash[index] = digest;
        rawLength[index] = raw.length;
        entryCount = index + 1;

        emit Archived(index, digest, raw.length, packed.length);
    }

    /// @notice The compressed stream held for `index`, exactly as stored.
    function storedBlob(uint256 index) external view returns (bytes memory) {
        if (index >= entryCount) revert UnknownEntry(index);
        return _blobs[index];
    }

    /// @notice Expand entry `index` back to its original bytes.
    /// @dev The cheap direction, and the reason the archive is useful rather than merely small: O(N)
    ///      in the expanded size, so this is affordable on-chain for blobs far larger than anything
    ///      that could have been compressed on-chain in the first place.
    function expand(uint256 index) external view returns (bytes memory) {
        if (index >= entryCount) revert UnknownEntry(index);
        return Lzss.decompress(_blobs[index]);
    }

    /// @notice Whether expanding entry `index` reproduces the hash recorded when it was archived.
    /// @dev Checks the round-trip against state that a quorum settled, so it is the on-chain
    ///      statement that the compression was lossless and the diff was applied faithfully.
    function verifyIntegrity(uint256 index) external view returns (bool) {
        if (index >= entryCount) revert UnknownEntry(index);
        return keccak256(Lzss.decompress(_blobs[index])) == rawHash[index];
    }

    /// @notice Stored size of entry `index` as a fraction of its original size, in basis points.
    /// @dev 10_000 means no saving; 1_000 means the entry occupies a tenth of what it would have.
    function storedSizeBps(uint256 index) external view returns (uint256) {
        if (index >= entryCount) revert UnknownEntry(index);
        return (_blobs[index].length * 10_000) / rawLength[index];
    }

    /// @notice Total bytes archived, and total bytes actually held, across every entry.
    /// @dev O(entryCount) reads. Reports the archive's cumulative saving without needing an indexer.
    function totals() external view returns (uint256 totalRaw, uint256 totalStored) {
        uint256 n = entryCount;
        for (uint256 i = 0; i < n; i++) {
            totalRaw += rawLength[i];
            totalStored += _blobs[i].length;
        }
    }
}
