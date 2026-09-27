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

    function _wethRisk() internal pure returns (LendingPool.RiskParams memory) {
        // borrow up to 75%, liquidatable at 80%, liquidator bonus 7.5%
        return LendingPool.RiskParams({ltvBps: 7500, liqThresholdBps: 8000, liqBonusBps: 750, borrowEnabled: true});
    }

    function _usdcRisk() internal pure returns (LendingPool.RiskParams memory) {
        return LendingPool.RiskParams({ltvBps: 7000, liqThresholdBps: 7500, liqBonusBps: 500, borrowEnabled: true});
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
        pool.addAsset(address(weth), _wethRisk(), _wethModel());
        pool.addAsset(address(usdc), _usdcRisk(), _usdcModel());
        vm.stopPrank();

        usdc.mint(alice, 100_000e6);
        usdc.mint(carol, 100_000e6); // carol is also our liquidator
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
        (bool supported, bool borrowEnabled, uint16 ltv, uint16 lt, uint16 bonus, uint8 dec) =
            pool.assetConfig(address(usdc));
        assertTrue(supported);
        assertTrue(borrowEnabled);
        assertEq(ltv, 7000);
        assertEq(lt, 7500);
        assertEq(bonus, 500);
        assertEq(dec, 6);
        (uint256 li, uint256 bi,,,,) = pool.reserve(address(usdc));
        assertEq(li, RAY); // indices start at 1.0
        assertEq(bi, RAY);
    }

    function test_RevertAddAssetNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        pool.addAsset(address(0xBEEF), _usdcRisk(), _usdcModel());
    }

    function test_RevertAddAssetTwice() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(LendingPool.AssetAlreadySupported.selector, address(usdc)));
        pool.addAsset(address(usdc), _usdcRisk(), _usdcModel());
    }

    function test_RevertLtvAboveThreshold() public {
        MockERC20 x = new MockERC20("X", "X", 18);
        LendingPool.RiskParams memory r = _usdcRisk();
        r.ltvBps = 8000; // above the 75% liquidation threshold
        vm.prank(owner);
        vm.expectRevert(LendingPool.InvalidRiskParams.selector);
        pool.addAsset(address(x), r, _usdcModel());
    }

    /// threshold x (1 + bonus) >= 100% would make every liquidation create bad debt.
    function test_RevertThresholdTimesBonusTooHigh() public {
        MockERC20 x = new MockERC20("X", "X", 18);
        LendingPool.RiskParams memory r =
            LendingPool.RiskParams({ltvBps: 9000, liqThresholdBps: 9500, liqBonusBps: 600, borrowEnabled: true});
        vm.prank(owner);
        vm.expectRevert(LendingPool.InvalidRiskParams.selector);
        pool.addAsset(address(x), r, _usdcModel());
    }

    function test_RevertInvalidRateModel() public {
        MockERC20 x = new MockERC20("X", "X", 18);
        LendingPool.RateModel memory m = _usdcModel();
        m.optimalUtil = RAY; // kink at 100% -> division by zero above it
        vm.prank(owner);
        vm.expectRevert(LendingPool.InvalidRateModel.selector);
        pool.addAsset(address(x), _usdcRisk(), m);
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
        LendingPool.RiskParams memory r = _usdcRisk();
        r.borrowEnabled = false;
        pool.setRiskParams(address(usdc), r);
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
    // Health factor & liquidations
    // =====================================================================

    /// Bob: 1 WETH collateral, borrows the max 2,250 USDC (75% LTV).
    function _bobAtMaxLtv() internal {
        _seed();
        vm.prank(bob);
        pool.borrow(address(usdc), 2_250e6);
    }

    function _setEth(uint256 price) internal {
        vm.prank(owner);
        oracle.setPrice(address(weth), price);
    }

    /// LTV (75%) < liquidation threshold (80%): a max-LTV position is still healthy.
    function test_HealthFactorBufferAtMaxLtv() public {
        _bobAtMaxLtv();
        LendingPool.AccountData memory a = pool.getAccountData(bob);
        assertEq(a.liquidationCollateral, 2_400e18); // $3,000 x 80%
        assertEq(a.healthFactor, uint256(2_400e18) * 1e18 / 2_250e18); // ~1.067
        assertGt(a.healthFactor, 1e18);
    }

    function test_NoDebtMeansInfiniteHealthFactor() public {
        _seed();
        assertEq(pool.getAccountData(bob).healthFactor, type(uint256).max);
    }

    function test_RevertLiquidateHealthy() public {
        _bobAtMaxLtv();
        uint256 hf = pool.getAccountData(bob).healthFactor;
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(LendingPool.PositionHealthy.selector, hf));
        pool.liquidate(address(weth), address(usdc), bob, 1_000e6, true);
    }

    /// ETH $3,000 -> $2,750: HF = 2,200 / 2,250 = 0.978. Above 0.95, so max 50% per call.
    function test_LiquidateHalfAboveFullThreshold() public {
        _bobAtMaxLtv();
        _setEth(2_750e18);
        assertLt(pool.getAccountData(bob).healthFactor, 1e18);

        uint256 carolUsdcBefore = usdc.balanceOf(carol);
        vm.prank(carol);
        (uint256 covered, uint256 seized) = pool.liquidate(address(weth), address(usdc), bob, type(uint256).max, true);

        assertEq(covered, 1_125e6); // clamped to 50% of 2,250
        uint256 expectedSeized = uint256(1_125e18) * 10_750 / 10_000 / 2_750; // 0.43977 WETH
        assertApproxEqAbs(seized, expectedSeized, 1e6);

        // Carol paid USDC, received WETH worth more than she paid (the bonus)
        assertEq(carolUsdcBefore - usdc.balanceOf(carol), 1_125e6);
        assertEq(weth.balanceOf(carol), seized);
        assertGt(seized * 2_750, 1_125e18); // WETH received is worth more than the 1,125 USDC paid

        // Bob: half the debt gone, collateral reduced, and his HF went UP
        assertEq(pool.debtBalanceOf(address(usdc), bob), 1_125e6);
        assertEq(pool.supplyBalanceOf(address(weth), bob), 1e18 - seized);
        assertGt(pool.getAccountData(bob).healthFactor, 1e18);
    }

    /// ETH -> $2,600: HF = 2,080 / 2,250 = 0.924 < 0.95, so the whole debt can be closed.
    function test_LiquidateFullBelowThreshold() public {
        _bobAtMaxLtv();
        _setEth(2_600e18);

        vm.prank(carol);
        (uint256 covered, uint256 seized) = pool.liquidate(address(weth), address(usdc), bob, type(uint256).max, true);

        assertEq(covered, 2_250e6);
        assertEq(pool.debtBalanceOf(address(usdc), bob), 0);
        // Bob keeps what the liquidator did not need: 1 - 2,250 x 1.075 / 2,600
        assertApproxEqAbs(pool.supplyBalanceOf(address(weth), bob), 1e18 - seized, 0);
        assertGt(pool.supplyBalanceOf(address(weth), bob), 0.069e18);
    }

    /// Liquidator can choose to receive the collateral as a pool position instead of tokens.
    function test_LiquidateReceiveAsSupplyPosition() public {
        _bobAtMaxLtv();
        _setEth(2_750e18);

        vm.prank(carol);
        (, uint256 seized) = pool.liquidate(address(weth), address(usdc), bob, type(uint256).max, false);

        assertEq(weth.balanceOf(carol), 0);
        assertApproxEqAbs(pool.supplyBalanceOf(address(weth), carol), seized, 1);
        assertEq(pool.availableLiquidity(address(weth)), 1e18); // no WETH left the pool
    }

    /// ETH crashes to $2,000: collateral ($2,000) is worth less than the debt ($2,250).
    /// The liquidator takes ALL collateral and covers only what it pays for.
    /// The rest of Bob's debt is BAD DEBT: nothing behind it.
    function test_BadDebtRemainsAfterCrash() public {
        _bobAtMaxLtv();
        _setEth(2_000e18);

        vm.prank(carol);
        (uint256 covered, uint256 seized) = pool.liquidate(address(weth), address(usdc), bob, type(uint256).max, true);

        assertEq(seized, 1e18); // all of Bob's WETH
        assertApproxEqAbs(covered, uint256(2_000e6) * 10_000 / 10_750, 1); // ~1,860.47 USDC
        assertEq(pool.supplyBalanceOf(address(weth), bob), 0);

        uint256 badDebt = pool.debtBalanceOf(address(usdc), bob);
        assertApproxEqAbs(badDebt, 2_250e6 - covered, 1); // ~389.53 USDC, uncollateralized
        assertEq(pool.getAccountData(bob).collateralValue, 0);
    }

    /// No price move needed: interest alone pushes a max-LTV position under water.
    function test_InterestMakesPositionLiquidatable() public {
        vm.prank(alice);
        pool.supply(address(usdc), 2_500e6); // small pool -> 90% utilization -> 4% APR
        vm.startPrank(bob);
        pool.supply(address(weth), 1e18);
        pool.borrow(address(usdc), 2_250e6);
        vm.stopPrank();

        assertGt(pool.getAccountData(bob).healthFactor, 1e18);
        vm.warp(block.timestamp + 2 * 365 days); // ~8% more debt > the 6.7% buffer
        assertLt(pool.getAccountData(bob).healthFactor, 1e18);

        vm.prank(carol);
        pool.liquidate(address(weth), address(usdc), bob, type(uint256).max, true);
        assertGt(pool.getAccountData(bob).healthFactor, 1e18);
    }

    function test_RevertLiquidateWrongDebtAsset() public {
        _bobAtMaxLtv();
        _setEth(2_750e18);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(LendingPool.NoDebt.selector, address(weth)));
        pool.liquidate(address(usdc), address(weth), bob, 1e18, true); // bob has no WETH debt
    }

    // =====================================================================
    // Fuzz: solvency and index monotonicity
    // =====================================================================

    /// Any price drop + max liquidation: tracked cash still equals real balances,
    /// and the debt never goes up.
    function testFuzz_LiquidationAccounting(uint256 ethPrice, uint256 debtToCover) public {
        _bobAtMaxLtv();
        ethPrice = bound(ethPrice, 500e18, 2_800e18);
        debtToCover = bound(debtToCover, 1e6, 10_000e6);
        _setEth(ethPrice);

        uint256 debtBefore = pool.debtBalanceOf(address(usdc), bob);
        vm.prank(carol);
        pool.liquidate(address(weth), address(usdc), bob, debtToCover, true);

        assertLt(pool.debtBalanceOf(address(usdc), bob), debtBefore);
        assertEq(usdc.balanceOf(address(pool)), pool.availableLiquidity(address(usdc)));
        assertEq(weth.balanceOf(address(pool)), pool.availableLiquidity(address(weth)));
    }

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
