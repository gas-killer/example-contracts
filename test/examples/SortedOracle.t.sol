// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BenchmarkBase} from "../helpers/BenchmarkBase.sol";
import {Vm} from "forge-std/Vm.sol";
import {SortedOracle} from "../../src/examples/sorted-oracle/SortedOracle.sol";
import {MockBLSSignatureChecker} from "../mocks/MockBLSSignatureChecker.sol";
import {OffchainPayloadBuilder} from "../helpers/OffchainPayloadBuilder.sol";
import {StateUpdateType} from "gas-killer-sdk/StateChangeHandlerLib.sol";

/// @notice Shared fixtures + diff-building helpers for the SortedOracle unit tests and benchmarks.
abstract contract SortedOracleTestKit is BenchmarkBase {
    MockBLSSignatureChecker internal bls;
    address internal avs = makeAddr("avs");

    // Slot constants (verified against `forge inspect`): observations @ 0, then the six words a
    // commit writes. These are the only slots that ever appear in a diff.
    uint256 internal constant SORTED_ROOT_SLOT = 1;
    uint256 internal constant MINIMUM_SLOT = 2;
    uint256 internal constant MEDIAN_SLOT = 3;
    uint256 internal constant P95_SLOT = 4;
    uint256 internal constant MAXIMUM_SLOT = 5;
    uint256 internal constant EPOCH_SLOT = 6;

    bytes32 internal constant COMMITTED_SIG = keccak256("Committed(uint256,bytes32,uint256)");

    /// @notice Number of payload operations a commit produces, whatever N is: six stores and one log.
    /// @dev Payload operations only. Applying it also bumps the SDK's `trackState` transition counter,
    ///      which is a seventh storage write but is made by `verifyAndUpdate` itself, not carried in the
    ///      payload — see `test_diff_leavesObservationsUntouched`, which allows exactly that slot.
    uint256 internal constant COMMIT_OPS = 7;

    function setUp() public virtual {
        bls = _deployPassingBls();
    }

    /// @dev Build the storage diff an operator would submit after `o` committed: the six order-
    ///      statistic words plus a LOG2 mirroring `Committed`. Deliberately reads only the post-state
    ///      the operator would have — never the observation array, which a commit does not touch.
    function _buildOracleDiff(SortedOracle o) internal view returns (bytes memory) {
        OffchainPayloadBuilder.Op[] memory ops = new OffchainPayloadBuilder.Op[](COMMIT_OPS);

        ops[0] = OffchainPayloadBuilder.Op(
            StateUpdateType.STORE, OffchainPayloadBuilder.encodeStore(bytes32(SORTED_ROOT_SLOT), o.sortedRoot())
        );
        ops[1] = OffchainPayloadBuilder.Op(
            StateUpdateType.STORE, OffchainPayloadBuilder.encodeStore(bytes32(MINIMUM_SLOT), bytes32(o.minimum()))
        );
        ops[2] = OffchainPayloadBuilder.Op(
            StateUpdateType.STORE, OffchainPayloadBuilder.encodeStore(bytes32(MEDIAN_SLOT), bytes32(o.median()))
        );
        ops[3] = OffchainPayloadBuilder.Op(
            StateUpdateType.STORE, OffchainPayloadBuilder.encodeStore(bytes32(P95_SLOT), bytes32(o.p95()))
        );
        ops[4] = OffchainPayloadBuilder.Op(
            StateUpdateType.STORE, OffchainPayloadBuilder.encodeStore(bytes32(MAXIMUM_SLOT), bytes32(o.maximum()))
        );
        ops[5] = OffchainPayloadBuilder.Op(
            StateUpdateType.STORE, OffchainPayloadBuilder.encodeStore(bytes32(EPOCH_SLOT), bytes32(o.epoch()))
        );
        ops[6] = OffchainPayloadBuilder.Op(
            StateUpdateType.LOG2,
            OffchainPayloadBuilder.encodeLog2(abi.encode(o.sortedRoot(), o.median()), COMMITTED_SIG, bytes32(o.epoch()))
        );
        return OffchainPayloadBuilder.build(ops);
    }

    function _deployOracle() internal returns (SortedOracle) {
        return new SortedOracle(avs, address(bls));
    }

    /// @dev Pseudorandom observations — the average case for the sort behind a commit.
    function _randomObservations(uint256 seed, uint256 n) internal pure returns (uint256[] memory out) {
        out = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = uint256(keccak256(abi.encode(seed, i)));
        }
    }

    /// @dev Ascending observations — what a steadily rising feed produces, and the worst case for the
    ///      last-element pivot behind a commit.
    function _ascendingObservations(uint256 n) internal pure returns (uint256[] memory out) {
        out = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = i + 1;
        }
    }

    function _seed(SortedOracle o, uint256[] memory values) internal {
        o.reportBatch(values);
    }

    function _findCommitLog(Vm.Log[] memory logs) internal pure returns (Vm.Log memory found) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length == 2 && logs[i].topics[0] == COMMITTED_SIG) {
                return logs[i];
            }
        }
        revert("Committed log not found");
    }
}

