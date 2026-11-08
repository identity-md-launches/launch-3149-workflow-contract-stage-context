// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {MarketTypes as T} from "../src/libraries/MarketTypes.sol";
import {PimdSwap2} from "../src/PimdSwap2.sol";

contract PimdSwap2Test is BaseTest {
    function setUp() public override {
        super.setUp();
        T.PoolKey[3] memory p = imdPath();
        // WETH/IMD: 1 ETH = 1500 IMD -> currency0 (WETH) per 1e18 currency1 (IMD) = 1e18/1500.
        manager.setPool(p[0], uint256(1e18) / 1500, 0);
        // WETH/USDC: 1 ETH = 4000 USDC -> wei per 1e18 USDC-atomic = 1e18 * 1e18 / 4000e6.
        manager.setPool(p[1], 1e18 * 1e18 / 4000e6, 0);
        imd.mint(address(manager), 1_000_000 ether);
        usdc.mint(address(manager), 1_000_000e6);
        imd.mint(alice, 1000 ether);
        usdc.mint(alice, 1000e6);
        vm.startPrank(alice);
        imd.approve(address(swapper), type(uint256).max);
        usdc.approve(address(swapper), type(uint256).max);
        vm.stopPrank();
    }

    function test_assetToUsdcExactOutputRefundsUnspent() public {
        vm.prank(alice);
        uint256 spent = swapper.exactOutput(1, 100e6, 50 ether);
        // 100 USDC = 0.025 ETH = 37.5 IMD
        assertApproxEqAbs(spent, 37.5 ether, 1e12);
        assertEq(usdc.balanceOf(alice), 1100e6);
        assertEq(imd.balanceOf(alice), 1000 ether - spent);
        assertEq(imd.balanceOf(address(swapper)), 0);
        assertEq(usdc.balanceOf(address(swapper)), 0);
    }

    function test_usdcToAssetExactOutput() public {
        vm.prank(alice);
        uint256 spent = swapper.exactOutputAsset(1, 30 ether, 100e6);
        // 30 IMD = 0.02 ETH = 80 USDC
        assertApproxEqAbs(spent, 80e6, 2);
        assertEq(imd.balanceOf(alice), 1030 ether);
        assertEq(usdc.balanceOf(alice), 1000e6 - spent);
    }

    function test_overTheLimitReverts() public {
        vm.prank(alice);
        vm.expectRevert(PimdSwap2.InvalidSwap.selector);
        swapper.exactOutput(1, 100e6, 30 ether);
        vm.prank(alice);
        vm.expectRevert(PimdSwap2.InvalidSwap.selector);
        swapper.exactOutputAsset(1, 30 ether, 70e6);
        assertEq(imd.balanceOf(alice), 1000 ether);
        assertEq(usdc.balanceOf(alice), 1000e6);
    }

    function test_poolShortOfTheOutputReverts() public {
        T.PoolKey[3] memory p = imdPath();
        manager.setPool(p[1], 1e18 * 1e18 / 4000e6, 50e6);
        vm.prank(alice);
        vm.expectRevert(bytes("pool short"));
        swapper.exactOutput(1, 100e6, 50 ether);
    }

    function test_invalidArgumentsAndUnknownVersion() public {
        vm.startPrank(alice);
        vm.expectRevert(PimdSwap2.InvalidSwap.selector);
        swapper.exactOutput(1, 0, 1 ether);
        vm.expectRevert(PimdSwap2.InvalidSwap.selector);
        swapper.exactOutput(1, 1e6, 0);
        vm.expectRevert();
        swapper.exactOutput(5, 1e6, 1 ether);
        vm.stopPrank();
    }

    function test_onlyManagerMayCallBack() public {
        vm.expectRevert(PimdSwap2.InvalidSwap.selector);
        swapper.unlockCallback("");
        vm.prank(T.MANAGER);
        vm.expectRevert(PimdSwap2.InvalidSwap.selector);
        swapper.unlockCallback("");
    }

    function test_threeHopYoloPath() public {
        vm.prank(ADMIN);
        uint32 v = registry.configureAsset(yoloAsset(1e18));
        T.PoolKey memory k = T.PoolKey(YOLO, T.IMD, 12500, 60, YOLO_HOOK);
        // YOLO/IMD: 1 IMD = 10 YOLO -> currency0 (YOLO) per 1e18 currency1 (IMD) = 10e18
        manager.setPool(k, 10e18, 0);
        yolo.mint(address(manager), 1_000_000 ether);
        yolo.mint(alice, 1000 ether);
        vm.prank(alice);
        yolo.approve(address(swapper), type(uint256).max);
        vm.prank(alice);
        uint256 spent = swapper.exactOutput(v, 8e6, 100 ether);
        // 8 USDC = 0.002 ETH = 3 IMD = 30 YOLO
        assertApproxEqAbs(spent, 30 ether, 1e12);
        assertEq(usdc.balanceOf(alice), 1008e6);
    }
}
