// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BenchmarkBase} from "../helpers/BenchmarkBase.sol";
import {Vm} from "forge-std/Vm.sol";
import {OnchainLife} from "../../src/examples/onchain-life/OnchainLife.sol";
import {MockBLSSignatureChecker} from "../mocks/MockBLSSignatureChecker.sol";
import {OffchainPayloadBuilder} from "../helpers/OffchainPayloadBuilder.sol";
import {StateUpdateType} from "gas-killer-sdk/StateChangeHandlerLib.sol";
import {IGasKillerSDK} from "gas-killer-sdk/interface/IGasKillerSDK.sol";

/// @notice Shared fixtures + diff-building helpers for the OnchainLife unit tests and benchmarks.
abstract contract LifeTestKit is BenchmarkBase {
    MockBLSSignatureChecker internal bls;
    address internal avs = makeAddr("avs");

    // Slot constants (verified against `forge inspect`): board words 0..15, generation 16.
    uint256 internal constant GENERATION_SLOT = 16;
    bytes32 internal constant STEP_SIG = keccak256("GenerationStepped(uint256,bytes32)");

    function setUp() public virtual {
        bls = _deployPassingBls();
    }

    /// @dev Build the storage diff an operator would submit after `a` was stepped: STORE all 16 board
    ///      words (a production operator could write only the words that actually changed) + the
    ///      generation word + a LOG2 mirroring `GenerationStepped`.
    function _buildLifeDiff(OnchainLife a) internal view returns (bytes memory) {
        uint256[16] memory finalBoard = a.getBoard();
        uint256 newGen = a.generation();
        bytes32 bHash = a.boardHash();

        OffchainPayloadBuilder.Op[] memory ops = new OffchainPayloadBuilder.Op[](18);
        for (uint256 w = 0; w < 16; w++) {
            ops[w] = OffchainPayloadBuilder.Op(
                StateUpdateType.STORE, OffchainPayloadBuilder.encodeStore(bytes32(w), bytes32(finalBoard[w]))
            );
        }
        ops[16] = OffchainPayloadBuilder.Op(
            StateUpdateType.STORE, OffchainPayloadBuilder.encodeStore(bytes32(GENERATION_SLOT), bytes32(newGen))
        );
        ops[17] = OffchainPayloadBuilder.Op(
            StateUpdateType.LOG2, OffchainPayloadBuilder.encodeLog2(abi.encode(bHash), STEP_SIG, bytes32(newGen))
        );
        return OffchainPayloadBuilder.build(ops);
    }

    function _set(uint256[16] memory b, uint256 x, uint256 y) internal pure {
        uint256 idx = y * 64 + x;
        b[idx >> 8] |= (uint256(1) << (idx & 255));
    }

    /// @dev Dense pseudo-random board (~50% live) so most words are non-zero and change each step.
    function _randomSeed(uint256 salt) internal pure returns (uint256[16] memory s) {
        for (uint256 i = 0; i < 16; i++) {
            s[i] = uint256(keccak256(abi.encode(salt, i)));
        }
    }
}

