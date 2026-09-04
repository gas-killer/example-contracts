// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {LzssRunner} from "../src/examples/algo/compress/Lzss.sol";

/// @notice Deploy the pure LZSS runner.
/// @dev No AVS or BLS checker is wired here: `LzssRunner` has no storage and inherits no Gas Killer
///      state, so there is nothing for a quorum to settle. It exists to make the algorithm's
///      on-chain cost measurable as a real transaction — and to make the point that the forward
///      direction is unaffordable past a few hundred bytes while the inverse is routine. The
///      contract that settles the *result* of a compression is `CompressedArchive` — see
///      `DeployCompressedArchive.s.sol`.
contract DeployLzss is Script {
    function run() external returns (address runner) {
        vm.startBroadcast();
        runner = address(new LzssRunner());
        vm.stopBroadcast();

        console.log("LzssRunner:", runner);
    }
}
