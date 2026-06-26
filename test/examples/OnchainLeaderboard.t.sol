// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BenchmarkBase} from "../helpers/BenchmarkBase.sol";
import {Vm} from "forge-std/Vm.sol";
import {OnchainLeaderboard} from "../../src/examples/onchain-leaderboard/OnchainLeaderboard.sol";
import {OnchainLeaderboardExposed} from "../exposed/OnchainLeaderboardExposed.sol";
import {MockBLSSignatureChecker} from "../mocks/MockBLSSignatureChecker.sol";
import {OffchainPayloadBuilder} from "../helpers/OffchainPayloadBuilder.sol";
import {StateUpdateType} from "gas-killer-sdk/StateChangeHandlerLib.sol";
import {IGasKillerSDK} from "gas-killer-sdk/interface/IGasKillerSDK.sol";

/// @notice Shared fixtures + diff/seed helpers for the OnchainLeaderboard unit tests and benchmarks.
abstract contract LeaderboardTestKit is BenchmarkBase {
    MockBLSSignatureChecker internal bls;
    address internal avs = makeAddr("avs");

    // Slot constants (board dynamic array @0, rankOf mapping @1). Verified by the equivalence test.
    uint256 internal constant BOARD_SLOT = 0;
    uint256 internal constant RANK_SLOT = 1;
    bytes32 internal constant SCORE_SIG = keccak256("ScoreSubmitted(address,uint256,uint256)");

    function setUp() public virtual {
        bls = _deployPassingBls();
    }

    function _player(uint256 i) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode("player", i)))));
    }

    /// @dev Build the diff an operator submits after `a.submitScore(player, score)`: rewrite the full
    ///      (reordered) board — length + every entry's player/score slots + every player's rank — plus
    ///      a LOG2 mirroring `ScoreSubmitted`. Writing the whole board is O(N) but unambiguously
    ///      correct; an operator could instead write only the changed suffix.
    function _buildLeaderboardDiff(OnchainLeaderboard a, address player, uint256 score)
        internal
        view
        returns (bytes memory)
    {
        uint256 n = a.boardLength();
        OffchainPayloadBuilder.Op[] memory ops = new OffchainPayloadBuilder.Op[](3 * n + 2);
        uint256 k;

        ops[k++] = OffchainPayloadBuilder.Op(
            StateUpdateType.STORE,
            OffchainPayloadBuilder.encodeStore(OffchainPayloadBuilder.dynamicArrayLengthSlot(BOARD_SLOT), bytes32(n))
        );
        for (uint256 i = 0; i < n; i++) {
            OnchainLeaderboard.Entry memory e = a.getEntry(i);
            ops[k++] = OffchainPayloadBuilder.Op(
                StateUpdateType.STORE,
                OffchainPayloadBuilder.encodeStore(
                    OffchainPayloadBuilder.dynamicArraySlot(BOARD_SLOT, 2 * i),
                    OffchainPayloadBuilder.addressTopic(e.player)
                )
            );
            ops[k++] = OffchainPayloadBuilder.Op(
                StateUpdateType.STORE,
                OffchainPayloadBuilder.encodeStore(
                    OffchainPayloadBuilder.dynamicArraySlot(BOARD_SLOT, 2 * i + 1), bytes32(e.score)
                )
            );
            ops[k++] = OffchainPayloadBuilder.Op(
                StateUpdateType.STORE,
                OffchainPayloadBuilder.encodeStore(
                    OffchainPayloadBuilder.mappingSlot(e.player, RANK_SLOT), bytes32(i + 1)
                )
            );
        }
        ops[k++] = OffchainPayloadBuilder.Op(
            StateUpdateType.LOG2,
            OffchainPayloadBuilder.encodeLog2(
                abi.encode(score, a.rankOf(player)), SCORE_SIG, OffchainPayloadBuilder.addressTopic(player)
            )
        );
        return OffchainPayloadBuilder.build(ops);
    }

    /// @dev Build a diff that seeds a sorted, n-entry board (scores n..1) directly — used by the
    ///      benchmark to set up a large board cheaply (one O(N) applyDiff vs N naive submits).
    function _buildSeedDiff(uint256 n) internal pure returns (bytes memory) {
        OffchainPayloadBuilder.Op[] memory ops = new OffchainPayloadBuilder.Op[](3 * n + 1);
        uint256 k;
        ops[k++] = OffchainPayloadBuilder.Op(
            StateUpdateType.STORE,
            OffchainPayloadBuilder.encodeStore(OffchainPayloadBuilder.dynamicArrayLengthSlot(BOARD_SLOT), bytes32(n))
        );
        for (uint256 i = 0; i < n; i++) {
            address p = _seedPlayer(i);
            uint256 score = n - i; // descending
            ops[k++] = OffchainPayloadBuilder.Op(
                StateUpdateType.STORE,
                OffchainPayloadBuilder.encodeStore(
                    OffchainPayloadBuilder.dynamicArraySlot(BOARD_SLOT, 2 * i), OffchainPayloadBuilder.addressTopic(p)
                )
            );
            ops[k++] = OffchainPayloadBuilder.Op(
                StateUpdateType.STORE,
                OffchainPayloadBuilder.encodeStore(
                    OffchainPayloadBuilder.dynamicArraySlot(BOARD_SLOT, 2 * i + 1), bytes32(score)
                )
            );
            ops[k++] = OffchainPayloadBuilder.Op(
                StateUpdateType.STORE,
                OffchainPayloadBuilder.encodeStore(OffchainPayloadBuilder.mappingSlot(p, RANK_SLOT), bytes32(i + 1))
            );
        }
        return OffchainPayloadBuilder.build(ops);
    }

    function _seedPlayer(uint256 i) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode("seed", i)))));
    }
}

