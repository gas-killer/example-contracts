// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {GasKillerSDK} from "gas-killer-sdk/GasKillerSDK.sol";

/// @title OnchainLeaderboard
/// @notice A fully on-chain, fully sorted leaderboard. Every `submitScore` re-sorts the board with a
///         naive insertion sort: it removes the player's old entry (O(N) shift), finds the new
///         position (O(N) scan), shifts the suffix down (O(N)), and rewrites the rank of every moved
///         player (O(N) mapping writes). Maintaining a sorted multi-thousand-entry board on-chain
///         like this is the textbook "never do this on-chain" gas nightmare — a single worst-case
///         (new high score) submission shifts the entire board and exceeds a 30M mainnet block at
///         ~1.5k entries.
///
///         With Gas Killer, an operator computes the reordered board off-chain and submits it as a
///         storage diff. Because the operator already knows the final positions, the apply path skips
///         the O(N) scan-and-compare reads the naive sort pays for — so it is modestly cheaper — but
///         the diff is still O(N) in the number of shifted entries. Like MegaDrop (and unlike
///         OnchainLife), this is the "diff scales with the change" regime; very large reshuffles
///         chunk across multiple verifyAndUpdate calls. See SECURITY.md.
///
/// @dev Storage layout (verify with `forge inspect ... storage-layout`): `board` is declared first
///      so it is the dynamic array at slot 0 (length at slot 0; entry `i` data at
///      `keccak256(abi.encode(0)) + 2*i`, since each Entry occupies 2 slots: player, then score).
///      `rankOf` is the mapping at slot 1 (rank of `p` at `keccak256(abi.encode(p, 1))`).
contract OnchainLeaderboard is GasKillerSDK {
    /// @notice A single ranked entry. Occupies 2 storage slots (address in its own slot, then score).
    struct Entry {
        address player;
        uint256 score;
    }

    /// @notice The leaderboard, kept sorted by descending score. DECLARED FIRST so its base slot is 0.
    Entry[] public board;

    /// @notice 1-based rank of each player (0 == not on the board). Slot 1.
    mapping(address => uint256) public rankOf;

    /// @notice Emitted on every score submission with the player's resulting rank.
    /// @dev One indexed param => 2 log topics, so the operator's diff uses a LOG2 op:
    ///      data = abi.encode(score, rank), topics = [sig, player].
    event ScoreSubmitted(address indexed player, uint256 score, uint256 rank);

    constructor(address _avsAddress, address _blsSigChecker) {
        _setAvsAddress(_avsAddress);
        _setBlsSignatureChecker(_blsSigChecker);
    }

    /// @notice Submit (or update) `player`'s score and keep the board fully sorted — the naive,
    ///         gas-explosive spec. This is what tests execute to derive the expected ordering and what
    ///         the benchmarks measure; in production the operator reproduces the result off-chain.
    function submitScore(address player, uint256 score) external trackState {
        _removeIfPresent(player);
        _insertSorted(player, score);
        emit ScoreSubmitted(player, score, rankOf[player]);
    }

    /// @notice Number of entries currently on the board.
    function boardLength() external view returns (uint256) {
        return board.length;
    }

    /// @notice Return entry `i` (0-based, descending by score).
    function getEntry(uint256 i) external view returns (Entry memory) {
        return board[i];
    }

    /// @notice Return the whole board (descending by score).
    function getBoard() external view returns (Entry[] memory out) {
        out = new Entry[](board.length);
        for (uint256 i = 0; i < board.length; i++) {
            out[i] = board[i];
        }
    }

    /* ----------------------------- internal sort ----------------------------- */

    /// @dev Remove `player`'s existing entry, shifting the suffix up and rewriting moved ranks.
    function _removeIfPresent(address player) private {
        uint256 rank = rankOf[player];
        if (rank == 0) return;
        uint256 idx = rank - 1;
        uint256 len = board.length;
        for (uint256 i = idx; i + 1 < len; i++) {
            board[i] = board[i + 1];
            rankOf[board[i].player] = i + 1;
        }
        board.pop();
        rankOf[player] = 0;
    }

    /// @dev Insert `player`/`score` at the correct descending position, shifting the suffix down and
    ///      rewriting moved ranks. Ties keep the existing entry ahead (stable).
    function _insertSorted(address player, uint256 score) private {
        uint256 len = board.length;
        uint256 pos = len; // default: append at the end (lowest score)
        for (uint256 i = 0; i < len; i++) {
            if (score > board[i].score) {
                pos = i;
                break;
            }
        }
        board.push(Entry(address(0), 0)); // grow by one
        for (uint256 i = len; i > pos; i--) {
            board[i] = board[i - 1];
            rankOf[board[i].player] = i + 1;
        }
        board[pos] = Entry(player, score);
        rankOf[player] = pos + 1;
    }
}
