// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {GasKillerSDK} from "gas-killer-sdk/GasKillerSDK.sol";

/// @title Hybrid-dispatch fixtures
/// @notice Test-only consumers that exercise the two cases the prestate fast-path must dispatch on:
///         a cross-contract regular CALL (→ structLogs fallback, CALL-op replay) and a transparent
///         DELEGATECALL into a storage library (→ prestate fast-path). They let the e2e prove the
///         extractor "does everything the structLogs version does", end to end through `verifyAndUpdate`.

/// @dev An ordinary external contract the consumer CALLs. Its storage can only be reproduced on-chain by
///      re-executing the call (a CALL op) — not by extracting its slots.
contract Sink {
    uint256 public total;

    event Recorded(address indexed by, uint256 amount);

    function record(uint256 amt) external {
        total += amt;
        emit Recorded(msg.sender, amt);
    }
}

/// @dev Consumer whose tracked fn writes its OWN storage, emits a log, then makes a regular CALL to a
///      Sink. The extractor must FALL BACK to structLogs: [STORE localCount, LOG Poked, CALL sink.record].
contract CrossConsumer is GasKillerSDK {
    uint256 public localCount; // slot 0
    Sink public sink; // slot 1

    event Poked(uint256 amt);

    constructor(address avs, address bls, Sink _sink) {
        _setAvsAddress(avs);
        _setBlsSignatureChecker(bls);
        sink = _sink;
    }

    function poke(uint256 amt) external trackState {
        localCount += amt;
        emit Poked(amt);
        sink.record(amt); // regular CALL → forces the structLogs fallback
    }

    function applyDiff(bytes calldata storageUpdates) external {
        _stateChangeHandler(storageUpdates);
    }
}

/// @dev A library invoked by DELEGATECALL: it writes slot 0 in the CALLER's storage context and emits a
///      log from the caller's address — exactly the "transparent" case the prestate path must include.
contract StorageLib {
    event Bumped(uint256 delta);

    function bump(uint256 delta) external {
        assembly {
            sstore(0, add(sload(0), delta))
        }
        emit Bumped(delta);
    }
}

/// @dev A library that emits a log mid-execution via DELEGATECALL — used to build the interleaved
///      ordering case (consumer log, then this, then consumer log).
contract OrderLib {
    event Mid(uint256 v);

    function mid(uint256 v) external {
        emit Mid(v);
    }
}

/// @dev Emits First, then DELEGATECALLs OrderLib (emits Mid from the consumer's context), then emits
///      Last. True emission order is First, Mid, Last — the case where naive parent-first DFS would
///      wrongly yield First, Last, Mid. Still prestate-eligible (delegatecall is transparent).
contract OrderConsumer is GasKillerSDK {
    uint256 public n; // slot 0
    address public lib; // slot 1

    event First(uint256 v);
    event Last(uint256 v);

    constructor(address avs, address bls, address _lib) {
        _setAvsAddress(avs);
        _setBlsSignatureChecker(bls);
        lib = _lib;
    }

    function go(uint256 v) external trackState {
        emit First(v);
        n += v;
        (bool ok,) = lib.delegatecall(abi.encodeWithSignature("mid(uint256)", v));
        require(ok, "delegatecall failed");
        emit Last(v);
    }

    function applyDiff(bytes calldata storageUpdates) external {
        _stateChangeHandler(storageUpdates);
    }
}

/// @dev Consumer whose tracked fn DELEGATECALLs StorageLib. The write lands on the consumer's own slot 0
///      and the log is emitted from the consumer — so the prestate fast-path applies:
///      [STORE value, LOG Bumped]. No CALL op, no cross-contract storage.
contract DelegateConsumer is GasKillerSDK {
    uint256 public value; // slot 0 (written via delegatecall)
    address public lib; // slot 1

    constructor(address avs, address bls, address _lib) {
        _setAvsAddress(avs);
        _setBlsSignatureChecker(bls);
        lib = _lib;
    }

    function bump(uint256 delta) external trackState {
        (bool ok,) = lib.delegatecall(abi.encodeWithSignature("bump(uint256)", delta));
        require(ok, "delegatecall failed");
    }

    function applyDiff(bytes calldata storageUpdates) external {
        _stateChangeHandler(storageUpdates);
    }
}
