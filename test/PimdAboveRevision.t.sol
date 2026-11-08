// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Test.sol";
import {BaseTest} from "./Base.t.sol";
import {PimdAbove} from "../src/PimdAbove.sol";
import {BoundaryOracle} from "../src/BoundaryOracle.sol";

/// @dev Edges of the revised PimdAbove (per-fill gap, live order lists, settle finalizing a proposal)
/// that PimdAbove.t.sol and PimdAboveFailures.t.sol do not reach.
contract PimdAboveRevisionTest is BaseTest {
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

    function _limit(address who, bool yes, bool buy, uint128 qty, uint128 price, uint64 expiry)
        internal
        returns (uint64)
    {
        vm.prank(who);
        return above.place(mid, PimdAbove.OrderInput(yes, buy, qty, 0, price, expiry, false));
    }

    function _total() internal view returns (uint256 t) {
        t = above.balance(alice) + above.balance(bob) + above.balance(vika) + above.balance(carol)
            + above.balance(OWNER) + above.market(mid).pairs;
        uint64 last = above.nextOrderId();
        for (uint64 id = 1; id < last; ++id) {
            t += above.order(id).lock;
        }
    }

    function _lastFill(Vm.Log[] memory logs) internal pure returns (uint256 n, uint256 takerAmount) {
        bytes32 sig = keccak256("Fill(bytes32,uint64,uint64,uint256,uint256,uint256,uint256,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == sig) {
                (n,, takerAmount,,) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256));
            }
        }
    }

    // ------------------------------------------------------------ expiry and live lists

    /// @dev An expired head closed by someone else's matchMarket refunds its whole lock to its trader,
    /// pays the caller nothing and leaves the trader's live list.
    function test_expiredHeadClosedByThirdPartyRefundsTrader() public {
        uint64 id = _limit(alice, true, true, 10e6, 400_000, uint64(block.timestamp + 5 minutes));
        assertEq(above.ordersOf(mid, alice).length, 1);
        vm.warp(block.timestamp + 5 minutes);
        vm.prank(carol);
        assertEq(above.matchMarket(mid), 0);
        assertFalse(above.order(id).resting);
        assertEq(above.order(id).lock, 0);
        assertEq(above.balance(alice), 1000e6, "lock back to the trader");
        assertEq(above.balance(carol), 0, "nothing to the match caller");
        assertEq(above.ordersOf(mid, alice).length, 0);
        assertEq(above.best(mid, true, true), 0);
    }

    /// @dev An expired order behind the head never fills: it is closed when it reaches the head.
    function test_expiredOrderBehindHeadNeverFills() public {
        uint64 head = _limit(alice, true, true, 2e6, 500_000, uint64(block.timestamp + 1 days));
        uint64 stale = _limit(alice, true, true, 10e6, 400_000, uint64(block.timestamp + 5 minutes));
        vm.warp(block.timestamp + 6 minutes);
        // still listed and resting: only heads are expired
        assertEq(above.ordersOf(mid, alice).length, 2);
        assertTrue(above.order(stale).resting);
        vm.prank(bob);
        above.split(mid, 10e6);
        vm.prank(bob);
        above.place(mid, PimdAbove.OrderInput(true, false, 10e6, 0, 300_000, 0, true));
        assertGt(above.order(head).fills, 0);
        assertEq(above.order(stale).fills, 0, "an expired order filled");
        assertFalse(above.order(stale).resting);
        assertEq(above.order(stale).lock, 0);
        assertEq(above.ordersOf(mid, alice).length, 0);
        assertEq(_total(), 3000e6, "conservation");
    }

    /// @dev Swap-and-pop removal keeps every remaining live order listed, whatever position closes.
    function test_liveListAfterMixedCloses() public {
        uint64 a = _limit(alice, true, true, 10e6, 100_000, uint64(block.timestamp + 1 days));
        uint64 b = _limit(alice, false, true, 10e6, 200_000, uint64(block.timestamp + 1 days));
        uint64 c = _limit(alice, true, true, 10e6, 150_000, uint64(block.timestamp + 1 days));
        uint64 d = _limit(alice, false, true, 10e6, 250_000, uint64(block.timestamp + 1 days));
        vm.prank(alice);
        above.cancel(a); // first slot
        uint64[] memory mine = above.ordersOf(mid, alice);
        assertEq(mine.length, 3);
        assertEq(mine[0], d);
        assertEq(mine[1], b);
        assertEq(mine[2], c);
        // bob fills d completely (NO sell 10 at 0.25 is the maker side for d's buy)
        vm.prank(bob);
        above.split(mid, 10e6);
        vm.prank(bob);
        above.place(mid, PimdAbove.OrderInput(false, false, 10e6, 0, 250_000, 0, true));
        assertFalse(above.order(d).resting);
        mine = above.ordersOf(mid, alice);
        assertEq(mine.length, 2);
        for (uint256 i; i < mine.length; ++i) {
            assertTrue(above.order(mine[i]).resting);
            assertTrue(mine[i] == b || mine[i] == c);
        }
        // a closed order cannot be cancelled again and does not corrupt the list
        vm.prank(alice);
        vm.expectRevert(PimdAbove.Unauthorized.selector);
        above.cancel(d);
        assertEq(above.ordersOf(mid, alice).length, 2);
    }

    // ------------------------------------------------------------ per-fill gap

    /// @dev A resting taker sell whose fee eats into its limit has no surplus: the match caller gets 0
    /// and the seller the full net proceeds.
    function test_restingTakerSellFeeInsideLimitNoSurplusForCaller() public {
        for (uint256 i; i < 65; ++i) {
            _limit(alice, true, true, 2e6, 500_000, uint64(block.timestamp + 1 days)); // lock 1 USDC
        }
        vm.prank(bob);
        above.split(mid, 130e6);
        uint64 bobId = _limit(bob, true, false, 130e6, 500_000, uint64(block.timestamp + 1 days));
        assertEq(above.order(bobId).fills, 64);
        assertTrue(above.order(bobId).resting);
        // each maker lock of 1 USDC buys 1.99 shares (maker fee 0.5% inside); taker fee 2.5% of 0.995
        uint256 net = 995_000 - 24_875;
        assertEq(above.balance(bob), 870e6 + 64 * net);
        uint256 bobBefore = above.balance(bob);
        vm.prank(carol);
        assertEq(above.matchMarket(mid), 1);
        assertEq(above.balance(carol), 0, "no surplus over the limit");
        assertEq(above.balance(bob), bobBefore + net, "seller keeps the whole net");
        assertFalse(above.order(bobId).resting, "rest of 0.65 at 0.5 is under the minimum");
        assertEq(_total(), 3000e6, "conservation");
    }

    /// @dev A resting taker buy in a mint crossing: the match caller earns exactly that fill's gap
    /// (limit cost n*L minus the taker's cost, fee inside), and the lock drops by exactly n*L, so the
    /// remaining lock still covers the remaining shares at the limit.
    function test_restingTakerMintBuyGapExactPerFill() public {
        for (uint256 i; i < 65; ++i) {
            _limit(alice, false, true, 3e6, 400_000, uint64(block.timestamp + 1 days)); // lock 1.2 USDC
        }
        uint64 bobId = _limit(bob, true, true, 300e6, 700_000, uint64(block.timestamp + 1 days));
        PimdAbove.Order memory o = above.order(bobId);
        assertEq(o.fills, 64);
        assertTrue(o.resting);
        assertEq(o.lock, uint256(o.remaining) * 700_000 / 1e6, "lock == remaining shares at the limit");
        uint256 bobBefore = above.balance(bob);
        vm.recordLogs();
        vm.prank(carol);
        assertEq(above.matchMarket(mid), 1);
        (uint256 n, uint256 takerAmount) = _lastFill(vm.getRecordedLogs());
        uint256 limitAmount = n * 700_000 / 1e6;
        assertGt(limitAmount, takerAmount);
        assertEq(above.balance(carol), limitAmount - takerAmount, "caller gets this fill's gap only");
        assertEq(above.balance(bob), bobBefore, "the owner's free balance is untouched");
        assertEq(o.lock - above.order(bobId).lock, limitAmount, "lock drops by n*L");
        assertTrue(above.order(bobId).resting);
        // bob cancels: the rest of his lock is his, nothing more to carol
        vm.prank(bob);
        above.cancel(bobId);
        assertEq(above.balance(carol), limitAmount - takerAmount);
        assertEq(_total(), 3000e6, "conservation");
        assertEq(usdc.balanceOf(address(above)), 3000e6);
    }

    /// @dev An amount-based market buy has no share limit: no gap is paid to anyone, the unspent
    /// amount returns to the buyer, who is the sender.
    function test_amountMarketBuyNoGap() public {
        vm.prank(alice);
        above.split(mid, 4e6);
        _limit(alice, true, false, 4e6, 250_000, uint64(block.timestamp + 1 days));
        vm.recordLogs();
        vm.prank(bob);
        uint64 id = above.place(mid, PimdAbove.OrderInput(true, true, 0, 10e6, 900_000, 0, true));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 gapSig = keccak256("GapReturned(uint64,address,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != gapSig, "gap paid on an amount buy");
        }
        (uint256 n, uint256 takerAmount) = _lastFill(logs);
        assertEq(n, 4e6);
        assertEq(above.balance(bob), 1000e6 - takerAmount, "bob paid the fill only");
        assertFalse(above.order(id).resting);
    }

    // ------------------------------------------------------------ settlement and proposals

    function _propose(uint64 at) internal {
        imd.mint(bob, 100 ether);
        vm.prank(bob);
        imd.approve(address(oracle), type(uint256).max);
        vm.warp(at);
        vm.roll(20_000_100);
        vm.prank(bob);
        oracle.propose(1, END, 3.5e18, 20_000_000);
    }

    /// @dev Before end + 3 days settle does not finalize for anyone: a missing price reverts, and the
    /// proposal must be finalized on the oracle first. After that settle uses the finalized close.
    function test_settleBeforeVoidDelayNeedsExplicitFinalize() public {
        vm.prank(alice);
        above.split(mid, 10e6);
        _propose(END + 27 hours + 1);
        vm.warp(END + 27 hours + 1 + 1 hours);
        vm.expectRevert(PimdAbove.MissingPrice.selector);
        above.settle(mid);
        vm.prank(carol);
        oracle.finalize(1, END);
        above.settle(mid);
        assertEq(uint8(above.market(mid).outcome), uint8(PimdAbove.Outcome.Yes));
        assertEq(above.market(mid).close, 3.5e18);
    }

    /// @dev A disputed proposal the oracle released by timeout is finished: settle voids to Half and
    /// does not try to finalize it.
    function test_settleAfterProposalTimedOutIsHalf() public {
        intake.configure(0.5 ether, false);
        imd.mint(vika, 100 ether);
        vm.prank(vika);
        imd.approve(address(oracle), type(uint256).max);
        vm.prank(alice);
        above.split(mid, 10e6);
        _propose(END + 27 hours + 1);
        vm.prank(vika);
        oracle.dispute(1, END, 1 ether);
        vm.warp(END + 3 days);
        oracle.timeout(1, END);
        assertTrue(oracle.proposal(oracle.proposalId(1, END)).finished);
        above.settle(mid);
        assertEq(uint8(above.market(mid).outcome), uint8(PimdAbove.Outcome.Half));
        assertEq(above.market(mid).close, 0);
        vm.prank(alice);
        assertEq(above.claim(mid), 10e6);
    }

    /// @dev claim settles through the same path: at end + 3 days an unchallenged proposal is finalized
    /// by the first claimer and pays the winner, not half.
    function test_claimFinalizesUnchallengedProposal() public {
        vm.prank(alice);
        above.split(mid, 10e6);
        _limit(alice, false, false, 5e6, 500_000, uint64(block.timestamp + 1 days));
        _propose(END + 3 days - 1 hours - 1);
        vm.warp(END + 3 days);
        vm.prank(alice);
        assertEq(above.claim(mid), 10e6, "YES wins at 3.5 > 3; escrowed NO returned and lose");
        assertEq(uint8(above.market(mid).outcome), uint8(PimdAbove.Outcome.Yes));
        assertEq(oracle.price(1, END), 3.5e18);
        assertEq(above.ordersOf(mid, alice).length, 0);
    }

    // ------------------------------------------------------------ fuzz

    /// @dev Whoever calls matchMarket, a resting taker buy's trader ends with exactly its lock minus
    /// what it spent on fills minus the gaps paid out; nothing of the lock is lost or duplicated.
    /// forge-config: default.fuzz.runs = 256
    function testFuzz_restingBuyLockConservedAcrossMatchers(uint256 pSeed, uint256 limitSeed) public {
        uint128 ask = uint128(bound(pSeed, 20, 60) * 10_000); // 0.20 .. 0.60
        uint128 limit = uint128(bound(limitSeed, ask / 100, 9900) * 100);
        uint128 per = uint128((uint256(1e12) + ask - 1) / ask) + 1e6; // notional >= 1 USDC
        vm.prank(alice);
        above.split(mid, uint256(per) * 66);
        for (uint256 i; i < 66; ++i) {
            _limit(alice, true, false, per, ask, uint64(block.timestamp + 1 days));
        }
        uint128 qty = uint128(uint256(per) * 66);
        if (uint256(qty) * limit / 1e6 > 1000e6) return;
        uint64 bobId = _limit(bob, true, true, qty, limit, uint64(block.timestamp + 1 days));
        vm.prank(carol);
        above.matchMarket(mid);
        if (above.order(bobId).resting) {
            vm.prank(bob);
            above.cancel(bobId);
        }
        assertEq(above.order(bobId).lock, 0);
        // a move fill charges the buyer ceil(n*p) and credits the seller floor(n*p): at most one unit of
        // dust per fill stays in the contract, which therefore never owes more than it holds
        assertEq(usdc.balanceOf(address(above)), 3000e6);
        assertLe(_total(), 3000e6, "owes more than it holds");
        assertGe(_total() + above.order(bobId).fills, 3000e6, "more than rounding dust unaccounted");
        (uint256 by,) = above.positions(mid, bob);
        assertLe(by, qty);
        // what left bob and carol together (the fills' cost, fee inside) never exceeds bob's lock N*L
        uint256 paid = 1000e6 - above.balance(bob) - above.balance(carol);
        assertLe(paid, uint256(qty) * limit / 1e6, "spent over the lock");
        assertGt(by, 0);
    }
}
