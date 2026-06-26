// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BenchmarkBase} from "../helpers/BenchmarkBase.sol";
import {Vm} from "forge-std/Vm.sol";
import {MegaDrop} from "../../src/examples/megadrop/MegaDrop.sol";
import {MockBLSSignatureChecker} from "../mocks/MockBLSSignatureChecker.sol";
import {OffchainPayloadBuilder} from "../helpers/OffchainPayloadBuilder.sol";
import {StateUpdateType} from "gas-killer-sdk/StateChangeHandlerLib.sol";
import {IGasKillerSDK} from "gas-killer-sdk/interface/IGasKillerSDK.sol";

/// @notice Shared fixtures + diff-building helpers for the MegaDrop unit tests and benchmarks.
abstract contract MegaDropTestKit is BenchmarkBase {
    MockBLSSignatureChecker internal bls;
    address internal avs = makeAddr("avs");

    // Slot constants (verified via `forge inspect`): balanceOf mapping @0, totalSupply @1.
    uint256 internal constant BALANCES_SLOT = 0;
    uint256 internal constant TOTAL_SUPPLY_SLOT = 1;
    bytes32 internal constant TRANSFER_SIG = keccak256("Transfer(address,address,uint256)");
    bytes32 internal constant AIRDROP_SIG = keccak256("AirdropApplied(uint256,uint256)");

    function setUp() public {
        bls = _deployPassingBls();
    }

    function _newToken() internal returns (MegaDrop) {
        return new MegaDrop(avs, address(bls), "MegaToken", "MEGA", 18);
    }

    /// @dev `n` unique recipients and deterministic non-zero amounts.
    function _makeAirdrop(uint256 n, uint256 salt)
        internal
        pure
        returns (address[] memory recipients, uint256[] memory amounts)
    {
        recipients = new address[](n);
        amounts = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            recipients[i] = address(uint160(uint256(keccak256(abi.encode("recipient", salt, i)))));
            amounts[i] = 1 + (uint256(keccak256(abi.encode("amount", salt, i))) % 1_000_000);
        }
    }

    /// @dev Build the diff an operator submits after `a.airdrop(recipients, amounts)`: one balance
    ///      STORE per entry (writing the recipient's FINAL balance read from `a`, so duplicate
    ///      recipients resolve correctly — a real operator would dedupe these redundant writes), the
    ///      totalSupply STORE, one Transfer LOG3 per entry (in order), and the AirdropApplied LOG1.
    function _buildAirdropDiff(MegaDrop a, address[] memory recipients, uint256[] memory amounts)
        internal
        view
        returns (bytes memory)
    {
        uint256 n = recipients.length;
        uint256 totalMinted;
        for (uint256 i = 0; i < n; i++) {
            totalMinted += amounts[i];
        }

        // ops: n balance STOREs + 1 totalSupply STORE + n Transfer LOG3s + 1 AirdropApplied LOG1.
        OffchainPayloadBuilder.Op[] memory ops = new OffchainPayloadBuilder.Op[](2 * n + 2);
        uint256 k;
        for (uint256 i = 0; i < n; i++) {
            ops[k++] = OffchainPayloadBuilder.Op(
                StateUpdateType.STORE,
                OffchainPayloadBuilder.encodeStore(
                    OffchainPayloadBuilder.mappingSlot(recipients[i], BALANCES_SLOT),
                    bytes32(a.balanceOf(recipients[i]))
                )
            );
        }
        ops[k++] = OffchainPayloadBuilder.Op(
            StateUpdateType.STORE,
            OffchainPayloadBuilder.encodeStore(bytes32(TOTAL_SUPPLY_SLOT), bytes32(a.totalSupply()))
        );
        for (uint256 i = 0; i < n; i++) {
            ops[k++] = OffchainPayloadBuilder.Op(
                StateUpdateType.LOG3,
                OffchainPayloadBuilder.encodeLog3(
                    abi.encode(amounts[i]),
                    TRANSFER_SIG,
                    OffchainPayloadBuilder.addressTopic(address(0)),
                    OffchainPayloadBuilder.addressTopic(recipients[i])
                )
            );
        }
        ops[k++] = OffchainPayloadBuilder.Op(
            StateUpdateType.LOG1, OffchainPayloadBuilder.encodeLog1(abi.encode(n, totalMinted), AIRDROP_SIG)
        );
        return OffchainPayloadBuilder.build(ops);
    }
}

