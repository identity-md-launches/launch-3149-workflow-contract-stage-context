// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {MarketTypes as T} from "../src/libraries/MarketTypes.sol";
import {PimdRegistry} from "../src/PimdRegistry.sol";
import {BoundaryOracle} from "../src/BoundaryOracle.sol";

contract BoundaryOracleTest is BaseTest {
    function setUp() public override {
        super.setUp();
        vm.startPrank(ADMIN);
        registry.configureAsset(imdAsset(1e18, 3000, 60)); // IMD v2
        registry.configureAsset(yoloAsset(10_000e18)); // YOLO v3
        vm.stopPrank();
        intake.configure(0.5 ether, false);
    }

    function test_constants() public view {
        assertEq(oracle.PROOF_WINDOW(), 27 hours);
        assertEq(oracle.DISPUTE_WINDOW(), 1 hours);
        assertEq(oracle.TIMEOUT(), 3 days);
        assertEq(oracle.BOND(), 10 ether);
        assertEq(oracle.INTAKE(), INTAKE);
        assertEq(address(oracle.registry()), address(registry));
        assertEq(address(oracle.verifier()), VERIFIER);
    }

    function test_provesBoundaryForEveryVersion() public {
        vm.warp(T0 + 10);
        verifier.set(2.6758e18, false);
        oracle.prove(1, T0, emptyProofs());
        assertEq(oracle.price(1, T0), 2.6758e18);
        assertEq(oracle.latestBoundary(1), T0);
        verifier.set(2.7e18, false);
        oracle.prove(2, T0, emptyProofs());
        assertEq(oracle.price(2, T0), 2.7e18);
        verifier.set(31e18, false);
        oracle.prove(3, T0, emptyProofs());
        assertEq(oracle.price(3, T0), 31e18);
        // a second proof for the same boundary is refused
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.prove(1, T0, emptyProofs());
    }

    function test_proveRejectsUnknownVersionNonBoundaryAndLateProof() public {
        vm.warp(T0 + 10);
        verifier.set(1e18, false);
        vm.expectRevert(PimdRegistry.InvalidConfiguration.selector);
        oracle.prove(9, T0, emptyProofs());
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.prove(1, T0 + 1, emptyProofs());
        vm.warp(T0 + 27 hours + 1);
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.prove(1, T0, emptyProofs());
        // an invalid proof bubbles the verifier's revert
        vm.warp(T0 + 10);
        verifier.set(1e18, true);
        vm.expectRevert(bytes("bad proof"));
        oracle.prove(1, T0, emptyProofs());
    }

    function test_oracleCostIsIntakePriceTimesHops() public {
        (uint256 per, uint256 total) = oracle.oracleCost(1);
        assertEq(per, 0.5 ether);
        assertEq(total, 1 ether);
        (, total) = oracle.oracleCost(3);
        assertEq(total, 1.5 ether);
        intake.configure(1.25 ether, false);
        (per, total) = oracle.oracleCost(3);
        assertEq(per, 1.25 ether);
        assertEq(total, 3.75 ether);
        intake.configure(4 ether, false);
        vm.expectRevert(BoundaryOracle.InvalidPayment.selector);
        oracle.oracleCost(3);
        vm.expectRevert(PimdRegistry.InvalidConfiguration.selector);
        oracle.oracleCost(9);
    }

    function test_proposeAndFinalizeUnchallenged() public {
        imd.mint(alice, 100 ether);
        vm.prank(alice);
        imd.approve(address(oracle), type(uint256).max);
        vm.warp(T0 + 27 hours + 1);
        vm.roll(20_000_100);
        vm.prank(alice);
        oracle.propose(1, T0, 3e18, 20_000_000);
        assertEq(imd.balanceOf(address(oracle)), 10 ether);
        assertTrue(oracle.priceable(1, T0));
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.finalize(1, T0);
        vm.warp(T0 + 28 hours + 1);
        oracle.finalize(1, T0);
        assertEq(oracle.price(1, T0), 3e18);
        assertEq(oracle.credit(alice), 10 ether);
        vm.prank(alice);
        oracle.withdrawCredit();
        assertEq(imd.balanceOf(alice), 100 ether);
    }

    function test_proposeRejectedInsideProofWindow() public {
        imd.mint(alice, 100 ether);
        vm.prank(alice);
        imd.approve(address(oracle), type(uint256).max);
        vm.warp(T0 + 26 hours);
        vm.roll(20_000_100);
        vm.prank(alice);
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.propose(1, T0, 3e18, 20_000_000);
    }

    function test_disputeAsksTheIntakeOnceperHop() public {
        imd.mint(alice, 100 ether);
        imd.mint(bob, 100 ether);
        vm.prank(alice);
        imd.approve(address(oracle), type(uint256).max);
        vm.prank(bob);
        imd.approve(address(oracle), type(uint256).max);
        vm.warp(T0 + 27 hours + 1);
        vm.roll(20_000_100);
        vm.prank(alice);
        oracle.propose(3, T0, 3e18, 20_000_000);
        vm.prank(bob);
        oracle.dispute(3, T0, 2 ether);
        assertEq(intake.idCount(), 3);
        assertEq(intake.pulled(), 1.5 ether);
        assertEq(oracle.credit(bob), 0.5 ether);
    }
}
