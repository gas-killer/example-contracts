// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {GasKillerSDK} from "gas-killer-sdk/GasKillerSDK.sol";

/// @title BackedDeposit
/// @notice The smallest Gas Killer target that takes ETH in: a ledger of deposits that must stay
///         backed by the contract's balance.
///
/// @dev The quorum signs what a call did with the `msg.value` it was simulated with, but
///      `verifyAndUpdate` can be sent with any value. A diff that credits a deposit could
///      otherwise be settled with no ETH, crediting a balance the contract cannot pay. So
///      `deposit()` ends with an external self-call to `checkBacked()`. It is a CALL (not a view
///      STATICCALL, which the diff leaves out), so the operators record it in the signed diff and
///      it runs again at settlement, after the stores: a settlement that does not bring the
///      deposit's ETH reverts with `Unbacked`.
///
///      The pattern comes from a Gas Killer fork of Tacit's private ETH pool. This contract is the
///      end-to-end fixture for a task sent with `value`.
contract BackedDeposit is GasKillerSDK {
    /// @notice Each depositor's credited balance.
    mapping(address => uint256) public balanceOf;
    /// @notice The ETH the contract owes its depositors. Its balance never falls below this.
    uint256 public owed;

    event Deposited(address indexed account, uint256 amount);

    error Unbacked(uint256 balance, uint256 owed);

    constructor(address _avsAddress, address _schnorrStakeRegistry) {
        _setAvsAddress(_avsAddress);
        _setSchnorrRegistry(_schnorrStakeRegistry);
    }

    /// @notice Credit `msg.value` to the caller. Direct, or through Gas Killer with the deposit's ETH
    ///         sent along with `verifyAndUpdate`.
    function deposit() external payable trackState {
        balanceOf[msg.sender] += msg.value;
        owed += msg.value;
        emit Deposited(msg.sender, msg.value);
        BackedDeposit(address(this)).checkBacked();
    }

    /// @notice Reverts unless the contract holds at least what it owes.
    /// @dev Deliberately not `view`, so `deposit()` reaches it with CALL and the diff records it.
    function checkBacked() external {
        if (address(this).balance < owed) revert Unbacked(address(this).balance, owed);
    }
}
