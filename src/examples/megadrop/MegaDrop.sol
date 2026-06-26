// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {GasKillerSDK} from "gas-killer-sdk/GasKillerSDK.sol";

/// @title MegaDrop
/// @notice A minimal ERC-20 whose `airdrop` mints to a whole list of recipients in one naive loop —
///         exactly the "dumb expensive" pattern you'd never ship. At a few thousand recipients the
///         on-chain loop blows past a 30M-gas mainnet block, so today airdrops are done with Merkle
///         claims (users pay gas and friction) or thousands of transactions.
///
///         Gas Killer lets you write the dumb loop anyway: an operator computes the resulting
///         balances off-chain and applies them as a signed batch of direct storage writes (one STORE
///         per recipient balance + the standard `Transfer` log), with no claim UX and no per-recipient
///         calldata on the consumer. This is the literal "write storage slots directly" product.
///
///         HONEST FRAMING: unlike OnchainLife, MegaDrop's diff is O(N) — applying N balance writes
///         still costs ~N cold SSTOREs, so a very large airdrop must be CHUNKED across multiple
///         `verifyAndUpdate` calls (each within a block). The win here is structural (one signed
///         batch instead of N user transactions, no Merkle, no claim friction, no recompute), not a
///         flat tiny diff. See SECURITY.md.
///
/// @dev Storage layout (verify with `forge inspect ... storage-layout`): `balanceOf` is declared
///      first so it is the mapping at slot 0 (balance of `r` lives at `keccak256(abi.encode(r, 0))`);
///      `totalSupply` is slot 1. GasKillerSDK's own state lives in ERC-7201 namespaces.
contract MegaDrop is GasKillerSDK {
    /// @notice Token balances. DECLARED FIRST so the mapping base slot is 0.
    mapping(address => uint256) public balanceOf;
    /// @notice Total token supply (slot 1).
    uint256 public totalSupply;

    /// @notice ERC-20 metadata.
    string public name;
    string public symbol;
    uint8 public decimals;

    /// @notice Thrown when `recipients` and `amounts` lengths differ.
    error LengthMismatch();
    /// @notice Thrown on transfer from an account with insufficient balance.
    error InsufficientBalance();

    /// @notice Standard ERC-20 Transfer event. A mint is `from = address(0)`.
    /// @dev Two indexed params => the EVM log has 3 topics, so the operator's equivalent diff uses a
    ///      LOG3 op: data = abi.encode(value), topics = [sig, from, to].
    event Transfer(address indexed from, address indexed to, uint256 value);

    /// @notice Summary event emitted once per airdrop batch.
    event AirdropApplied(uint256 count, uint256 totalMinted);

    constructor(
        address _avsAddress,
        address _blsSigChecker,
        string memory _name,
        string memory _symbol,
        uint8 _decimals
    ) {
        _setAvsAddress(_avsAddress);
        _setBlsSignatureChecker(_blsSigChecker);
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    /// @notice Mint `amounts[i]` to `recipients[i]` for every i — the naive, gas-explosive spec.
    /// @dev This is what tests execute to derive expected balances and what the benchmarks measure.
    ///      In production an operator reproduces the resulting balances off-chain and submits them via
    ///      `verifyAndUpdate` (chunked if the list is large).
    function airdrop(address[] calldata recipients, uint256[] calldata amounts) external trackState {
        if (recipients.length != amounts.length) revert LengthMismatch();
        uint256 added;
        for (uint256 i = 0; i < recipients.length; i++) {
            balanceOf[recipients[i]] += amounts[i];
            added += amounts[i];
            emit Transfer(address(0), recipients[i], amounts[i]);
        }
        totalSupply += added;
        emit AirdropApplied(recipients.length, added);
    }

    /// @notice Standard ERC-20 transfer. Present to prove the airdropped (raw-STORE-written) balances
    ///         are indistinguishable from "real" balances: a recipient can transfer them normally.
    function transfer(address to, uint256 amount) external returns (bool) {
        uint256 bal = balanceOf[msg.sender];
        if (bal < amount) revert InsufficientBalance();
        unchecked {
            balanceOf[msg.sender] = bal - amount;
        }
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }
}
