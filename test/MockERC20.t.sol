// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../src/MockERC20.sol";

contract MockERC20Test is Test {
    MockERC20 usdc;
    MockERC20 weth;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        usdc = new MockERC20("USD Coin (mock)", "USDC", 6);
        weth = new MockERC20("Wrapped Ether (mock)", "WETH", 18);
    }

    function test_Metadata() public view {
        assertEq(usdc.name(), "USD Coin (mock)");
        assertEq(usdc.symbol(), "USDC");
        assertEq(usdc.decimals(), 6);
        assertEq(weth.decimals(), 18);
    }

    function test_Mint() public {
        usdc.mint(alice, 1_000e6); // 1,000 USDC
        assertEq(usdc.balanceOf(alice), 1_000e6);
        assertEq(usdc.totalSupply(), 1_000e6);
    }

    function test_Transfer() public {
        usdc.mint(alice, 1_000e6);
        vm.prank(alice); // next call is sent by alice
        assertTrue(usdc.transfer(bob, 250e6));
        assertEq(usdc.balanceOf(alice), 750e6);
        assertEq(usdc.balanceOf(bob), 250e6);
    }

    /// The pattern the lending pool will use: user approves, pool pulls.
    function test_ApproveAndTransferFrom() public {
        usdc.mint(alice, 1_000e6);
        vm.prank(alice);
        assertTrue(usdc.approve(bob, 400e6));
        assertEq(usdc.allowance(alice, bob), 400e6);

        vm.prank(bob);
        assertTrue(usdc.transferFrom(alice, bob, 400e6));
        assertEq(usdc.balanceOf(bob), 400e6);
        assertEq(usdc.allowance(alice, bob), 0);
    }

    function test_RevertTransferMoreThanBalance() public {
        usdc.mint(alice, 100e6);
        vm.prank(alice);
        vm.expectRevert(); // ERC20InsufficientBalance
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        usdc.transfer(bob, 101e6);
    }
}
