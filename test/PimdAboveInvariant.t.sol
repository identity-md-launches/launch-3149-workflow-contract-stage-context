// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BaseTest} from "./Base.t.sol";
import {MarketTypes as T} from "../src/libraries/MarketTypes.sol";
import {PimdAbove} from "../src/PimdAbove.sol";
import {MockERC20, MockVerifier} from "./mocks/Mocks.sol";
import {BoundaryOracle} from "../src/BoundaryOracle.sol";
import {IBoundaryProofVerifier} from "../src/interfaces/IBoundaryProofVerifier.sol";

/// @dev Drives PimdAbove with bounded random calls from three traders and a third-party matcher.
contract AboveHandler is Test {
    PimdAbove public above;
    BoundaryOracle public oracle;
    MockERC20 public usdc;
    MockVerifier public verifier;
    bytes32 public mid;
    uint64 public end;
    address public owner;
    address[4] public actors;
    uint256 public ownerHigh; // owner balance never decreases while nobody withdraws it
    uint256 public claimedTotal; // USDC credited by claims
    bool public settled;
    uint256 public calls;

    constructor(PimdAbove above_, BoundaryOracle oracle_, bytes32 mid_, uint64 end_, address owner_) {
        above = above_;
        oracle = oracle_;
        usdc = MockERC20(T.USDC);
        verifier = MockVerifier(0xa19a97B522cB379c2FB846A4b18589775F674Ee9);
        mid = mid_;
        end = end_;
        owner = owner_;
        actors = [makeAddr("t0"), makeAddr("t1"), makeAddr("t2"), makeAddr("matcher")];
        for (uint256 i; i < 4; ++i) {
            vm.prank(actors[i]);
            usdc.approve(address(above), type(uint256).max);
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % 3];
    }

    function _price(uint256 seed) internal pure returns (uint128) {
        return uint128(bound(seed, 1, 9999) * 100);
    }

    function deposit(uint256 who, uint256 amount) external {
        address a = _actor(who);
        amount = bound(amount, 1, 1_000e6);
        usdc.mint(a, amount);
        vm.prank(a);
        above.deposit(amount);
        ++calls;
    }

    function withdraw(uint256 who, uint256 amount) external {
        address a = _actor(who);
        uint256 b = above.balance(a);
        if (b == 0) return;
        amount = bound(amount, 1, b);
        vm.prank(a);
        above.withdraw(amount);
        ++calls;
    }

    function split(uint256 who, uint256 amount) external {
        if (settled) return;
        address a = _actor(who);
        uint256 b = above.balance(a);
        if (b == 0) return;
        amount = bound(amount, 1, b);
        vm.prank(a);
        above.split(mid, amount);
        ++calls;
    }

    function merge(uint256 who, uint256 amount) external {
        if (settled) return;
        address a = _actor(who);
        (uint256 y, uint256 n) = above.positions(mid, a);
        uint256 m = y < n ? y : n;
        if (m == 0) return;
        amount = bound(amount, 1, m);
        vm.prank(a);
        above.merge(mid, amount);
        ++calls;
    }

    function buy(uint256 who, bool yes, uint256 qty, uint256 price, bool marketOrder) external {
        if (settled) return;
        address a = _actor(who);
        uint128 p = _price(price);
        uint256 maxQty = above.balance(a) * 1e6 / p;
        uint256 minQty = (1e6 * 1e6 + p - 1) / p;
        if (maxQty < minQty) return;
        uint128 q = uint128(bound(qty, minQty, maxQty > minQty + 200e6 ? minQty + 200e6 : maxQty));
        vm.prank(a);
        above.place(mid, PimdAbove.OrderInput(yes, true, q, 0, p, uint64(block.timestamp + 1 days), marketOrder));
        ++calls;
    }

    function buyAmount(uint256 who, bool yes, uint256 amount, uint256 price) external {
        if (settled) return;
        address a = _actor(who);
        uint256 b = above.balance(a);
        if (b < 1e6) return;
        amount = bound(amount, 1e6, b);
        vm.prank(a);
        above.place(mid, PimdAbove.OrderInput(yes, true, 0, amount, _price(price), 0, true));
        ++calls;
    }

    function sell(uint256 who, bool yes, uint256 qty, uint256 price, bool marketOrder) external {
        if (settled) return;
        address a = _actor(who);
        uint128 p = _price(price);
        (uint256 y, uint256 n) = above.positions(mid, a);
        uint256 held = yes ? y : n;
        uint256 minQty = (1e6 * 1e6 + p - 1) / p;
        if (held < minQty) return;
        uint128 q = uint128(bound(qty, minQty, held));
        vm.prank(a);
        above.place(mid, PimdAbove.OrderInput(yes, false, q, 0, p, uint64(block.timestamp + 1 days), marketOrder));
        ++calls;
    }

    function cancel(uint256 who, uint256 idSeed) external {
        address a = _actor(who);
        uint64[] memory mine = above.ordersOf(mid, a);
        if (mine.length == 0) return;
        uint64 id = mine[idSeed % mine.length];
        if (!above.order(id).resting) return;
        PimdAbove.Order memory o = above.order(id);
        uint256 balBefore = above.balance(a);
        uint256 matcherBefore = above.balance(actors[3]);
        (uint256 yBefore, uint256 nBefore) = above.positions(mid, a);
        vm.prank(a);
        above.cancel(id);
        // the whole unspent lock (buy) or the escrowed shares (sell) go back to the trader, no one else
        (uint256 yAfter, uint256 nAfter) = above.positions(mid, a);
        if (o.buy) {
            require(above.balance(a) == balBefore + o.lock, "cancel refund != lock");
        } else {
            require(above.balance(a) == balBefore, "cancel of a sell moved USDC");
            require(yAfter == yBefore + (o.yes ? o.remaining : 0), "YES not returned");
            require(nAfter == nBefore + (o.yes ? 0 : o.remaining), "NO not returned");
        }
        require(above.balance(actors[3]) == matcherBefore, "cancel paid the matcher");
        ++calls;
    }

    function matchByThirdParty() external {
        if (settled) return;
        uint256[4] memory bal;
        uint256[3] memory ys;
        uint256[3] memory ns;
        for (uint256 i; i < 4; ++i) {
            bal[i] = above.balance(actors[i]);
            if (i < 3) (ys[i], ns[i]) = above.positions(mid, actors[i]);
        }
        vm.prank(actors[3]);
        above.matchMarket(mid);
        // matching only credits: fills, gaps and refunds never take a free balance or a position away
        for (uint256 i; i < 4; ++i) {
            require(above.balance(actors[i]) >= bal[i], "match debited a free balance");
            if (i < 3) {
                (uint256 y, uint256 n) = above.positions(mid, actors[i]);
                require(y >= ys[i] && n >= ns[i], "match took a position");
            }
        }
        ++calls;
    }

    function setRates(uint256 taker, uint256 maker) external {
        vm.prank(0x8Ad18E99F4C8d8406f9Ba8899CF308000518A981);
        above.setRates(bound(taker, 0, 1000), bound(maker, 0, 500));
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 6 hours));
    }

    function settleAndClaim(uint256 closeSeed) external {
        if (settled) return;
        if (block.timestamp <= end) vm.warp(end + 1);
        uint256 close = [uint256(2e18), 3e18, 4e18][closeSeed % 3];
        verifier.set(close, false);
        IBoundaryProofVerifier.BlockProof[3] memory proofs;
        if (block.timestamp <= uint256(end) + 27 hours) oracle.prove(1, end, proofs);
        above.settle(mid);
        settled = true;
        for (uint256 i; i < 3; ++i) {
            (uint256 y, uint256 n) = above.positions(mid, actors[i]);
            uint64[] memory mine = above.ordersOf(mid, actors[i]);
            bool any = y + n != 0;
            for (uint256 j; j < mine.length && !any; ++j) {
                if (above.order(mine[j]).resting && !above.order(mine[j]).buy) any = true;
            }
            if (!any) continue;
            vm.prank(actors[i]);
            claimedTotal += above.claim(mid);
        }
    }

    function recordOwner() external {
        uint256 b = above.balance(owner);
        require(b >= ownerHigh, "owner fees decreased");
        ownerHigh = b;
    }

    function actorCount() external pure returns (uint256) {
        return 4;
    }
}

