// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {StateUpdateType} from "gas-killer-sdk/StateChangeHandlerLib.sol";

/// @title OffchainPayloadBuilder
/// @notice Mirrors what a Gas Killer off-chain operator produces: an ABI-encoded
///         `(StateUpdateType[], bytes[])` storage-diff payload that `verifyAndUpdate`
///         applies via raw `sstore` / `call` / `log`. It has two layers:
///           1. **Payload assembly** — turn ops into the exact bytes `verifyAndUpdate` expects.
///           2. **Slot math** — compute the storage slot a value lives at, so a STORE op targets
///              the right location.
/// @dev The arg encoders below mirror `StateChangeHandlerLib._runStateUpdates`' `abi.decode`
///      order **byte-for-byte**. If the SDK changes a decode order, change it here too.
///
///      FINDING THE RIGHT SLOT: never hardcode a slot by eyeballing the source. Read the exact
///      layout with `forge inspect <path>:<Contract> storage-layout` (immutables/constants take
///      no slot; GasKillerSDK's own state lives in ERC-7201 namespaces, so a consumer's first
///      declared mutable var is at slot 0). Then VERIFY in a test with `vm.load(addr, slot)`
///      before trusting a computed slot. The self-test in OffchainPayloadBuilder.t.sol does
///      exactly this round-trip for every helper here.
library OffchainPayloadBuilder {
    /* --------------------------------------------------------------------- */
    /*                          Payload assembly                              */
    /* --------------------------------------------------------------------- */

    /// @notice A single typed state-update operation.
    /// @param kind The StateUpdateType discriminator.
    /// @param arg The ABI-encoded args for `kind` (use the `encode*` helpers below).
    struct Op {
        StateUpdateType kind;
        bytes arg;
    }

    /// @notice Encode parallel `types`/`args` arrays into the `storageUpdates` payload.
    /// @dev This is the canonical shape `_stateChangeHandler` decodes: `(StateUpdateType[], bytes[])`.
    function encode(StateUpdateType[] memory types, bytes[] memory args) internal pure returns (bytes memory) {
        return abi.encode(types, args);
    }

    /// @notice Assemble many ops into one `storageUpdates` payload, preserving order.
    function build(Op[] memory ops) internal pure returns (bytes memory) {
        StateUpdateType[] memory types = new StateUpdateType[](ops.length);
        bytes[] memory args = new bytes[](ops.length);
        for (uint256 i = 0; i < ops.length; i++) {
            types[i] = ops[i].kind;
            args[i] = ops[i].arg;
        }
        return abi.encode(types, args);
    }

    /// @notice Convenience: a payload with exactly one STORE op.
    function store(bytes32 slot, bytes32 value) internal pure returns (bytes memory) {
        StateUpdateType[] memory types = new StateUpdateType[](1);
        bytes[] memory args = new bytes[](1);
        types[0] = StateUpdateType.STORE;
        args[0] = encodeStore(slot, value);
        return abi.encode(types, args);
    }

    /* --------------------------------------------------------------------- */
    /*       Per-op arg encoders (mirror StateChangeHandlerLib decode)       */
    /* --------------------------------------------------------------------- */

    /// @dev STORE: `sstore(slot, value)`.
    function encodeStore(bytes32 slot, bytes32 value) internal pure returns (bytes memory) {
        return abi.encode(slot, value);
    }

    /// @dev CALL: `call(target, value, callargs)`.
    function encodeCall(address target, uint256 value, bytes memory callargs) internal pure returns (bytes memory) {
        return abi.encode(target, value, callargs);
    }

    /// @dev LOG0: `log0(data)`.
    function encodeLog0(bytes memory data) internal pure returns (bytes memory) {
        return abi.encode(data);
    }

    /// @dev LOG1: `log1(data, topic1)`.
    function encodeLog1(bytes memory data, bytes32 topic1) internal pure returns (bytes memory) {
        return abi.encode(data, topic1);
    }

    /// @dev LOG2: `log2(data, topic1, topic2)`.
    function encodeLog2(bytes memory data, bytes32 topic1, bytes32 topic2) internal pure returns (bytes memory) {
        return abi.encode(data, topic1, topic2);
    }

    /// @dev LOG3: `log3(data, topic1, topic2, topic3)`. (e.g. an ERC-20 `Transfer`.)
    function encodeLog3(bytes memory data, bytes32 topic1, bytes32 topic2, bytes32 topic3)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(data, topic1, topic2, topic3);
    }

    /// @dev LOG4: `log4(data, topic1, topic2, topic3, topic4)`.
    function encodeLog4(bytes memory data, bytes32 topic1, bytes32 topic2, bytes32 topic3, bytes32 topic4)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(data, topic1, topic2, topic3, topic4);
    }

    /// @dev CREATE: `create(value, initcode)`.
    function encodeCreate(uint256 value, bytes memory initcode) internal pure returns (bytes memory) {
        return abi.encode(value, initcode);
    }

    /// @dev CREATE2: `create2(value, initcode, salt)`.
    function encodeCreate2(bytes32 salt, uint256 value, bytes memory initcode) internal pure returns (bytes memory) {
        return abi.encode(salt, value, initcode);
    }

    /* --------------------------------------------------------------------- */
    /*                              Slot math                                 */
    /* --------------------------------------------------------------------- */

    /// @notice Slot of a non-mapping, non-dynamic state var declared at index `n`.
    function simpleSlot(uint256 n) internal pure returns (bytes32) {
        return bytes32(n);
    }

    /// @notice Slot of `mapping(address => V)[key]` for a mapping declared at `mappingDeclSlot`.
    /// @dev `keccak256(abi.encode(key, mappingDeclSlot))`; `abi.encode` left-pads the address to 32 bytes.
    function mappingSlot(address key, uint256 mappingDeclSlot) internal pure returns (bytes32) {
        return keccak256(abi.encode(key, mappingDeclSlot));
    }

    /// @notice Slot of `mapping(uint256 => V)[key]`.
    function mappingSlot(uint256 key, uint256 mappingDeclSlot) internal pure returns (bytes32) {
        return keccak256(abi.encode(key, mappingDeclSlot));
    }

    /// @notice Slot of `mapping(bytes32 => V)[key]`.
    function mappingSlot(bytes32 key, uint256 mappingDeclSlot) internal pure returns (bytes32) {
        return keccak256(abi.encode(key, mappingDeclSlot));
    }

    /// @notice Slot of a nested mapping value `m[k1][k2]` for `m` declared at `baseSlot`.
    /// @dev `keccak256(k2, keccak256(k1, baseSlot))`.
    function nestedMappingSlot(bytes32 k1, bytes32 k2, uint256 baseSlot) internal pure returns (bytes32) {
        return keccak256(abi.encode(k2, keccak256(abi.encode(k1, baseSlot))));
    }

    /// @notice Slot for an element offset within a dynamic array declared at `arrayDeclSlot`.
    /// @dev Element data starts at `keccak256(abi.encode(arrayDeclSlot))`; `elementSlotOffset`
    ///      is the slot index into the data region. For `T[]` where `T` occupies `k` slots,
    ///      element `i`'s `j`-th slot is `elementSlotOffset = i*k + j`.
    function dynamicArraySlot(uint256 arrayDeclSlot, uint256 elementSlotOffset) internal pure returns (bytes32) {
        return bytes32(uint256(keccak256(abi.encode(arrayDeclSlot))) + elementSlotOffset);
    }

    /// @notice The slot holding a dynamic array's length — which is just its declaration slot.
    function dynamicArrayLengthSlot(uint256 arrayDeclSlot) internal pure returns (bytes32) {
        return bytes32(arrayDeclSlot);
    }

    /* --------------------------------------------------------------------- */
    /*                          Word / bit packing                           */
    /* --------------------------------------------------------------------- */

    /// @notice Return `word` with bit `bitIndex` set to 1.
    function setBit(bytes32 word, uint256 bitIndex) internal pure returns (bytes32) {
        return bytes32(uint256(word) | (uint256(1) << bitIndex));
    }

    /// @notice Return `word` with bit `bitIndex` cleared to 0.
    function clearBit(bytes32 word, uint256 bitIndex) internal pure returns (bytes32) {
        return bytes32(uint256(word) & ~(uint256(1) << bitIndex));
    }

    /// @notice Pack two 128-bit values into one slot (`lo` in the low 128 bits, `hi` in the high 128).
    function packTwo(uint128 lo, uint128 hi) internal pure returns (bytes32) {
        return bytes32((uint256(hi) << 128) | uint256(lo));
    }

    /// @notice Left-pad an address into a 32-byte log topic (as Solidity does for indexed address params).
    function addressTopic(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }
}
