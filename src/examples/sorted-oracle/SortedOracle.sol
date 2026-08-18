// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {GasKillerSDK} from "gas-killer-sdk/GasKillerSDK.sol";
import {Quicksort} from "../algo/sort/Quicksort.sol";

/// @title SortedOracle
/// @notice An oracle that publishes order statistics — median, p95, min, max — over **every**
///         observation ever reported to it, recomputed from scratch on each commit by sorting the
///         whole set. It is the consumer half of the `Quicksort` example: the algorithm supplies
///         unbounded, storage-free compute, and this contract supplies the small diff that makes
///         that compute settleable.
///
///         THE SHAPE GAS KILLER REWARDS. `commit()` reads all N observations, sorts them, and writes
///         six words: a commitment to the sorted order plus four order statistics and an epoch
///         counter. Both halves of its cost — the N storage reads and the O(N log N) (or O(N^2), see
///         below) sort — are invisible to a Gas Killer payload, which can only carry `STORE`,
///         `LOG*`, `CALL` and `CREATE` operations. So the settled cost is six stores and one log
///         *regardless of N*, while the on-chain cost grows without bound. Contrast the deleted
///         leaderboard example, which sorted and then wrote the sorted array: there the diff grew
///         with the work and Gas Killer was a net loss.
///
///         THE WORST CASE IS ORDINARY DATA. `Quicksort` uses a last-element pivot, so an ascending
///         observation set degrades it to O(N^2). A price feed that rises steadily produces exactly
///         that. On-chain this is a denial-of-service surface — a reporter can make `commit()`
///         unminable without submitting anything anomalous. Off-chain the same input costs an
///         operator some seconds and the chain nothing, and the diff is byte-identical either way.
///
///         The sorted array itself is never stored: `sortedRoot` commits to it, and a consumer that
///         needs the full order passes it back as a calldata witness for `isCommittedOrder` to check.
///         Keeping expanded state in calldata and only its hash in storage is what lets the diff stay
///         flat while the computation behind it does not.
///
/// @dev Storage layout (verify with `forge inspect ... storage-layout`): `observations` is declared
///      first, so its length is slot 0 and element `i` lives at `keccak256(abi.encode(0)) + i`;
///      `sortedRoot` @ 1, `minimum` @ 2, `median` @ 3, `p95` @ 4, `maximum` @ 5, `epoch` @ 6.
///      `commit()` writes only slots 1..6 — never the observation array — which is why the diff does
///      not scale with N. GasKillerSDK's own state lives in ERC-7201 namespaces.
contract SortedOracle is GasKillerSDK {
    /// @notice Every observation ever reported, in arrival order. DECLARED FIRST so its base slot is 0.
    uint256[] public observations;

    /// @notice `keccak256(abi.encodePacked(sortedObservations))` as of the last commit. Slot 1.
    bytes32 public sortedRoot;
    /// @notice Smallest observation as of the last commit. Slot 2.
    uint256 public minimum;
    /// @notice Median observation as of the last commit. Slot 3.
    uint256 public median;
    /// @notice 95th-percentile observation as of the last commit. Slot 4.
    uint256 public p95;
    /// @notice Largest observation as of the last commit. Slot 5.
    uint256 public maximum;
    /// @notice Number of commits so far. Slot 6.
    uint256 public epoch;

    /// @notice Emitted by each commit with the new epoch, order commitment and median.
    /// @dev One indexed param => the EVM log has 2 topics (sig + epoch), so the operator's equivalent
    ///      diff uses a LOG2 op: data = abi.encode(sortedRoot, median), topics = [sig, epoch].
    event Committed(uint256 indexed epoch, bytes32 sortedRoot, uint256 median);

    error EmptyObservationSet();

    /// @param _avsAddress AVS service-manager address (scopes the Gas Killer namespace).
    /// @param _blsSigChecker BLS signature checker used by `verifyAndUpdate`.
    constructor(address _avsAddress, address _blsSigChecker) {
        _setAvsAddress(_avsAddress);
        _setBlsSignatureChecker(_blsSigChecker);
    }

    /// @notice Record one observation. O(1); not the focus of the example.
    function report(uint256 value) external {
        observations.push(value);
    }

    /// @notice Record many observations in one transaction.
    function reportBatch(uint256[] calldata values) external {
        for (uint256 i = 0; i < values.length; i++) {
            observations.push(values[i]);
        }
    }

    /// @notice Recompute every order statistic from scratch and commit to the sorted order.
    /// @dev THIS IS THE NAIVE, GAS-EXPLOSIVE SPEC. It is what tests execute to derive the expected
    ///      post-state and what the benchmarks measure; in production the operator quorum runs it
    ///      off-chain and submits the six-word diff via `verifyAndUpdate`. Nothing here is
    ///      incrementalized on purpose: the whole set is re-read and re-sorted on every commit, which
    ///      is precisely the work that costs nothing once it moves off-chain.
    function commit() external trackState {
        uint256 n = observations.length;
        if (n == 0) revert EmptyObservationSet();

        uint256[] memory values = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            values[i] = observations[i];
        }
        Quicksort.sort(values);

        sortedRoot = keccak256(abi.encodePacked(values));
        minimum = values[0];
        median = _quantile(values, 5_000);
        p95 = _quantile(values, 9_500);
        maximum = values[n - 1];
        epoch += 1;

        emit Committed(epoch, sortedRoot, median);
    }

    /// @notice Whether `witness` is exactly the sorted observation set the last commit committed to.
    /// @dev The counterpart to never storing the sorted array: a consumer that needs the full order
    ///      supplies it as calldata and this check binds it to `sortedRoot`. O(N) in calldata, but no
    ///      storage is read beyond the single commitment word.
    function isCommittedOrder(uint256[] calldata witness) external view returns (bool) {
        return keccak256(abi.encodePacked(witness)) == sortedRoot;
    }

    /// @notice Number of observations recorded so far (the sort's N).
    function observationCount() external view returns (uint256) {
        return observations.length;
    }

    /// @dev Nearest-rank quantile: the element at index `floor(n * bps / 10000)` of the ascending
    ///      array, clamped to the last element. No interpolation between neighbours, so every
    ///      published statistic is itself a reported observation rather than a synthesised value.
    ///      For an even-length set this makes `median` the upper of the two middle observations.
    function _quantile(uint256[] memory ascending, uint256 bps) private pure returns (uint256) {
        uint256 n = ascending.length;
        uint256 idx = (n * bps) / 10_000;
        if (idx >= n) idx = n - 1;
        return ascending[idx];
    }
}
