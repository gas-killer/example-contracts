// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {DeployBase} from "./DeployBase.sol";
import {console} from "forge-std/Script.sol";
import {CompressedArchive} from "../src/examples/compressed-archive/CompressedArchive.sol";

/// @notice Deploy CompressedArchive, optionally seeding it with one archived blob.
/// @dev Env: AVS_ADDRESS (optional, demo default), SIG_CHECKER_ADDRESS (optional; mock if unset),
///      SEED_BYTES (optional, default 256) — size of the blob to archive in the deploy transaction,
///      or 0 to skip seeding.
///
///      KEEP SEED_BYTES SMALL. Seeding runs the naive `archive` on-chain, and that is the O(N^2)
///      search this example exists to move off-chain: past roughly 390 bytes it will not fit in a
///      mainnet block, and it is slow even on a local anvil with a raised gas limit. The point of
///      the example is that operators run this off-chain and submit the compressed diff, so a large
///      seed is not a better demo — it is the exact thing the demo says not to do.
contract DeployCompressedArchive is DeployBase {
    function run() external returns (address archive) {
        uint256 seedBytes = vm.envOr("SEED_BYTES", uint256(256));

        vm.startBroadcast();
        address checker = _resolveChecker();
        CompressedArchive deployed = new CompressedArchive(_avs(), checker);
        if (seedBytes != 0) {
            deployed.archive(_seedBlob(seedBytes));
        }
        vm.stopBroadcast();

        archive = address(deployed);
        console.log("CompressedArchive:", archive);
        console.log("AVS:", _avs());
        console.log("BLS checker:", checker);
        if (seedBytes != 0) {
            console.log("Seeded raw bytes:", seedBytes);
            console.log("Stored bytes:", deployed.storedBlob(0).length);
        }
    }

    /// @dev Zero-padded 32-byte words holding small integers — the shape real archived calldata
    ///      takes, and one that compresses well, so a demo deployment shows a meaningful ratio.
    function _seedBlob(uint256 size) internal pure returns (bytes memory blob) {
        blob = new bytes(size);
        for (uint256 i = 31; i < size; i += 32) {
            blob[i] = bytes1(uint8((i / 32) % 7));
        }
    }
}
