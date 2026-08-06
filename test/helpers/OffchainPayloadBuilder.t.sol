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
contract SlotProbe {
    uint256 public a;
    mapping(address => uint256) public m;
    uint256[] public arr;
    uint256[16] public words;
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
