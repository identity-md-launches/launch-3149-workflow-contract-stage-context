// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {PimdAbove} from "../src/PimdAbove.sol";

/// @dev Failure paths and edges of PimdAbove not covered by PimdAbove.t.sol.
contract PimdAboveFailuresTest is BaseTest {
    PimdAbove above;
    bytes32 mid;
    uint64 END;
    address carol = makeAddr("carol");

    function setUp() public override {
        super.setUp();
        above = new PimdAbove(registry, oracle, ADMIN, OWNER);
        END = T0 + 1 hours;
        vm.prank(ADMIN);
        mid = above.createMarket(1, 0, END, 3e18);
        address[3] memory who = [alice, bob, vika];
        for (uint256 i; i < 3; ++i) {
            usdc.mint(who[i], 1000e6);
            vm.startPrank(who[i]);
            usdc.approve(address(above), type(uint256).max);
            above.deposit(1000e6);
            vm.stopPrank();
        }
    }

    function _in(bool yes, bool buy, uint128 qty, uint128 price) internal view returns (PimdAbove.OrderInput memory) {
        return PimdAbove.OrderInput(yes, buy, qty, 0, price, uint64(block.timestamp + 1 days), false);
    }

    function _settle(uint256 close) internal {
        vm.warp(END + 1);
        verifier.set(close, false);
        oracle.prove(1, END, emptyProofs());
        above.settle(mid);
    }

    // ------------------------------------------------------------ constructor and admin

    function test_constructorRejectsZeroAddresses() public {
        vm.expectRevert(PimdAbove.InvalidMarket.selector);
        new PimdAbove(registry, oracle, address(0), OWNER);
        vm.expectRevert(PimdAbove.InvalidMarket.selector);
        new PimdAbove(registry, oracle, ADMIN, address(0));
    }

    function test_ratesCapsExactAndOver() public {
        vm.startPrank(ADMIN);
        above.setRates(1000, 500); // exactly the caps
        vm.expectRevert(PimdAbove.InvalidRate.selector);
        above.setRates(1001, 0);
        vm.expectRevert(PimdAbove.InvalidRate.selector);
        above.setRates(0, 501);
        vm.stopPrank();
        vm.prank(OWNER);
        vm.expectRevert(PimdAbove.Unauthorized.selector);
        above.setRates(0, 0);
    }

    function test_adminHandoverRemovesOldPowers() public {
        vm.prank(alice);
        vm.expectRevert(PimdAbove.Unauthorized.selector);
        above.transferAdmin(alice);
        vm.prank(ADMIN);
        vm.expectRevert(PimdAbove.InvalidMarket.selector);
        above.transferAdmin(address(0));
        vm.prank(ADMIN);
        above.transferAdmin(carol);
        vm.startPrank(ADMIN);
        vm.expectRevert(PimdAbove.Unauthorized.selector);
        above.setRates(0, 0);
        vm.expectRevert(PimdAbove.Unauthorized.selector);
        above.createMarket(1, 0, END, 5e18);
        vm.stopPrank();
        vm.prank(carol);
        above.createMarket(1, 0, END, 5e18);
    }

    function test_createMarketRejectsBadInputs() public {
        vm.startPrank(ADMIN);
        vm.expectRevert(); // unknown version
        above.createMarket(9, 0, END, 4e18);
        vm.expectRevert(PimdAbove.InvalidMarket.selector);
        above.createMarket(1, 0, END, 0); // zero threshold
        vm.expectRevert(PimdAbove.InvalidMarket.selector);
        above.createMarket(1, 0, T0, 4e18); // end not after now
        vm.expectRevert(PimdAbove.InvalidMarket.selector);
        above.createMarket(1, 0, END, 1e30 + 1); // threshold over the price scale
        vm.stopPrank();
    }

    // ------------------------------------------------------------ balances

    function test_depositWithdrawEdges() public {
        vm.startPrank(alice);
        vm.expectRevert(PimdAbove.InvalidTransfer.selector);
        above.deposit(0);
        vm.expectRevert(PimdAbove.InvalidTransfer.selector);
        above.withdraw(0);
        vm.expectRevert(PimdAbove.InsufficientBalance.selector);
        above.withdraw(1000e6 + 1);
        above.withdraw(1000e6);
        vm.stopPrank();
        assertEq(above.balance(alice), 0);
        assertEq(usdc.balanceOf(alice), 1000e6);
    }

    function test_feeOnTransferDepositReverts() public {
        usdc.setFeeBps(1);
        usdc.mint(carol, 100e6);
        vm.startPrank(carol);
        usdc.approve(address(above), type(uint256).max);
        vm.expectRevert(PimdAbove.InvalidTransfer.selector);
        above.deposit(100e6);
        vm.stopPrank();
        assertEq(above.balance(carol), 0);
    }

    function test_splitMergeFailures() public {
        vm.startPrank(alice);
        vm.expectRevert(PimdAbove.InvalidMarket.selector);
        above.split(bytes32(uint256(1)), 1e6);
        vm.expectRevert(PimdAbove.InvalidMarket.selector);
        above.split(mid, 0);
        vm.expectRevert(PimdAbove.InsufficientBalance.selector);
        above.split(mid, 1000e6 + 1);
        above.split(mid, 5e6);
        vm.expectRevert(PimdAbove.InsufficientBalance.selector);
        above.merge(mid, 5e6 + 1);
        // selling YES leaves fewer YES than NO: merge is bounded by the smaller side
        above.place(mid, _in(true, false, 2e6, 500_000));
        vm.expectRevert(PimdAbove.InsufficientBalance.selector);
        above.merge(mid, 4e6);
        above.merge(mid, 3e6);
        vm.stopPrank();
        assertEq(above.market(mid).pairs, 2e6);
    }

    // ------------------------------------------------------------ orders

    function test_orderInputFailures() public {
        vm.startPrank(alice);
        vm.expectRevert(PimdAbove.InvalidMarket.selector);
        above.place(bytes32(uint256(7)), _in(true, true, 10e6, 500_000));
        vm.expectRevert(PimdAbove.InvalidOrder.selector);
        above.place(mid, _in(true, true, 10e6, 99)); // under 0.0001
        vm.expectRevert(PimdAbove.InvalidOrder.selector);
        above.place(mid, _in(true, true, 10e6, 1_000_000)); // 1.0
        vm.expectRevert(PimdAbove.InvalidOrder.selector);
        above.place(mid, _in(true, true, 10e6, 500_050)); // off tick
        vm.expectRevert(PimdAbove.InvalidOrder.selector);
        above.place(mid, _in(true, true, 1e6, 999_800)); // 0.9998 USDC < 1 USDC min
        // amount-based only for market buys without a quantity
        vm.expectRevert(PimdAbove.InvalidOrder.selector);
        above.place(mid, PimdAbove.OrderInput(true, false, 0, 5e6, 500_000, 0, true));
        vm.expectRevert(PimdAbove.InvalidOrder.selector);
        above.place(mid, PimdAbove.OrderInput(true, true, 1e6, 5e6, 500_000, 0, true));
        vm.expectRevert(PimdAbove.InvalidOrder.selector);
        above.place(mid, PimdAbove.OrderInput(true, true, 0, 5e6, 500_000, uint64(block.timestamp + 1 days), false));
        vm.expectRevert(PimdAbove.InvalidOrder.selector);
        above.place(mid, PimdAbove.OrderInput(true, true, 0, 0.5e6, 500_000, 0, true)); // amount < 1 USDC
        // expiry must be at least 5 minutes out
        vm.expectRevert(PimdAbove.InvalidOrder.selector);
        above.place(
            mid, PimdAbove.OrderInput(true, true, 10e6, 0, 500_000, uint64(block.timestamp + 5 minutes - 1), false)
        );
        above.place(mid, PimdAbove.OrderInput(true, true, 10e6, 0, 500_000, uint64(block.timestamp + 5 minutes), false));
        // sells need the shares; a free USDC balance is never used
        vm.expectRevert(PimdAbove.InsufficientBalance.selector);
        above.place(mid, _in(true, false, 10e6, 500_000));
        vm.expectRevert(PimdAbove.InsufficientBalance.selector);
        above.place(mid, _in(true, true, 2001e6, 500_000)); // lock over balance
        vm.stopPrank();
    }

    function test_minimumNotionalBoundaryAccepted() public {
        vm.prank(alice);
        uint64 id = above.place(mid, _in(true, true, 2e6, 500_000)); // exactly 1 USDC
        assertTrue(above.order(id).resting);
        assertEq(above.order(id).lock, 1e6);
    }

    function test_cancelOnlyOwnRestingOrderAndRefundsExactly() public {
        vm.prank(alice);
        uint64 id = above.place(mid, _in(true, true, 10e6, 400_000));
        assertEq(above.balance(alice), 996e6);
        vm.prank(bob);
        vm.expectRevert(PimdAbove.Unauthorized.selector);
        above.cancel(id);
        vm.prank(alice);
        above.cancel(id);
        assertEq(above.balance(alice), 1000e6, "no fee on cancel");
        vm.prank(alice);
        vm.expectRevert(PimdAbove.Unauthorized.selector);
        above.cancel(id);
        assertEq(above.balance(OWNER), 0);
    }

    function test_cancelSellReturnsShares() public {
        vm.startPrank(alice);
        above.split(mid, 10e6);
        uint64 id = above.place(mid, _in(false, false, 4e6, 500_000));
        (, uint256 no) = above.positions(mid, alice);
        assertEq(no, 6e6, "only the sold shares are locked");
        above.cancel(id);
        (, no) = above.positions(mid, alice);
        assertEq(no, 10e6);
        vm.stopPrank();
    }

    function test_marketOrderRestReturnedSameTransaction() public {
        vm.prank(alice);
        above.split(mid, 4e6);
        vm.prank(alice);
        above.place(mid, _in(true, false, 4e6, 500_000));
        // bob wants 10 YES at worst 0.6; only 4 offered: the rest returns in this transaction
        vm.prank(bob);
        uint64 id = above.place(mid, PimdAbove.OrderInput(true, true, 10e6, 0, 600_000, 0, true));
        assertFalse(above.order(id).resting);
        assertEq(above.order(id).lock, 0);
        (uint256 yes,) = above.positions(mid, bob);
        assertEq(yes, 4e6);
        // 4 shares at 0.5 with taker fee 0.05*(1-0.5) inside: 2 / 0.975 = 2.051283.. rounded up
        assertEq(above.balance(bob), 1000e6 - 2_051_283);
    }

    function test_noCrossNoFill() public {
        vm.prank(alice);
        uint64 a = above.place(mid, _in(true, true, 10e6, 400_000));
        vm.prank(bob);
        uint64 b = above.place(mid, _in(false, true, 10e6, 590_000)); // 0.4 + 0.59 < 1
        assertTrue(above.order(a).resting && above.order(b).resting);
        assertEq(above.matchMarket(mid), 0);
        assertEq(above.market(mid).pairs, 0);
    }

    function test_atMost64FillsPerTransactionThenThirdPartyMatch() public {
        vm.startPrank(alice);
        above.split(mid, 140e6);
        for (uint256 i; i < 66; ++i) {
            above.place(mid, _in(true, false, 2e6, 500_000));
        }
        vm.stopPrank();
        vm.recordLogs();
        vm.prank(bob);
        uint64 id = above.place(mid, _in(true, true, 140e6, 500_000));
        // bob's own transaction fills exactly 64 makers
        assertEq(above.order(id).fills, 64);
        assertTrue(above.order(id).resting);
        vm.prank(carol);
        assertEq(above.matchMarket(mid), 2);
        assertEq(above.order(id).fills, 66);
    }

    function test_orderPlacedBeforeEndFillsAfterEnd() public {
        vm.prank(alice);
        uint64 a = above.place(mid, _in(true, true, 10e6, 500_000));
        vm.warp(END + 10 minutes);
        vm.prank(bob);
        above.place(mid, _in(false, true, 10e6, 500_000));
        assertGt(above.order(a).fills, 0);
        assertGt(above.market(mid).pairs, 0);
    }

    // ------------------------------------------------------------ settlement

    function test_settleBeforeEndAndUnknownMarketRevert() public {
        vm.expectRevert(PimdAbove.InvalidMarket.selector);
        above.settle(mid);
        vm.expectRevert(PimdAbove.InvalidMarket.selector);
        above.settle(bytes32(uint256(3)));
        vm.warp(END);
        vm.expectRevert(PimdAbove.MissingPrice.selector);
        above.settle(mid);
    }

    function test_afterSettlementOnlyCancelClaimWithdraw() public {
        vm.startPrank(alice);
        above.split(mid, 10e6);
        uint64 buyId = above.place(mid, _in(true, true, 10e6, 300_000));
        vm.stopPrank();
        _settle(3.5e18);
        vm.startPrank(alice);
        vm.expectRevert(PimdAbove.InvalidMarket.selector);
        above.place(mid, _in(true, true, 10e6, 300_000));
        vm.expectRevert(PimdAbove.InvalidMarket.selector);
        above.split(mid, 1e6);
        vm.expectRevert(PimdAbove.InvalidMarket.selector);
        above.merge(mid, 1e6);
        vm.expectRevert(PimdAbove.InvalidMarket.selector);
        above.matchMarket(mid);
        vm.expectRevert(PimdAbove.InvalidMarket.selector);
        above.settle(mid);
        above.cancel(buyId);
        assertEq(above.claim(mid), 10e6);
        vm.expectRevert(PimdAbove.InsufficientBalance.selector);
        above.claim(mid);
        above.withdraw(1000e6);
        vm.stopPrank();
        assertEq(above.balance(alice), 0);
    }

    function test_claimCancelsRestingSellsAndPaysTheirShares() public {
        vm.startPrank(alice);
        above.split(mid, 10e6);
        uint64 s = above.place(mid, _in(true, false, 6e6, 900_000));
        vm.stopPrank();
        _settle(2e18); // NO wins
        vm.prank(alice);
        assertEq(above.claim(mid), 10e6);
        assertFalse(above.order(s).resting);
        (uint256 y, uint256 n) = above.positions(mid, alice);
        assertEq(y + n, 0);
        assertEq(above.balance(alice), 1000e6, "split 10 USDC, claimed back 10");
    }

    function test_claimWithoutSharesReverts() public {
        _settle(3.5e18);
        vm.prank(carol);
        vm.expectRevert(PimdAbove.InsufficientBalance.selector);
        above.claim(mid);
    }

    function test_proofAfterVoidStillHalf() public {
        vm.prank(alice);
        above.split(mid, 3e6);
        vm.warp(END + 3 days);
        vm.prank(alice);
        assertEq(above.claim(mid), 3e6, "3 YES + 3 NO at 0.5 each");
        assertEq(uint8(above.market(mid).outcome), uint8(PimdAbove.Outcome.Half));
    }

    // ------------------------------------------------------------ fuzz

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_mintFillCollateralExact(uint256 pSeed, uint256 qSeed, uint256 limitSeed) public {
        uint128 p = uint128(bound(pSeed, 1, 9998) * 100);
        uint128 limit = uint128(bound(limitSeed, (1_000_000 - p) / 100, 9999) * 100);
        uint128 qMin = uint128((uint256(1e12) + p - 1) / p);
        uint128 qMax = uint128((uint256(500e6) * 1e6) / (p > limit ? p : limit));
        if (qMax < qMin) return;
        uint128 q = uint128(bound(qSeed, qMin, qMax));
        vm.prank(alice);
        above.place(mid, _in(true, true, q, p));
        uint256 lockTotal;
        vm.prank(bob);
        above.place(mid, PimdAbove.OrderInput(false, true, 0, 1e6 + qSeed % 400e6, limit, 0, true));
        uint256 pairs = above.market(mid).pairs;
        uint64 last = above.nextOrderId();
        for (uint64 id = 1; id < last; ++id) {
            lockTotal += above.order(id).lock;
        }
        uint256 owed = above.balance(alice) + above.balance(bob) + above.balance(vika) + above.balance(OWNER);
        assertGe(usdc.balanceOf(address(above)), owed + lockTotal + pairs, "pair under-collateralized");
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_buyNeverSpendsMoreThanLock(uint256 pSeed, uint256 qSeed, uint256 askSeed) public {
        uint128 p = uint128(bound(pSeed, 100, 9999) * 100);
        uint128 ask = uint128(bound(askSeed, 1, p / 100) * 100);
        uint128 q = uint128(bound(qSeed, (uint256(1e12) + p - 1) / p, uint256(400e6) * 1e6 / p));
        vm.startPrank(alice);
        above.split(mid, 500e6);
        uint128 sellQty = q < (uint256(1e12) + ask - 1) / ask ? uint128((uint256(1e12) + ask - 1) / ask) : q;
        if (sellQty > 500e6) return;
        above.place(mid, _in(true, false, sellQty, ask));
        vm.stopPrank();
        uint256 lock = uint256(q) * p / 1e6;
        uint256 before = above.balance(bob);
        vm.prank(bob);
        uint64 id = above.place(mid, PimdAbove.OrderInput(true, true, q, 0, p, 0, true));
        uint256 spent = before - above.balance(bob);
        (uint256 got,) = above.positions(mid, bob);
        assertLe(spent, lock, "spent more than N*p");
        assertLe(got, q, "more than N shares");
        assertFalse(above.order(id).resting);
    }
}
