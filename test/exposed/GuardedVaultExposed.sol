// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {GuardedVault} from "../../src/examples/guarded-vault/GuardedVault.sol";

/// @notice Test-only subclass exposing the internal diff applier. Used both to measure pure apply-diff
///         gas and, crucially, to let the "operator" apply a candidate diff to a sandbox and run the
///         invariant on the resulting post-state before deciding whether to sign.
contract GuardedVaultExposed is GuardedVault {
    constructor(address avs, address bls, uint256 maxBps) GuardedVault(avs, bls, maxBps) {}

    function applyDiff(bytes calldata storageUpdates) external {
        _stateChangeHandler(storageUpdates);
    }
}
