// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {MarketTypes as T} from "../src/libraries/MarketTypes.sol";
import {OracleRequest} from "../src/libraries/OracleRequest.sol";
import {BoundaryOracle} from "../src/BoundaryOracle.sol";
import {StartOracle} from "../src/StartOracle.sol";

/// @dev REQUEST_TTL replacement edges of StartOracle not covered by StartOracle.t.sol.
contract StartOracleTtlTest is BaseTest {
    uint64 constant FIRST = 20_000_000;
    uint256 TTL;

    function setUp() public override {
        super.setUp();
        intake.configure(0.5 ether, false);
        address[2] memory who = [alice, bob];
        for (uint256 i; i < 2; ++i) {
            imd.mint(who[i], 100 ether);
            vm.prank(who[i]);
            imd.approve(address(startOracle), type(uint256).max);
        }
        vm.roll(20_000_500);
        TTL = startOracle.REQUEST_TTL();
        vm.warp(T0 + 30 days);
    }

    function _attestation(uint8 hop, uint256 answer, bytes32 blockHash, uint64 firstBlock)
        internal
        view
        returns (BoundaryOracle.Attestation memory a)
    {
        T.Asset memory asset = registry.asset(1);
        string memory q = OracleRequest.question(asset, hop, T0, firstBlock, address(startOracle), 1);
        a.requestId = keccak256(abi.encode("ttl", hop, answer, firstBlock));
        a.chainId = 1;
        a.questionHash = OracleRequest.questionHash(q, firstBlock);
        a.answerType = 3;
        a.answer = abi.encode(answer);
        a.fromBlock = firstBlock;
        a.toBlock = firstBlock + 2;
        a.blockHash = blockHash;
        a.panelSize = 5;
        a.quorum = 4;
        a.agreed = 5;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 1 days);
    }

    function _answer(bytes32 rid, uint8 hop, uint256 answer, uint64 firstBlock) internal {
        BoundaryOracle.Attestation memory a = _attestation(hop, answer, keccak256("block"), firstBlock);
        signer.accept(startOracle.digest(a));
        vm.prank(INTAKE);
        startOracle.onOracleResult(rid, a, "");
    }

    /// @dev A failure report for a replaced request is refused and cannot close the new request.
    function test_failureOfReplacedRequestRefused() public {
        vm.prank(alice);
        startOracle.request(1, T0, FIRST);
        bytes32 old0 = intake.ids(0);
        vm.warp(block.timestamp + TTL);
        vm.prank(bob);
        startOracle.request(1, T0, FIRST + 1);
        vm.prank(INTAKE);
        vm.expectRevert(StartOracle.InvalidState.selector);
        startOracle.onFailure(old0, 1, bytes32(0), 0, 0, "");
        assertTrue(startOracle.pending(1, T0).open, "the new request stays open");
        assertEq(startOracle.pending(1, T0).requester, bob);
    }

    /// @dev A half-answered request replaced after the TTL starts over: the old answer is dropped, the
    /// old second hop is refused, and the price comes only from the new request's two answers.
    function test_partialAnswerDroppedOnReplacement() public {
        vm.prank(alice);
        startOracle.request(1, T0, FIRST);
        bytes32 old0 = intake.ids(0);
        bytes32 old1 = intake.ids(1);
        _answer(old0, 0, 1500e36, FIRST);
        assertEq(startOracle.pending(1, T0).received, 1);
        vm.warp(block.timestamp + TTL);
        vm.prank(bob);
        startOracle.request(1, T0, FIRST + 1);
        StartOracle.Pending memory p = startOracle.pending(1, T0);
        assertEq(p.received, 0, "old answer carried over");
        assertEq(p.anchorHash, bytes32(0));
        // the old second hop cannot complete anything
        BoundaryOracle.Attestation memory late = _attestation(1, 4000e24, keccak256("block"), FIRST);
        signer.accept(startOracle.digest(late));
        vm.prank(INTAKE);
        vm.expectRevert(StartOracle.InvalidState.selector);
        startOracle.onOracleResult(old1, late, "");
        assertEq(startOracle.price(1, T0), 0);
        // one answer to the new request is not a price
        _answer(intake.ids(2), 0, 2000e36, FIRST + 1);
        assertEq(startOracle.price(1, T0), 0);
        _answer(intake.ids(3), 1, 4000e24, FIRST + 1);
        assertApproxEqAbs(startOracle.price(1, T0), uint256(1e18) * 4000 / 2000, 1e6);
    }

    /// @dev Once a price is recorded no request is accepted, however long after.
    function test_noRequestAfterPriceRecorded() public {
        vm.prank(alice);
        startOracle.request(1, T0, FIRST);
        _answer(intake.ids(0), 0, 1500e36, FIRST);
        _answer(intake.ids(1), 1, 4000e24, FIRST);
        assertGt(startOracle.price(1, T0), 0);
        vm.warp(block.timestamp + TTL * 3);
        vm.prank(bob);
        vm.expectRevert(StartOracle.InvalidState.selector);
        startOracle.request(1, T0, FIRST + 1);
    }

    /// @dev Replacement repeats: each request is replaceable only after its own TTL, the replaced
    /// requester's IMD is not refunded, and every replacement is paid again in full.
    function test_replacementChainEachWaitsItsOwnTtl() public {
        vm.prank(alice);
        startOracle.request(1, T0, FIRST);
        uint256 t1 = block.timestamp + TTL;
        vm.warp(t1);
        vm.prank(bob);
        startOracle.request(1, T0, FIRST);
        // alice cannot immediately replace bob's fresh request
        vm.warp(t1 + TTL - 1);
        vm.prank(alice);
        vm.expectRevert(StartOracle.InvalidState.selector);
        startOracle.request(1, T0, FIRST);
        vm.warp(t1 + TTL);
        vm.prank(alice);
        startOracle.request(1, T0, FIRST);
        assertEq(intake.pulled(), 3 ether, "three requests, each paid 2 x 0.5 IMD");
        assertEq(imd.balanceOf(alice), 98 ether, "no refund for a replaced request");
        assertEq(imd.balanceOf(bob), 99 ether);
        assertEq(imd.balanceOf(address(startOracle)), 0, "nothing stranded in StartOracle");
        // bob's voided questions cannot answer alice's request
        BoundaryOracle.Attestation memory a = _attestation(0, 1500e36, keccak256("block"), FIRST);
        signer.accept(startOracle.digest(a));
        bytes32 bobs0 = intake.ids(2);
        vm.prank(INTAKE);
        vm.expectRevert(StartOracle.InvalidState.selector);
        startOracle.onOracleResult(bobs0, a, "");
        _answer(intake.ids(4), 0, 1500e36, FIRST);
        _answer(intake.ids(5), 1, 4000e24, FIRST);
        assertGt(startOracle.price(1, T0), 0);
    }

    /// @dev A refused request (intake reverts) records nothing even after the TTL of an earlier one:
    /// the earlier request is not voided by a replacement that failed.
    function test_refusedReplacementKeepsOldRequest() public {
        vm.prank(alice);
        startOracle.request(1, T0, FIRST);
        vm.warp(block.timestamp + TTL);
        intake.configure(0.5 ether, true);
        vm.prank(bob);
        vm.expectRevert();
        startOracle.request(1, T0, FIRST + 1);
        StartOracle.Pending memory p = startOracle.pending(1, T0);
        assertTrue(p.open);
        assertEq(p.requester, alice);
        _answer(intake.ids(0), 0, 1500e36, FIRST);
        _answer(intake.ids(1), 1, 4000e24, FIRST);
        assertGt(startOracle.price(1, T0), 0);
    }
}