contract MegaDropTest is MegaDropTestKit {
    function test_airdrop_naiveBalancesAndSupply() public {
        MegaDrop t = _newToken();
        (address[] memory r, uint256[] memory a) = _makeAirdrop(5, 1);
        t.airdrop(r, a);

        uint256 expectedTotal;
        for (uint256 i = 0; i < 5; i++) {
            assertEq(t.balanceOf(r[i]), a[i], "balance");
            expectedTotal += a[i];
        }
        assertEq(t.totalSupply(), expectedTotal, "total supply");
        assertEq(t.stateTransitionCount(), 1, "one tracked transition");
    }

    function test_airdrop_lengthMismatchReverts() public {
        MegaDrop t = _newToken();
        address[] memory r = new address[](2);
        uint256[] memory a = new uint256[](1);
        vm.expectRevert(MegaDrop.LengthMismatch.selector);
        t.airdrop(r, a);
    }

    /// @notice Equivalence: naive airdrop on A == operator diff applied to B, for balances (raw slot),
    ///         total supply, and the full Transfer/AirdropApplied log sequence.
    function test_equivalence_naiveVsDiff() public {
        (address[] memory r, uint256[] memory a) = _makeAirdrop(6, 2);

        MegaDrop A = _newToken();
        MegaDrop B = _newToken();

        vm.recordLogs();
        A.airdrop(r, a);
        Vm.Log[] memory aLogs = vm.getRecordedLogs();

        bytes memory diff = _buildAirdropDiff(A, r, a);

        uint256 countBefore = B.stateTransitionCount();
        vm.recordLogs();
        _verify(B, diff, MegaDrop.airdrop.selector);
        Vm.Log[] memory bLogs = vm.getRecordedLogs();

        // Balances: raw storage slot AND public getter agree between naive and diff.
        for (uint256 i = 0; i < r.length; i++) {
            bytes32 slot = OffchainPayloadBuilder.mappingSlot(r[i], BALANCES_SLOT);
            assertEq(vm.load(address(B), slot), vm.load(address(A), slot), "balance slot mismatch");
            assertEq(B.balanceOf(r[i]), a[i], "getter should read the raw-written balance");
        }
        assertEq(vm.load(address(B), bytes32(TOTAL_SUPPLY_SLOT)), vm.load(address(A), bytes32(TOTAL_SUPPLY_SLOT)));
        assertEq(B.stateTransitionCount(), countBefore + 1);

        // Logs: same sequence, topics, and data.
        assertEq(bLogs.length, aLogs.length, "log count mismatch");
        for (uint256 i = 0; i < aLogs.length; i++) {
            assertEq(bLogs[i].topics.length, aLogs[i].topics.length, "topic count");
            for (uint256 j = 0; j < aLogs[i].topics.length; j++) {
                assertEq(bLogs[i].topics[j], aLogs[i].topics[j], "topic mismatch");
            }
            assertEq(keccak256(bLogs[i].data), keccak256(aLogs[i].data), "data mismatch");
        }
    }

    /// @notice Airdropped balances written by raw STORE are fully functional: a recipient can transfer.
    function test_airdroppedTokensAreTransferable() public {
        (address[] memory r, uint256[] memory a) = _makeAirdrop(3, 3);
        MegaDrop B = _newToken();
        MegaDrop A = _newToken();
        A.airdrop(r, a);
        _verify(B, _buildAirdropDiff(A, r, a), MegaDrop.airdrop.selector);

        address alice = r[0];
        address bob = makeAddr("bob");
        uint256 amt = a[0] / 2;
        vm.prank(alice);
        assertTrue(B.transfer(bob, amt), "transfer should return true");
        assertEq(B.balanceOf(bob), amt, "transfer of airdropped balance works");
        assertEq(B.balanceOf(alice), a[0] - amt);
    }

    /// @notice The airdrop allows duplicate recipients (balances accumulate). The operator diff, which
    ///         writes each recipient's FINAL balance per entry, must reproduce that exactly — storage
    ///         and the full Transfer log sequence.
    function test_equivalence_withDuplicateRecipients() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        address[] memory r = new address[](3);
        uint256[] memory a = new uint256[](3);
        r[0] = alice;
        a[0] = 100;
        r[1] = bob;
        a[1] = 50;
        r[2] = alice;
        a[2] = 25; // alice appears twice -> final balance 125

        MegaDrop A = _newToken();
        MegaDrop B = _newToken();

        vm.recordLogs();
        A.airdrop(r, a);
        Vm.Log[] memory aLogs = vm.getRecordedLogs();

        bytes memory diff = _buildAirdropDiff(A, r, a);
        vm.recordLogs();
        _verify(B, diff, MegaDrop.airdrop.selector);
        Vm.Log[] memory bLogs = vm.getRecordedLogs();

        // Duplicate accumulated correctly, and the diff reproduced it byte-for-byte.
        assertEq(A.balanceOf(alice), 125, "naive accumulates duplicate");
        assertEq(B.balanceOf(alice), 125, "diff reproduces accumulated balance");
        assertEq(B.balanceOf(bob), 50);
        bytes32 aliceSlot = OffchainPayloadBuilder.mappingSlot(alice, BALANCES_SLOT);
        assertEq(vm.load(address(B), aliceSlot), vm.load(address(A), aliceSlot), "raw slot equal");
        assertEq(vm.load(address(B), bytes32(TOTAL_SUPPLY_SLOT)), vm.load(address(A), bytes32(TOTAL_SUPPLY_SLOT)));

        // Full log sequence (3 Transfers in entry order + AirdropApplied) matches.
        assertEq(bLogs.length, aLogs.length, "log count");
        for (uint256 i = 0; i < aLogs.length; i++) {
            assertEq(bLogs[i].topics.length, aLogs[i].topics.length, "topic count");
            for (uint256 j = 0; j < aLogs[i].topics.length; j++) {
                assertEq(bLogs[i].topics[j], aLogs[i].topics[j], "topic");
            }
            assertEq(keccak256(bLogs[i].data), keccak256(aLogs[i].data), "data");
        }
    }

    function test_verifyAndUpdate_revertsBelowThreshold() public {
        (address[] memory r, uint256[] memory a) = _makeAirdrop(3, 4);
        MegaDrop A = _newToken();
        MegaDrop B = _newToken();
        A.airdrop(r, a);
        bytes memory diff = _buildAirdropDiff(A, r, a);

        bls.setSignedBps(6599);
        if (block.number == 0) vm.roll(1);
        uint256 ti = B.stateTransitionCount();
        bytes32 h = B.getMessageHash(ti, MegaDrop.airdrop.selector, diff);
        vm.expectRevert(IGasKillerSDK.InsufficientQuorumThreshold.selector);
        B.verifyAndUpdate(
            h, _quorumNumbers(), uint32(block.number - 1), diff, ti, MegaDrop.airdrop.selector, _emptySignature()
        );
    }
}
