// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {MockERC20} from "../src/MockERC20.sol";
import {MockPriceOracle} from "../src/MockPriceOracle.sol";

contract LendingPoolTest is Test {
    LendingPool pool;
    MockERC20 usdc; // 6 decimals
    MockERC20 weth; // 18 decimals
    MockPriceOracle oracle;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice"); // USDC supplier (lender)
    address bob = makeAddr("bob"); // WETH supplier, USDC borrower

    function setUp() public {
        usdc = new MockERC20("USD Coin (mock)", "USDC", 6);
        weth = new MockERC20("Wrapped Ether (mock)", "WETH", 18);
        oracle = new MockPriceOracle(owner);
        pool = new LendingPool(owner, address(oracle));

        vm.startPrank(owner);
        oracle.setPrice(address(weth), 3000e18);
        oracle.setPrice(address(usdc), 1e18);
        pool.addAsset(address(weth), 7500, true); // 75% LTV
        pool.addAsset(address(usdc), 7000, true); // 70% LTV
        vm.stopPrank();

        usdc.mint(alice, 100_000e6);
        weth.mint(bob, 10e18);
        usdc.mint(bob, 1_000e6); // for repaying

        vm.prank(alice);
        usdc.approve(address(pool), type(uint256).max);
        vm.startPrank(bob);
        weth.approve(address(pool), type(uint256).max);
        usdc.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    /// Alice lends 50k USDC; Bob supplies 1 WETH ($3,000 -> $2,250 borrow power).
    function _seed() internal {
        vm.prank(alice);
        pool.supply(address(usdc), 50_000e6);
        vm.prank(bob);
        pool.supply(address(weth), 1e18);
    }

    // =====================================================================
    // Admin
    // =====================================================================

    function test_AddAssetStoresConfig() public view {
        (bool supported, bool borrowEnabled, uint16 ltv, uint8 dec) = pool.assetConfig(address(usdc));
        assertTrue(supported);
        assertTrue(borrowEnabled);
        assertEq(ltv, 7000);
        assertEq(dec, 6); // read from the token
        assertEq(pool.assetCount(), 2);
    }

    function test_RevertAddAssetNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        pool.addAsset(address(0xBEEF), 5000, true);
    }

    function test_RevertAddAssetTwice() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(LendingPool.AssetAlreadySupported.selector, address(usdc)));
        pool.addAsset(address(usdc), 5000, true);
    }

    function test_RevertLtvTooHigh() public {
        MockERC20 x = new MockERC20("X", "X", 18);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(LendingPool.InvalidLtv.selector, 9500));
        pool.addAsset(address(x), 9500, true);
    }

    function test_RevertSetOracleNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        pool.setOracle(address(0xBEEF));
    }

    // =====================================================================
    // Supply / withdraw (step 2 behaviour, still intact)
    // =====================================================================

    function test_Supply() public {
        vm.prank(alice);
        pool.supply(address(usdc), 1_000e6);
        assertEq(pool.suppliedBalance(address(usdc), alice), 1_000e6);
        assertEq(pool.totalSupplied(address(usdc)), 1_000e6);
        assertEq(usdc.balanceOf(address(pool)), 1_000e6);
    }

    function test_RevertSupplyWithoutApproval() public {
        address carol = makeAddr("carol");
        usdc.mint(carol, 100e6);
        vm.prank(carol);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(pool), 0, 100e6)
        );
        pool.supply(address(usdc), 100e6);
    }

    function test_RevertSupplyUnsupported() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LendingPool.AssetNotSupported.selector, address(0xBEEF)));
        pool.supply(address(0xBEEF), 1);
    }

    function test_WithdrawMaxWithoutDebt() public {
        vm.startPrank(alice);
        pool.supply(address(usdc), 1_000e6);
        uint256 out = pool.withdraw(address(usdc), type(uint256).max);
        vm.stopPrank();
        assertEq(out, 1_000e6);
        assertEq(usdc.balanceOf(alice), 100_000e6);
    }

    function test_RevertWithdrawMoreThanSupplied() public {
        vm.startPrank(alice);
        pool.supply(address(usdc), 1_000e6);
        vm.expectRevert(abi.encodeWithSelector(LendingPool.InsufficientBalance.selector, 1_000e6, 1_001e6));
        pool.withdraw(address(usdc), 1_001e6);
        vm.stopPrank();
    }

    // =====================================================================
    // Borrow
    // =====================================================================

    function test_BorrowWithinLtv() public {
        _seed();
        vm.prank(bob);
        pool.borrow(address(usdc), 2_000e6);

        assertEq(pool.borrowedBalance(address(usdc), bob), 2_000e6);
        assertEq(pool.totalBorrowed(address(usdc)), 2_000e6);
        assertEq(usdc.balanceOf(bob), 3_000e6); // 1,000 own + 2,000 borrowed
        assertEq(pool.availableLiquidity(address(usdc)), 48_000e6);
    }

    /// 1 WETH x $3,000 x 75% = exactly $2,250 of borrow power.
    function test_BorrowExactlyAtLtv() public {
        _seed();
        vm.prank(bob);
        pool.borrow(address(usdc), 2_250e6);
        LendingPool.AccountData memory a = pool.getAccountData(bob);
        assertEq(a.debtValue, a.borrowPower);
    }

    function test_RevertBorrowAboveLtv() public {
        _seed();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(LendingPool.InsufficientCollateral.selector, 2_250e18, 2_250.000001e18));
        pool.borrow(address(usdc), 2_250.000001e6); // 1 base unit too much
    }

    function test_RevertBorrowWithoutCollateral() public {
        _seed();
        address carol = makeAddr("carol");
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(LendingPool.InsufficientCollateral.selector, 0, 100e18));
        pool.borrow(address(usdc), 100e6);
    }

    function test_RevertBorrowMoreThanLiquidity() public {
        _seed(); // only 50k USDC in the pool
        weth.mint(bob, 100e18);
        vm.startPrank(bob);
        pool.supply(address(weth), 100e18); // plenty of collateral
        vm.expectRevert(abi.encodeWithSelector(LendingPool.InsufficientLiquidity.selector, 50_000e6, 60_000e6));
        pool.borrow(address(usdc), 60_000e6);
        vm.stopPrank();
    }

    function test_RevertBorrowDisabledAsset() public {
        _seed();
        vm.prank(owner);
        pool.setAssetConfig(address(usdc), 7000, false);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(LendingPool.BorrowNotEnabled.selector, address(usdc)));
        pool.borrow(address(usdc), 100e6);
    }

    function test_BorrowPowerAddsUpAcrossAssets() public {
        _seed();
        vm.startPrank(bob);
        pool.supply(address(usdc), 1_000e6); // + $1,000 x 70% = $700
        pool.borrow(address(usdc), 2_950e6); // $2,250 + $700
        vm.stopPrank();
        LendingPool.AccountData memory a = pool.getAccountData(bob);
        assertEq(a.collateralValue, 4_000e18);
        assertEq(a.borrowPower, 2_950e18);
        assertEq(a.debtValue, 2_950e18);
    }

    // =====================================================================
    // Repay
    // =====================================================================

    function test_RepayPartial() public {
        _seed();
        vm.startPrank(bob);
        pool.borrow(address(usdc), 2_000e6);
        uint256 paid = pool.repay(address(usdc), 500e6);
        vm.stopPrank();
        assertEq(paid, 500e6);
        assertEq(pool.borrowedBalance(address(usdc), bob), 1_500e6);
        assertEq(pool.totalBorrowed(address(usdc)), 1_500e6);
    }

    function test_RepayMaxCapsAtDebt() public {
        _seed();
        vm.startPrank(bob);
        pool.borrow(address(usdc), 2_000e6);
        uint256 paid = pool.repay(address(usdc), type(uint256).max);
        vm.stopPrank();
        assertEq(paid, 2_000e6); // not type(uint256).max
        assertEq(pool.borrowedBalance(address(usdc), bob), 0);
        assertEq(usdc.balanceOf(bob), 1_000e6); // back to start
    }

    function test_RevertRepayWithoutDebt() public {
        _seed();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(LendingPool.NoDebt.selector, address(usdc)));
        pool.repay(address(usdc), 1e6);
    }

    // =====================================================================
    // Withdraw with debt / liquidity
    // =====================================================================

    function test_RevertWithdrawCollateralBackingDebt() public {
        _seed();
        vm.startPrank(bob);
        pool.borrow(address(usdc), 2_000e6);
        // 0.5 WETH left = $1,125 borrow power < $2,000 debt
        vm.expectRevert(abi.encodeWithSelector(LendingPool.InsufficientCollateral.selector, 1_125e18, 2_000e18));
        pool.withdraw(address(weth), 0.5e18);
        vm.stopPrank();
    }

    function test_WithdrawPartOfCollateralWithDebt() public {
        _seed();
        vm.startPrank(bob);
        pool.borrow(address(usdc), 1_000e6);
        pool.withdraw(address(weth), 0.5e18); // $1,125 power >= $1,000 debt
        vm.stopPrank();
        assertEq(pool.suppliedBalance(address(weth), bob), 0.5e18);
    }

    function test_FullExitAfterRepay() public {
        _seed();
        vm.startPrank(bob);
        pool.borrow(address(usdc), 2_000e6);
        pool.repay(address(usdc), type(uint256).max);
        pool.withdraw(address(weth), type(uint256).max);
        vm.stopPrank();
        assertEq(weth.balanceOf(bob), 10e18);
    }

    /// Lent-out cash cannot be withdrawn by the lender until it is repaid.
    function test_RevertLenderWithdrawWhileLentOut() public {
        _seed();
        vm.prank(bob);
        pool.borrow(address(usdc), 2_000e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LendingPool.InsufficientLiquidity.selector, 48_000e6, 50_000e6));
        pool.withdraw(address(usdc), type(uint256).max);
    }

    // =====================================================================
    // Price moves & oracle failures
    // =====================================================================

    function test_PriceDropBlocksMoreBorrowAndWithdraw() public {
        _seed();
        vm.prank(bob);
        pool.borrow(address(usdc), 2_000e6);

        vm.prank(owner);
        oracle.setPrice(address(weth), 2_500e18); // power $1,875 < debt $2,000

        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(LendingPool.InsufficientCollateral.selector, 1_875e18, 2_001e18));
        pool.borrow(address(usdc), 1e6);
        vm.expectRevert(abi.encodeWithSelector(LendingPool.InsufficientCollateral.selector, 1_874.25e18, 2_000e18));
        pool.withdraw(address(weth), 0.0004e18);

        // ...but repaying always works
        pool.repay(address(usdc), 500e6);
        vm.stopPrank();
        assertEq(pool.borrowedBalance(address(usdc), bob), 1_500e6);
    }

    /// Oracle down (e.g. stale price / breaker tripped): borrowing stops,
    /// but repaying and debt-free withdrawals keep working.
    function test_OracleFailureOnlyBlocksRiskyActions() public {
        _seed();
        vm.prank(bob);
        pool.borrow(address(usdc), 1_000e6);

        vm.mockCallRevert(address(oracle), abi.encodeWithSelector(oracle.getPrice.selector), "oracle down");

        vm.prank(bob);
        vm.expectRevert();
        pool.borrow(address(usdc), 1e6);

        vm.prank(bob);
        pool.repay(address(usdc), type(uint256).max); // no price needed

        vm.prank(alice);
        pool.withdraw(address(usdc), 1_000e6); // alice has no debt: no price needed
        assertEq(usdc.balanceOf(alice), 51_000e6);
    }

    // =====================================================================
    // Fuzz / invariant
    // =====================================================================

    /// For any borrow within LTV and any repay: token balance = supplied - borrowed.
    function testFuzz_CashAccounting(uint256 borrowAmt, uint256 repayAmt) public {
        _seed();
        borrowAmt = bound(borrowAmt, 1, 2_250e6);
        repayAmt = bound(repayAmt, 1, borrowAmt);

        vm.startPrank(bob);
        pool.borrow(address(usdc), borrowAmt);
        pool.repay(address(usdc), repayAmt);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(pool)), pool.totalSupplied(address(usdc)) - pool.totalBorrowed(address(usdc)));
        assertEq(pool.borrowedBalance(address(usdc), bob), borrowAmt - repayAmt);

        LendingPool.AccountData memory a = pool.getAccountData(bob);
        assertLe(a.debtValue, a.borrowPower);
    }
}
