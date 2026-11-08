// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {MarketTypes as T} from "../src/libraries/MarketTypes.sol";
import {PimdRegistry} from "../src/PimdRegistry.sol";

contract PimdRegistryTest is BaseTest {
    function test_version1ExactlyAsSpecified() public view {
        assertEq(registry.assetAdmin(), ADMIN);
        assertEq(registry.assetVersionCount(), 1);
        assertEq(registry.currentVersion(T.IMD), 1);
        assertEq(registry.assetCount(), 1);
        assertEq(registry.assets(0), T.IMD);
        T.Asset memory a = registry.asset(1);
        assertEq(a.token, T.IMD);
        assertEq(a.unitsPerShare, 1e18);
        assertEq(a.maxOpenPairs, 0);
        assertEq(a.hops, 2);
        assertEq(T.poolId(a.path[0]), 0xb07d640fd9e2eb9dc81b953c8e4fd006bdfeaf276010fb5418eb763ca15abfb3);
        assertEq(T.poolId(a.path[1]), 0x21c67e77068de97969ba93d4aab21826d33ca12bb9f565d8496e8fda8a82ca27);
        assertEq(a.path[0].fee, 10000);
        assertEq(a.path[0].tickSpacing, 200);
        assertEq(a.path[1].fee, 500);
        assertEq(a.path[1].tickSpacing, 10);
    }

    function test_periodsHourDayWeekMonth() public view {
        assertEq(registry.periodCount(), 4);
        (uint32 s0,,) = registry.periods(0);
        (uint32 s1,,) = registry.periods(1);
        (uint32 s2, uint32 o2,) = registry.periods(2);
        (,, bool m3) = registry.periods(3);
        assertEq(s0, 3600);
        assertEq(s1, 86400);
        assertEq(s2, 604800);
        assertEq(o2, 345600);
        assertTrue(m3);
        // T0 is Monday 2026-01-05 00:00 UTC: hour, day and week boundary.
        assertTrue(registry.isBoundary(T0));
        assertFalse(registry.isBoundary(T0 + 1));
        (uint64 ws, uint64 we) = registry.bounds(2, T0 + 3 days);
        assertEq(ws, T0);
        assertEq(we, T0 + 7 days);
        (uint64 ms, uint64 me) = registry.bounds(3, T0);
        assertEq(ms, 1767225600); // 2026-01-01
        assertEq(me, 1769904000); // 2026-02-01
    }

    function test_adminAddsImdVersion2LeavingVersion1() public {
        vm.prank(ADMIN);
        uint32 v = registry.configureAsset(imdAsset(1e18, 3000, 60));
        assertEq(v, 2);
        assertEq(registry.currentVersion(T.IMD), 2);
        assertEq(registry.assetCount(), 1);
        T.Asset memory a1 = registry.asset(1);
        assertEq(a1.path[1].fee, 500);
        T.Asset memory a2 = registry.asset(2);
        assertEq(a2.path[1].fee, 3000);
        assertEq(a2.path[1].tickSpacing, 60);
        // Version 3 with another U leaves version 2 unchanged.
        vm.prank(ADMIN);
        assertEq(registry.configureAsset(imdAsset(5e18, 3000, 60)), 3);
        assertEq(registry.asset(2).unitsPerShare, 1e18);
        assertEq(registry.asset(3).unitsPerShare, 5e18);
        assertEq(registry.currentVersion(T.IMD), 3);
    }

    function test_othersCannotConfigureOrAddPeriods() public {
        address[3] memory callers = [OWNER, alice, address(this)];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(PimdRegistry.Unauthorized.selector);
            registry.configureAsset(imdAsset(1e18, 3000, 60));
            vm.prank(callers[i]);
            vm.expectRevert(PimdRegistry.Unauthorized.selector);
            registry.addPeriod(600, 0);
            vm.prank(callers[i]);
            vm.expectRevert(PimdRegistry.Unauthorized.selector);
            registry.transferAssetAdmin(callers[i]);
        }
    }

    function test_roleHandover() public {
        vm.prank(ADMIN);
        vm.expectRevert(PimdRegistry.InvalidConfiguration.selector);
        registry.transferAssetAdmin(address(0));
        vm.prank(ADMIN);
        registry.transferAssetAdmin(alice);
        assertEq(registry.assetAdmin(), alice);
        vm.prank(ADMIN);
        vm.expectRevert(PimdRegistry.Unauthorized.selector);
        registry.addPeriod(600, 0);
        vm.prank(alice);
        assertEq(registry.addPeriod(600, 0), 4);
    }

    function test_yoloPathWithHookAccepted() public {
        vm.prank(ADMIN);
        uint32 v = registry.configureAsset(yoloAsset(1e18));
        assertEq(v, 2);
        assertEq(registry.currentVersion(YOLO), 2);
        assertEq(registry.assetCount(), 2);
        assertEq(registry.assets(1), YOLO);
        vm.prank(ADMIN);
        assertEq(registry.configureAsset(yoloAsset(10_000e18)), 3);
    }

    function test_invalidConfigurationsRevert() public {
        T.Asset memory a;
        vm.startPrank(ADMIN);
        // zero token, USDC token
        a = imdAsset(1e18, 500, 10);
        a.token = address(0);
        _expectInvalid(a);
        a = imdAsset(1e18, 500, 10);
        a.token = T.USDC;
        _expectInvalid(a);
        // U bounds and granularity
        a = imdAsset(1e6 - 1, 500, 10);
        _expectInvalid(a);
        a = imdAsset(1e24 + 1e6, 500, 10);
        _expectInvalid(a);
        a = imdAsset(1e18 + 1, 500, 10);
        _expectInvalid(a);
        // hops
        a = imdAsset(1e18, 500, 10);
        a.hops = 0;
        _expectInvalid(a);
        a.hops = 4;
        _expectInvalid(a);
        // currency order, fee, tick spacing, hook flags
        a = imdAsset(1e18, 500, 10);
        a.path[0] = T.PoolKey(T.IMD, WETH, 10000, 200, address(0));
        _expectInvalid(a);
        a = imdAsset(1e18, 100_001, 10);
        _expectInvalid(a);
        a = imdAsset(1e18, 500, 0);
        _expectInvalid(a);
        a = imdAsset(1e18, 500, 10);
        a.path[0].hooks = address(uint160(1 << 7));
        _expectInvalid(a);
        // path must walk from token, no currency twice, must end at USDC
        a = imdAsset(1e18, 500, 10);
        a.path[0] = T.PoolKey(WETH, YOLO, 10000, 200, address(0));
        _expectInvalid(a);
        a = imdAsset(1e18, 500, 10);
        a.path[1] = T.PoolKey(WETH, T.IMD, 3000, 60, address(0));
        _expectInvalid(a);
        a = imdAsset(1e18, 500, 10);
        a.hops = 1;
        _expectInvalid(a);
        // any valid U and path is accepted, IMD included
        a = imdAsset(1e18, 500, 10);
        a.path[0] = T.PoolKey(T.USDC, T.IMD, 3000, 60, address(0)); // USDC sorts below IMD
        a.hops = 1;
        a.path[1] = T.PoolKey(address(0), address(0), 0, 0, address(0));
        assertEq(registry.configureAsset(a), 2);
        vm.stopPrank();
    }

    function _expectInvalid(T.Asset memory a) private {
        vm.expectRevert(PimdRegistry.InvalidConfiguration.selector);
        registry.configureAsset(a);
    }

    function test_addPeriodRules() public {
        vm.startPrank(ADMIN);
        vm.expectRevert(PimdRegistry.InvalidConfiguration.selector);
        registry.addPeriod(299, 0);
        vm.expectRevert(PimdRegistry.InvalidConfiguration.selector);
        registry.addPeriod(366 days + 1, 0);
        vm.expectRevert(PimdRegistry.InvalidConfiguration.selector);
        registry.addPeriod(600, 600);
        vm.expectRevert(PimdRegistry.InvalidConfiguration.selector);
        registry.addPeriod(3600, 0); // duplicate of the hour
        assertEq(registry.addPeriod(300, 0), 4);
        for (uint32 i = 5; i < 32; ++i) {
            registry.addPeriod(300 + i, 0);
        }
        assertEq(registry.periodCount(), 32);
        vm.expectRevert(PimdRegistry.InvalidConfiguration.selector);
        registry.addPeriod(301, 0);
        vm.stopPrank();
    }

    function test_assetViewRejectsUnknownVersion() public {
        vm.expectRevert(PimdRegistry.InvalidConfiguration.selector);
        registry.asset(0);
        vm.expectRevert(PimdRegistry.InvalidConfiguration.selector);
        registry.asset(2);
    }
}
