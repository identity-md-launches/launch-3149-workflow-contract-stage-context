// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    LaunchToken token;
    address deployer = makeAddr("factory");
    address alice = makeAddr("alice");

    function setUp() public {
        vm.prank(deployer);
        token = new LaunchToken();
    }

    function test_metadataAndSupply() public view {
        assertEq(token.name(), "(p)IMD");
        assertEq(token.symbol(), "pIMD");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000e18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(deployer), 1e27);
    }

    function test_transfer() public {
        vm.prank(deployer);
        assertTrue(token.transfer(alice, 5e18));
        assertEq(token.balanceOf(alice), 5e18);
        assertEq(token.balanceOf(deployer), 1e27 - 5e18);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_transferFromWithAllowance() public {
        vm.prank(deployer);
        token.approve(alice, 3e18);
        vm.prank(alice);
        token.transferFrom(deployer, alice, 2e18);
        assertEq(token.allowance(deployer, alice), 1e18);
        assertEq(token.balanceOf(alice), 2e18);
        vm.prank(alice);
        vm.expectRevert(LaunchToken.InsufficientAllowance.selector);
        token.transferFrom(deployer, alice, 2e18);
    }

    function test_transferFailures() public {
        vm.prank(alice);
        vm.expectRevert(LaunchToken.InsufficientBalance.selector);
        token.transfer(deployer, 1);
        vm.prank(deployer);
        vm.expectRevert(LaunchToken.ZeroAddress.selector);
        token.transfer(address(0), 1);
    }

    function test_noMintOrOwnerFunctions() public {
        (bool ok,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", alice, 1));
        assertFalse(ok);
        (ok,) = address(token).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok);
        assertEq(token.totalSupply(), 1e27);
    }
}
