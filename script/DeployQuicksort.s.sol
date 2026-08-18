// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {QuicksortRunner} from "../src/examples/algo/sort/Quicksort.sol";

/// @notice Deploy the pure Quicksort runner.
/// @dev No AVS or BLS checker is wired here: `QuicksortRunner` has no storage and inherits no Gas
///      Killer state, so there is nothing for a quorum to settle. It exists to make the algorithm's
///      on-chain cost measurable as a real transaction. The contract that settles the *result* of a
///      sort is `SortedOracle` — see `DeploySortedOracle.s.sol`.
contract DeployQuicksort is Script {
    function run() external returns (address runner) {
        vm.startBroadcast();
        runner = address(new QuicksortRunner());
        vm.stopBroadcast();

        console.log("QuicksortRunner:", runner);
    }
}
