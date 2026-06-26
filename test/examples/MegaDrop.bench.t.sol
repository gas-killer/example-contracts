// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {MegaDropTestKit} from "./MegaDrop.t.sol";
import {MegaDrop} from "../../src/examples/megadrop/MegaDrop.sol";
import {MegaDropExposed} from "../exposed/MegaDropExposed.sol";

/// @notice Honest gas benchmarks for MegaDrop — the write-bound counter-example to OnchainLife.
///
///         MegaDrop's diff is O(N): applying N balances is ~N cold SSTOREs, and the SDK's per-op
///         decode overhead actually makes apply-diff a bit *more* expensive than the naive loop
///         itself. So MegaDrop is NOT a raw-gas-collapse like OnchainLife (where compute >> diff).
///         Two honest points the benchmark proves instead:
///           1. The naive airdrop loop exceeds a 30M mainnet block at ~1.1-1.2k recipients, so you
///              cannot ship it as a single transaction at all — the loop is the "dumb" spec.
///           2. Versus the realistic alternative (a Merkle airdrop where each user submits a claim
///              tx, ~55k gas/user, and many never claim), the operator apply-diff is cheaper per
///              recipient AND requires zero user action — that is MegaDrop's structural win. It is
///              still O(N), so large airdrops chunk across multiple verifyAndUpdate calls.
contract MegaDropBench is MegaDropTestKit {
    /// @notice Conservative gas for one Merkle-airdrop claim (proof verification + SSTORE + event).
    /// @dev Real claims run ~50-70k depending on tree depth; 55k is a deliberately conservative anchor.
    uint256 internal constant MERKLE_CLAIM_GAS_PER_USER = 55_000;

    function _gasOfAirdrop(MegaDrop c, address[] memory r, uint256[] memory a) internal returns (uint256 used) {
        uint256 g0 = gasleft();
        c.airdrop(r, a);
        used = g0 - gasleft();
    }

    function _gasOfApply(MegaDropExposed c, bytes memory diff) internal returns (uint256 used) {
        uint256 g0 = gasleft();
        c.applyDiff(diff);
        used = g0 - gasleft();
    }

    /// @notice The naive airdrop loop crosses a 30M mainnet block — unshippable as one transaction.
    function test_sweep_naiveCrossesBlockLimit() public {
        uint256[4] memory sizes = [uint256(250), 500, 1000, 1500];
        uint256 lastNaive;
        for (uint256 s = 0; s < sizes.length; s++) {
            uint256 n = sizes[s];
            (address[] memory r, uint256[] memory a) = _makeAirdrop(n, 100 + s);
            MegaDrop t = _newToken();
            uint256 naive = _gasOfAirdrop(t, r, a);
            emit log_named_uint(string.concat("naive airdrop ", _label(n), " gas"), naive);
            if (s > 0) assertGt(naive, lastNaive, "naive should grow with N");
            lastNaive = naive;
        }
        assertGt(lastNaive, MAINNET_BLOCK_GAS, "1500-recipient airdrop should exceed a 30M block");
    }

    /// @notice MegaDrop's real win is structural: per-recipient apply cost beats a Merkle claim, with
    ///         no user action. (It is still O(N) — comparable to the naive loop's own cost.)
    function test_applyDiff_perRecipientBeatsMerkleClaim() public {
        uint256 n = 1000;
        (address[] memory r, uint256[] memory a) = _makeAirdrop(n, 7);

        MegaDrop A = _newToken();
        uint256 naive = _gasOfAirdrop(A, r, a);

        bytes memory diff = _buildAirdropDiff(A, r, a);
        MegaDropExposed B = new MegaDropExposed(avs, address(bls), "MegaToken", "MEGA", 18);
        uint256 applyGas = _gasOfApply(B, diff);
        uint256 applyPerRecipient = applyGas / n;

        emit log_named_uint("naive airdrop(1000) gas      ", naive);
        emit log_named_uint("apply diff(1000) gas         ", applyGas);
        emit log_named_uint("apply per recipient          ", applyPerRecipient);
        emit log_named_uint("merkle claim per user (est)  ", MERKLE_CLAIM_GAS_PER_USER);

        // The honest, favorable comparison: vs the realistic Merkle-claim alternative.
        assertLt(applyPerRecipient, MERKLE_CLAIM_GAS_PER_USER, "apply-per-recipient should beat a Merkle claim");
        // The honest caveat: apply-diff is write-bound and O(N), in the same ballpark as the naive
        // loop's own cost (NOT a flat tiny diff). This is why large airdrops must be chunked.
        assertGt(applyGas, naive / 2, "apply-diff is O(N), comparable to the naive loop (not a tiny diff)");
    }

    /// @notice Empirically confirm the apply-diff is O(N): per-recipient gas stays ~constant as N
    ///         grows (each B is freshly deployed, so its balance slots are cold across the sweep).
    function test_applyDiff_perRecipientIsStableAcrossN() public {
        uint256[3] memory sizes = [uint256(250), 500, 1000];
        uint256 base;
        for (uint256 s = 0; s < sizes.length; s++) {
            uint256 n = sizes[s];
            (address[] memory r, uint256[] memory a) = _makeAirdrop(n, 900 + s);
            MegaDrop A = _newToken();
            A.airdrop(r, a);
            bytes memory diff = _buildAirdropDiff(A, r, a);
            MegaDropExposed B = new MegaDropExposed(avs, address(bls), "MegaToken", "MEGA", 18);
            uint256 per = _gasOfApply(B, diff) / n;
            emit log_named_uint(string.concat("apply / recipient ", _label(n)), per);
            if (s == 0) {
                base = per;
            } else {
                // Per-recipient cost roughly constant => linear total => O(N), not O(N^2).
                assertApproxEqRel(per, base, 0.25e18, "per-recipient apply cost should be ~constant in N");
            }
        }
    }
}
