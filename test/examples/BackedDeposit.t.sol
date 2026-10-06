// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BenchmarkBase} from "../helpers/BenchmarkBase.sol";
import {BackedDeposit} from "../../src/examples/backed-deposit/BackedDeposit.sol";
import {MockSchnorrStakeRegistry} from "../mocks/MockSchnorrStakeRegistry.sol";
import {OffchainPayloadBuilder} from "../helpers/OffchainPayloadBuilder.sol";
import {StateUpdateType, StateChangeHandlerLib} from "gas-killer-sdk/StateChangeHandlerLib.sol";

/// A deposit through Gas Killer settles only when `verifyAndUpdate` brings the deposit's ETH.
contract BackedDepositTest is BenchmarkBase {
    BackedDeposit internal c;
    address internal alice = makeAddr("alice");
    address internal settler = makeAddr("settler");
    uint256 internal constant AMOUNT = 0.01 ether;

    // Slots (forge inspect BackedDeposit storageLayout): balanceOf@0, owed@1.
    uint256 internal constant BALANCE_OF_SLOT = 0;
    uint256 internal constant OWED_SLOT = 1;

    function setUp() public {
        MockSchnorrStakeRegistry registry = _deployPassingRegistry();
        c = new BackedDeposit(makeAddr("avs"), address(registry));
        vm.deal(alice, 1 ether);
        vm.deal(settler, 1 ether);
    }

    /// What the operators sign for `alice` depositing AMOUNT on a fresh contract: the two stores, the
    /// log, and the backing self-call, in the order `deposit()` makes them.
    function _depositDiff() internal view returns (bytes memory) {
        OffchainPayloadBuilder.Op[] memory ops = new OffchainPayloadBuilder.Op[](4);
        ops[0] = OffchainPayloadBuilder.Op(
            StateUpdateType.STORE,
            OffchainPayloadBuilder.encodeStore(
                OffchainPayloadBuilder.mappingSlot(alice, BALANCE_OF_SLOT), bytes32(AMOUNT)
            )
        );
        ops[1] = OffchainPayloadBuilder.Op(
            StateUpdateType.STORE,
            OffchainPayloadBuilder.encodeStore(OffchainPayloadBuilder.simpleSlot(OWED_SLOT), bytes32(AMOUNT))
        );
        ops[2] = OffchainPayloadBuilder.Op(
            StateUpdateType.LOG2,
            OffchainPayloadBuilder.encodeLog2(
                abi.encode(AMOUNT), BackedDeposit.Deposited.selector, OffchainPayloadBuilder.addressTopic(alice)
            )
        );
        ops[3] = OffchainPayloadBuilder.Op(
            StateUpdateType.CALL,
            OffchainPayloadBuilder.encodeCall(address(c), 0, abi.encodeCall(BackedDeposit.checkBacked, ()))
        );
        return OffchainPayloadBuilder.build(ops);
    }

    function _settle(bytes memory diff, uint256 value) internal {
        (bytes32 msgHash, uint32 ref, uint256 ti) = _prepVerify(c, diff, BackedDeposit.deposit.selector);
        (uint256 s, address rAddr, address[] memory nonSigners) = _placeholderSignature();
        vm.prank(settler);
        c.verifyAndUpdate{value: value}(msgHash, ref, diff, ti, BackedDeposit.deposit.selector, s, rAddr, nonSigners);
    }

    function test_directDeposit() public {
        vm.prank(alice);
        c.deposit{value: AMOUNT}();
        assertEq(c.balanceOf(alice), AMOUNT);
        assertEq(c.owed(), AMOUNT);
        assertEq(address(c).balance, AMOUNT);
        assertEq(c.stateTransitionCount(), 1);
    }

    /// The hand-built diff is what a direct deposit writes: same slots, same values.
    function test_diffMatchesDirectExecution() public {
        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        c.deposit{value: AMOUNT}();
        bytes32 bal = vm.load(address(c), OffchainPayloadBuilder.mappingSlot(alice, BALANCE_OF_SLOT));
        bytes32 owedWord = vm.load(address(c), OffchainPayloadBuilder.simpleSlot(OWED_SLOT));
        vm.revertToState(snap);

        _settle(_depositDiff(), AMOUNT);
        assertEq(vm.load(address(c), OffchainPayloadBuilder.mappingSlot(alice, BALANCE_OF_SLOT)), bal);
        assertEq(vm.load(address(c), OffchainPayloadBuilder.simpleSlot(OWED_SLOT)), owedWord);
    }

    function test_gasKillerDepositWithItsEthSettles() public {
        _settle(_depositDiff(), AMOUNT);
        assertEq(c.balanceOf(alice), AMOUNT);
        assertEq(c.owed(), AMOUNT);
        assertEq(address(c).balance, AMOUNT, "the settlement brought the ETH");
        assertEq(c.stateTransitionCount(), 1);
    }

    /// The case the backing check exists for: without it this would credit 0.01 ETH nobody paid.
    function test_gasKillerDepositWithoutItsEthReverts() public {
        bytes memory diff = _depositDiff();
        (bytes32 msgHash, uint32 ref, uint256 ti) = _prepVerify(c, diff, BackedDeposit.deposit.selector);
        (uint256 s, address rAddr, address[] memory nonSigners) = _placeholderSignature();
        bytes memory unbacked = abi.encodeWithSelector(BackedDeposit.Unbacked.selector, uint256(0), AMOUNT);
        vm.expectRevert(
            abi.encodeWithSelector(
                StateChangeHandlerLib.RevertingContext.selector,
                uint256(3),
                address(c),
                unbacked,
                abi.encodeCall(BackedDeposit.checkBacked, ())
            )
        );
        vm.prank(settler);
        c.verifyAndUpdate(msgHash, ref, diff, ti, BackedDeposit.deposit.selector, s, rAddr, nonSigners);
    }

    function test_gasKillerDepositShortByOneWeiReverts() public {
        bytes memory diff = _depositDiff();
        (bytes32 msgHash, uint32 ref, uint256 ti) = _prepVerify(c, diff, BackedDeposit.deposit.selector);
        (uint256 s, address rAddr, address[] memory nonSigners) = _placeholderSignature();
        vm.expectRevert();
        vm.prank(settler);
        c.verifyAndUpdate{value: AMOUNT - 1}(
            msgHash, ref, diff, ti, BackedDeposit.deposit.selector, s, rAddr, nonSigners
        );
    }
}
