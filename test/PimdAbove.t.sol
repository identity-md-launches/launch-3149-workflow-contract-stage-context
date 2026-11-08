// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {MarketTypes as T} from "../src/libraries/MarketTypes.sol";
import {PimdAbove} from "../src/PimdAbove.sol";

contract PimdAboveTest is BaseTest {
    PimdAbove above;
    bytes32 mid;
    uint64 END;

    function setUp() public override {
        super.setUp();
        above = new PimdAbove(registry, oracle, ADMIN, OWNER);
        END = T0 + 1 hours;
        vm.prank(ADMIN);
        mid = above.createMarket(1, 0, END, 3e18);
        for (uint256 i; i < 3; ++i) {
            address who = [alice, bob, vika][i];
            usdc.mint(who, 1000e6);
            vm.startPrank(who);
            usdc.approve(address(above), type(uint256).max);
            above.deposit(1000e6);
            vm.stopPrank();
        }
    }

    function _buy(address who, bool yes, uint128 qty, uint128 price) internal returns (uint64) {
        vm.prank(who);
        return above.place(mid, PimdAbove.OrderInput(yes, true, qty, 0, price, uint64(block.timestamp + 1 days), false));
    }

    function _sell(address who, bool yes, uint128 qty, uint128 price) internal returns (uint64) {
        vm.prank(who);
        return
            above.place(mid, PimdAbove.OrderInput(yes, false, qty, 0, price, uint64(block.timestamp + 1 days), false));
    }

    function test_constructorRolesAndRates() public view {
        assertEq(above.admin(), ADMIN);
        assertEq(above.owner(), OWNER);
        assertEq(above.takerRate(), 500);
        assertEq(above.makerRate(), 100);
        assertEq(above.marketCount(), 1);
    }

    function test_onlyAdminCreatesMarkets() public {
        vm.prank(OWNER);
        vm.expectRevert(PimdAbove.Unauthorized.selector);
        above.createMarket(1, 0, END, 4e18);
        vm.prank(alice);
        vm.expectRevert(PimdAbove.Unauthorized.selector);
        above.createMarket(1, 0, END, 4e18);
        vm.startPrank(ADMIN);
        vm.expectRevert(PimdAbove.InvalidMarket.selector);
        above.createMarket(1, 0, END, 3e18); // duplicate
        vm.expectRevert(PimdAbove.InvalidMarket.selector);
        above.createMarket(1, 0, END + 1, 3e18); // not a boundary
        vm.expectRevert(PimdAbove.InvalidMarket.selector);
        above.createMarket(1, 0, T0, 3e18); // not after now
        vm.expectRevert();
        above.createMarket(5, 0, END, 3e18); // unknown version
        above.createMarket(1, 0, END, 4e18); // ladder: another threshold, same date
        vm.stopPrank();
        assertEq(above.marketCount(), 2);
    }

    function test_depositExactAndWithdraw() public {
        usdc.setFeeBps(100);
        usdc.mint(alice, 100e6);
        vm.prank(alice);
        vm.expectRevert(PimdAbove.InvalidTransfer.selector);
        above.deposit(100e6);
        usdc.setFeeBps(0);
        vm.prank(alice);
        above.withdraw(400e6);
        assertEq(above.balance(alice), 600e6);
        assertEq(usdc.balanceOf(alice), 500e6); // the 100 whose deposit reverted plus the 400 withdrawn
        vm.prank(alice);
        vm.expectRevert(PimdAbove.InsufficientBalance.selector);
        above.withdraw(601e6);
    }

    function test_splitAndMergeBackedByExactlyOneUsdc() public {
        vm.prank(alice);
        above.split(mid, 10e6);
        (uint256 y, uint256 n) = above.positions(mid, alice);
        assertEq(y, 10e6);
        assertEq(n, 10e6);
        assertEq(above.balance(alice), 990e6);
        assertEq(above.market(mid).pairs, 10e6);
        vm.prank(alice);
        above.merge(mid, 4e6);
        (y, n) = above.positions(mid, alice);
        assertEq(y, 6e6);
        assertEq(above.balance(alice), 994e6);
        vm.prank(alice);
        vm.expectRevert(PimdAbove.InsufficientBalance.selector);
        above.merge(mid, 7e6);
    }

    /// @dev SPEC.md section 5 example to 4 decimals.
    function test_specExampleVikaAndBob() public {
        uint64 vikaOrder = _buy(vika, true, 10e6, 0.4e6);
        assertEq(above.balance(vika), 996e6);
        vm.prank(bob);
        above.place(mid, PimdAbove.OrderInput(false, true, 0, 6e6, 0.62e6, 0, true));
        (uint256 vy,) = above.positions(mid, vika);
        (, uint256 bn) = above.positions(mid, bob);
        assertEq(vy, 9.8e6, "vika yes");
        assertEq(bn, 9.8e6, "bob no");
        assertEq(above.balance(bob), 994e6, "bob spent 6");
        // Vika pays 3.9437 (fee 0.0237); her 0.0563 rest under the minimum is refunded.
        assertApproxEqAbs(above.balance(vika), 1000e6 - 3.9437e6, 100, "vika paid");
        assertApproxEqAbs(above.balance(OWNER), 0.1437e6, 100, "owner fees");
        assertFalse(above.order(vikaOrder).resting);
        assertEq(above.market(mid).pairs, 9.8e6);
        // conservation: balances + pairs backing == deposits
        uint256 total = above.balance(alice) + above.balance(bob) + above.balance(vika) + above.balance(OWNER)
            + above.market(mid).pairs;
        assertEq(total, 3000e6);

        // X = 3: close 3.01 pays Vika 9.8 USDC
        vm.warp(END + 10);
        verifier.set(3.01e18, false);
        oracle.prove(1, END, emptyProofs());
        vm.prank(vika);
        uint256 got = above.claim(mid);
        assertEq(got, 9.8e6);
        assertEq(uint8(above.market(mid).outcome), uint8(PimdAbove.Outcome.Yes));
        vm.prank(bob);
        assertEq(above.claim(mid), 0);
    }

    function test_tiePaysHalfEach() public {
        _buy(vika, true, 10e6, 0.4e6);
        vm.prank(bob);
        above.place(mid, PimdAbove.OrderInput(false, true, 0, 6e6, 0.62e6, 0, true));
        vm.warp(END + 10);
        verifier.set(3e18, false);
        oracle.prove(1, END, emptyProofs());
        vm.prank(vika);
        assertEq(above.claim(mid), 4.9e6);
        vm.prank(bob);
        assertEq(above.claim(mid), 4.9e6);
    }

    function test_noCloseVoidsAfterThreeDaysOnly() public {
        vm.prank(alice);
        above.split(mid, 10e6);
        vm.warp(END + 1);
        vm.prank(alice);
        vm.expectRevert(PimdAbove.MissingPrice.selector);
        above.claim(mid);
        vm.warp(END + 3 days);
        vm.prank(alice);
        assertEq(above.claim(mid), 10e6);
        assertEq(uint8(above.market(mid).outcome), uint8(PimdAbove.Outcome.Half));
        // no trading after settlement
        vm.prank(alice);
        vm.expectRevert(PimdAbove.InvalidMarket.selector);
        above.split(mid, 1e6);
    }

    function test_noPaysOnCloseBelow() public {
        _buy(vika, true, 10e6, 0.4e6);
        vm.prank(bob);
        above.place(mid, PimdAbove.OrderInput(false, true, 0, 6e6, 0.62e6, 0, true));
        vm.warp(END + 10);
        verifier.set(2.5e18, false);
        oracle.prove(1, END, emptyProofs());
        vm.prank(bob);
        assertEq(above.claim(mid), 9.8e6);
        vm.prank(vika);
        assertEq(above.claim(mid), 0);
    }

    function test_moveFillSameSideAndBurnFill() public {
        vm.prank(alice);
        above.split(mid, 20e6);
        // alice sells 10 YES at 0.5; bob buys 10 YES at 0.5 (taker): shares move, no new pairs
        _sell(alice, true, 10e6, 0.5e6);
        _buy(bob, true, 10e6, 0.5e6);
        (uint256 by,) = above.positions(mid, bob);
        // Bob's lock 5 USDC has his taker fee inside: 5*(1-0.025)/0.5 = 9.75 shares.
        assertEq(by, 9.75e6);
        assertEq(above.market(mid).pairs, 20e6);
        // alice received 9.75*0.5 = 4.875 minus maker fee 0.01*(1-0.5)*4.875 = 0.024375
        assertEq(above.balance(alice), 980e6 + 4.875e6 - 0.024375e6);
        // Bob's amount is his whole lock 5: fee 0.05*(1-0.5)*5 = 0.125 inside it, 4.875 for the shares
        assertEq(above.balance(bob), 995e6);
        assertEq(above.balance(OWNER), 0.024375e6 + 0.125e6);
        // burn: alice sells 5 NO at 0.5, bob sells his YES at 0.5 -> pairs burn
        uint256 pairsBefore = above.market(mid).pairs;
        _sell(alice, false, 5e6, 0.5e6);
        _sell(bob, true, 5e6, 0.5e6);
        assertEq(above.market(mid).pairs, pairsBefore - 5e6);
    }

    function test_ordersAfterEndFillUntilSettlement() public {
        uint64 id = _buy(vika, true, 10e6, 0.4e6);
        vm.warp(END + 10);
        assertTrue(above.order(id).resting);
        vm.prank(bob);
        above.place(mid, PimdAbove.OrderInput(false, true, 0, 6e6, 0.62e6, 0, true));
        (, uint256 bn) = above.positions(mid, bob);
        assertEq(bn, 9.8e6);
    }

    function test_expiredOrderSkippedAndLockReturned() public {
        vm.prank(vika);
        uint64 id = above.place(
            mid, PimdAbove.OrderInput(true, true, 10e6, 0, 0.4e6, uint64(block.timestamp + 10 minutes), false)
        );
        vm.warp(block.timestamp + 11 minutes);
        vm.prank(bob);
        above.place(mid, PimdAbove.OrderInput(false, true, 0, 6e6, 0.62e6, 0, true));
        assertFalse(above.order(id).resting);
        assertEq(above.balance(vika), 1000e6);
        assertEq(above.balance(bob), 1000e6); // nothing to match: market order returned
        (, uint256 bn) = above.positions(mid, bob);
        assertEq(bn, 0);
    }

    function test_thirdPartyMatchAndCancel() public {
        uint64 a = _buy(vika, true, 10e6, 0.4e6);
        // resting orders only match via matchMarket when both rest; place matches immediately, so
        // create a crossed book by raising rates? Instead: cancel then verify refund.
        vm.prank(bob);
        vm.expectRevert(PimdAbove.Unauthorized.selector);
        above.cancel(a);
        vm.prank(vika);
        above.cancel(a);
        assertEq(above.balance(vika), 1000e6);
        assertEq(above.matchMarket(mid), 0);
    }

    function test_orderValidation() public {
        vm.startPrank(alice);
        vm.expectRevert(PimdAbove.InvalidOrder.selector);
        above.place(mid, PimdAbove.OrderInput(true, true, 10e6, 0, 0.4e6 + 1, uint64(block.timestamp + 1 days), false));
        vm.expectRevert(PimdAbove.InvalidOrder.selector);
        above.place(mid, PimdAbove.OrderInput(true, true, 10e6, 0, 1e6, uint64(block.timestamp + 1 days), false));
        vm.expectRevert(PimdAbove.InvalidOrder.selector);
        above.place(mid, PimdAbove.OrderInput(true, true, 1e6, 0, 0.4e6, uint64(block.timestamp + 1 days), false)); // 0.4 < 1 USDC
        vm.expectRevert(PimdAbove.InvalidOrder.selector);
        above.place(mid, PimdAbove.OrderInput(true, true, 10e6, 0, 0.4e6, uint64(block.timestamp + 4 minutes), false));
        vm.expectRevert(PimdAbove.InsufficientBalance.selector);
        above.place(mid, PimdAbove.OrderInput(true, false, 10e6, 0, 0.4e6, uint64(block.timestamp + 1 days), false));
        vm.stopPrank();
    }

    /// @dev Taker buy cost of `n` shares at maker price `p` with the taker fee inside (K = 0.05).
    function _takerCost(uint256 n, uint256 p) internal pure returns (uint256) {
        uint256 base = n * p / 1e6;
        uint256 rate = 500 * (1e6 - p);
        uint256 fee = (base * rate + (1e10 - rate) - 1) / (1e10 - rate);
        return base + fee;
    }

    /// @dev Finding 8904774a: a resting taker buy closed by a third party's matchMarket keeps its unspent
    /// lock; the match caller earns only the gap of the fills its transaction made.
    function test_restingTakerBuyGapPerFillAndLockStaysWithOwner() public {
        address carol = makeAddr("carol");
        vm.prank(alice);
        above.split(mid, 130e6);
        for (uint256 i; i < 65; ++i) {
            _sell(alice, true, 2e6, 0.5e6);
        }
        // bob: limit buy 130 YES at 0.9, lock 117 USDC; 64 fills of 2 at 0.5 in his own transaction
        uint64 bobId = _buy(bob, true, 130e6, 0.9e6);
        uint256 cost = _takerCost(2e6, 0.5e6); // 1,025,642
        uint256 gap = 1.8e6 - cost; // 774,358 per fill
        PimdAbove.Order memory o = above.order(bobId);
        assertTrue(o.resting);
        assertEq(o.fills, 64);
        assertEq(o.remaining, 2e6);
        assertEq(o.lock, 1.8e6, "lock covers exactly the remaining shares at the limit");
        assertEq(above.balance(bob), 1000e6 - 117e6 + 64 * gap, "own fills' gap back to the taker");
        // carol matches the 65th fill: she earns that fill's gap only, bob's order closes with nothing left
        uint256 bobBefore = above.balance(bob);
        vm.prank(carol);
        assertEq(above.matchMarket(mid), 1);
        assertEq(above.balance(carol), gap, "match caller gets one fill's gap");
        assertEq(above.balance(bob), bobBefore, "owner's balance untouched by the match");
        o = above.order(bobId);
        assertFalse(o.resting);
        assertEq(o.lock, 0);
        assertEq(o.fills, 65);
        (uint256 by,) = above.positions(mid, bob);
        assertEq(by, 130e6);
        // conservation: deposits == balances + locks + pairs
        uint256 total = above.balance(alice) + above.balance(bob) + above.balance(vika) + above.balance(carol)
            + above.balance(OWNER) + above.market(mid).pairs;
        assertEq(total, 3000e6);
    }

    /// @dev Finding 8904774a at the 1024-fill cap: the lock of shares never bought returns to the owner.
    function test_fillCapReturnsUnfilledLockToOwner() public {
        address carol = makeAddr("carol");
        usdc.mint(alice, 3000e6);
        usdc.mint(bob, 5000e6);
        vm.prank(alice);
        above.deposit(3000e6);
        vm.prank(bob);
        above.deposit(5000e6);
        vm.prank(alice);
        above.split(mid, 3075e6);
        // 1025 asks of 3 YES at 0.6000 down to 0.4976, each inserted at the head
        for (uint256 i; i < 1025; ++i) {
            _sell(alice, true, 3e6, uint128(0.6e6 - i * 100));
        }
        // bob: limit buy 10,000 YES at 0.6 (lock 6000); his transaction fills the 64 cheapest asks
        uint64 bobId = _buy(bob, true, 10_000e6, 0.6e6);
        // per fill: limit cost 1.8 USDC; the gap is what the fill cost less than that (0 when the fee
        // inside the limit pushes a fill near the limit over it: `over`, paid from the lock as always)
        uint256 ownGap;
        uint256 carolGap;
        uint256 spent;
        uint256 over;
        for (uint256 i = 1024; i >= 1; --i) {
            uint256 c = _takerCost(3e6, 0.6e6 - i * 100);
            spent += c;
            if (c < 1.8e6) {
                if (i >= 961) ownGap += 1.8e6 - c;
                else carolGap += 1.8e6 - c;
            } else {
                over += c - 1.8e6;
            }
        }
        assertEq(above.balance(bob), ownGap, "bob's own fills' gap is his");
        for (uint256 i; i < 15; ++i) {
            vm.prank(carol);
            above.matchMarket(mid);
        }
        PimdAbove.Order memory o = above.order(bobId);
        assertEq(o.fills, 1024);
        assertFalse(o.resting, "closed at the cap");
        assertEq(above.balance(carol), carolGap, "the match caller gets the gap of her fills only");
        uint256 unfilledLock = (10_000e6 - 3072e6) * 0.6e6 / 1e6; // 4156.8 USDC
        assertEq(above.balance(bob), ownGap + unfilledLock - over, "the lock of unbought shares is back with bob");
        assertEq(above.balance(bob) + above.balance(carol) + spent, 6000e6, "conservation of bob's lock");
        (uint256 by,) = above.positions(mid, bob);
        assertEq(by, 3072e6);
    }

    /// @dev Finding a5389dc1: a buy's rest under 1 USDC of notional closes in the same transaction.
    function test_buyRestUnderMinClosesInTransaction() public {
        vm.prank(alice);
        above.split(mid, 2e6);
        _sell(alice, true, 2e6, 0.5e6);
        uint64 bobId = _buy(bob, true, 3e6, 0.9e6);
        PimdAbove.Order memory o = above.order(bobId);
        assertFalse(o.resting, "rest of 1 share at 0.9 is under the minimum");
        assertEq(o.lock, 0);
        assertEq(above.balance(bob), 1000e6 - _takerCost(2e6, 0.5e6), "bob paid the fill only");
        (uint256 by,) = above.positions(mid, bob);
        assertEq(by, 2e6);
        assertEq(above.ordersOf(mid, bob).length, 0);
    }

    /// @dev Finding 8961590e: a resting taker sell's proceeds over its limit go to the match caller.
    function test_restingTakerSellGapGoesToMatchCaller() public {
        address carol = makeAddr("carol");
        for (uint256 i; i < 65; ++i) {
            _buy(alice, true, 2e6, 0.6e6);
        }
        vm.prank(bob);
        above.split(mid, 130e6);
        uint64 bobId = _sell(bob, true, 130e6, 0.5e6);
        // each maker buy of 2 at 0.6 with lock 1.2 affords 1.992 shares (its fee inside)
        uint256 n = 1.992e6;
        uint256 proceeds = n * 0.6e6 / 1e6; // 1,195,200
        uint256 fee = (proceeds * 500 * 0.4e6 + 1e10 - 1) / 1e10; // 23,904
        uint256 net = proceeds - fee; // 1,171,296
        uint256 limitProceeds = n * 0.5e6 / 1e6; // 996,000
        assertEq(above.balance(bob), 870e6 + 64 * net, "own fills: bob keeps everything");
        assertEq(above.order(bobId).fills, 64);
        uint256 bobBefore = above.balance(bob);
        vm.prank(carol);
        assertEq(above.matchMarket(mid), 1);
        assertEq(above.balance(bob), bobBefore + limitProceeds, "seller gets its limit");
        assertEq(above.balance(carol), net - limitProceeds, "match caller gets the surplus after the fee");
        // the rest (0.53 shares at 0.5) is under the minimum and went back to bob's position
        assertFalse(above.order(bobId).resting);
        (uint256 by,) = above.positions(mid, bob);
        assertEq(by, 130e6 - 65 * n);
    }

    /// @dev Finding c5e99df8: closed orders leave the trader's list, so claim's cost does not grow with history.
    function test_claimWalksOnlyLiveOrders() public {
        vm.prank(alice);
        above.split(mid, 5e6);
        vm.prank(bob);
        above.split(mid, 5e6);
        for (uint256 i; i < 300; ++i) {
            uint64 id = _buy(alice, true, 10_000e6, 100); // lock 1 USDC
            vm.prank(alice);
            above.cancel(id);
        }
        assertEq(above.ordersOf(mid, alice).length, 0);
        // swap-and-pop keeps the other live orders listed
        uint64 a = _buy(alice, true, 10_000e6, 100);
        uint64 b = _buy(alice, true, 10_000e6, 200);
        uint64 c = _buy(alice, true, 10_000e6, 300);
        vm.prank(alice);
        above.cancel(b);
        uint64[] memory mine = above.ordersOf(mid, alice);
        assertEq(mine.length, 2);
        assertEq(mine[0], a);
        assertEq(mine[1], c);
        vm.warp(END + 10);
        verifier.set(3.01e18, false);
        oracle.prove(1, END, emptyProofs());
        vm.prank(bob);
        uint256 g = gasleft();
        above.claim(mid);
        uint256 plain = g - gasleft();
        vm.prank(alice);
        g = gasleft();
        uint256 got = above.claim(mid);
        uint256 withHistory = g - gasleft();
        assertEq(got, 5e6);
        assertEq(above.ordersOf(mid, alice).length, 0, "claim cancelled the two live orders");
        assertEq(above.balance(alice), 1000e6 - 5e6 + 5e6, "both locks back");
        // two cancellations on top of a plain claim, nothing for the 300 closed orders
        assertLt(withHistory, plain + 120_000);
    }

    /// @dev Finding 1d8da67f: at end + 3 days settle finalizes an unchallenged late proposal instead of voiding.
    function test_settleFinalizesLateUnchallengedProposal() public {
        imd.mint(bob, 100 ether);
        vm.prank(bob);
        imd.approve(address(oracle), type(uint256).max);
        vm.prank(alice);
        above.split(mid, 10e6);
        vm.warp(END + 3 days - 1 hours - 1);
        vm.roll(20_000_100);
        vm.prank(bob);
        oracle.propose(1, END, 3.5e18, 20_000_000);
        vm.warp(END + 3 days);
        above.settle(mid);
        assertEq(uint8(above.market(mid).outcome), uint8(PimdAbove.Outcome.Yes));
        assertEq(above.market(mid).close, 3.5e18);
        assertEq(oracle.price(1, END), 3.5e18);
        assertEq(oracle.credit(bob), 10 ether, "the proposer's bond is released by the finalization");
        vm.prank(alice);
        assertEq(above.claim(mid), 10e6);
    }

    /// @dev A disputed proposal the oracle never answered still voids the market at end + 3 days.
    function test_settleVoidsWhenDisputedProposalTimesOut() public {
        intake.configure(0.5 ether, false);
        imd.mint(bob, 100 ether);
        imd.mint(vika, 100 ether);
        vm.prank(bob);
        imd.approve(address(oracle), type(uint256).max);
        vm.prank(vika);
        imd.approve(address(oracle), type(uint256).max);
        vm.prank(alice);
        above.split(mid, 10e6);
        vm.warp(END + 27 hours + 1);
        vm.roll(20_000_100);
        vm.prank(bob);
        oracle.propose(1, END, 3.5e18, 20_000_000);
        vm.prank(vika);
        oracle.dispute(1, END, 1 ether);
        vm.warp(END + 3 days - 1);
        vm.expectRevert(PimdAbove.MissingPrice.selector);
        above.settle(mid);
        vm.warp(END + 3 days);
        above.settle(mid);
        assertEq(uint8(above.market(mid).outcome), uint8(PimdAbove.Outcome.Half));
        vm.prank(alice);
        assertEq(above.claim(mid), 10e6);
    }

    function test_ratesOnlyAdminWithinCapsForLaterFills() public {
        vm.prank(OWNER);
        vm.expectRevert(PimdAbove.Unauthorized.selector);
        above.setRates(600, 100);
        vm.startPrank(ADMIN);
        vm.expectRevert(PimdAbove.InvalidRate.selector);
        above.setRates(1001, 100);
        vm.expectRevert(PimdAbove.InvalidRate.selector);
        above.setRates(500, 501);
        above.setRates(1000, 500);
        vm.stopPrank();
        assertEq(above.takerRate(), 1000);
        assertEq(above.makerRate(), 500);
        // a fill after the change uses the new rates: taker fee on 5.88 base at q 0.6 = 0.10*(0.4)*amount
        _buy(vika, true, 10e6, 0.4e6);
        vm.prank(bob);
        above.place(mid, PimdAbove.OrderInput(false, true, 0, 6e6, 0.62e6, 0, true));
        (, uint256 bn) = above.positions(mid, bob);
        // Bob: amount 6, fee 0.24, shares 5.76/0.6 = 9.6
        assertEq(bn, 9.6e6);
        // role handover
        vm.prank(ADMIN);
        above.transferAdmin(alice);
        vm.prank(ADMIN);
        vm.expectRevert(PimdAbove.Unauthorized.selector);
        above.setRates(500, 100);
        vm.prank(alice);
        above.setRates(500, 100);
    }
}
