// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {MarketTypes as T} from "../src/libraries/MarketTypes.sol";
import {OracleRequest} from "../src/libraries/OracleRequest.sol";
import {BoundaryOracle} from "../src/BoundaryOracle.sol";
import {StartOracle} from "../src/StartOracle.sol";

contract StartOracleTest is BaseTest {
    uint64 constant FIRST = 20_000_000;

    function setUp() public override {
        super.setUp();
        intake.configure(0.5 ether, false);
        imd.mint(alice, 100 ether);
        vm.prank(alice);
        imd.approve(address(startOracle), type(uint256).max);
        vm.roll(20_000_500);
    }

    function _attestation(uint8 hop, uint256 answer, bytes32 blockHash, uint64 firstBlock)
        internal
        view
        returns (BoundaryOracle.Attestation memory a)
    {
        T.Asset memory asset = registry.asset(1);
        string memory q = OracleRequest.question(asset, hop, T0, firstBlock, address(startOracle), 1);
        a.requestId = keccak256(abi.encode("att", hop, answer));
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

    function test_requestRefusedBefore27Hours() public {
        vm.warp(T0 + 27 hours - 1);
        vm.prank(alice);
        vm.expectRevert(StartOracle.InvalidState.selector);
        startOracle.request(1, T0, FIRST);
    }

    function test_requestRefusedForNonBoundaryBadBlockUnknownVersion() public {
        vm.warp(T0 + 27 hours);
        vm.startPrank(alice);
        vm.expectRevert(StartOracle.InvalidState.selector);
        startOracle.request(1, T0 + 1, FIRST);
        vm.expectRevert(StartOracle.InvalidState.selector);
        startOracle.request(1, T0, 0);
        vm.expectRevert(StartOracle.InvalidState.selector);
        startOracle.request(1, T0, uint64(block.number - 2));
        vm.expectRevert();
        startOracle.request(7, T0, FIRST);
        vm.stopPrank();
    }

    function test_requestAt27HoursAsksOneQuestionPerHopAndCallerPays() public {
        vm.warp(T0 + 27 hours);
        vm.prank(alice);
        startOracle.request(1, T0, FIRST);
        assertEq(intake.idCount(), 2);
        assertEq(intake.pulled(), 1 ether);
        assertEq(imd.balanceOf(alice), 99 ether);
        assertEq(imd.balanceOf(address(startOracle)), 0);
        StartOracle.Pending memory p = startOracle.pending(1, T0);
        assertTrue(p.open);
        assertEq(p.requester, alice);
        assertEq(p.firstBlock, FIRST);
        // a second request while one is open is refused
        vm.prank(alice);
        vm.expectRevert(StartOracle.InvalidState.selector);
        startOracle.request(1, T0, FIRST);
    }

    function test_refusedIntakeRecordsNothing() public {
        vm.warp(T0 + 30 days);
        intake.configure(0.5 ether, true);
        vm.prank(alice);
        vm.expectRevert(bytes("intake refused"));
        startOracle.request(1, T0, FIRST);
        assertFalse(startOracle.pending(1, T0).open);
        assertEq(imd.balanceOf(alice), 100 ether);
    }

    function test_answersAt30DaysRecordTheStartPrice() public {
        vm.warp(T0 + 30 days);
        vm.prank(alice);
        startOracle.request(1, T0, FIRST);
        bytes32 id0 = intake.ids(0);
        bytes32 id1 = intake.ids(1);
        bytes32 bh = keccak256("block");
        // hop 0: pool WETH/IMD, cursor IMD = currency1 -> backward: value * HOP_BASE / answer.
        // answer0 = currency1 (IMD) per 1e36 currency0 (WETH): 1500 IMD per ETH -> 1500e36 wei-units ratio.
        uint256 a0 = 1500 * 1e36;
        // hop 1: pool WETH/USDC, cursor WETH = currency0 -> forward: value * answer / HOP_BASE.
        // answer1 = USDC atomic per 1e36 wei: 4000 USDC per ETH = 4000e6 / 1e18 * 1e36 = 4000e24.
        uint256 a1 = 4000e24;
        BoundaryOracle.Attestation memory att0 = _attestation(0, a0, bh, FIRST);
        BoundaryOracle.Attestation memory att1 = _attestation(1, a1, bh, FIRST);
        signer.accept(startOracle.digest(att0));
        signer.accept(startOracle.digest(att1));
        vm.prank(INTAKE);
        startOracle.onOracleResult(id0, att0, "");
        assertEq(startOracle.price(1, T0), 0);
        vm.prank(INTAKE);
        startOracle.onOracleResult(id1, att1, "");
        // 1 IMD = 1/1500 ETH = 4000/1500 USD = 2.666... USD at 18 decimals.
        uint256 expected = uint256(1e18) * 4000 / 1500;
        assertApproxEqAbs(startOracle.price(1, T0), expected, 1e6);
        assertFalse(startOracle.pending(1, T0).open);
        // BoundaryOracle never learns of it: StartOracle prices never settle a market.
        assertEq(oracle.price(1, T0), 0);
        // a recorded start cannot be requested again
        vm.prank(alice);
        vm.expectRevert(StartOracle.InvalidState.selector);
        startOracle.request(1, T0, FIRST);
    }

    function test_answerForWrongFirstBlockOrUnsignedIsRefused() public {
        vm.warp(T0 + 30 days);
        vm.prank(alice);
        startOracle.request(1, T0, FIRST);
        bytes32 id0 = intake.ids(0);
        bytes32 id1 = intake.ids(1);
        bytes32 bh = keccak256("block");
        BoundaryOracle.Attestation memory wrong = _attestation(0, 1500e36, bh, FIRST + 1);
        signer.accept(startOracle.digest(wrong));
        vm.prank(INTAKE);
        vm.expectRevert(StartOracle.InvalidAnswer.selector);
        startOracle.onOracleResult(id0, wrong, "");
        BoundaryOracle.Attestation memory unsigned = _attestation(0, 1500e36, bh, FIRST);
        vm.prank(INTAKE);
        vm.expectRevert(StartOracle.InvalidAnswer.selector);
        startOracle.onOracleResult(id0, unsigned, "");
        // only the intake may answer
        signer.accept(startOracle.digest(unsigned));
        vm.prank(alice);
        vm.expectRevert(StartOracle.InvalidState.selector);
        startOracle.onOracleResult(id0, unsigned, "");
    }

    function test_failureFreesTheSlotForARepeat() public {
        vm.warp(T0 + 30 days);
        vm.prank(alice);
        startOracle.request(1, T0, FIRST);
        bytes32 id0 = intake.ids(0);
        bytes32 id1 = intake.ids(1);
        vm.prank(alice);
        vm.expectRevert(StartOracle.InvalidState.selector);
        startOracle.onFailure(id0, 1, bytes32(0), 0, 0, "");
        vm.prank(INTAKE);
        startOracle.onFailure(id0, 1, bytes32(0), 0, 0, "");
        assertFalse(startOracle.pending(1, T0).open);
        assertEq(startOracle.price(1, T0), 0);
        // a late answer to the failed request is refused
        BoundaryOracle.Attestation memory att = _attestation(1, 4000e24, keccak256("b"), FIRST);
        signer.accept(startOracle.digest(att));
        vm.prank(INTAKE);
        vm.expectRevert(StartOracle.InvalidState.selector);
        startOracle.onOracleResult(id1, att, "");
        // repeatable
        vm.prank(alice);
        startOracle.request(1, T0, FIRST + 1);
        assertTrue(startOracle.pending(1, T0).open);
        assertEq(intake.pulled(), 2 ether);
    }
}
