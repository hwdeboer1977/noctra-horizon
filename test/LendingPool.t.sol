// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {MockERC20} from "../src/MockERC20.sol";

contract LendingPoolTest is Test {
    LendingPool pool;
    MockERC20 usdc;
    MockERC20 weth;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        usdc = new MockERC20("USD Coin (mock)", "USDC", 6);
        weth = new MockERC20("Wrapped Ether (mock)", "WETH", 18);
        pool = new LendingPool(owner);

        vm.startPrank(owner);
        pool.addAsset(address(usdc));
        pool.addAsset(address(weth));
        vm.stopPrank();

        usdc.mint(alice, 10_000e6);
        weth.mint(bob, 5e18);
    }

    // --- happy path -------------------------------------------------------

    function test_Supply() public {
        vm.startPrank(alice);
        usdc.approve(address(pool), 1_000e6);
        pool.supply(address(usdc), 1_000e6);
        vm.stopPrank();

        assertEq(pool.suppliedBalance(address(usdc), alice), 1_000e6);
        assertEq(pool.totalSupplied(address(usdc)), 1_000e6);
        assertEq(usdc.balanceOf(address(pool)), 1_000e6); // tokens really moved
        assertEq(usdc.balanceOf(alice), 9_000e6);
    }

    function test_SupplyTwiceAccumulates() public {
        vm.startPrank(alice);
        usdc.approve(address(pool), 3_000e6);
        pool.supply(address(usdc), 1_000e6);
        pool.supply(address(usdc), 2_000e6);
        vm.stopPrank();

        assertEq(pool.suppliedBalance(address(usdc), alice), 3_000e6);
    }

    function test_TwoUsersTwoAssets() public {
        vm.startPrank(alice);
        usdc.approve(address(pool), 1_000e6);
        pool.supply(address(usdc), 1_000e6);
        vm.stopPrank();

        vm.startPrank(bob);
        weth.approve(address(pool), 2e18);
        pool.supply(address(weth), 2e18);
        vm.stopPrank();

        assertEq(pool.suppliedBalance(address(usdc), alice), 1_000e6);
        assertEq(pool.suppliedBalance(address(weth), bob), 2e18);
        assertEq(pool.suppliedBalance(address(weth), alice), 0);
    }

    function test_SupplyEmitsEvent() public {
        vm.startPrank(alice);
        usdc.approve(address(pool), 1_000e6);
        vm.expectEmit(address(pool));
        emit LendingPool.Supplied(address(usdc), alice, 1_000e6);
        pool.supply(address(usdc), 1_000e6);
        vm.stopPrank();
    }

    // --- reverts ----------------------------------------------------------

    function test_RevertSupplyWithoutApproval() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(pool), 0, 1_000e6)
        );
        pool.supply(address(usdc), 1_000e6);
    }

    function test_RevertSupplyMoreThanBalance() public {
        vm.startPrank(alice);
        usdc.approve(address(pool), 20_000e6);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 10_000e6, 20_000e6)
        );
        pool.supply(address(usdc), 20_000e6);
        vm.stopPrank();
    }

    function test_RevertSupplyZero() public {
        vm.prank(alice);
        vm.expectRevert(LendingPool.ZeroAmount.selector);
        pool.supply(address(usdc), 0);
    }

    function test_RevertSupplyUnsupportedAsset() public {
        MockERC20 random = new MockERC20("Random", "RND", 18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LendingPool.AssetNotSupported.selector, address(random)));
        pool.supply(address(random), 1e18);
    }

    function test_RevertAddAssetNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        pool.addAsset(address(0xBEEF));
    }

    function test_RevertAddAssetTwice() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(LendingPool.AssetAlreadySupported.selector, address(usdc)));
        pool.addAsset(address(usdc));
    }

    // --- withdraw -----------------------------------------------------------

    /// Helper: alice supplies 1,000 USDC.
    function _aliceSupplies() internal {
        vm.startPrank(alice);
        usdc.approve(address(pool), 1_000e6);
        pool.supply(address(usdc), 1_000e6);
        vm.stopPrank();
    }

    function test_WithdrawPartial() public {
        _aliceSupplies();

        vm.prank(alice);
        uint256 out = pool.withdraw(address(usdc), 400e6);

        assertEq(out, 400e6);
        assertEq(pool.suppliedBalance(address(usdc), alice), 600e6);
        assertEq(pool.totalSupplied(address(usdc)), 600e6);
        assertEq(usdc.balanceOf(alice), 9_400e6);
        assertEq(usdc.balanceOf(address(pool)), 600e6);
    }

    function test_WithdrawExactFullBalance() public {
        _aliceSupplies();

        vm.prank(alice);
        pool.withdraw(address(usdc), 1_000e6);

        assertEq(pool.suppliedBalance(address(usdc), alice), 0);
        assertEq(usdc.balanceOf(alice), 10_000e6); // back to where she started
    }

    function test_WithdrawMax() public {
        _aliceSupplies();

        vm.prank(alice);
        uint256 out = pool.withdraw(address(usdc), type(uint256).max);

        assertEq(out, 1_000e6);
        assertEq(pool.suppliedBalance(address(usdc), alice), 0);
        assertEq(usdc.balanceOf(address(pool)), 0);
    }

    function test_WithdrawEmitsEvent() public {
        _aliceSupplies();

        vm.prank(alice);
        vm.expectEmit(address(pool));
        emit LendingPool.Withdrawn(address(usdc), alice, 250e6);
        pool.withdraw(address(usdc), 250e6);
    }

    function test_RevertWithdrawMoreThanSupplied() public {
        _aliceSupplies();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LendingPool.InsufficientBalance.selector, 1_000e6, 1_001e6));
        pool.withdraw(address(usdc), 1_001e6);
    }

    /// Bob has no USDC supplied, so he cannot take Alice's USDC out of the pool.
    function test_RevertWithdrawSomeoneElsesFunds() public {
        _aliceSupplies();

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(LendingPool.InsufficientBalance.selector, 0, 500e6));
        pool.withdraw(address(usdc), 500e6);
    }

    function test_RevertWithdrawMaxWithNothingSupplied() public {
        vm.prank(bob);
        vm.expectRevert(LendingPool.ZeroAmount.selector);
        pool.withdraw(address(usdc), type(uint256).max);
    }

    function test_RevertWithdrawZero() public {
        _aliceSupplies();
        vm.prank(alice);
        vm.expectRevert(LendingPool.ZeroAmount.selector);
        pool.withdraw(address(usdc), 0);
    }

    function test_RevertWithdrawUnsupportedAsset() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LendingPool.AssetNotSupported.selector, address(0xBEEF)));
        pool.withdraw(address(0xBEEF), 1);
    }

    // --- fuzz ---------------------------------------------------------------

    /// For any supply/withdraw amounts: bookkeeping always matches real token balances.
    function testFuzz_SupplyWithdrawAccounting(uint256 supplyAmt, uint256 withdrawAmt) public {
        supplyAmt = bound(supplyAmt, 1, 10_000e6);
        withdrawAmt = bound(withdrawAmt, 1, supplyAmt);

        vm.startPrank(alice);
        usdc.approve(address(pool), supplyAmt);
        pool.supply(address(usdc), supplyAmt);
        pool.withdraw(address(usdc), withdrawAmt);
        vm.stopPrank();

        assertEq(pool.suppliedBalance(address(usdc), alice), supplyAmt - withdrawAmt);
        assertEq(pool.totalSupplied(address(usdc)), usdc.balanceOf(address(pool)));
        assertEq(usdc.balanceOf(alice), 10_000e6 - supplyAmt + withdrawAmt);
    }
}