contract PimdAboveInvariantTest is BaseTest {
    PimdAbove above;
    AboveHandler handler;
    bytes32 mid;
    uint64 END;

    function setUp() public override {
        super.setUp();
        above = new PimdAbove(registry, oracle, ADMIN, OWNER);
        END = T0 + 1 days;
        vm.prank(ADMIN);
        mid = above.createMarket(1, 1, END, 3e18);
        handler = new AboveHandler(above, oracle, mid, END, OWNER);
        targetContract(address(handler));
        bytes4[] memory sel = new bytes4[](12);
        sel[0] = AboveHandler.deposit.selector;
        sel[1] = AboveHandler.withdraw.selector;
        sel[2] = AboveHandler.split.selector;
        sel[3] = AboveHandler.merge.selector;
        sel[4] = AboveHandler.buy.selector;
        sel[5] = AboveHandler.buyAmount.selector;
        sel[6] = AboveHandler.sell.selector;
        sel[7] = AboveHandler.cancel.selector;
        sel[8] = AboveHandler.matchByThirdParty.selector;
        sel[9] = AboveHandler.setRates.selector;
        sel[10] = AboveHandler.warp.selector;
        sel[11] = AboveHandler.settleAndClaim.selector;
        targetSelector(FuzzSelector(address(handler), sel));
    }

    function _liabilities() internal view returns (uint256 owed, uint256 yesTotal, uint256 noTotal) {
        for (uint256 i; i < 4; ++i) {
            address a = handler.actors(i);
            owed += above.balance(a);
            (uint256 y, uint256 n) = above.positions(mid, a);
            yesTotal += y;
            noTotal += n;
        }
        owed += above.balance(OWNER);
        uint64 last = above.nextOrderId();
        for (uint64 id = 1; id < last; ++id) {
            PimdAbove.Order memory o = above.order(id);
            owed += o.lock;
            if (!o.resting) {
                assertEq(o.lock, 0, "closed order keeps a lock");
                continue;
            }
            if (!o.buy) {
                if (o.yes) yesTotal += o.remaining;
                else noTotal += o.remaining;
            }
        }
    }

    /// @notice Every YES and every NO share in existence is backed by one pair: positions plus shares
    /// escrowed in resting sell orders equal the market's pairs, until claims burn positions.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 40
    function invariant_sharesEqualPairs() public view {
        if (handler.settled()) return;
        (, uint256 yesTotal, uint256 noTotal) = _liabilities();
        uint256 pairs = above.market(mid).pairs;
        assertEq(yesTotal, pairs, "YES supply != pairs");
        assertEq(noTotal, pairs, "NO supply != pairs");
    }

    /// @notice The contract's USDC covers every free balance, every buy lock and 1 USDC per open pair.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 40
    function invariant_solvent() public view {
        (uint256 owed,,) = _liabilities();
        uint256 backing = handler.settled() ? 0 : above.market(mid).pairs;
        assertGe(usdc.balanceOf(address(above)), owed + backing, "under-collateralized");
    }

    /// @notice Only fills credit the owner; nothing the handler does reduces its fee balance.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 40
    function invariant_ownerFeesNeverDecrease() public {
        handler.recordOwner();
    }

    /// @notice ordersOf lists exactly the trader's resting orders in the market, each once.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 40
    function invariant_liveListsMatchBook() public view {
        uint64 last = above.nextOrderId();
        for (uint256 i; i < 3; ++i) {
            address a = handler.actors(i);
            uint64[] memory mine = above.ordersOf(mid, a);
            uint256 resting;
            for (uint64 id = 1; id < last; ++id) {
                PimdAbove.Order memory o = above.order(id);
                if (o.resting && o.trader == a) ++resting;
            }
            assertEq(mine.length, resting, "list length != resting orders");
            for (uint256 j; j < mine.length; ++j) {
                PimdAbove.Order memory o = above.order(mine[j]);
                assertTrue(o.resting, "closed order listed");
                assertEq(o.trader, a, "foreign order listed");
                for (uint256 k = j + 1; k < mine.length; ++k) {
                    assertTrue(mine[j] != mine[k], "order listed twice");
                }
            }
        }
    }

    /// @notice A resting buy's lock never exceeds its limit cost for its remaining shares (plus one
    /// unit of rounding per fill): gaps leave the lock as fills happen, they are not hoarded in it.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 40
    function invariant_restingBuyLockWithinLimit() public view {
        uint64 last = above.nextOrderId();
        for (uint64 id = 1; id < last; ++id) {
            PimdAbove.Order memory o = above.order(id);
            if (!o.resting || !o.buy || o.remaining == type(uint128).max) continue;
            assertLe(o.lock, uint256(o.remaining) * o.price / 1e6 + o.fills, "lock over N*p");
        }
    }

    /// @notice A settled market stays settled.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 40
    function invariant_settlementNeverReopens() public view {
        if (handler.settled()) assertTrue(above.market(mid).outcome != PimdAbove.Outcome.Active);
    }
}
