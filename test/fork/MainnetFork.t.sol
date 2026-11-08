// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MarketTypes as T} from "../../src/libraries/MarketTypes.sol";
import {PimdRegistry} from "../../src/PimdRegistry.sol";
import {BoundaryOracle} from "../../src/BoundaryOracle.sol";
import {StartOracle} from "../../src/StartOracle.sol";
import {PimdSwap2} from "../../src/PimdSwap2.sol";
import {PimdAbove} from "../../src/PimdAbove.sol";
import {IBoundaryProofVerifier} from "../../src/interfaces/IBoundaryProofVerifier.sol";
import {IERC20} from "../../src/vendor/openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IExtsload {
    function extsload(bytes32 slot) external view returns (bytes32);
}

interface IIntakePrice {
    function priceOf(bytes32 action, address asset) external view returns (uint256);
}

interface IDecimals {
    function decimals() external view returns (uint8);
}

/// @notice SPEC.md section 7 checks against live Ethereum mainnet state at the pinned block 26370890.
/// The contracts of this launch are deployed on the fork; the fixed mainnet contracts (USDC, IMD, YOLO,
/// PoolManager, INTAKE, BoundaryProofVerifier) are the live ones. Skips when MAINNET_RPC_URL is empty.
contract MainnetForkTest is Test {
    uint256 constant FORK_BLOCK = 26370890;
    address constant ADMIN = 0x8Ad18E99F4C8d8406f9Ba8899CF308000518A981;
    address constant VERIFIER = 0xa19a97B522cB379c2FB846A4b18589775F674Ee9;
    address constant INTAKE = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    address constant YOLO = 0x49E55A87AA4bB0d2fd58fDCf1A31c9612DE015dc;
    address constant YOLO_HOOK = 0x784FF9a3ac5d88A30bfff6F7f2a270161FBE6000;
    address constant V1_REGISTRY = 0x99BF2c49b25bdFF7bAA36A248Bd27072C90dfA35;
    address constant V1_ORACLE = 0x2CED79eba39EE972c6C4F7Dd51A08f28DC034555;
    address constant V1_MARKETS = 0x6804CA9b86731056Bb8E7976086C58E3E37047DB;
    bytes32 constant IMD_ETH_ID = 0xb07d640fd9e2eb9dc81b953c8e4fd006bdfeaf276010fb5418eb763ca15abfb3;
    bytes32 constant ETH_USDC_ID = 0x21c67e77068de97969ba93d4aab21826d33ca12bb9f565d8496e8fda8a82ca27;

    bool forked;
    PimdRegistry registry;
    BoundaryOracle oracle;
    StartOracle startOracle;
    PimdSwap2 swapper;
    PimdAbove above;
    address owner = makeAddr("owner");
    address user = makeAddr("user");
    address vika = makeAddr("vika");
    address bob = makeAddr("bob");

    function setUp() public {
        string memory url = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url, FORK_BLOCK);
        forked = true;
        registry = new PimdRegistry(ADMIN);
        oracle = new BoundaryOracle(registry, IBoundaryProofVerifier(VERIFIER));
        above = new PimdAbove(registry, oracle, ADMIN, owner);
        startOracle = new StartOracle(registry, oracle);
        swapper = new PimdSwap2(registry);
    }

    modifier onFork() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    // ------------------------------------------------------------ helpers

    function _slot0(bytes32 id) internal view returns (uint160 sqrtPriceX96) {
        bytes32 s = IExtsload(T.MANAGER).extsload(keccak256(abi.encode(id, uint256(6))));
        sqrtPriceX96 = uint160(uint256(s));
    }

    function _yoloAsset(uint128 units) internal pure returns (T.Asset memory a) {
        a.token = YOLO;
        a.unitsPerShare = units;
        a.hops = 3;
        a.path[0] = T.PoolKey(YOLO, T.IMD, 12500, 60, YOLO_HOOK);
        a.path[1] = T.PoolKey(address(0), T.IMD, 10000, 200, address(0));
        a.path[2] = T.PoolKey(address(0), T.USDC, 500, 10, address(0));
    }

    function _imdAsset(uint128 units, uint24 fee2, int24 spacing2) internal pure returns (T.Asset memory a) {
        a.token = T.IMD;
        a.unitsPerShare = units;
        a.hops = 2;
        a.path[0] = T.PoolKey(address(0), T.IMD, 10000, 200, address(0));
        a.path[1] = T.PoolKey(address(0), T.USDC, fee2, spacing2, address(0));
    }

    function _buyImd(address who, uint256 imdOut) internal returns (uint256 spent) {
        deal(T.USDC, who, 1_000_000e6);
        vm.startPrank(who);
        IERC20(T.USDC).approve(address(swapper), type(uint256).max);
        spent = swapper.exactOutputAsset(1, imdOut, 1_000_000e6);
        vm.stopPrank();
    }

    // ------------------------------------------------------------ fixed addresses

    function test_fork_fixedAddressesAreLive() public onFork {
        assertEq(block.chainid, 1);
        assertEq(block.number, FORK_BLOCK);
        address[8] memory fixedAddrs = [T.USDC, T.IMD, YOLO, T.MANAGER, VERIFIER, INTAKE, V1_REGISTRY, V1_ORACLE];
        for (uint256 i; i < fixedAddrs.length; ++i) {
            assertGt(fixedAddrs[i].code.length, 0, "fixed address has no code");
        }
        assertGt(V1_MARKETS.code.length, 0);
        assertEq(IDecimals(T.USDC).decimals(), 6);
        assertEq(IDecimals(T.IMD).decimals(), 18);
        assertEq(IDecimals(YOLO).decimals(), 18);
    }

    // ------------------------------------------------------------ registry against live pools

    function test_fork_version1PathIsTheLivePools() public onFork {
        T.Asset memory a = registry.asset(1);
        assertEq(a.token, T.IMD);
        assertEq(a.unitsPerShare, 1e18);
        assertEq(a.hops, 2);
        assertEq(T.poolId(a.path[0]), IMD_ETH_ID);
        assertEq(T.poolId(a.path[1]), ETH_USDC_ID);
        assertGt(_slot0(IMD_ETH_ID), 0, "IMD/ETH pool not initialized");
        assertGt(_slot0(ETH_USDC_ID), 0, "ETH/USDC pool not initialized");
        assertEq(registry.currentVersion(T.IMD), 1);
    }

    function test_fork_versionsAndYoloPathOnLivePools() public onFork {
        vm.startPrank(ADMIN);
        uint32 v2 = registry.configureAsset(_imdAsset(1e18, 3000, 60));
        uint32 v3 = registry.configureAsset(_yoloAsset(1e18));
        uint32 v4 = registry.configureAsset(_yoloAsset(10_000e18));
        vm.stopPrank();
        assertEq(v2, 2);
        assertEq(v3, 3);
        assertEq(v4, 4);
        assertEq(registry.currentVersion(T.IMD), 2);
        assertEq(registry.currentVersion(YOLO), 4);
        assertEq(T.poolId(registry.asset(1).path[1]), ETH_USDC_ID, "version 1 changed");
        // the YOLO/IMD hooked pool is a live, initialized pool
        assertGt(_slot0(T.poolId(_yoloAsset(1e18).path[0])), 0, "YOLO/IMD pool not initialized");
        // the owner of the launch cannot configure anything
        vm.prank(owner);
        vm.expectRevert(PimdRegistry.Unauthorized.selector);
        registry.configureAsset(_yoloAsset(1e18));
    }

    // ------------------------------------------------------------ oracle cost from the live INTAKE

    function test_fork_oracleCostIsLiveIntakePriceTimesHops() public onFork {
        uint256 live = IIntakePrice(INTAKE).priceOf(oracle.ACTION(), T.IMD);
        uint256 perQuestion = live == 0 ? 0.5 ether : live;
        (uint256 q1, uint256 total1) = oracle.oracleCost(1);
        assertEq(q1, perQuestion);
        assertEq(total1, perQuestion * 2);
        vm.prank(ADMIN);
        uint32 yv = registry.configureAsset(_yoloAsset(1e18));
        (, uint256 totalY) = oracle.oracleCost(yv);
        assertEq(totalY, perQuestion * 3);
        vm.expectRevert(PimdRegistry.InvalidConfiguration.selector);
        oracle.oracleCost(99);
    }

    // ------------------------------------------------------------ PimdSwap2 on the live path

    function test_fork_swapUsdcForExactImdAndBack() public onFork {
        deal(T.USDC, user, 10_000e6);
        vm.startPrank(user);
        IERC20(T.USDC).approve(address(swapper), type(uint256).max);
        uint256 spent = swapper.exactOutputAsset(1, 10e18, 10_000e6);
        vm.stopPrank();
        assertEq(IERC20(T.IMD).balanceOf(user), 10e18, "exact IMD out");
        assertGt(spent, 0);
        assertEq(IERC20(T.USDC).balanceOf(user), 10_000e6 - spent, "unspent USDC refunded");
        assertEq(IERC20(T.USDC).balanceOf(address(swapper)), 0);
        assertEq(IERC20(T.IMD).balanceOf(address(swapper)), 0);

        // back: exactly 1 USDC for IMD
        uint256 usdcBefore = IERC20(T.USDC).balanceOf(user);
        vm.startPrank(user);
        IERC20(T.IMD).approve(address(swapper), type(uint256).max);
        uint256 imdSpent = swapper.exactOutput(1, 1e6, 10e18);
        vm.stopPrank();
        assertEq(IERC20(T.USDC).balanceOf(user), usdcBefore + 1e6, "exact USDC out");
        assertEq(IERC20(T.IMD).balanceOf(user), 10e18 - imdSpent, "unspent IMD refunded");
        assertEq(IERC20(T.IMD).balanceOf(address(swapper)), 0);
    }

    function test_fork_swapOverTheLimitReverts() public onFork {
        deal(T.USDC, user, 10_000e6);
        vm.startPrank(user);
        IERC20(T.USDC).approve(address(swapper), type(uint256).max);
        // 10 IMD can never cost 1 micro-USDC: the path is short of the limit
        vm.expectRevert(PimdSwap2.InvalidSwap.selector);
        swapper.exactOutputAsset(1, 10e18, 1);
        vm.expectRevert(PimdSwap2.InvalidSwap.selector);
        swapper.exactOutputAsset(1, 0, 10_000e6);
        vm.expectRevert(PimdRegistry.InvalidConfiguration.selector);
        swapper.exactOutputAsset(7, 1e18, 10_000e6);
        vm.stopPrank();
        assertEq(IERC20(T.USDC).balanceOf(user), 10_000e6, "nothing spent");
    }

    function test_fork_callbackOnlyFromManagerDuringSwap() public onFork {
        vm.expectRevert(PimdSwap2.InvalidSwap.selector);
        swapper.unlockCallback("");
        bytes memory data = abi.encode(registry.asset(1), true, uint256(1e6), uint256(1e18));
        // the manager itself cannot call back outside a swap this contract opened
        vm.prank(T.MANAGER);
        vm.expectRevert(PimdSwap2.InvalidSwap.selector);
        swapper.unlockCallback(data);
    }

    function test_fork_yoloThreeHopSwap() public onFork {
        vm.prank(ADMIN);
        uint32 yv = registry.configureAsset(_yoloAsset(1e18));
        deal(T.USDC, user, 10_000e6);
        vm.startPrank(user);
        IERC20(T.USDC).approve(address(swapper), type(uint256).max);
        uint256 spent = swapper.exactOutputAsset(yv, 100e18, 10_000e6);
        vm.stopPrank();
        assertEq(IERC20(YOLO).balanceOf(user), 100e18, "exact YOLO out");
        assertEq(IERC20(T.USDC).balanceOf(user), 10_000e6 - spent);
        assertEq(IERC20(YOLO).balanceOf(address(swapper)), 0);
    }

    // ------------------------------------------------------------ StartOracle against the live INTAKE

    function test_fork_startOracleRefusesEarlyAndWrongFirstBlock() public onFork {
        uint64 recent = uint64(block.timestamp / 3600 * 3600);
        vm.expectRevert(StartOracle.InvalidState.selector);
        startOracle.request(1, recent, uint64(block.number - 10)); // under 27 h
        uint64 old = recent - 30 hours;
        vm.expectRevert(StartOracle.InvalidState.selector);
        startOracle.request(1, old, 0); // no firstBlock
        vm.expectRevert(StartOracle.InvalidState.selector);
        startOracle.request(1, old, uint64(block.number)); // firstBlock not in the past
        vm.expectRevert(StartOracle.InvalidState.selector);
        startOracle.request(1, old + 1, uint64(block.number - 9000)); // not a boundary
    }

    // ------------------------------------------------------------ PimdAbove with live USDC

    function _aboveMarket() internal returns (bytes32 mid, uint64 end) {
        end = uint64((block.timestamp / 3600 + 1) * 3600);
        vm.prank(ADMIN);
        mid = above.createMarket(1, 0, end, 3e18);
        address[2] memory who = [vika, bob];
        for (uint256 i; i < 2; ++i) {
            deal(T.USDC, who[i], 100e6);
            vm.startPrank(who[i]);
            IERC20(T.USDC).approve(address(above), type(uint256).max);
            above.deposit(100e6);
            vm.stopPrank();
        }
    }

    function _example(bytes32 mid) internal {
        vm.prank(vika);
        above.place(mid, PimdAbove.OrderInput(true, true, 10e6, 0, 400_000, uint64(block.timestamp + 1 days), false));
        vm.prank(bob);
        above.place(mid, PimdAbove.OrderInput(false, true, 0, 6e6, 620_000, 0, true));
    }

    function _close(uint64 end, uint256 closePrice) internal {
        vm.warp(end + 1);
        vm.mockCall(VERIFIER, abi.encodeWithSelector(IBoundaryProofVerifier.verify.selector), abi.encode(closePrice));
        IBoundaryProofVerifier.BlockProof[3] memory proofs;
        oracle.prove(1, end, proofs);
        assertEq(oracle.price(1, end), closePrice);
    }

    function test_fork_aboveSpecExampleYesWins() public onFork {
        (bytes32 mid, uint64 end) = _aboveMarket();
        _example(mid);
        (uint256 vYes,) = above.positions(mid, vika);
        (, uint256 bNo) = above.positions(mid, bob);
        assertEq(vYes, 9.8e6);
        assertEq(bNo, 9.8e6);
        // Vika pays 3.9437 (fee 0.0237) and her 0.0563 rest is refunded; Bob pays 6 (fee 0.12)
        assertEq((100e6 - above.balance(vika) + 50) / 100, 39437);
        assertEq(above.balance(bob), 94e6);
        assertEq((above.balance(owner) + 50) / 100, 1437);
        assertEq(IERC20(T.USDC).balanceOf(address(above)), 200e6);

        _close(end, 3.01e18);
        vm.prank(vika);
        assertEq(above.claim(mid), 9.8e6);
        vm.prank(bob);
        assertEq(above.claim(mid), 0);

        // everyone withdraws to live USDC; the contract keeps only rounding dust
        uint256 vb = above.balance(vika);
        vm.prank(vika);
        above.withdraw(vb);
        assertEq(IERC20(T.USDC).balanceOf(vika), vb);
        vm.prank(bob);
        above.withdraw(94e6);
        uint256 ob = above.balance(owner);
        vm.prank(owner);
        above.withdraw(ob);
        assertLt(IERC20(T.USDC).balanceOf(address(above)), 10);
    }

    function test_fork_aboveTieAndNoClose() public onFork {
        (bytes32 mid, uint64 end) = _aboveMarket();
        _example(mid);
        _close(end, 3e18);
        vm.prank(vika);
        assertEq(above.claim(mid), 4.9e6);
        vm.prank(bob);
        assertEq(above.claim(mid), 4.9e6);
    }

    function test_fork_aboveNoCloseAfterThreeDaysIsHalf() public onFork {
        (bytes32 mid, uint64 end) = _aboveMarket();
        _example(mid);
        vm.warp(end + 3 days - 1);
        vm.expectRevert(PimdAbove.MissingPrice.selector);
        above.settle(mid);
        vm.warp(end + 3 days);
        vm.prank(bob);
        assertEq(above.claim(mid), 4.9e6);
    }

    function test_fork_proveRefusedOutsideWindow() public onFork {
        (, uint64 end) = _aboveMarket();
        IBoundaryProofVerifier.BlockProof[3] memory proofs;
        vm.mockCall(VERIFIER, abi.encodeWithSelector(IBoundaryProofVerifier.verify.selector), abi.encode(uint256(3e18)));
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.prove(1, end, proofs); // boundary in the future
        vm.warp(uint256(end) + 27 hours + 1);
        vm.expectRevert(BoundaryOracle.InvalidState.selector);
        oracle.prove(1, end, proofs); // past the proof window
    }
}
