// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {DeployBase} from "./DeployBase.sol";
import {console} from "forge-std/Script.sol";
import {MegaDrop} from "../src/examples/megadrop/MegaDrop.sol";

/// @notice Deploy the MegaDrop token.
/// @dev Env: AVS_ADDRESS (optional, demo default), SIG_CHECKER_ADDRESS (optional; mock if unset),
///      TOKEN_NAME, TOKEN_SYMBOL, TOKEN_DECIMALS (optional).
contract DeployMegaDrop is DeployBase {
    function run() external returns (address token) {
        string memory name = vm.envOr("TOKEN_NAME", string("MegaToken"));
        string memory symbol = vm.envOr("TOKEN_SYMBOL", string("MEGA"));
        uint8 decimals = uint8(vm.envOr("TOKEN_DECIMALS", uint256(18)));

        vm.startBroadcast();
        address checker = _resolveChecker();
        token = address(new MegaDrop(_avs(), checker, name, symbol, decimals));
        vm.stopBroadcast();

        console.log("MegaDrop:", token);
        console.log("AVS:", _avs());
        console.log("BLS checker:", checker);
    }
}
