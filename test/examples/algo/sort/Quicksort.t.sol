// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Quicksort, QuicksortRunner} from "../../../../src/examples/algo/sort/Quicksort.sol";

/// @notice Shared fixtures for the Quicksort unit tests and benchmarks: input generators and an
///         independent reference sort to check results against.
abstract contract QuicksortTestKit is Test {
    QuicksortRunner internal runner;

    function setUp() public virtual {
        runner = new QuicksortRunner();
    }

    /// @dev Insertion sort, written separately from the implementation under test so a shared bug
    ///      cannot make both agree. O(N^2), so only used on small arrays.
    function _referenceSort(uint256[] memory data) internal pure returns (uint256[] memory out) {
        out = new uint256[](data.length);
        for (uint256 i = 0; i < data.length; i++) {
            out[i] = data[i];
        }
        for (uint256 i = 1; i < out.length; i++) {
            uint256 key = out[i];
            uint256 j = i;
            while (j != 0 && out[j - 1] > key) {
                out[j] = out[j - 1];
                j--;
            }
            out[j] = key;
        }
    }

    function _random(uint256 seed, uint256 n) internal pure returns (uint256[] memory data) {
        data = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            data[i] = uint256(keccak256(abi.encode(seed, i)));
        }
    }

    function _ascending(uint256 n) internal pure returns (uint256[] memory data) {
        data = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            data[i] = i;
        }
    }

    function _descending(uint256 n) internal pure returns (uint256[] memory data) {
        data = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            data[i] = n - i;
        }
    }

    function _constant(uint256 n, uint256 value) internal pure returns (uint256[] memory data) {
        data = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            data[i] = value;
        }
    }

    function _assertAscending(uint256[] memory data, string memory label) internal pure {
        for (uint256 i = 1; i < data.length; i++) {
            assertLe(data[i - 1], data[i], label);
        }
    }

    /// @dev Sortedness alone is satisfiable by an array of zeroes, so every correctness test also
    ///      checks the result is a permutation of the input — compared elementwise against the
    ///      reference sort, which is a permutation by construction.
    function _assertPermutationOf(uint256[] memory result, uint256[] memory original) internal pure {
        uint256[] memory expected = _referenceSort(original);
        assertEq(result.length, expected.length, "length changed");
        for (uint256 i = 0; i < expected.length; i++) {
            assertEq(result[i], expected[i], "element mismatch vs reference sort");
        }
    }
}

