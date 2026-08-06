// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {GasKillerSDK} from "gas-killer-sdk/GasKillerSDK.sol";

/// @title GuardedVault
/// @notice A shares vault that enforces an **expensive global invariant on every state transition** —
///         the kind of "run the whole invariant suite on every transaction" guard you could never
///         afford on-chain, but which Gas Killer makes free.
///
///         In production, a keeper proposes a `settle` (a batch redistribution of shares). Operators
///         SIMULATE it off-chain, then run `checkInvariant()` over the resulting post-state. Honest
///         operators only BLS-sign a diff whose post-state passes the invariant; the 66% quorum is
///         therefore an attestation that *this state transition preserves the invariant*. The diff
///         then lands via `verifyAndUpdate`, which does NOT re-run the O(N) invariant on-chain — that
///         cost was paid once, off-chain. A whole class of exploits (anything that breaks a global
///         invariant the contract can't afford to re-check) becomes impossible to land.
///
///         `checkInvariant()` re-validates, from scratch, three things over ALL depositors:
///           1. conservation: Σ shares == totalShares (catches phantom-share / accounting bugs);
///           2. solvency:     totalAssets >= totalShares (every share backed by >= 1 asset);
///           3. concentration: no depositor holds more than `maxConcentrationBps` of the supply.
///         (1) and (3) are O(N) and cannot be cheaply incrementalized — re-validating them on every
///         transaction is exactly the "dumb expensive" thing you'd never write on-chain.
///
/// @dev Storage layout (verify with `forge inspect ... storage-layout`): `shares` mapping @ slot 0
///      (shares of `d` at keccak256(abi.encode(d,0))), `totalShares` @ 1, `totalAssets` @ 2,
///      `depositors` array @ 3 (length @ 3, element i at keccak256(abi.encode(3))+i),
///      `isDepositor` mapping @ 4. `maxConcentrationBps` is immutable (no slot). GasKillerSDK's own
///      state lives in ERC-7201 namespaces.
contract GuardedVault is GasKillerSDK {
    /// @notice Shares per depositor. DECLARED FIRST so the mapping base slot is 0.
    mapping(address => uint256) public shares;
    /// @notice Sum of all shares (maintained incrementally; re-validated by checkInvariant). Slot 1.
    uint256 public totalShares;
    /// @notice Assets backing the vault. Slot 2.
    uint256 public totalAssets;
    /// @notice All depositor addresses, so the invariant can iterate them. Slot 3.
    address[] public depositors;
    /// @notice Membership flag to keep `depositors` duplicate-free. Slot 4.
    mapping(address => bool) public isDepositor;

    /// @notice Max share of total supply a single depositor may hold, in basis points (e.g. 5000 = 50%).
    uint256 public immutable maxConcentrationBps;

    /// @notice Emitted after a successful settle (the diff mirrors this with a LOG1).
    event Settled(uint256 userCount);

    error LengthMismatch();
    error NotDepositor(address account);
    error NegativeShares(address account);
    error NonConservingSettle(int256 net);
    error ConservationBroken(uint256 sumShares, uint256 declaredTotal);
    error InsolventVault(uint256 assets, uint256 sharesOutstanding);
    error ConcentrationExceeded(address account, uint256 heldShares, uint256 capShares);

    constructor(address _avsAddress, address _blsSigChecker, uint256 _maxConcentrationBps) {
        _setAvsAddress(_avsAddress);
        _setBlsSignatureChecker(_blsSigChecker);
        maxConcentrationBps = _maxConcentrationBps;
    }

    /// @notice Simple 1:1 deposit (mints shares = assets). O(1); not the focus of the example.
    /// @dev Kept unguarded for setup simplicity. In production every entry point would be guarded the
    ///      same way `settle` is.
    function deposit(uint256 assets) external {
        if (!isDepositor[msg.sender]) {
            isDepositor[msg.sender] = true;
            depositors.push(msg.sender);
        }
        shares[msg.sender] += assets;
        totalShares += assets;
        totalAssets += assets;
    }

    /// @notice Redistribute shares among `users` by signed `deltas`. THE GUARDED SPEC: it applies the
    ///         deltas (conservation-neutral: deltas must net to zero so totalShares is unchanged), then
    ///         re-validates the ENTIRE global invariant. This is what operators run in simulation; if
    ///         it reverts, no diff is produced and nothing lands on-chain.
    /// @dev Marked `trackState`. The expensive part is `checkInvariant()` (O(N)); in production it runs
    ///      off-chain and only the resulting O(K) share diff is submitted via `verifyAndUpdate`.
    function settle(address[] calldata users, int256[] calldata deltas) external trackState {
        if (users.length != deltas.length) revert LengthMismatch();
        int256 net;
        for (uint256 i = 0; i < users.length; i++) {
            if (!isDepositor[users[i]]) revert NotDepositor(users[i]);
            int256 updated = int256(shares[users[i]]) + deltas[i];
            if (updated < 0) revert NegativeShares(users[i]);
            // forge-lint: disable-next-line(unsafe-typecast) -- guarded by the `updated < 0` check above
            shares[users[i]] = uint256(updated);
            net += deltas[i];
        }
        if (net != 0) revert NonConservingSettle(net); // pure redistribution => totalShares unchanged
        checkInvariant(); // EXPENSIVE O(N) global guard — the whole point of the example
        emit Settled(users.length);
    }

    /// @notice Re-validate every global invariant over ALL depositors. Reverts on the first violation.
    /// @dev O(N). Operators call this (via eth_call) on a simulated post-state before signing a diff.
    ///      It is intentionally NOT called by `verifyAndUpdate` — that is the gas Gas Killer saves.
    ///
    ///      COMPLETENESS CAVEAT: this only sums shares for addresses in `depositors[]`. An invariant is
    ///      only as strong as the state it enumerates — a diff that writes `shares[x]` for an `x` never
    ///      added to `depositors[]` would escape the conservation sum (demonstrated in
    ///      `test_guard_limitation_phantomOnNonDepositorEscapes`). Honest operators never produce such a
    ///      diff (`settle` only touches `isDepositor` users), so this matters only under a >=66%
    ///      malicious quorum — which can already sign anything. The lesson: design the invariant to
    ///      cover all reachable state and constrain operators to touch only enumerated slots.
    function checkInvariant() public view {
        uint256 sum;
        uint256 total = totalShares;
        uint256 cap = (total * maxConcentrationBps) / 10_000;
        uint256 n = depositors.length;
        for (uint256 i = 0; i < n; i++) {
            uint256 s = shares[depositors[i]];
            if (s > cap) revert ConcentrationExceeded(depositors[i], s, cap);
            sum += s;
        }
        if (sum != total) revert ConservationBroken(sum, total);
        if (totalAssets < total) revert InsolventVault(totalAssets, total);
    }

    /// @notice Non-reverting health check — convenient for operators / monitoring.
    function isHealthy() external view returns (bool) {
        try this.checkInvariant() {
            return true;
        } catch {
            return false;
        }
    }

    /// @notice Number of depositors (the invariant's O(N) dimension).
    function depositorCount() external view returns (uint256) {
        return depositors.length;
    }
}
