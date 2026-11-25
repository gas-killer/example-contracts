// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {DiffApplier} from "./DiffApplier.sol";
import {SortedOracle} from "../../src/examples/sorted-oracle/SortedOracle.sol";

/// @notice Test-only subclass exposing the internal diff applier so benchmarks can measure the pure
///         cost of applying a storage diff (raw sstore/log) in isolation from quorum verification.
///         Mirrors the SDK's own `GasKillerSDKExposed.stateChangeHandlerExternal`.
contract SortedOracleExposed is SortedOracle, DiffApplier {
    constructor(address avs, address registry) SortedOracle(avs, registry) {}
}
