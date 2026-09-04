// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BenchmarkBase} from "../helpers/BenchmarkBase.sol";
import {Vm} from "forge-std/Vm.sol";
import {CompressedArchive} from "../../src/examples/compressed-archive/CompressedArchive.sol";
import {Lzss} from "../../src/examples/algo/compress/Lzss.sol";
import {MockBLSSignatureChecker} from "../mocks/MockBLSSignatureChecker.sol";
import {OffchainPayloadBuilder} from "../helpers/OffchainPayloadBuilder.sol";
import {StateUpdateType} from "gas-killer-sdk/StateChangeHandlerLib.sol";

/// @notice Shared fixtures + diff-building helpers for the CompressedArchive unit tests and
///         benchmarks.
abstract contract CompressedArchiveTestKit is BenchmarkBase {
    MockBLSSignatureChecker internal bls;
    address internal avs = makeAddr("avs");

    // Slot constants (verified against `forge inspect`): the blob mapping is declared first, so its
    // base slot is 0, then the two metadata mappings and the counter.
    uint256 internal constant BLOBS_SLOT = 0;
    uint256 internal constant RAW_HASH_SLOT = 1;
    uint256 internal constant RAW_LENGTH_SLOT = 2;
    uint256 internal constant ENTRY_COUNT_SLOT = 3;

    bytes32 internal constant ARCHIVED_SIG = keccak256("Archived(uint256,bytes32,uint256,uint256)");

    function setUp() public virtual {
        bls = _deployPassingBls();
    }

    function _deployArchive() internal returns (CompressedArchive) {
        return new CompressedArchive(avs, address(bls));
    }

    /// @dev Build the storage diff an operator would submit after `a` archived entry `index`: the
    ///      compressed blob's slots, the two metadata words, the bumped counter, and a LOG2
    ///      mirroring `Archived`. Unlike the other examples this diff is *not* fixed-size — it grows
    ///      with the compressed blob, which is the whole reason compression is worth doing here.
    function _buildArchiveDiff(CompressedArchive a, uint256 index) internal view returns (bytes memory) {
        bytes memory packed = a.storedBlob(index);
        bytes32 rawHash = a.rawHash(index);
        uint256 rawLength = a.rawLength(index);

        OffchainPayloadBuilder.Op[] memory blobOps =
            OffchainPayloadBuilder.bytesStoreOps(OffchainPayloadBuilder.mappingSlot(index, BLOBS_SLOT), packed);

        OffchainPayloadBuilder.Op[] memory ops = new OffchainPayloadBuilder.Op[](blobOps.length + 4);
        for (uint256 i = 0; i < blobOps.length; i++) {
            ops[i] = blobOps[i];
        }

        ops[blobOps.length] = OffchainPayloadBuilder.Op(
            StateUpdateType.STORE,
            OffchainPayloadBuilder.encodeStore(OffchainPayloadBuilder.mappingSlot(index, RAW_HASH_SLOT), rawHash)
        );
        ops[blobOps.length + 1] = OffchainPayloadBuilder.Op(
            StateUpdateType.STORE,
            OffchainPayloadBuilder.encodeStore(
                OffchainPayloadBuilder.mappingSlot(index, RAW_LENGTH_SLOT), bytes32(rawLength)
            )
        );
        ops[blobOps.length + 2] = OffchainPayloadBuilder.Op(
            StateUpdateType.STORE,
            OffchainPayloadBuilder.encodeStore(
                OffchainPayloadBuilder.simpleSlot(ENTRY_COUNT_SLOT), bytes32(a.entryCount())
            )
        );
        ops[blobOps.length + 3] = OffchainPayloadBuilder.Op(
            StateUpdateType.LOG2,
            OffchainPayloadBuilder.encodeLog2(
                abi.encode(rawHash, rawLength, packed.length), ARCHIVED_SIG, bytes32(index)
            )
        );

        return OffchainPayloadBuilder.build(ops);
    }

    /// @dev Number of payload operations an archive of `packed` produces: the blob's slots plus two
    ///      metadata words, the counter, and the log.
    function _expectedOpCount(bytes memory packed) internal pure returns (uint256) {
        return OffchainPayloadBuilder.bytesSlotCount(packed.length) + 4;
    }

    /// @dev The shape a real calldata archive takes: 32-byte words that are mostly zero padding.
    function _abiLike(uint256 words) internal pure returns (bytes memory data) {
        data = new bytes(words * 32);
        for (uint256 w = 0; w < words; w++) {
            data[w * 32 + 31] = bytes1(uint8(w % 7));
        }
    }

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

    function _random(uint256 seed, uint256 n) internal pure returns (bytes memory data) {
        data = new bytes(n);
        for (uint256 i = 0; i < n; i++) {
            data[i] = bytes1(uint8(uint256(keccak256(abi.encode(seed, i)))));
        }
    }

    function _findArchivedLog(Vm.Log[] memory logs) internal pure returns (Vm.Log memory) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length == 2 && logs[i].topics[0] == ARCHIVED_SIG) {
                return logs[i];
            }
        }
        revert("Archived log not found");
    }
}