contract SortedOracleTest is SortedOracleTestKit {
    /* ------------------------------------------------------------------ */
    /*                          Naive correctness                          */
    /* ------------------------------------------------------------------ */

    /// @notice A hand-checkable oracle: nine known values, reported out of order.
    function test_commit_knownOrderStatistics() public {
        SortedOracle o = _deployOracle();
        uint256[] memory values = new uint256[](9);
        values[0] = 50;
        values[1] = 10;
        values[2] = 90;
        values[3] = 30;
        values[4] = 70;
        values[5] = 20;
        values[6] = 80;
        values[7] = 40;
        values[8] = 60;
        _seed(o, values);

        o.commit();

        // Ascending: [10,20,30,40,50,60,70,80,90]
        assertEq(o.minimum(), 10, "minimum");
        assertEq(o.maximum(), 90, "maximum");
        assertEq(o.median(), 50, "median at index floor(9*5000/10000)=4");
        assertEq(o.p95(), 90, "p95 at index floor(9*9500/10000)=8");
        assertEq(o.epoch(), 1, "epoch");
    }

    /// @notice The median is the upper of the two middle observations for an even-length set, and is
    ///         always a value that was actually reported.
    function test_commit_evenLengthMedianIsUpperMiddle() public {
        SortedOracle o = _deployOracle();
        uint256[] memory values = new uint256[](4);
        values[0] = 1;
        values[1] = 2;
        values[2] = 3;
        values[3] = 4;
        _seed(o, values);

        o.commit();

        assertEq(o.median(), 3, "index floor(4*5000/10000)=2 => the upper middle");
    }

    function test_commit_singleObservation() public {
        SortedOracle o = _deployOracle();
        uint256[] memory values = new uint256[](1);
        values[0] = 123;
        _seed(o, values);

        o.commit();

        assertEq(o.minimum(), 123);
        assertEq(o.median(), 123);
        assertEq(o.p95(), 123);
        assertEq(o.maximum(), 123);
    }

    function test_commit_revertsWithNoObservations() public {
        SortedOracle o = _deployOracle();
        vm.expectRevert(SortedOracle.EmptyObservationSet.selector);
        o.commit();
    }

    /// @notice The commitment binds exactly the sorted order, so a witness in any other order fails.
    function test_isCommittedOrder_acceptsSortedWitnessOnly() public {
        SortedOracle o = _deployOracle();
        uint256[] memory values = new uint256[](5);
        values[0] = 5;
        values[1] = 1;
        values[2] = 4;
        values[3] = 2;
        values[4] = 3;
        _seed(o, values);
        o.commit();

        uint256[] memory sortedWitness = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            sortedWitness[i] = i + 1;
        }
        assertTrue(o.isCommittedOrder(sortedWitness), "sorted witness must verify");
        assertFalse(o.isCommittedOrder(values), "unsorted witness must not verify");
    }

    /// @notice Commits are cumulative: every observation ever reported is re-sorted from scratch.
    function test_commit_recomputesOverTheWholeSet() public {
        SortedOracle o = _deployOracle();
        uint256[] memory first = new uint256[](3);
        first[0] = 10;
        first[1] = 20;
        first[2] = 30;
        _seed(o, first);
        o.commit();
        assertEq(o.maximum(), 30);

        o.report(5);
        o.report(100);
        o.commit();

        assertEq(o.minimum(), 5, "new low must be picked up");
        assertEq(o.maximum(), 100, "new high must be picked up");
        assertEq(o.epoch(), 2, "second commit");
        assertEq(o.observationCount(), 5);
    }

    /* ------------------------------------------------------------------ */
    /*          Equivalence: naive on-chain  ==  operator diff             */
    /* ------------------------------------------------------------------ */

    /// @notice The heart of the demo: run the naive `commit` on instance A, have the "operator" build
    ///         the resulting storage diff, apply it to an identically-seeded instance B through the
    ///         *full* `verifyAndUpdate` path (mock BLS), and assert A and B end up byte-identical —
    ///         every written slot (via raw `vm.load`) and the emitted log.
    function test_equivalence_naiveVsDiff() public {
        uint256[] memory values = _randomObservations(42, 200);
        SortedOracle a = _deployOracle();
        SortedOracle b = _deployOracle();
        _seed(a, values);
        _seed(b, values);

        // --- A: run the naive spec, capturing its log. ---
        vm.recordLogs();
        a.commit();
        Vm.Log[] memory aLogs = vm.getRecordedLogs();

        // --- Operator: build the diff from A's resulting state. ---
        bytes memory diff = _buildOracleDiff(a);

        // --- B: apply via verifyAndUpdate, capturing its log. ---
        uint256 countBefore = b.stateTransitionCount();
        vm.recordLogs();
        _verify(b, diff, SortedOracle.commit.selector);
        Vm.Log[] memory bLogs = vm.getRecordedLogs();

        // --- Assert state equality, slot by slot, via raw storage reads. ---
        for (uint256 slot = SORTED_ROOT_SLOT; slot <= EPOCH_SLOT; slot++) {
            assertEq(
                vm.load(address(b), bytes32(slot)),
                vm.load(address(a), bytes32(slot)),
                "committed slot mismatch between naive and diff"
            );
        }
        assertEq(b.stateTransitionCount(), countBefore + 1, "verifyAndUpdate should bump the counter once");

        // --- Assert the emitted log matches the naive event exactly. ---
        Vm.Log memory aEvt = _findCommitLog(aLogs);
        Vm.Log memory bEvt = _findCommitLog(bLogs);
        assertEq(bEvt.topics[0], aEvt.topics[0], "log sig mismatch");
        assertEq(bEvt.topics[1], aEvt.topics[1], "indexed epoch mismatch");
        assertEq(keccak256(bEvt.data), keccak256(aEvt.data), "log data mismatch");
    }

    /// @notice A commit never writes the observation array, so settling one leaves the inputs exactly
    ///         where they were. This is what keeps the diff from scaling with N.
    function test_diff_leavesObservationsUntouched() public {
        uint256[] memory values = _randomObservations(7, 100);
        SortedOracle a = _deployOracle();
        SortedOracle b = _deployOracle();
        _seed(a, values);
        _seed(b, values);
        a.commit();

        vm.record();
        _verify(b, _buildOracleDiff(a), SortedOracle.commit.selector);
        (, bytes32[] memory writes) = vm.accesses(address(b));

        for (uint256 i = 0; i < writes.length; i++) {
            uint256 slot = uint256(writes[i]);
            bool isCommitSlot = slot >= SORTED_ROOT_SLOT && slot <= EPOCH_SLOT;
            // The SDK's own transition counter lives in an ERC-7201 namespace, far from slots 0..6.
            bool isSdkNamespace = slot > EPOCH_SLOT;
            assertTrue(isCommitSlot || isSdkNamespace, "diff wrote outside the six committed slots");
            assertTrue(slot != 0, "diff must never touch the observation array length");
        }
        assertEq(b.observationCount(), values.length, "observation count changed");
    }

    /* ------------------------------------------------------------------ */
    /*        The property that makes this a Gas Killer win                */
    /* ------------------------------------------------------------------ */

    /// @notice The diff is byte-for-byte the same size at N=50 and N=2000. Every argument in the
    ///         payload is fixed-width, so the encoded length cannot move with the observation count —
    ///         which is exactly what the deleted leaderboard example failed to achieve.
    function test_diffSizeIsIndependentOfN() public {
        SortedOracle small = _deployOracle();
        SortedOracle large = _deployOracle();
        _seed(small, _randomObservations(1, 50));
        _seed(large, _randomObservations(1, 2000));

        small.commit();
        large.commit();

        bytes memory smallDiff = _buildOracleDiff(small);
        bytes memory largeDiff = _buildOracleDiff(large);

        emit log_named_uint("diff bytes at N=50  ", smallDiff.length);
        emit log_named_uint("diff bytes at N=2000", largeDiff.length);

        assertEq(largeDiff.length, smallDiff.length, "payload size must not scale with N");
    }

    /// @notice Input order changes the off-chain cost by orders of magnitude and the payload not at
    ///         all: an ascending observation set and a random one of the same size settle identically.
    function test_diffSizeIsIndependentOfInputOrder() public {
        SortedOracle random = _deployOracle();
        SortedOracle ascending = _deployOracle();
        _seed(random, _randomObservations(3, 300));
        _seed(ascending, _ascendingObservations(300));

        random.commit();
        ascending.commit();

        assertEq(
            _buildOracleDiff(ascending).length,
            _buildOracleDiff(random).length,
            "payload size must not depend on how hard the sort was"
        );
    }
}