contract OnchainLifeTest is LifeTestKit {
    /* ------------------------------------------------------------------ */
    /*                          Naive correctness                          */
    /* ------------------------------------------------------------------ */

    /// @notice A blinker (3 in a row) must rotate to 3 in a column after one step — a human-checkable
    ///         oracle independent of the diff path.
    function test_blinker_knownOracle() public {
        uint256[16] memory seed;
        // Horizontal blinker at (10,10),(11,10),(12,10).
        _set(seed, 10, 10);
        _set(seed, 11, 10);
        _set(seed, 12, 10);
        OnchainLife life = new OnchainLife(avs, address(bls), seed);

        life.step(1);

        // After one step: vertical blinker at (11,9),(11,10),(11,11).
        assertTrue(life.getCell(11, 9), "top");
        assertTrue(life.getCell(11, 10), "center");
        assertTrue(life.getCell(11, 11), "bottom");
        assertFalse(life.getCell(10, 10), "left cleared");
        assertFalse(life.getCell(12, 10), "right cleared");
        assertEq(life.generation(), 1);
    }

    function test_constructor_seedsBoardAndGeneration() public {
        uint256[16] memory seed = _randomSeed(1);
        OnchainLife life = new OnchainLife(avs, address(bls), seed);
        assertEq(life.generation(), 0);
        uint256[16] memory got = life.getBoard();
        for (uint256 i = 0; i < 16; i++) {
            assertEq(got[i], seed[i], "seed word mismatch");
        }
    }

    /* ------------------------------------------------------------------ */
    /*          Equivalence: naive on-chain  ==  operator diff             */
    /* ------------------------------------------------------------------ */

    /// @notice The heart of the demo: run the naive `step` on instance A, have the "operator" build
    ///         the resulting storage diff, apply it to a fresh instance B through the *full*
    ///         `verifyAndUpdate` path (mock BLS), and assert A and B end up byte-identical — board
    ///         words (via raw `vm.load`), generation, and the emitted log.
    function test_equivalence_naiveVsDiff() public {
        uint256[16] memory seed = _randomSeed(42);
        uint32 gens = 4;

        OnchainLife a = new OnchainLife(avs, address(bls), seed);
        OnchainLife b = new OnchainLife(avs, address(bls), seed);

        // --- A: run the naive spec, capturing its log. ---
        vm.recordLogs();
        a.step(gens);
        Vm.Log[] memory aLogs = vm.getRecordedLogs();

        // --- Operator: build the diff from A's resulting state. ---
        bytes memory diff = _buildLifeDiff(a);

        // --- B: apply via verifyAndUpdate, capturing its log. ---
        uint256 countBefore = b.stateTransitionCount();
        vm.recordLogs();
        _verify(b, diff, OnchainLife.step.selector);
        Vm.Log[] memory bLogs = vm.getRecordedLogs();

        // --- Assert state equality, slot by slot, via raw storage reads. ---
        for (uint256 w = 0; w < 16; w++) {
            assertEq(
                vm.load(address(b), bytes32(w)),
                vm.load(address(a), bytes32(w)),
                "board word mismatch between naive and diff"
            );
        }
        assertEq(b.generation(), a.generation(), "generation mismatch");
        assertEq(b.stateTransitionCount(), countBefore + 1, "verifyAndUpdate should bump the counter once");

        // --- Assert the emitted log matches the naive event exactly. ---
        Vm.Log memory aEvt = _findStepLog(aLogs);
        Vm.Log memory bEvt = _findStepLog(bLogs);
        assertEq(bEvt.topics[0], aEvt.topics[0], "log sig mismatch");
        assertEq(bEvt.topics[1], aEvt.topics[1], "log generation topic mismatch");
        assertEq(keccak256(bEvt.data), keccak256(aEvt.data), "log data mismatch");
        // And the board hash in the event reflects the real final board.
        assertEq(abi.decode(aEvt.data, (bytes32)), a.boardHash(), "event boardHash should match board");
    }

    /// @notice verifyAndUpdate must reject a diff when the signing quorum is below the 66% threshold.
    function test_verifyAndUpdate_revertsBelowThreshold() public {
        uint256[16] memory seed = _randomSeed(7);
        OnchainLife a = new OnchainLife(avs, address(bls), seed);
        OnchainLife b = new OnchainLife(avs, address(bls), seed);
        a.step(2);
        bytes memory diff = _buildLifeDiff(a);

        bls.setSignedBps(6599); // 65.99% < 66%
        // Build the same plumbing _verify uses, then expect the revert on the call itself.
        (bytes32 msgHash, bytes memory quorumNumbers, uint32 refBlock, uint256 transitionIndex) = _prepLocal(b, diff);
        vm.expectRevert(IGasKillerSDK.InsufficientQuorumThreshold.selector);
        b.verifyAndUpdate(
            msgHash, quorumNumbers, refBlock, diff, transitionIndex, OnchainLife.step.selector, _emptySignature()
        );
    }

    /// @notice The exact 66% boundary must PASS: the SDK check is `signed*100 >= total*66`, so a quorum
    ///         signing exactly 66% is sufficient. (With the mock's default million-unit total, 6600 bps
    ///         is exactly 66% with no rounding loss.)
    function test_verifyAndUpdate_passesAtExactThreshold() public {
        uint256[16] memory seed = _randomSeed(8);
        OnchainLife a = new OnchainLife(avs, address(bls), seed);
        OnchainLife b = new OnchainLife(avs, address(bls), seed);
        a.step(1);
        bytes memory diff = _buildLifeDiff(a);

        bls.setSignedBps(6600); // exactly 66%
        _verify(b, diff, OnchainLife.step.selector); // must not revert
        assertEq(b.generation(), a.generation(), "exactly-66% quorum applies the diff");
    }

    /* ------------------------------------------------------------------ */
    /*        Trust-only, UNBOUNDED regime (read SECURITY.md!)             */
    /* ------------------------------------------------------------------ */

    /// @notice Demonstrates — and warns about — the unbounded regime. We apply a diff *labelled*
    ///         "generation 1,000,000". The board it claims is arbitrary: NOTHING on-chain re-runs a
    ///         million generations to check it (there is no fraud proof, no re-execution, no
    ///         bisection in Gas Killer). The apply cost is the same tiny ~16-word write as a single
    ///         step. This is the honest double-edge: you can offload truly unbounded compute, but its
    ///         correctness rests ENTIRELY on the 66% operator quorum being honest.
    function test_trustOnly_unboundedGenerationIsCheapButUnverified() public {
        uint256[16] memory seed = _randomSeed(99);
        OnchainLife life = new OnchainLife(avs, address(bls), seed);

        // An arbitrary "far future" board + generation. An honest operator would have computed this
        // off-chain; the chain cannot tell the difference.
        uint256[16] memory claimed = _randomSeed(123456);
        uint256 claimedGen = 1_000_000;

        OffchainPayloadBuilder.Op[] memory ops = new OffchainPayloadBuilder.Op[](18);
        for (uint256 w = 0; w < 16; w++) {
            ops[w] = OffchainPayloadBuilder.Op(
                StateUpdateType.STORE, OffchainPayloadBuilder.encodeStore(bytes32(w), bytes32(claimed[w]))
            );
        }
        ops[16] = OffchainPayloadBuilder.Op(
            StateUpdateType.STORE, OffchainPayloadBuilder.encodeStore(bytes32(GENERATION_SLOT), bytes32(claimedGen))
        );
        ops[17] = OffchainPayloadBuilder.Op(
            StateUpdateType.LOG2,
            OffchainPayloadBuilder.encodeLog2(abi.encode(keccak256(abi.encode(claimed))), STEP_SIG, bytes32(claimedGen))
        );
        bytes memory diff = OffchainPayloadBuilder.build(ops);

        _verify(life, diff, OnchainLife.step.selector);

        assertEq(life.generation(), claimedGen, "claimed generation applied");
        for (uint256 w = 0; w < 16; w++) {
            assertEq(vm.load(address(life), bytes32(w)), bytes32(claimed[w]), "claimed board applied");
        }
    }

    /* ------------------------------------------------------------------ */
    /*                              helpers                                 */
    /* ------------------------------------------------------------------ */

    /// @dev Local copy of _prepVerify's outputs minus the signature (so we can drive a revert test).
    function _prepLocal(OnchainLife c, bytes memory diff)
        internal
        returns (bytes32 msgHash, bytes memory quorumNumbers, uint32 refBlock, uint256 transitionIndex)
    {
        if (block.number == 0) vm.roll(1);
        transitionIndex = c.stateTransitionCount();
        msgHash = c.getMessageHash(transitionIndex, OnchainLife.step.selector, diff);
        quorumNumbers = _quorumNumbers();
        refBlock = uint32(block.number - 1);
    }

    function _findStepLog(Vm.Log[] memory logs) internal pure returns (Vm.Log memory) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length >= 1 && logs[i].topics[0] == STEP_SIG) {
                return logs[i];
            }
        }
        revert("GenerationStepped log not found");
    }
}
