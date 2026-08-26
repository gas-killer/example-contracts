// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title PrestateOracle — ground-truth diff vector for the heavy-compute case.
/// @notice Forks Sepolia, runs the naive `step(1)` against the REAL deployed OnchainLife, and asserts
///         the resulting storage and event equal the constants pinned below.
///
///         `step(1)` is ~16.8M gas, past what a struct-log tracer can produce, so no tracer output
///         exists to compare a diff extractor against for this call. These constants stand in for
///         one, read off EVM execution: a conformance vector for any extractor implementation.
///
/// @dev Run:  RPC_URL=<sepolia-archive> forge test --match-contract PrestateOracle -vv
///      Skips automatically when RPC_URL is unset (so the default `forge test` run stays offline).
contract PrestateOracleTest is Test {
    // Deployed OnchainLife (Sepolia) — generation 0, glider seed (step has never landed on-chain).
    address constant LIFE = 0x01A8C90963EbE399872C63afe0c885A43c93fA9C;
    address constant CALLER = 0xff467a85932cF543Df50255f00A8A829c12a3A11;

    // The true storage effect of step(1): board word 0 + generation.
    bytes32 constant EXPECTED_WORD0 = 0x0000000000000002000000000000000600000000000000050000000000000000;
    uint256 constant EXPECTED_GENERATION = 1;
    // …and the LOG2 it emitted: topic1 = event sig, topic2 = generation, data = abi.encode(boardHash).
    bytes32 constant EXPECTED_LOG_SIG = 0x617d56c3ebab12cde63eb934a1c00e83583ebed795c56799879729352fbbe1dc;
    bytes32 constant EXPECTED_BOARD_HASH = 0x9604934a48b16193d0f57fd2f0f9b2e02ac90511f92efa3405b7efbb9863265f;

    // Storage layout: board is uint256[16] declared first → slots 0..15; generation → slot 16.
    uint256 constant SLOT_BOARD_WORD0 = 0;
    uint256 constant SLOT_GENERATION = 16;

    function test_OnchainLife_step1_prestateDiffIsTrueDiff() public {
        string memory rpc = vm.envOr("RPC_URL", string(""));
        vm.skip(bytes(rpc).length == 0);
        vm.createSelectFork(rpc);

        // Sanity: the forked contract is the un-stepped, glider-seeded board the extractor saw.
        assertEq(uint256(vm.load(LIFE, bytes32(SLOT_GENERATION))), 0, "fork should be at generation 0");

        // Run the naive on-chain computation — the EVM is the oracle. Record its events too.
        vm.recordLogs();
        vm.prank(CALLER);
        (bool ok,) = LIFE.call(abi.encodeWithSignature("step(uint32)", uint32(1)));
        assertTrue(ok, "naive step(1) reverted on fork");

        // The post-step storage must equal what --prestate extracted, slot-for-slot.
        assertEq(vm.load(LIFE, bytes32(SLOT_BOARD_WORD0)), EXPECTED_WORD0, "board word 0 mismatch vs --prestate");
        assertEq(
            uint256(vm.load(LIFE, bytes32(SLOT_GENERATION))), EXPECTED_GENERATION, "generation mismatch vs --prestate"
        );

        // The glider lives entirely in word 0; every other board word must be unchanged (still zero),
        // matching --prestate emitting exactly ONE board STORE.
        uint256[16] memory boardAfter;
        boardAfter[0] = uint256(EXPECTED_WORD0);
        for (uint256 w = 1; w < 16; w++) {
            assertEq(vm.load(LIFE, bytes32(w)), bytes32(0), "unexpected change outside word 0");
        }

        // The emitted LOG2 must match what --prestate extracted AND be internally consistent with the
        // resulting board — closing the gap where the oracle checked storage but not the event.
        Vm.Log memory stepped = _findLog(vm.getRecordedLogs(), EXPECTED_LOG_SIG);
        assertEq(stepped.topics.length, 2, "GenerationStepped must be a LOG2 (sig + indexed generation)");
        assertEq(stepped.topics[0], EXPECTED_LOG_SIG, "log sig mismatch vs --prestate");
        assertEq(uint256(stepped.topics[1]), EXPECTED_GENERATION, "log generation topic mismatch vs --prestate");
        assertEq(stepped.data, abi.encode(EXPECTED_BOARD_HASH), "log data (boardHash) mismatch vs --prestate");
        // …and the hash the extractor reported is exactly the hash of the board the EVM produced.
        assertEq(keccak256(abi.encode(boardAfter)), EXPECTED_BOARD_HASH, "extracted boardHash != EVM board hash");
        // sanity: the constant sig equals the actual event signature.
        assertEq(EXPECTED_LOG_SIG, keccak256("GenerationStepped(uint256,bytes32)"), "sig constant drifted");
    }

    function _findLog(Vm.Log[] memory logs, bytes32 sig) internal returns (Vm.Log memory) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == LIFE && logs[i].topics.length > 0 && logs[i].topics[0] == sig) {
                return logs[i];
            }
        }
        fail();
        return logs[0]; // unreachable
    }
}
