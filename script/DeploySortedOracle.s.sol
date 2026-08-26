// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {DeployBase} from "./DeployBase.sol";
import {console} from "forge-std/Script.sol";
import {SortedOracle} from "../src/examples/sorted-oracle/SortedOracle.sol";

/// @notice Deploy SortedOracle pre-seeded with a batch of observations, so `commit()` is callable
///         immediately after deployment.
/// @dev Env: AVS_ADDRESS (optional, demo default), SIG_CHECKER_ADDRESS (optional; mock if unset),
///      OBSERVATIONS (optional, default 64) — how many observations to seed. Seeding happens in the
///      deploy transaction, so keep it modest; the point of the example is that `commit()` reads them
///      all back and sorts them, which is what an operator runs off-chain.
contract DeploySortedOracle is DeployBase {
    function run() external returns (address oracle) {
        uint256 count = vm.envOr("OBSERVATIONS", uint256(64));
        uint256[] memory seedValues = _seedObservations(count);

        vm.startBroadcast();
        address checker = _resolveChecker();
        SortedOracle deployed = new SortedOracle(_avs(), checker);
        deployed.reportBatch(seedValues);
        vm.stopBroadcast();

        oracle = address(deployed);
        console.log("SortedOracle:", oracle);
        console.log("AVS:", _avs());
        console.log("BLS checker:", checker);
        console.log("Seeded observations:", count);
    }

    /// @dev Deterministic pseudorandom observations, so a demo deployment is reproducible.
    function _seedObservations(uint256 count) internal pure returns (uint256[] memory out) {
        out = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            out[i] = uint256(keccak256(abi.encode("gas-killer-sorted-oracle", i))) % 1_000_000;
        }
    }
}
