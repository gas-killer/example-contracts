// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {DiffApplier} from "./DiffApplier.sol";
import {SortedOracle} from "../../src/examples/sorted-oracle/SortedOracle.sol";

/// @notice Test-only subclass exposing the internal diff applier so benchmarks can measure the
///         cost of applying a storage diff (under the SDK's storage guard and call policy) in isolation
///         from quorum verification. See `DiffApplier`, which mirrors the SDK's private settlement
///         handler.
contract SortedOracleExposed is SortedOracle, DiffApplier {
    constructor(address avs, address registry) SortedOracle(avs, registry) {}
}
