// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MarketTypes as T} from "../src/libraries/MarketTypes.sol";
import {PimdRegistry} from "../src/PimdRegistry.sol";
import {BoundaryOracle} from "../src/BoundaryOracle.sol";
import {StartOracle} from "../src/StartOracle.sol";
import {PimdSwap2} from "../src/PimdSwap2.sol";
import {MockERC20, MockVerifier, MockIntake, MockSigner, MockPoolManager} from "./mocks/Mocks.sol";

/// @dev Shared fixture: the fixed mainnet addresses carry mocks, chain id 1, time at a known boundary.
abstract contract BaseTest is Test {
    address constant ADMIN = 0x8Ad18E99F4C8d8406f9Ba8899CF308000518A981;
    address constant OWNER = 0x3c587Eff6c96eAcF7E3dcC2CFf6416161386E48C;
    address constant VERIFIER = 0xa19a97B522cB379c2FB846A4b18589775F674Ee9;
    address constant INTAKE = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    address constant SIGNER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;
    address constant YOLO = 0x49E55A87AA4bB0d2fd58fDCf1A31c9612DE015dc;
    address constant YOLO_HOOK = 0x784FF9a3ac5d88A30bfff6F7f2a270161FBE6000;
    address constant WETH = address(0);

    // 2026-01-05 00:00:00 UTC, a Monday: hour, day and week boundary.
    uint64 constant T0 = 1767571200;

    PimdRegistry registry;
    BoundaryOracle oracle;
    StartOracle startOracle;
    PimdSwap2 swapper;
    MockERC20 imd;
    MockERC20 usdc;
    MockERC20 yolo;
    MockVerifier verifier;
    MockIntake intake;
    MockSigner signer;
    MockPoolManager manager;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address vika = makeAddr("vika");

    function setUp() public virtual {
        vm.chainId(1);
        vm.warp(T0);
        vm.roll(20_000_000);
        _etch(T.IMD, address(new MockERC20()));
        _etch(T.USDC, address(new MockERC20()));
        _etch(YOLO, address(new MockERC20()));
        _etch(VERIFIER, address(new MockVerifier()));
        _etch(INTAKE, address(new MockIntake()));
        _etch(SIGNER, address(new MockSigner()));
        _etch(T.MANAGER, address(new MockPoolManager()));
        imd = MockERC20(T.IMD);
        usdc = MockERC20(T.USDC);
        yolo = MockERC20(YOLO);
        imd.init("IMD", "IMD", 18);
        usdc.init("USD Coin", "USDC", 6);
        yolo.init("YOLO", "YOLO", 18);
        verifier = MockVerifier(VERIFIER);
        intake = MockIntake(INTAKE);
        signer = MockSigner(SIGNER);
        manager = MockPoolManager(T.MANAGER);

        registry = new PimdRegistry(ADMIN);
        oracle = new BoundaryOracle(registry, IBoundaryProofVerifierCast(VERIFIER));
        startOracle = new StartOracle(registry, oracle);
        swapper = new PimdSwap2(registry);
    }

    function _etch(address at, address from) internal {
        vm.etch(at, from.code);
    }

    function imdPath() internal pure returns (T.PoolKey[3] memory p) {
        p[0] = T.PoolKey(WETH, T.IMD, 10000, 200, address(0));
        p[1] = T.PoolKey(WETH, T.USDC, 500, 10, address(0));
    }

    function imdAsset(uint128 units, uint24 fee2, int24 spacing2) internal pure returns (T.Asset memory a) {
        a.token = T.IMD;
        a.unitsPerShare = units;
        a.hops = 2;
        a.path[0] = T.PoolKey(WETH, T.IMD, 10000, 200, address(0));
        a.path[1] = T.PoolKey(WETH, T.USDC, fee2, spacing2, address(0));
    }

    function yoloAsset(uint128 units) internal pure returns (T.Asset memory a) {
        a.token = YOLO;
        a.unitsPerShare = units;
        a.hops = 3;
        a.path[0] = T.PoolKey(YOLO, T.IMD, 12500, 60, YOLO_HOOK);
        a.path[1] = T.PoolKey(WETH, T.IMD, 10000, 200, address(0));
        a.path[2] = T.PoolKey(WETH, T.USDC, 500, 10, address(0));
    }

    function emptyProofs() internal pure returns (IBoundaryProofVerifierCast.BlockProof[3] memory p) {}
}

import {IBoundaryProofVerifier as IBoundaryProofVerifierCast} from "../src/interfaces/IBoundaryProofVerifier.sol";
