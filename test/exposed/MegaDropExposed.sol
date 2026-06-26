// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {MegaDrop} from "../../src/examples/megadrop/MegaDrop.sol";

/// @notice Test-only subclass exposing the internal diff applier for isolated gas measurement.
contract MegaDropExposed is MegaDrop {
    constructor(address avs, address bls, string memory n, string memory s, uint8 d) MegaDrop(avs, bls, n, s, d) {}

    function applyDiff(bytes calldata storageUpdates) external {
        _stateChangeHandler(storageUpdates);
    }
}
