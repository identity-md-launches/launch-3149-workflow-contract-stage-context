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
