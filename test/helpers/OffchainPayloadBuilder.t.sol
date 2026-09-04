// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {OffchainPayloadBuilder} from "./OffchainPayloadBuilder.sol";
import {StateUpdateType} from "gas-killer-sdk/StateChangeHandlerLib.sol";

/// @dev A probe contract with a known, simple storage layout used to prove the slot-math helpers
///      target the exact same slots Solidity uses. Layout (verifiable via
///      `forge inspect test/helpers/OffchainPayloadBuilder.t.sol:SlotProbe storage-layout`):
///        a      -> slot 0
///        m      -> slot 1
///        arr    -> slot 2 (length at slot 2, data at keccak256(2))
///        words  -> slots 3..18 (fixed array, contiguous)
///        blob   -> slot 19 (header at 19, long-form data at keccak256(19))
///        blobs  -> slot 20 (per-key header at keccak256(key, 20))
contract SlotProbe {
    uint256 public a;
    mapping(address => uint256) public m;
    uint256[] public arr;
    uint256[16] public words;
    bytes public blob;
    mapping(uint256 => bytes) public blobs;
}

/// @title OffchainPayloadBuilderTest
/// @notice Verifies the slot derivations and payload encoders. If any of these fail, every
///         example's "operator builds the diff" path would target the wrong storage and the
///         equivalence tests would (rightly) blow up — so this is the suite's foundation.
contract OffchainPayloadBuilderTest is Test {
    using OffchainPayloadBuilder for *;

    SlotProbe internal probe;

    function setUp() public {
        probe = new SlotProbe();
    }

    function test_simpleSlot_matchesSolidity() public {
        vm.store(address(probe), OffchainPayloadBuilder.simpleSlot(0), bytes32(uint256(42)));
        assertEq(probe.a(), 42, "simpleSlot(0) should target `a`");
    }

    function test_mappingSlot_address_matchesSolidity() public {
        address alice = makeAddr("alice");
        vm.store(address(probe), OffchainPayloadBuilder.mappingSlot(alice, 1), bytes32(uint256(77)));
        assertEq(probe.m(alice), 77, "mappingSlot(addr,1) should target m[addr]");
    }

    function test_mappingSlot_matchesCastIndex() public pure {
        // `cast index address <addr> 1` for address(1) at mapping slot 1.
        bytes32 expected = keccak256(abi.encode(address(1), uint256(1)));
        assertEq(OffchainPayloadBuilder.mappingSlot(address(1), 1), expected);
    }

    function test_dynamicArraySlot_matchesSolidity() public {
        // Set length = 3, then write element 1 directly and read it back via the getter.
        vm.store(address(probe), OffchainPayloadBuilder.dynamicArrayLengthSlot(2), bytes32(uint256(3)));
        vm.store(address(probe), OffchainPayloadBuilder.dynamicArraySlot(2, 1), bytes32(uint256(99)));
        assertEq(probe.arr(1), 99, "dynamicArraySlot(2,1) should target arr[1]");
    }

    function test_fixedArrayWord_isContiguous() public {
        // Fixed `uint256[16] words` at slot 3 -> element 5 lives at slot 8. This is the packed-word
        // pattern OnchainLife relies on (with its board declared first, so word w lives at slot w).
        vm.store(address(probe), OffchainPayloadBuilder.simpleSlot(3 + 5), bytes32(uint256(123)));
        assertEq(probe.words(5), 123, "fixed-array element 5 should be at base+5");
    }

    /* ------------------------------------------------------------------ */
    /*                       `bytes` in storage                            */
    /* ------------------------------------------------------------------ */

    /// @notice A `bytes` shorter than 32 packs into its header slot; the helper must reproduce the
    ///         exact word Solidity writes, data left-aligned with `length * 2` in the low byte.
    function test_shortBytesHeader_matchesSolidity() public {
        bytes memory value = hex"0badc0de";
        vm.store(address(probe), bytes32(uint256(19)), OffchainPayloadBuilder.shortBytesHeader(value));
        assertEq(probe.blob(), value, "shortBytesHeader should reproduce the packed short form");
    }

    /// @notice An empty `bytes` is an all-zero header.
    function test_shortBytesHeader_empty() public pure {
        assertEq(OffchainPayloadBuilder.shortBytesHeader(""), bytes32(0));
    }

    /// @notice 31 bytes is the largest short form; 32 crosses into the long form.
    function test_shortBytesHeader_atBoundary() public {
        bytes memory value = new bytes(31);
        for (uint256 i = 0; i < 31; i++) {
            value[i] = bytes1(uint8(i + 1));
        }
        vm.store(address(probe), bytes32(uint256(19)), OffchainPayloadBuilder.shortBytesHeader(value));
        assertEq(probe.blob(), value, "31 bytes should still be the short form");
        assertTrue(OffchainPayloadBuilder.isShortBytes(31), "31 is short");
        assertFalse(OffchainPayloadBuilder.isShortBytes(32), "32 is long");
    }

    /// @notice A `bytes` of 32 or more uses `length * 2 + 1` in the header and keccak-derived data
    ///         slots; writing both through the helpers must be readable as a normal Solidity value.
    function test_longBytes_headerAndDataSlots_matchSolidity() public {
        bytes memory value = new bytes(70);
        for (uint256 i = 0; i < value.length; i++) {
            value[i] = bytes1(uint8(i + 1));
        }

        bytes32 headerSlot = bytes32(uint256(19));
        vm.store(address(probe), headerSlot, OffchainPayloadBuilder.longBytesHeader(value.length));
        for (uint256 i = 0; i < 3; i++) {
            vm.store(
                address(probe),
                OffchainPayloadBuilder.bytesDataSlot(headerSlot, i),
                OffchainPayloadBuilder.bytesDataWord(value, i)
            );
        }

        assertEq(probe.blob(), value, "long-form helpers should reproduce Solidity's layout");
    }

    /// @notice The same helpers, aimed at a `bytes` inside a mapping — the shape `CompressedArchive`
    ///         settles. The header slot is the mapping slot, and data hangs off that.
    function test_longBytes_insideMapping_matchesSolidity() public {
        bytes memory value = new bytes(100);
        for (uint256 i = 0; i < value.length; i++) {
            value[i] = bytes1(uint8(255 - i));
        }

        bytes32 headerSlot = OffchainPayloadBuilder.mappingSlot(uint256(7), 20);
        vm.store(address(probe), headerSlot, OffchainPayloadBuilder.longBytesHeader(value.length));
        for (uint256 i = 0; i < 4; i++) {
            vm.store(
                address(probe),
                OffchainPayloadBuilder.bytesDataSlot(headerSlot, i),
                OffchainPayloadBuilder.bytesDataWord(value, i)
            );
        }

        assertEq(probe.blobs(7), value, "mapping(uint256 => bytes) slot math should match Solidity");
    }

    /// @notice The final word of a long `bytes` is zero-filled past the end of the data, matching
    ///         what Solidity leaves in that slot.
    function test_bytesDataWord_zeroFillsTail() public pure {
        bytes memory value = new bytes(33);
        value[32] = 0xff;
        bytes32 last = OffchainPayloadBuilder.bytesDataWord(value, 1);
        assertEq(last, bytes32(uint256(0xff) << 248), "tail past the data must be zero");
    }

    /// @notice `bytesStoreOps` emits header-then-data in slot order, and applying it verbatim
    ///         reproduces the value — this is the helper the archive's diff builder relies on.
    function test_bytesStoreOps_roundTripsThroughStorage() public {
        bytes memory value = new bytes(65);
        for (uint256 i = 0; i < value.length; i++) {
            value[i] = bytes1(uint8(i * 3 + 1));
        }

        bytes32 headerSlot = OffchainPayloadBuilder.mappingSlot(uint256(1), 20);
        OffchainPayloadBuilder.Op[] memory ops = OffchainPayloadBuilder.bytesStoreOps(headerSlot, value);

        assertEq(ops.length, OffchainPayloadBuilder.bytesSlotCount(value.length), "op count vs slot count");
        assertEq(ops.length, 4, "65 bytes is a header plus three data words");

        for (uint256 i = 0; i < ops.length; i++) {
            (bytes32 slot, bytes32 word) = abi.decode(ops[i].arg, (bytes32, bytes32));
            vm.store(address(probe), slot, word);
        }

        assertEq(probe.blobs(1), value, "applying bytesStoreOps should reproduce the value");
    }

    /// @notice A short value produces exactly one op, and it round-trips too.
    function test_bytesStoreOps_shortForm() public {
        bytes memory value = hex"deadbeefcafe";
        bytes32 headerSlot = OffchainPayloadBuilder.mappingSlot(uint256(2), 20);
        OffchainPayloadBuilder.Op[] memory ops = OffchainPayloadBuilder.bytesStoreOps(headerSlot, value);

        assertEq(ops.length, 1, "a short bytes is a single header store");
        (bytes32 slot, bytes32 word) = abi.decode(ops[0].arg, (bytes32, bytes32));
        vm.store(address(probe), slot, word);

        assertEq(probe.blobs(2), value, "short-form ops should reproduce the value");
    }

    function test_setBit_clearBit() public pure {
        bytes32 zero = bytes32(0);
        assertEq(OffchainPayloadBuilder.setBit(zero, 5), bytes32(uint256(1) << 5));
        bytes32 ones = bytes32(type(uint256).max);
        assertEq(OffchainPayloadBuilder.clearBit(ones, 5), bytes32(type(uint256).max & ~(uint256(1) << 5)));
        // round-trip
        assertEq(OffchainPayloadBuilder.clearBit(OffchainPayloadBuilder.setBit(zero, 200), 200), zero);
    }

    function test_packTwo() public pure {
        bytes32 packed = OffchainPayloadBuilder.packTwo(uint128(0xABCD), uint128(0x1234));
        assertEq(uint256(packed) & type(uint128).max, 0xABCD, "low 128 bits");
        assertEq(uint256(packed) >> 128, 0x1234, "high 128 bits");
    }

    function test_addressTopic_leftPads() public pure {
        address a = address(0xBEEF);
        assertEq(OffchainPayloadBuilder.addressTopic(a), bytes32(uint256(uint160(a))));
    }

    function test_store_producesDecodablePayload() public pure {
        bytes32 slot = bytes32(uint256(7));
        bytes32 value = bytes32(uint256(123456));
        bytes memory payload = OffchainPayloadBuilder.store(slot, value);

        (StateUpdateType[] memory types, bytes[] memory args) = abi.decode(payload, (StateUpdateType[], bytes[]));
        assertEq(types.length, 1);
        assertEq(args.length, 1);
        assertTrue(types[0] == StateUpdateType.STORE);
        (bytes32 decodedSlot, bytes32 decodedValue) = abi.decode(args[0], (bytes32, bytes32));
        assertEq(decodedSlot, slot);
        assertEq(decodedValue, value);
    }

    function test_build_preservesOrderAndKinds() public pure {
        OffchainPayloadBuilder.Op[] memory ops = new OffchainPayloadBuilder.Op[](2);
        ops[0] = OffchainPayloadBuilder.Op(
            StateUpdateType.STORE, OffchainPayloadBuilder.encodeStore(bytes32(uint256(1)), bytes32(uint256(2)))
        );
        ops[1] = OffchainPayloadBuilder.Op(StateUpdateType.LOG0, OffchainPayloadBuilder.encodeLog0(hex"dead"));

        bytes memory payload = OffchainPayloadBuilder.build(ops);
        (StateUpdateType[] memory types, bytes[] memory args) = abi.decode(payload, (StateUpdateType[], bytes[]));
        assertEq(types.length, 2);
        assertTrue(types[0] == StateUpdateType.STORE);
        assertTrue(types[1] == StateUpdateType.LOG0);
        assertEq(args.length, 2);
    }
}