contract QuicksortTest is QuicksortTestKit {
    /* ------------------------------------------------------------------ */
    /*                            Degenerate sizes                         */
    /* ------------------------------------------------------------------ */

    function test_empty() public pure {
        uint256[] memory data = new uint256[](0);
        assertEq(Quicksort.sort(data).length, 0);
    }

    function test_single() public pure {
        uint256[] memory data = new uint256[](1);
        data[0] = 7;
        uint256[] memory out = Quicksort.sort(data);
        assertEq(out.length, 1);
        assertEq(out[0], 7);
    }

    function test_twoElements_bothOrders() public pure {
        uint256[] memory rising = new uint256[](2);
        rising[0] = 1;
        rising[1] = 2;
        Quicksort.sort(rising);
        assertEq(rising[0], 1);
        assertEq(rising[1], 2);

        uint256[] memory falling = new uint256[](2);
        falling[0] = 2;
        falling[1] = 1;
        Quicksort.sort(falling);
        assertEq(falling[0], 1);
        assertEq(falling[1], 2);
    }

    /* ------------------------------------------------------------------ */
    /*                       Input shapes that matter                      */
    /* ------------------------------------------------------------------ */

    function test_randomInput() public pure {
        uint256[] memory data = _random(1, 200);
        uint256[] memory original = _random(1, 200);
        Quicksort.sort(data);
        _assertAscending(data, "random not ascending");
        _assertPermutationOf(data, original);
    }

    /// @notice Already-ascending input is the last-element pivot's worst case; it must still produce
    ///         the right answer, just slowly.
    function test_alreadyAscending() public pure {
        uint256[] memory data = _ascending(300);
        Quicksort.sort(data);
        _assertAscending(data, "ascending input not ascending");
        for (uint256 i = 0; i < 300; i++) {
            assertEq(data[i], i, "ascending input must be unchanged");
        }
    }

    function test_descending() public pure {
        uint256[] memory data = _descending(300);
        uint256[] memory original = _descending(300);
        Quicksort.sort(data);
        _assertAscending(data, "descending input not ascending");
        _assertPermutationOf(data, original);
    }

    /// @notice All-equal input drives Lomuto's `<=` comparison to maximally unbalanced partitions.
    function test_allEqual() public pure {
        uint256[] memory data = _constant(300, 42);
        Quicksort.sort(data);
        for (uint256 i = 0; i < 300; i++) {
            assertEq(data[i], 42, "all-equal element changed");
        }
    }

    function test_duplicatesPreserved() public pure {
        uint256[] memory data = new uint256[](9);
        data[0] = 5;
        data[1] = 1;
        data[2] = 5;
        data[3] = 3;
        data[4] = 1;
        data[5] = 5;
        data[6] = 9;
        data[7] = 3;
        data[8] = 1;
        uint256[] memory original = new uint256[](9);
        for (uint256 i = 0; i < 9; i++) {
            original[i] = data[i];
        }

        Quicksort.sort(data);
        _assertAscending(data, "duplicates not ascending");
        _assertPermutationOf(data, original);
    }

    /// @notice The full uint256 range must sort correctly — no signed comparison, no truncation.
    function test_extremeValues() public pure {
        uint256[] memory data = new uint256[](5);
        data[0] = type(uint256).max;
        data[1] = 0;
        data[2] = type(uint256).max - 1;
        data[3] = 1;
        data[4] = type(uint256).max / 2;

        Quicksort.sort(data);

        assertEq(data[0], 0);
        assertEq(data[1], 1);
        assertEq(data[2], type(uint256).max / 2);
        assertEq(data[3], type(uint256).max - 1);
        assertEq(data[4], type(uint256).max);
    }

    /* ------------------------------------------------------------------ */
    /*                          API-level behaviour                        */
    /* ------------------------------------------------------------------ */

    /// @notice `sort` reorders the caller's array in place and returns an alias of it.
    function test_sort_mutatesInPlaceAndReturnsAlias() public pure {
        uint256[] memory data = _random(3, 32);
        uint256[] memory returned = Quicksort.sort(data);
        _assertAscending(data, "argument not sorted in place");
        for (uint256 i = 0; i < data.length; i++) {
            assertEq(returned[i], data[i], "return value must alias the argument");
        }
    }

    /// @notice `sorted` leaves the caller's array untouched.
    function test_sorted_leavesInputUntouched() public pure {
        uint256[] memory data = _random(4, 32);
        uint256[] memory before = _random(4, 32);

        uint256[] memory out = Quicksort.sorted(data);

        _assertAscending(out, "copy not sorted");
        for (uint256 i = 0; i < data.length; i++) {
            assertEq(data[i], before[i], "input array was mutated");
        }
    }

    function test_isSorted() public pure {
        assertTrue(Quicksort.isSorted(_ascending(50)), "ascending should report sorted");
        assertTrue(Quicksort.isSorted(_constant(50, 3)), "all-equal should report sorted");
        assertTrue(Quicksort.isSorted(new uint256[](0)), "empty should report sorted");
        assertFalse(Quicksort.isSorted(_descending(50)), "descending should not report sorted");
    }

    /* ------------------------------------------------------------------ */
    /*         The property the Gas Killer framing depends on              */
    /* ------------------------------------------------------------------ */

    /// @notice The claim that sorting settles for zero rests on the algorithm touching none of the
    ///         state a Gas Killer payload can carry. Assert that directly: a call that sorts 400
    ///         elements performs no storage writes, no storage reads, and emits no logs, so there is
    ///         nothing for an operator to put in a diff.
    function test_pure_touchesNoStorageAndEmitsNoLogs() public {
        vm.record();
        vm.recordLogs();

        runner.sortRandom(9, 400);

        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(address(runner));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(writes.length, 0, "a pure sort must perform no SSTORE");
        assertEq(reads.length, 0, "a pure sort must perform no SLOAD");
        assertEq(logs.length, 0, "a pure sort must emit no logs");
    }

    /* ------------------------------------------------------------------ */
    /*                                Fuzz                                 */
    /* ------------------------------------------------------------------ */

    /// @notice Any input, compared elementwise against an independently written insertion sort.
    /// @dev Truncated to 128 elements because the reference sort is O(N^2).
    function testFuzz_matchesReferenceSort(uint256[] memory raw) public pure {
        uint256 n = raw.length > 128 ? 128 : raw.length;
        uint256[] memory input = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            input[i] = raw[i];
        }
        uint256[] memory result = Quicksort.sorted(input);

        _assertAscending(result, "fuzz result not ascending");
        _assertPermutationOf(result, input);
    }

    /// @notice Sorting an already-sorted array is a no-op, whatever the input was.
    function testFuzz_idempotent(uint256[] memory raw) public pure {
        uint256 n = raw.length > 128 ? 128 : raw.length;
        uint256[] memory input = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            input[i] = raw[i];
        }

        uint256[] memory once = Quicksort.sorted(input);
        uint256[] memory twice = Quicksort.sorted(once);
        for (uint256 i = 0; i < n; i++) {
            assertEq(twice[i], once[i], "sorting a sorted array changed it");
        }
    }

    /// @notice The deployed wrapper agrees with the library for caller-supplied arrays.
    function testFuzz_runnerMatchesLibrary(uint256[] memory raw) public view {
        uint256 n = raw.length > 128 ? 128 : raw.length;
        uint256[] memory input = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            input[i] = raw[i];
        }

        uint256[] memory viaRunner = runner.sort(input);
        uint256[] memory viaLibrary = Quicksort.sorted(input);
        for (uint256 i = 0; i < n; i++) {
            assertEq(viaRunner[i], viaLibrary[i], "runner and library disagree");
        }
    }
}