contract OnchainLeaderboardTest is LeaderboardTestKit {
    function _newBoard() internal returns (OnchainLeaderboard) {
        return new OnchainLeaderboard(avs, address(bls));
    }

    /// @notice Independent oracle: submit scores out of order, assert the board ends sorted with
    ///         correct ranks.
    function test_sortingCorrectnessAndRanks() public {
        OnchainLeaderboard b = _newBoard();
        uint256[5] memory scores = [uint256(50), 10, 90, 30, 70];
        for (uint256 i = 0; i < 5; i++) {
            b.submitScore(_player(i), scores[i]);
        }
        // Expected descending: 90,70,50,30,10 -> players 2,4,0,3,1.
        OnchainLeaderboard.Entry[] memory board = b.getBoard();
        assertEq(board.length, 5);
        assertEq(board[0].score, 90);
        assertEq(board[1].score, 70);
        assertEq(board[2].score, 50);
        assertEq(board[3].score, 30);
        assertEq(board[4].score, 10);
        // Strictly descending + rank consistency.
        for (uint256 i = 0; i + 1 < board.length; i++) {
            assertGe(board[i].score, board[i + 1].score, "not sorted");
            assertEq(b.rankOf(board[i].player), i + 1, "rank mismatch");
        }
        assertEq(b.rankOf(_player(2)), 1, "top player rank 1");
    }

    /// @notice Re-submitting a player repositions them (no duplicate entry).
    function test_scoreUpdateRepositions() public {
        OnchainLeaderboard b = _newBoard();
        b.submitScore(_player(0), 10);
        b.submitScore(_player(1), 20);
        b.submitScore(_player(2), 30);
        assertEq(b.rankOf(_player(0)), 3);

        b.submitScore(_player(0), 100); // jump to top
        assertEq(b.boardLength(), 3, "no duplicate");
        assertEq(b.rankOf(_player(0)), 1, "moved to top");
        assertEq(b.getEntry(0).score, 100);
    }

    /// @notice The heart of the demo: a worst-case front insertion that shifts the whole board,
    ///         reproduced exactly through verifyAndUpdate as a storage diff.
    function test_equivalence_naiveVsDiff() public {
        OnchainLeaderboard A = _newBoard();
        OnchainLeaderboard B = _newBoard();

        // Pre-populate both identically.
        for (uint256 i = 0; i < 8; i++) {
            uint256 sc = 100 + i * 10; // 100,110,...,170
            A.submitScore(_player(i), sc);
            B.submitScore(_player(i), sc);
        }

        // Worst case: a new highest score shifts the entire board down.
        address newcomer = _player(999);
        uint256 hi = 1_000;

        vm.recordLogs();
        A.submitScore(newcomer, hi);
        Vm.Log[] memory aLogs = vm.getRecordedLogs();

        bytes memory diff = _buildLeaderboardDiff(A, newcomer, hi);
        uint256 countBefore = B.stateTransitionCount();
        vm.recordLogs();
        _verify(B, diff, OnchainLeaderboard.submitScore.selector);
        Vm.Log[] memory bLogs = vm.getRecordedLogs();

        // Structural equality: length, every entry (getter + raw slot), every rank.
        assertEq(B.boardLength(), A.boardLength(), "length");
        for (uint256 i = 0; i < A.boardLength(); i++) {
            _assertEntryEqual(A, B, i);
        }
        assertEq(B.rankOf(newcomer), 1, "newcomer at top");
        assertEq(B.stateTransitionCount(), countBefore + 1);

        // Log equality.
        Vm.Log memory aEvt = _findScoreLog(aLogs);
        Vm.Log memory bEvt = _findScoreLog(bLogs);
        assertEq(bEvt.topics[0], aEvt.topics[0], "log sig");
        assertEq(bEvt.topics[1], aEvt.topics[1], "log player topic");
        assertEq(keccak256(bEvt.data), keccak256(aEvt.data), "log data");
    }

    function test_verifyAndUpdate_revertsBelowThreshold() public {
        OnchainLeaderboard A = _newBoard();
        OnchainLeaderboard B = _newBoard();
        A.submitScore(_player(0), 10);
        B.submitScore(_player(0), 10);
        A.submitScore(_player(1), 99);
        bytes memory diff = _buildLeaderboardDiff(A, _player(1), 99);

        bls.setSignedBps(6599);
        if (block.number == 0) vm.roll(1);
        uint256 ti = B.stateTransitionCount();
        bytes32 h = B.getMessageHash(ti, OnchainLeaderboard.submitScore.selector, diff);
        vm.expectRevert(IGasKillerSDK.InsufficientQuorumThreshold.selector);
        B.verifyAndUpdate(
            h,
            _quorumNumbers(),
            uint32(block.number - 1),
            diff,
            ti,
            OnchainLeaderboard.submitScore.selector,
            _emptySignature()
        );
    }

    /// @dev Assert entry `i` matches between A and B via both the getter and the raw storage slots.
    function _assertEntryEqual(OnchainLeaderboard A, OnchainLeaderboard B, uint256 i) internal view {
        OnchainLeaderboard.Entry memory ea = A.getEntry(i);
        OnchainLeaderboard.Entry memory eb = B.getEntry(i);
        assertEq(eb.player, ea.player, "player mismatch at index");
        assertEq(eb.score, ea.score, "score mismatch at index");
        assertEq(B.rankOf(ea.player), A.rankOf(ea.player), "rank mismatch");
        bytes32 pslot = OffchainPayloadBuilder.dynamicArraySlot(BOARD_SLOT, 2 * i);
        bytes32 sslot = OffchainPayloadBuilder.dynamicArraySlot(BOARD_SLOT, 2 * i + 1);
        assertEq(vm.load(address(B), pslot), vm.load(address(A), pslot), "raw player slot");
        assertEq(vm.load(address(B), sslot), vm.load(address(A), sslot), "raw score slot");
    }

    function _findScoreLog(Vm.Log[] memory logs) internal pure returns (Vm.Log memory) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length >= 1 && logs[i].topics[0] == SCORE_SIG) {
                return logs[i];
            }
        }
        revert("ScoreSubmitted log not found");
    }
}