contract CompressedArchiveTest is CompressedArchiveTestKit {
    /* ------------------------------------------------------------------ */
    /*                          Naive correctness                          */
    /* ------------------------------------------------------------------ */

    function test_archive_storesCompressedAndExpandsBack() public {
        CompressedArchive a = _deployArchive();
        bytes memory raw = _repeating(600, 40);

        a.archive(raw);

        assertEq(a.entryCount(), 1, "one entry");
        assertEq(a.rawLength(0), raw.length, "raw length recorded");
        assertEq(a.rawHash(0), keccak256(raw), "raw hash recorded");
        assertLt(a.storedBlob(0).length, raw.length, "stored form must be smaller");
        assertEq(a.expand(0), raw, "expansion must reproduce the original exactly");
        assertTrue(a.verifyIntegrity(0), "integrity check must pass");
    }

    /// @notice Entries are independent and keyed by index, so a second archive never disturbs a
    ///         first — the property that keeps every diff a pure zero-to-value write.
    function test_archive_multipleEntriesAreIndependent() public {
        CompressedArchive a = _deployArchive();
        bytes memory first = _repeating(400, 40);
        bytes memory second = _abiLike(20);
        bytes memory third = _random(3, 100);

        a.archive(first);
        a.archive(second);
        a.archive(third);

        assertEq(a.entryCount(), 3, "three entries");
        assertEq(a.expand(0), first, "entry 0 intact");
        assertEq(a.expand(1), second, "entry 1 intact");
        assertEq(a.expand(2), third, "entry 2 intact");
        assertTrue(a.verifyIntegrity(0) && a.verifyIntegrity(1) && a.verifyIntegrity(2), "all intact");
    }

    /// @notice A shorter entry after a longer one is the case that would corrupt a single-slot
    ///         design; keying by index makes it a non-event.
    function test_archive_shorterEntryAfterLonger() public {
        CompressedArchive a = _deployArchive();
        bytes memory long = _abiLike(40);
        bytes memory short = _repeating(64, 8);

        a.archive(long);
        a.archive(short);

        assertEq(a.expand(0), long, "long entry must survive");
        assertEq(a.expand(1), short, "short entry must be correct");
    }

    /// @notice Incompressible input still archives correctly; it just costs one extra byte.
    function test_archive_incompressibleInput() public {
        CompressedArchive a = _deployArchive();
        bytes memory raw = _random(1, 300);

        a.archive(raw);

        assertEq(a.storedBlob(0).length, raw.length + 1, "stored form is the raw bytes plus a mode byte");
        assertEq(a.expand(0), raw, "expansion must still be exact");
        assertEq(a.storedSizeBps(0), (uint256(raw.length + 1) * 10_000) / raw.length, "bps for stored form");
    }

    /// @notice A blob short enough to live inside its header slot exercises the packed `bytes` form.
    function test_archive_shortBlobUsesPackedForm() public {
        CompressedArchive a = _deployArchive();
        bytes memory raw = _repeating(500, 4);

        a.archive(raw);

        bytes memory packed = a.storedBlob(0);
        assertLt(packed.length, 32, "this input should compress into the short form");
        assertEq(a.expand(0), raw, "short-form entry must expand correctly");
    }

    function test_archive_revertsOnEmptyBlob() public {
        CompressedArchive a = _deployArchive();
        vm.expectRevert(CompressedArchive.EmptyBlob.selector);
        a.archive("");
    }

    function test_revert_unknownEntry() public {
        CompressedArchive a = _deployArchive();
        vm.expectRevert(abi.encodeWithSelector(CompressedArchive.UnknownEntry.selector, uint256(0)));
        a.expand(0);
    }

    function test_storedSizeBps_andTotals() public {
        CompressedArchive a = _deployArchive();
        bytes memory raw = _abiLike(20);

        a.archive(raw);

        uint256 bps = a.storedSizeBps(0);
        assertLt(bps, 2_500, "abi-like input should occupy under a quarter of its raw size");

        (uint256 totalRaw, uint256 totalStored) = a.totals();
        assertEq(totalRaw, raw.length, "total raw");
        assertEq(totalStored, a.storedBlob(0).length, "total stored");
        assertLt(totalStored, totalRaw, "archive must hold less than it was given");
    }

    /* ------------------------------------------------------------------ */
    /*          Equivalence: naive on-chain  ==  operator diff             */
    /* ------------------------------------------------------------------ */

    /// @notice The heart of the demo: run the naive `archive` on instance A, have the "operator"
    ///         build the resulting storage diff, apply it to a fresh instance B through the *full*
    ///         `verifyAndUpdate` path (mock BLS), and assert A and B end up byte-identical — every
    ///         slot of the compressed blob (via raw `vm.load`) and the emitted log.
    function test_equivalence_naiveVsDiff() public {
        bytes memory raw = _abiLike(30);
        CompressedArchive a = _deployArchive();
        CompressedArchive b = _deployArchive();

        // --- A: run the naive spec, capturing its log. ---
        vm.recordLogs();
        a.archive(raw);
        Vm.Log[] memory aLogs = vm.getRecordedLogs();

        // --- Operator: build the diff from A's resulting state. ---
        bytes memory diff = _buildArchiveDiff(a, 0);

        // --- B: apply via verifyAndUpdate, capturing its log. ---
        uint256 countBefore = b.stateTransitionCount();
        vm.recordLogs();
        _verify(b, diff, CompressedArchive.archive.selector);
        Vm.Log[] memory bLogs = vm.getRecordedLogs();

        // --- Assert state equality, slot by slot, via raw storage reads. ---
        bytes32 blobHeader = OffchainPayloadBuilder.mappingSlot(uint256(0), BLOBS_SLOT);
        uint256 slotCount = OffchainPayloadBuilder.bytesSlotCount(a.storedBlob(0).length);
        assertEq(vm.load(address(b), blobHeader), vm.load(address(a), blobHeader), "blob header mismatch");
        for (uint256 i = 0; i + 1 < slotCount; i++) {
            bytes32 dataSlot = OffchainPayloadBuilder.bytesDataSlot(blobHeader, i);
            assertEq(vm.load(address(b), dataSlot), vm.load(address(a), dataSlot), "blob data slot mismatch");
        }
        assertEq(b.rawHash(0), a.rawHash(0), "rawHash mismatch");
        assertEq(b.rawLength(0), a.rawLength(0), "rawLength mismatch");
        assertEq(b.entryCount(), a.entryCount(), "entryCount mismatch");
        assertEq(b.stateTransitionCount(), countBefore + 1, "verifyAndUpdate should bump the counter once");

        // --- The settled contract must be readable, not merely written. ---
        assertEq(b.expand(0), raw, "settled blob must expand to the original bytes");
        assertTrue(b.verifyIntegrity(0), "settled blob must pass its own integrity check");

        // --- Assert the emitted log matches the naive event exactly. ---
        Vm.Log memory aEvt = _findArchivedLog(aLogs);
        Vm.Log memory bEvt = _findArchivedLog(bLogs);
        assertEq(bEvt.topics[0], aEvt.topics[0], "log sig mismatch");
        assertEq(bEvt.topics[1], aEvt.topics[1], "indexed index mismatch");
        assertEq(keccak256(bEvt.data), keccak256(aEvt.data), "log data mismatch");
    }

    /// @notice The same equivalence for a blob that compresses into the short (packed header) form,
    ///         which takes a different branch of the `bytes` storage encoding.
    function test_equivalence_shortForm() public {
        bytes memory raw = _repeating(500, 4);
        CompressedArchive a = _deployArchive();
        CompressedArchive b = _deployArchive();

        a.archive(raw);
        assertLt(a.storedBlob(0).length, 32, "fixture must use the short form");

        _verify(b, _buildArchiveDiff(a, 0), CompressedArchive.archive.selector);

        assertEq(b.expand(0), raw, "short-form settled blob must expand correctly");
        assertEq(b.storedBlob(0), a.storedBlob(0), "short-form blob mismatch");
    }

    /// @notice The same equivalence for incompressible input, where the stored fallback means the
    ///         diff carries essentially the raw bytes.
    function test_equivalence_incompressibleInput() public {
        bytes memory raw = _random(11, 200);
        CompressedArchive a = _deployArchive();
        CompressedArchive b = _deployArchive();

        a.archive(raw);
        _verify(b, _buildArchiveDiff(a, 0), CompressedArchive.archive.selector);

        assertEq(b.expand(0), raw, "settled stored-form blob must expand correctly");
    }

    /// @notice Settling a second entry must leave the first untouched, so consecutive diffs compose.
    function test_equivalence_consecutiveEntries() public {
        bytes memory first = _abiLike(10);
        bytes memory second = _repeating(400, 40);
        CompressedArchive a = _deployArchive();
        CompressedArchive b = _deployArchive();

        a.archive(first);
        _verify(b, _buildArchiveDiff(a, 0), CompressedArchive.archive.selector);

        a.archive(second);
        _verify(b, _buildArchiveDiff(a, 1), CompressedArchive.archive.selector);

        assertEq(b.entryCount(), 2, "two settled entries");
        assertEq(b.expand(0), first, "first entry must survive the second diff");
        assertEq(b.expand(1), second, "second entry must be correct");
    }

    /// @notice An archive touches only the slots belonging to the entry it is writing, so a diff
    ///         never has to clear anything and never disturbs an earlier entry.
    function test_diff_touchesOnlyTheNewEntrysSlots() public {
        bytes memory raw = _abiLike(15);
        CompressedArchive a = _deployArchive();
        CompressedArchive b = _deployArchive();
        a.archive(raw);

        vm.record();
        _verify(b, _buildArchiveDiff(a, 0), CompressedArchive.archive.selector);
        (, bytes32[] memory writes) = vm.accesses(address(b));

        bytes32 blobHeader = OffchainPayloadBuilder.mappingSlot(uint256(0), BLOBS_SLOT);
        uint256 slotCount = OffchainPayloadBuilder.bytesSlotCount(a.storedBlob(0).length);

        for (uint256 i = 0; i < writes.length; i++) {
            bytes32 slot = writes[i];
            bool expected = slot == blobHeader || slot == OffchainPayloadBuilder.mappingSlot(uint256(0), RAW_HASH_SLOT)
                || slot == OffchainPayloadBuilder.mappingSlot(uint256(0), RAW_LENGTH_SLOT)
                || slot == OffchainPayloadBuilder.simpleSlot(ENTRY_COUNT_SLOT);

            for (uint256 w = 0; !expected && w + 1 < slotCount; w++) {
                if (slot == OffchainPayloadBuilder.bytesDataSlot(blobHeader, w)) expected = true;
            }
            // The SDK's own transition counter lives in an ERC-7201 namespace, far from slots 0..3.
            if (!expected) expected = uint256(slot) > ENTRY_COUNT_SLOT;

            assertTrue(expected, "diff wrote a slot outside the new entry");
        }
    }

    /* ------------------------------------------------------------------ */
    /*        The property that makes this a Gas Killer win                */
    /* ------------------------------------------------------------------ */

    /// @notice Unlike the other examples, the diff here is *not* fixed-size — it tracks the
    ///         compressed blob. That is the point: the algorithm's output is the settlement cost, so
    ///         a better ratio is directly a cheaper `verifyAndUpdate`. A compressible blob settles a
    ///         fraction of the operations an incompressible one of the same size does.
    function test_diffSizeTracksCompressedSizeNotRawSize() public {
        CompressedArchive compressible = _deployArchive();
        CompressedArchive incompressible = _deployArchive();

        bytes memory structured = _abiLike(25);
        bytes memory noise = _random(1, 800);
        assertEq(structured.length, noise.length, "same raw size on both sides");

        compressible.archive(structured);
        incompressible.archive(noise);

        uint256 compressibleOps = _expectedOpCount(compressible.storedBlob(0));
        uint256 incompressibleOps = _expectedOpCount(incompressible.storedBlob(0));

        emit log_named_uint("800 raw bytes, structured -> payload ops", compressibleOps);
        emit log_named_uint("800 raw bytes, random     -> payload ops", incompressibleOps);

        assertLt(compressibleOps * 4, incompressibleOps, "compression should cut payload ops by >4x");
    }

    /* ------------------------------------------------------------------ */
    /*                                Fuzz                                 */
    /* ------------------------------------------------------------------ */

    /// @notice Any blob archived through the naive path must expand back to itself.
    function testFuzz_archiveRoundTrips(bytes memory raw) public {
        uint256 n = raw.length > 256 ? 256 : raw.length;
        vm.assume(n > 0);
        bytes memory input = new bytes(n);
        for (uint256 i = 0; i < n; i++) {
            input[i] = bytes1(uint8(raw[i]) % 4);
        }

        CompressedArchive a = _deployArchive();
        a.archive(input);

        assertEq(a.expand(0), input, "archived blob must expand to itself");
        assertTrue(a.verifyIntegrity(0), "integrity must hold");
    }

    /// @notice Any blob settled through `verifyAndUpdate` must land in exactly the state the naive
    ///         path produces, whatever its shape.
    function testFuzz_settledStateMatchesNaive(bytes memory raw) public {
        uint256 n = raw.length > 192 ? 192 : raw.length;
        vm.assume(n > 0);
        bytes memory input = new bytes(n);
        for (uint256 i = 0; i < n; i++) {
            input[i] = bytes1(uint8(raw[i]) % 3);
        }

        CompressedArchive a = _deployArchive();
        CompressedArchive b = _deployArchive();

        a.archive(input);
        _verify(b, _buildArchiveDiff(a, 0), CompressedArchive.archive.selector);

        assertEq(b.storedBlob(0), a.storedBlob(0), "settled blob differs from naive");
        assertEq(b.expand(0), input, "settled blob must expand to the original");
        assertEq(b.rawHash(0), a.rawHash(0), "rawHash differs");
        assertEq(b.entryCount(), a.entryCount(), "entryCount differs");
    }
}
