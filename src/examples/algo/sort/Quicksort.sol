// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @title Quicksort
/// @notice In-memory quicksort, written **greedily on purpose**: every element comparison, swap and
///         index calculation is executed, none of it is traded away for a cheaper shape. It touches
///         no storage, emits no logs and makes no external calls, so it is `pure` in the strict
///         Solidity sense and — more importantly here — invisible to Gas Killer's cost model.
///
///         WHY THAT MATTERS. A Gas Killer payload is a list of `STORE` / `LOG*` / `CALL` / `CREATE`
///         operations, and the analyzer prices exactly those. Memory traffic, arithmetic, comparisons
///         and jumps are not representable in a payload and are therefore never paid for on-chain:
///         they are the work the operator quorum absorbs off-chain. An algorithm that lives entirely
///         on those opcodes has a settlement cost of *zero* — it contributes nothing to the diff no
///         matter how much work it does. That is what "optimized for Gas Killer" means, and it is the
///         opposite of what optimizing for the EVM usually means: do not hoist work into storage, do
///         not precompute, do not cache across calls. Recompute everything, every time, in memory.
///
///         Consumers pair this with a `trackState` function that reduces the sorted result to a small
///         commitment — see `SortedOracle`, which sorts N observations and writes six words.
///
/// @dev ITERATIVE, WITH AN EXPLICIT MEMORY STACK. A recursive quicksort would be shorter, but its
///      depth is bounded by the EVM stack, so the very inputs this example exists to demonstrate —
///      the ones that drive partitioning to its O(N^2) worst case — would revert instead of running.
///      Ranges are held in a `uint256[]` used as a stack of `[lo, hi]` pairs, so depth is bounded by
///      memory rather than by the interpreter.
///
///      LOMUTO PARTITION, LAST-ELEMENT PIVOT. This is the textbook pivot, and it is chosen here for
///      its failure mode rather than in spite of it: on input that is already ascending, already
///      descending, or entirely equal, it splits off one element per pass and degrades to O(N^2).
///      Those are not exotic adversarial inputs — a slowly rising price feed is already sorted — so
///      on-chain this pivot is a griefing vector, and off-chain it is free. A production sort that
///      had to run on-chain would use median-of-three and an insertion-sort cutoff for small ranges.
library Quicksort {
    /// @notice Sort `data` ascending, in place, and return the same array.
    /// @dev Memory arrays are reference types, so the return value aliases the argument: the caller's
    ///      array is reordered. Use `sorted` when the input must survive.
    /// @param data The array to reorder.
    /// @return The same array, ascending.
    function sort(uint256[] memory data) internal pure returns (uint256[] memory) {
        uint256 n = data.length;
        if (n < 2) return data;

        // Only ranges of two or more elements are ever pushed, and pending ranges are disjoint
        // sub-intervals of [0, n), so at most floor(n/2) of them can be outstanding at once. Two
        // words per range gives a hard bound of n, plus slack for the initial pair.
        uint256[] memory stack = new uint256[](n + 2);
        uint256 sp;

        stack[sp++] = 0;
        stack[sp++] = n - 1;

        while (sp != 0) {
            uint256 hi = stack[--sp];
            uint256 lo = stack[--sp];

            uint256 p = _partition(data, lo, hi);

            // Push each side only when it still holds two or more elements; a range of one is
            // already sorted, which is what keeps the stack bound above valid.
            if (p > lo + 1) {
                stack[sp++] = lo;
                stack[sp++] = p - 1;
            }
            if (hi > p + 1) {
                stack[sp++] = p + 1;
                stack[sp++] = hi;
            }
        }
        return data;
    }

    /// @notice Sort a copy of `data` ascending, leaving the caller's array untouched.
    /// @param data The array to copy and sort.
    /// @return out A newly allocated ascending copy.
    function sorted(uint256[] memory data) internal pure returns (uint256[] memory out) {
        uint256 n = data.length;
        out = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = data[i];
        }
        return sort(out);
    }

    /// @notice Whether `data` is in non-decreasing order.
    /// @dev O(N) and cheap relative to sorting, so a consumer can assert order on a witness array
    ///      rather than re-sorting it.
    function isSorted(uint256[] memory data) internal pure returns (bool) {
        for (uint256 i = 1; i < data.length; i++) {
            if (data[i - 1] > data[i]) return false;
        }
        return true;
    }

    /// @dev Lomuto partition of `data[lo..hi]` around the last element. Elements less than or equal
    ///      to the pivot are swapped to the front; the pivot is then swapped into the boundary and
    ///      its final index returned. `lo < hi` is guaranteed by the push conditions in `sort`.
    ///
    ///      Comparing with `<=` rather than `<` is what makes an all-equal array a worst case: every
    ///      element is moved, the boundary walks to `hi`, and each pass peels off exactly one
    ///      element. Preserved deliberately — see the contract-level note on the pivot choice.
    function _partition(uint256[] memory data, uint256 lo, uint256 hi) private pure returns (uint256) {
        uint256 pivot = data[hi];
        uint256 boundary = lo;
        for (uint256 j = lo; j < hi; j++) {
            if (data[j] <= pivot) {
                (data[boundary], data[j]) = (data[j], data[boundary]);
                boundary++;
            }
        }
        (data[boundary], data[hi]) = (data[hi], data[boundary]);
        return boundary;
    }
}

/// @title QuicksortRunner
/// @notice Deployable wrapper around the `Quicksort` library, so the algorithm's on-chain cost can be
///         measured as a real transaction rather than only inside a test harness. Every entry point
///         is `pure`: this contract has no storage, and a call to it can never produce a Gas Killer
///         payload operation. Its whole cost is the work Gas Killer prices at zero.
/// @dev The two sweep helpers generate their own input instead of taking it as calldata. Calldata is
///      charged per byte on both the naive and the settled path, so including it would inflate both
///      sides of a benchmark with a cost that has nothing to do with sorting, and would cap N at
///      whatever fits in a transaction. They return a digest rather than the array for the same
///      reason: ABI-encoding N words back to the caller is measurable work that is not the sort.
contract QuicksortRunner {
    /// @notice Sort a caller-supplied array ascending.
    /// @param data The values to sort.
    /// @return out A newly allocated ascending array.
    function sort(uint256[] calldata data) external pure returns (uint256[] memory out) {
        uint256 n = data.length;
        out = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = data[i];
        }
        Quicksort.sort(out);
    }

    /// @notice Sort `n` pseudorandom values derived from `seed`; returns a digest of the result.
    /// @dev The average case: partitions stay roughly balanced, so the cost tracks O(N log N).
    function sortRandom(uint256 seed, uint256 n) external pure returns (bytes32) {
        uint256[] memory data = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            data[i] = uint256(keccak256(abi.encode(seed, i)));
        }
        return keccak256(abi.encodePacked(Quicksort.sort(data)));
    }

    /// @notice Sort `n` values that are already ascending; returns a digest of the result.
    /// @dev The worst case for a last-element pivot: every pass peels off a single element, so the
    ///      cost tracks O(N^2) even though the array is already in the answer's order. On-chain this
    ///      is a denial-of-service surface — ordinary monotonic data is enough to trigger it. Through
    ///      Gas Killer the same input costs an operator time and the chain nothing.
    function sortAdversarial(uint256 n) external pure returns (bytes32) {
        uint256[] memory data = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            data[i] = i;
        }
        return keccak256(abi.encodePacked(Quicksort.sort(data)));
    }
}
