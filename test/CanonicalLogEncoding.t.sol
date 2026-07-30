// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {OffchainPayloadBuilder} from "./helpers/OffchainPayloadBuilder.sol";
import {OnchainLifeExposed} from "./exposed/OnchainLifeExposed.sol";
import {MockBLSSignatureChecker} from "./mocks/MockBLSSignatureChecker.sol";
import {StateChangeHandlerLib, StateUpdateType} from "gas-killer-sdk/StateChangeHandlerLib.sol";

/// @title CanonicalLogEncoding
/// @notice Pins the LOG payload contract introduced by the SDK's settlement hardening.
///
///         `StateChangeHandlerLib` no longer `abi.decode`s LOG args. It reads them straight out of the
///         payload buffer in assembly, guarded by `_validateLogArg`, which reverts `MalformedLogPayload`
///         unless the arg is a **canonical, in-bounds** ABI encoding: the `data` offset word must equal
///         the head size `0x20 * (numTopics + 1)`, and the declared `data` length must fit inside the
///         arg. A hand-rolled or non-canonical encoder that previously "worked" (because `abi.decode`
///         tolerates any valid offset) now reverts on-chain.
///
///         That makes the encoder a consensus-critical surface: every operator must produce byte-identical
///         canonical payloads, and a diff that fails validation is unapplicable. These tests assert both
///         directions — that `OffchainPayloadBuilder` (which mirrors what the Rust analyzer emits) is
///         canonical for LOG0..LOG4, and that a deliberately non-canonical payload is rejected.
///
/// @dev The Rust side of the same contract is covered end-to-end by `script/e2e/run-prestate-e2e.sh`,
///      which feeds real `gk-diff-extractor` output through `verifyAndUpdate` (LOG2 + LOG3).
contract CanonicalLogEncodingTest is Test {
    OnchainLifeExposed internal consumer;

    bytes32 internal constant T1 = bytes32(uint256(0x11));
    bytes32 internal constant T2 = bytes32(uint256(0x22));
    bytes32 internal constant T3 = bytes32(uint256(0x33));
    bytes32 internal constant T4 = bytes32(uint256(0x44));

    function setUp() public {
        uint256[16] memory seed;
        consumer = new OnchainLifeExposed(makeAddr("avs"), address(new MockBLSSignatureChecker()), seed);
    }

    /* ------------------------------------------------------------------ */
    /*        The canonical layout the SDK now demands, asserted           */
    /* ------------------------------------------------------------------ */

    /// @notice Every `encodeLogN` must put the `data` offset word at exactly `0x20 * (N + 1)`.
    /// @dev This is the precise invariant `_validateLogArg` checks. Asserting it directly (rather than
    ///      only observing that application succeeds) pins the encoder itself, so a future change that
    ///      reorders fields or hand-rolls the encoding fails here with a clear message.
    function test_encodeLogN_dataOffsetIsCanonical() public pure {
        bytes memory data = hex"c0ffee";
        _assertDataOffset(OffchainPayloadBuilder.encodeLog0(data), 0x20, "LOG0");
        _assertDataOffset(OffchainPayloadBuilder.encodeLog1(data, T1), 0x40, "LOG1");
        _assertDataOffset(OffchainPayloadBuilder.encodeLog2(data, T1, T2), 0x60, "LOG2");
        _assertDataOffset(OffchainPayloadBuilder.encodeLog3(data, T1, T2, T3), 0x80, "LOG3");
        _assertDataOffset(OffchainPayloadBuilder.encodeLog4(data, T1, T2, T3, T4), 0xa0, "LOG4");
    }

    /// @notice Empty `data` is the edge case most likely to trip a length check — it must still validate.
    function test_encodeLogN_emptyDataIsCanonical() public pure {
        bytes memory empty = "";
        _assertDataOffset(OffchainPayloadBuilder.encodeLog0(empty), 0x20, "LOG0/empty");
        _assertDataOffset(OffchainPayloadBuilder.encodeLog2(empty, T1, T2), 0x60, "LOG2/empty");
        _assertDataOffset(OffchainPayloadBuilder.encodeLog4(empty, T1, T2, T3, T4), 0xa0, "LOG4/empty");
    }

    /* ------------------------------------------------------------------ */
    /*                 Positive: canonical payloads apply                  */
    /* ------------------------------------------------------------------ */

    /// @notice All five LOG kinds, built by our encoder, survive `_validateLogArg` and emit correctly —
    ///         right topics, right data, right order.
    function test_allLogKinds_applyAndEmitExactly() public {
        bytes memory data = hex"deadbeef";
        OffchainPayloadBuilder.Op[] memory ops = new OffchainPayloadBuilder.Op[](5);
        ops[0] = OffchainPayloadBuilder.Op(StateUpdateType.LOG0, OffchainPayloadBuilder.encodeLog0(data));
        ops[1] = OffchainPayloadBuilder.Op(StateUpdateType.LOG1, OffchainPayloadBuilder.encodeLog1(data, T1));
        ops[2] = OffchainPayloadBuilder.Op(StateUpdateType.LOG2, OffchainPayloadBuilder.encodeLog2(data, T1, T2));
        ops[3] = OffchainPayloadBuilder.Op(StateUpdateType.LOG3, OffchainPayloadBuilder.encodeLog3(data, T1, T2, T3));
        ops[4] =
            OffchainPayloadBuilder.Op(StateUpdateType.LOG4, OffchainPayloadBuilder.encodeLog4(data, T1, T2, T3, T4));

        vm.recordLogs();
        consumer.applyDiff(OffchainPayloadBuilder.build(ops));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 5, "expected one log per LOG op");
        for (uint256 i = 0; i < 5; i++) {
            assertEq(logs[i].topics.length, i, "topic count must match the LOG kind");
            assertEq(logs[i].data, data, "data must round-trip unchanged");
            assertEq(logs[i].emitter, address(consumer), "log must be emitted by the consumer");
        }
        assertEq(logs[4].topics[3], T4, "last topic must survive in position");
    }

    /// @notice Empty-data logs apply too (the `dataLen == 0` boundary of the length check).
    function test_emptyDataLog_applies() public {
        OffchainPayloadBuilder.Op[] memory ops = new OffchainPayloadBuilder.Op[](1);
        ops[0] = OffchainPayloadBuilder.Op(StateUpdateType.LOG2, OffchainPayloadBuilder.encodeLog2("", T1, T2));

        vm.recordLogs();
        consumer.applyDiff(OffchainPayloadBuilder.build(ops));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 1);
        assertEq(logs[0].data.length, 0, "empty data must stay empty");
        assertEq(logs[0].topics[1], T2);
    }

    /* ------------------------------------------------------------------ */
    /*        Negative: non-canonical payloads are rejected on-chain       */
    /* ------------------------------------------------------------------ */

    /// @notice A payload whose `data` offset is shifted past the head — valid to `abi.decode`, and
    ///         therefore accepted by the OLD SDK — must now revert `MalformedLogPayload`.
    /// @dev Built by hand: head = [offset=0x60, topic1], then padding, then the data. `abi.decode` would
    ///      happily follow the 0x60 pointer; `_validateLogArg` requires exactly 0x40 for LOG1.
    function test_nonCanonicalOffset_reverts() public {
        bytes memory arg = abi.encodePacked(
            uint256(0x60), // data offset — NOT the canonical 0x40 for LOG1
            T1, // topic1
            uint256(0), // filler occupying the canonical slot
            uint256(3), // data length
            bytes32(hex"c0ffee") // data (right-padded)
        );
        OffchainPayloadBuilder.Op[] memory ops = new OffchainPayloadBuilder.Op[](1);
        ops[0] = OffchainPayloadBuilder.Op(StateUpdateType.LOG1, arg);

        vm.expectRevert(StateChangeHandlerLib.MalformedLogPayload.selector);
        consumer.applyDiff(OffchainPayloadBuilder.build(ops));
    }

    /// @notice A payload declaring more `data` than it carries must revert rather than read out of bounds.
    function test_dataLengthPastEnd_reverts() public {
        bytes memory arg = abi.encodePacked(
            uint256(0x40), // canonical offset for LOG1
            T1, // topic1
            uint256(0x100) // declared length far exceeding the remaining bytes
        );
        OffchainPayloadBuilder.Op[] memory ops = new OffchainPayloadBuilder.Op[](1);
        ops[0] = OffchainPayloadBuilder.Op(StateUpdateType.LOG1, arg);

        vm.expectRevert(StateChangeHandlerLib.MalformedLogPayload.selector);
        consumer.applyDiff(OffchainPayloadBuilder.build(ops));
    }

    /// @notice A head too short to even hold the topics + length word must revert.
    function test_truncatedHead_reverts() public {
        OffchainPayloadBuilder.Op[] memory ops = new OffchainPayloadBuilder.Op[](1);
        ops[0] = OffchainPayloadBuilder.Op(StateUpdateType.LOG2, abi.encodePacked(uint256(0x60), T1));

        vm.expectRevert(StateChangeHandlerLib.MalformedLogPayload.selector);
        consumer.applyDiff(OffchainPayloadBuilder.build(ops));
    }

    /* ------------------------------------------------------------------ */

    /// @dev Read the first word of an encoded LOG arg — the `data` offset the SDK validates.
    function _assertDataOffset(bytes memory arg, uint256 expected, string memory label) private pure {
        uint256 off;
        assembly {
            off := mload(add(arg, 0x20))
        }
        assertEq(off, expected, string.concat(label, ": data offset must equal 0x20*(numTopics+1)"));
    }
}
