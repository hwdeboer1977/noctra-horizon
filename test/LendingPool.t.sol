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
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice"); // USDC supplier (lender)
    address bob = makeAddr("bob"); // WETH supplier, USDC borrower
    address carol = makeAddr("carol");

    uint256 constant RAY = 1e27;

    function _usdcModel() internal pure returns (LendingPool.RateModel memory) {
        // 0% base, +4% up to 90% utilization, +60% above: at 100% U borrowers pay 64%
        return LendingPool.RateModel({
            baseRate: 0, slope1: 0.04e27, slope2: 0.6e27, optimalUtil: 0.9e27, reserveFactorBps: 1000
        });
    }

    function _wethModel() internal pure returns (LendingPool.RateModel memory) {
        return LendingPool.RateModel({
            baseRate: 0, slope1: 0.03e27, slope2: 0.8e27, optimalUtil: 0.8e27, reserveFactorBps: 1500
        });
    }

    function setUp() public {
        vm.warp(1_800_000_000);
        usdc = new MockERC20("USD Coin (mock)", "USDC", 6);
        weth = new MockERC20("Wrapped Ether (mock)", "WETH", 18);
        oracle = new MockPriceOracle(owner);
        pool = new LendingPool(owner, address(oracle), treasury);

        vm.startPrank(owner);
        oracle.setPrice(address(weth), 3000e18);
        oracle.setPrice(address(usdc), 1e18);
        pool.addAsset(address(weth), 7500, true, _wethModel()); // 75% LTV
        pool.addAsset(address(usdc), 7000, true, _usdcModel()); // 70% LTV
        vm.stopPrank();

        usdc.mint(alice, 100_000e6);
        usdc.mint(carol, 100_000e6);
        weth.mint(bob, 10e18);
        usdc.mint(bob, 1_000e6); // for repaying (incl. interest)

        vm.prank(alice);
        usdc.approve(address(pool), type(uint256).max);
        vm.prank(carol);
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

    function test_AddAssetInitialState() public view {
        (bool supported, bool borrowEnabled, uint16 ltv, uint8 dec) = pool.assetConfig(address(usdc));
        assertTrue(supported);
        assertTrue(borrowEnabled);
        assertEq(ltv, 7000);
        assertEq(dec, 6);
        (uint256 li, uint256 bi,,,,) = pool.reserve(address(usdc));
        assertEq(li, RAY); // indices start at 1.0
        assertEq(bi, RAY);
    }

    function test_RevertAddAssetNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        pool.addAsset(address(0xBEEF), 5000, true, _usdcModel());
    }

    function test_RevertAddAssetTwice() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(LendingPool.AssetAlreadySupported.selector, address(usdc)));
        pool.addAsset(address(usdc), 5000, true, _usdcModel());
    }

    function test_RevertLtvTooHigh() public {
        MockERC20 x = new MockERC20("X", "X", 18);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(LendingPool.InvalidLtv.selector, 9500));
        pool.addAsset(address(x), 9500, true, _usdcModel());
    }

    function test_RevertInvalidRateModel() public {
        MockERC20 x = new MockERC20("X", "X", 18);
        LendingPool.RateModel memory m = _usdcModel();
        m.optimalUtil = RAY; // kink at 100% -> division by zero above it
        vm.prank(owner);
        vm.expectRevert(LendingPool.InvalidRateModel.selector);
        pool.addAsset(address(x), 5000, true, m);
    }

    // =====================================================================
    // Supply / withdraw
    // =====================================================================

    function test_Supply() public {
        vm.prank(alice);
        pool.supply(address(usdc), 1_000e6);
        assertEq(pool.supplyBalanceOf(address(usdc), alice), 1_000e6);
        assertEq(pool.availableLiquidity(address(usdc)), 1_000e6);
        assertEq(usdc.balanceOf(address(pool)), 1_000e6);
    }

    function test_RevertSupplyWithoutApproval() public {
        address dave = makeAddr("dave");
        usdc.mint(dave, 100e6);
        vm.prank(dave);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(pool), 0, 100e6)
        );
        pool.supply(address(usdc), 100e6);
    }

    function test_WithdrawMaxWithoutDebt() public {
        vm.startPrank(alice);
        pool.supply(address(usdc), 1_000e6);
        uint256 out = pool.withdraw(address(usdc), type(uint256).max);
        vm.stopPrank();
        assertEq(out, 1_000e6);
        assertEq(usdc.balanceOf(alice), 100_000e6);
        assertEq(pool.scaledSupplyOf(address(usdc), alice), 0);
    }

    function test_RevertWithdrawMoreThanSupplied() public {
        vm.startPrank(alice);
        pool.supply(address(usdc), 1_000e6);
        vm.expectRevert(abi.encodeWithSelector(LendingPool.InsufficientBalance.selector, 1_000e6, 1_001e6));
        pool.withdraw(address(usdc), 1_001e6);
        vm.stopPrank();
    }

    // =====================================================================
    // Borrow / repay (no time passes: no interest)
    // =====================================================================

    function test_BorrowWithinLtv() public {
        _seed();
        vm.prank(bob);
        pool.borrow(address(usdc), 2_000e6);
        assertEq(pool.debtBalanceOf(address(usdc), bob), 2_000e6);
        assertEq(usdc.balanceOf(bob), 3_000e6);
        assertEq(pool.availableLiquidity(address(usdc)), 48_000e6);
    }

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
        pool.borrow(address(usdc), 2_250.000001e6);
    }

    function test_RevertBorrowMoreThanLiquidity() public {
        _seed();
        weth.mint(bob, 100e18);
        vm.startPrank(bob);
        pool.supply(address(weth), 100e18);
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

    function test_RepayPartialAndFull() public {
        _seed();
        vm.startPrank(bob);
        pool.borrow(address(usdc), 2_000e6);
        assertEq(pool.repay(address(usdc), 500e6), 500e6);
        assertEq(pool.debtBalanceOf(address(usdc), bob), 1_500e6);
        assertEq(pool.repay(address(usdc), type(uint256).max), 1_500e6);
        vm.stopPrank();
        assertEq(pool.scaledDebtOf(address(usdc), bob), 0);
    }

    function test_RevertRepayWithoutDebt() public {
        _seed();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(LendingPool.NoDebt.selector, address(usdc)));
        pool.repay(address(usdc), 1e6);
    }

    function test_RevertWithdrawCollateralBackingDebt() public {
        _seed();
        vm.startPrank(bob);
        pool.borrow(address(usdc), 2_000e6);
        vm.expectRevert(abi.encodeWithSelector(LendingPool.InsufficientCollateral.selector, 1_125e18, 2_000e18));
        pool.withdraw(address(weth), 0.5e18);
        vm.stopPrank();
    }

    function test_RevertLenderWithdrawWhileLentOut() public {
        _seed();
        vm.prank(bob);
        pool.borrow(address(usdc), 2_000e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LendingPool.InsufficientLiquidity.selector, 48_000e6, 50_000e6));
        pool.withdraw(address(usdc), type(uint256).max);
    }

    function test_OracleFailureOnlyBlocksRiskyActions() public {
        _seed();
        vm.prank(bob);
        pool.borrow(address(usdc), 1_000e6);
        vm.mockCallRevert(address(oracle), abi.encodeWithSelector(oracle.getPrice.selector), "oracle down");

        vm.prank(bob);
        vm.expectRevert();
        pool.borrow(address(usdc), 1e6);

        vm.prank(bob);
        pool.repay(address(usdc), type(uint256).max);
        vm.prank(alice);
        pool.withdraw(address(usdc), 1_000e6);
    }

    // =====================================================================
    // Rate model
    // =====================================================================

    function test_RateCurve() public view {
        address a = address(usdc);
        assertEq(pool.borrowRateAt(a, 0), 0); // base
        assertEq(pool.borrowRateAt(a, 0.45e27), 0.02e27); // halfway to kink: half of slope1
        assertEq(pool.borrowRateAt(a, 0.9e27), 0.04e27); // at the kink: slope1
        assertEq(pool.borrowRateAt(a, 0.95e27), 0.34e27); // 4% + 60% * 0.05/0.10
        assertEq(pool.borrowRateAt(a, RAY), 0.64e27); // 100% utilization
    }

    function test_ReserveDataRates() public {
        _seed();
        vm.prank(bob);
        pool.borrow(address(usdc), 2_000e6); // U = 2,000 / 50,000 = 4%

        (uint256 totalSupply, uint256 totalDebt, uint256 u, uint256 br, uint256 sr) = pool.getReserveData(address(usdc));
        assertEq(totalSupply, 50_000e6);
        assertEq(totalDebt, 2_000e6);
        assertEq(u, 0.04e27);
        assertEq(br, uint256(0.04e27) * 0.04e27 / 0.9e27); // ~0.178%
        assertEq(sr, br * 0.04e27 / RAY * 9000 / 10000); // borrowRate x U x (1 - 10%)
    }

    // =====================================================================
    // Interest over time
    // =====================================================================

    function test_NoBorrowNoInterest() public {
        vm.prank(alice);
        pool.supply(address(usdc), 1_000e6);
        vm.warp(block.timestamp + 365 days);
        assertEq(pool.supplyBalanceOf(address(usdc), alice), 1_000e6);
    }

    /// One year at U = 4%: borrower pays the rate, supplier gets 90%, treasury 10%.
    function test_InterestOneYear() public {
        _seed();
        vm.prank(bob);
        pool.borrow(address(usdc), 2_000e6);

        vm.warp(block.timestamp + 365 days);
        pool.accrue(address(usdc));

        uint256 rate = uint256(0.04e27) * 0.04e27 / 0.9e27; // borrow rate at 4% U
        uint256 interest = 2_000e6 * rate / RAY; // ~3.555555 USDC

        assertApproxEqAbs(pool.debtBalanceOf(address(usdc), bob), 2_000e6 + interest, 1);
        assertApproxEqAbs(pool.supplyBalanceOf(address(usdc), alice), 50_000e6 + interest * 9 / 10, 1);
        assertApproxEqAbs(pool.supplyBalanceOf(address(usdc), treasury), interest / 10, 1);
    }

    /// The whole point of indices: a late supplier does not get interest earned before they joined.
    function test_LateSupplierGetsNoPastInterest() public {
        _seed();
        vm.prank(bob);
        pool.borrow(address(usdc), 2_000e6);
        vm.warp(block.timestamp + 365 days);

        vm.prank(carol);
        pool.supply(address(usdc), 1_000e6);
        assertApproxEqAbs(pool.supplyBalanceOf(address(usdc), carol), 1_000e6, 1);
        assertGt(pool.supplyBalanceOf(address(usdc), alice), 50_000e6);
    }

    /// Interest grows debt; at max LTV that alone blocks further borrowing and withdrawing.
    function test_InterestErodesBorrowPower() public {
        _seed();
        vm.prank(bob);
        pool.borrow(address(usdc), 2_250e6);
        vm.warp(block.timestamp + 30 days);

        LendingPool.AccountData memory a = pool.getAccountData(bob);
        assertGt(a.debtValue, a.borrowPower);

        vm.startPrank(bob);
        vm.expectRevert();
        pool.borrow(address(usdc), 1e6);
        vm.expectRevert();
        pool.withdraw(address(weth), 0.001e18);
        vm.stopPrank();
    }

    /// Changing the rate model must not apply new rates retroactively.
    function test_SetRateModelAccruesFirst() public {
        _seed();
        vm.prank(bob);
        pool.borrow(address(usdc), 2_000e6);
        vm.warp(block.timestamp + 365 days);

        uint256 debtBefore = pool.debtBalanceOf(address(usdc), bob);
        LendingPool.RateModel memory m = _usdcModel();
        m.baseRate = 0.5e27; // 50% base rate from now on
        vm.prank(owner);
        pool.setRateModel(address(usdc), m);

        assertEq(pool.debtBalanceOf(address(usdc), bob), debtBefore); // past year unchanged
    }

    /// After a year of interest everyone can fully exit; only rounding dust stays behind.
    function test_FullExitAfterInterest() public {
        _seed();
        vm.prank(bob);
        pool.borrow(address(usdc), 2_000e6);
        vm.warp(block.timestamp + 365 days);

        vm.startPrank(bob);
        pool.repay(address(usdc), type(uint256).max);
        pool.withdraw(address(weth), type(uint256).max);
        vm.stopPrank();

        vm.prank(alice);
        pool.withdraw(address(usdc), type(uint256).max);
        vm.prank(treasury);
        pool.withdraw(address(usdc), type(uint256).max);

        assertLe(pool.availableLiquidity(address(usdc)), 2); // dust from rounding in the pool's favour
        assertEq(usdc.balanceOf(address(pool)), pool.availableLiquidity(address(usdc)));
        assertEq(weth.balanceOf(bob), 10e18);
        assertGt(usdc.balanceOf(alice), 100_000e6); // alice earned interest
    }

    // =====================================================================
    // Fuzz: solvency and index monotonicity
    // =====================================================================

    function testFuzz_SolvencyOverTime(uint256 borrowAmt, uint32 dt1, uint32 dt2, uint256 repayAmt) public {
        _seed();
        borrowAmt = bound(borrowAmt, 1e6, 2_250e6);
        vm.prank(bob);
        pool.borrow(address(usdc), borrowAmt);

        vm.warp(block.timestamp + bound(dt1, 1, 365 days));
        vm.prank(bob);
        pool.repay(address(usdc), bound(repayAmt, 1, borrowAmt));

        vm.warp(block.timestamp + bound(dt2, 1, 365 days));
        pool.accrue(address(usdc));

        (uint256 totalSupply, uint256 totalDebt,,,) = pool.getReserveData(address(usdc));
        uint256 cash = pool.availableLiquidity(address(usdc));

        assertEq(usdc.balanceOf(address(pool)), cash); // tracked cash == real balance
        assertGe(cash + totalDebt + 2, totalSupply); // claims covered (2 wei rounding slack)

        (uint256 li, uint256 bi,,,,) = pool.reserve(address(usdc));
        assertGe(li, RAY);
        assertGe(bi, RAY);
    }
}
