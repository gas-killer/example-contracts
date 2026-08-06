// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {GasKillerSDK} from "gas-killer-sdk/GasKillerSDK.sol";

/// @title OnchainLife
/// @notice Conway's Game of Life on a 64x64 toroidal grid, run **entirely on-chain** — the kind of
///         "dumb expensive" contract you would never normally ship. `step(generations)` recomputes
///         every one of the 4096 cells' 8 neighbours, every generation. Naively this blows past a
///         ~30M-gas mainnet block within a handful of generations.
///
///         With Gas Killer, an operator evolves the board off-chain and submits the result through
///         `verifyAndUpdate` as a tiny storage diff: at most 16 changed words + the generation
///         counter + one log. That diff is the SAME size whether the operator stepped the board one
///         generation or a million — the apply cost is independent of the compute weight. This makes
///         OnchainLife the clearest demonstration of Gas Killer's "heavy compute -> small flat diff"
///         sweet spot, and the natural place to show the "trust-only, unbounded" regime (see the
///         tests and SECURITY.md): nothing on-chain re-checks the board, so a far-future state rests
///         entirely on the 66% operator quorum being honest.
///
/// @dev Storage layout (verify with `forge inspect ... storage-layout`): `board` is declared first
///      so it occupies slots 0..15 (one `uint256` per 256-cell word); `generation` is slot 16.
///      GasKillerSDK's own state lives in ERC-7201 namespaces and does not consume these slots.
///      Cell (x,y) maps to bit index `y*WIDTH + x`; that bit lives in word `idx >> 8` at position
///      `idx & 255`.
contract OnchainLife is GasKillerSDK {
    /// @notice Grid width in cells.
    uint256 public constant WIDTH = 64;
    /// @notice Grid height in cells.
    uint256 public constant HEIGHT = 64;
    /// @notice Number of 256-bit words needed to pack WIDTH*HEIGHT cells (64*64/256 = 16).
    uint256 public constant WORDS = 16;

    /// @notice The packed cell bitmap. Slot `w` (0..15) holds 256 cells. THIS IS DECLARED FIRST so
    ///         word `w` lives exactly at storage slot `w` — which is what the diff STOREs target.
    uint256[16] public board;

    /// @notice Number of generations elapsed since construction.
    uint256 public generation;

    /// @notice Emitted once at construction with the hash of the seeded board.
    event BoardSeeded(bytes32 boardHash);

    /// @notice Emitted after a `step`, carrying the new generation and a hash of the resulting board.
    /// @dev One indexed param => the EVM log has 2 topics (sig + generation), so the operator's
    ///      equivalent diff uses a LOG2 op: data = abi.encode(boardHash), topics = [sig, generation].
    event GenerationStepped(uint256 indexed generation, bytes32 boardHash);

    /// @param _avsAddress AVS service-manager address (scopes the Gas Killer namespace).
    /// @param _blsSigChecker BLS signature checker used by `verifyAndUpdate`.
    /// @param _seed Initial packed board (16 words). Cell (x,y) = bit `y*64+x`.
    constructor(address _avsAddress, address _blsSigChecker, uint256[16] memory _seed) {
        _setAvsAddress(_avsAddress);
        _setBlsSignatureChecker(_blsSigChecker);
        for (uint256 i = 0; i < WORDS; i++) {
            board[i] = _seed[i];
        }
        emit BoardSeeded(keccak256(abi.encode(board)));
    }

    /// @notice Evolve the board `generations` steps using Conway's rules on a toroidal grid.
    /// @dev THIS IS THE NAIVE, GAS-EXPLOSIVE SPEC. It is what tests execute to derive the expected
    ///      next state and what the gas benchmarks measure. In production you would not call this on
    ///      mainnet for more than a generation or two; the operator runs it off-chain and submits the
    ///      diff via `verifyAndUpdate`.
    function step(uint32 generations) external trackState {
        uint256[16] memory cur = _loadBoard();
        for (uint32 g = 0; g < generations; g++) {
            uint256[16] memory next; // zero-initialised => all cells dead
            for (uint256 y = 0; y < HEIGHT; y++) {
                for (uint256 x = 0; x < WIDTH; x++) {
                    uint256 live = _liveNeighbors(cur, x, y);
                    bool alive = _cellAt(cur, x, y);
                    // Conway: a live cell survives with 2-3 neighbours; a dead cell is born with 3.
                    if (alive ? (live == 2 || live == 3) : (live == 3)) {
                        _setCell(next, x, y);
                    }
                }
            }
            cur = next;
        }
        _storeBoard(cur);
        generation += generations;
        emit GenerationStepped(generation, keccak256(abi.encode(board)));
    }

    /// @notice Return the full packed board (16 words).
    function getBoard() external view returns (uint256[16] memory out) {
        for (uint256 i = 0; i < WORDS; i++) {
            out[i] = board[i];
        }
    }

    /// @notice Return whether cell (x,y) is alive.
    function getCell(uint256 x, uint256 y) external view returns (bool) {
        require(x < WIDTH && y < HEIGHT, "out of bounds");
        uint256 idx = y * WIDTH + x;
        return (board[idx >> 8] >> (idx & 255)) & 1 == 1;
    }

    /// @notice Hash of the current board — matches the `boardHash` in `GenerationStepped`.
    function boardHash() external view returns (bytes32) {
        return keccak256(abi.encode(board));
    }

    /* ----------------------------- internal helpers ----------------------------- */

    function _loadBoard() private view returns (uint256[16] memory cur) {
        for (uint256 i = 0; i < WORDS; i++) {
            cur[i] = board[i];
        }
    }

    function _storeBoard(uint256[16] memory next) private {
        for (uint256 i = 0; i < WORDS; i++) {
            board[i] = next[i];
        }
    }

    function _cellAt(uint256[16] memory b, uint256 x, uint256 y) private pure returns (bool) {
        uint256 idx = y * WIDTH + x;
        return (b[idx >> 8] >> (idx & 255)) & 1 == 1;
    }

    function _setCell(uint256[16] memory b, uint256 x, uint256 y) private pure {
        uint256 idx = y * WIDTH + x;
        b[idx >> 8] |= (uint256(1) << (idx & 255));
    }

    /// @dev Count the 8 toroidal (wrap-around) neighbours of (x,y) that are alive.
    function _liveNeighbors(uint256[16] memory b, uint256 x, uint256 y) private pure returns (uint256 count) {
        uint256 xm1 = x == 0 ? WIDTH - 1 : x - 1;
        uint256 xp1 = x == WIDTH - 1 ? 0 : x + 1;
        uint256 ym1 = y == 0 ? HEIGHT - 1 : y - 1;
        uint256 yp1 = y == HEIGHT - 1 ? 0 : y + 1;

        count = _b(b, xm1, ym1) + _b(b, x, ym1) + _b(b, xp1, ym1) + _b(b, xm1, y) + _b(b, xp1, y) + _b(b, xm1, yp1)
            + _b(b, x, yp1) + _b(b, xp1, yp1);
    }

    /// @dev Cell value as 0/1 for neighbour summation.
    function _b(uint256[16] memory b, uint256 x, uint256 y) private pure returns (uint256) {
        uint256 idx = y * WIDTH + x;
        return (b[idx >> 8] >> (idx & 255)) & 1;
    }
}
