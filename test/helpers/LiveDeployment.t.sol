// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {LiveDeployment} from "./LiveDeployment.sol";

/// @dev Returns whatever wiring a test constructs it with, so each hop of
///      `LiveDeployment.resolve` can be broken in isolation without forking a chain.
contract StubConsumer {
    address public avsAddress;
    address public blsSignatureChecker;

    constructor(address avs, address checker) {
        avsAddress = avs;
        blsSignatureChecker = checker;
    }
}

contract StubChecker {
    address public registryCoordinator;

    constructor(address coordinator) {
        registryCoordinator = coordinator;
    }
}

contract StubCoordinator {
    address public stakeRegistry;

    constructor(address registry) {
        stakeRegistry = registry;
    }
}

contract StubStakeRegistry {}

/// @dev `resolve` is an internal library function, so it inlines into its caller and its reverts
///      cannot be caught by `vm.expectRevert` directly. Calling it across this external boundary
///      puts the revert in a frame the cheatcode can observe.
contract Resolver {
    function resolve(address consumer) external view returns (LiveDeployment.Wiring memory) {
        return LiveDeployment.resolve(consumer);
    }
}

/// @notice The failure mode of a rotted reference, exercised hop by hop.
///
///         `resolve` walks four getters off an address supplied from outside the repo. Without a
///         code check per hop, a torn-down deployment or a mistyped `GK_LIVE_INSTANCE` trips
///         Solidity's extcodesize guard and surfaces as a bare `EvmError: Revert` that names
///         neither the hop nor the input — worse than the `InvalidQuorumApkHash` selector the
///         derivation exists to prevent. These tests hold the library to naming the broken hop.
contract LiveDeploymentTest is Test {
    address constant NO_CODE = address(0xBAD);

    Resolver internal resolver;
    StubStakeRegistry internal stakeRegistry;
    StubCoordinator internal coordinator;
    StubChecker internal checker;

    function setUp() public {
        resolver = new Resolver();
        stakeRegistry = new StubStakeRegistry();
        coordinator = new StubCoordinator(address(stakeRegistry));
        checker = new StubChecker(address(coordinator));
    }

    function test_resolve_walksEveryHop() public {
        address consumer = address(new StubConsumer(address(this), address(checker)));

        LiveDeployment.Wiring memory w = resolver.resolve(consumer);

        assertEq(w.consumer, consumer, "consumer");
        assertEq(w.avs, address(this), "avs");
        assertEq(w.checker, address(checker), "checker");
        assertEq(w.coordinator, address(coordinator), "coordinator");
        assertEq(w.stakeRegistry, address(stakeRegistry), "stakeRegistry");
    }

    function test_resolve_namesTheReferenceItselfWhenItHasNoCode() public {
        vm.expectRevert("LiveDeployment: no code at GK_LIVE_INSTANCE; refresh it from /avs-metadata");
        resolver.resolve(NO_CODE);
    }

    function test_resolve_namesTheAvsHop() public {
        address consumer = address(new StubConsumer(NO_CODE, address(checker)));
        vm.expectRevert("LiveDeployment: no code at the consumer's avsAddress");
        resolver.resolve(consumer);
    }

    function test_resolve_namesTheCheckerHop() public {
        address consumer = address(new StubConsumer(address(this), NO_CODE));
        vm.expectRevert("LiveDeployment: no code at the consumer's blsSignatureChecker");
        resolver.resolve(consumer);
    }

    function test_resolve_namesTheCoordinatorHop() public {
        address brokenChecker = address(new StubChecker(NO_CODE));
        address consumer = address(new StubConsumer(address(this), brokenChecker));
        vm.expectRevert("LiveDeployment: no code at the checker's registryCoordinator");
        resolver.resolve(consumer);
    }

    function test_resolve_namesTheStakeRegistryHop() public {
        address brokenCoordinator = address(new StubCoordinator(NO_CODE));
        address consumer = address(new StubConsumer(address(this), address(new StubChecker(brokenCoordinator))));
        vm.expectRevert("LiveDeployment: no code at the coordinator's stakeRegistry");
        resolver.resolve(consumer);
    }

    /// @dev Skipped when the caller has pinned an override, since that is the whole point of it.
    function test_liveInstance_defaultsToTheRecordedReference() public view {
        if (vm.envOr("GK_LIVE_INSTANCE", address(0)) != address(0)) return;
        assertEq(LiveDeployment.liveInstance(), LiveDeployment.DEFAULT_LIVE_INSTANCE);
    }
}
