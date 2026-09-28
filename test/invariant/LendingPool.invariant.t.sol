// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {LendingPool} from "../../src/LendingPool.sol";
import {MockERC20} from "../../src/MockERC20.sol";
import {MockPriceOracle} from "../../src/MockPriceOracle.sol";
import {LendingPoolHandler} from "./LendingPoolHandler.sol";

/// @title LendingPoolInvariantTest
/// @notice Properties that must hold after ANY sequence of supply / withdraw / borrow /
///         repay / liquidate / price moves / time jumps.
///
///         Run:  forge test --mc LendingPoolInvariantTest -vv
///         More: FOUNDRY_INVARIANT_RUNS=1000 FOUNDRY_INVARIANT_DEPTH=200 forge test --mc LendingPoolInvariantTest
contract LendingPoolInvariantTest is Test {
    LendingPool pool;
    MockERC20 usdc;
    MockERC20 weth;
    MockPriceOracle oracle;
    LendingPoolHandler handler;

    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address[] actors;

    uint256 constant RAY = 1e27;

    function setUp() public {
        vm.warp(1_800_000_000);
        usdc = new MockERC20("USD Coin (mock)", "USDC", 6);
        weth = new MockERC20("Wrapped Ether (mock)", "WETH", 18);
        oracle = new MockPriceOracle(owner);
        pool = new LendingPool(owner, address(oracle), treasury);

        vm.startPrank(owner);
        oracle.setPrice(address(weth), 3000e18);
        oracle.setPrice(address(usdc), 1e18);
        pool.addAsset(
            address(weth),
            LendingPool.RiskParams({ltvBps: 7500, liqThresholdBps: 8000, liqBonusBps: 750, borrowEnabled: true}),
            LendingPool.RateModel({
                baseRate: 0, slope1: 0.03e27, slope2: 0.8e27, optimalUtil: 0.8e27, reserveFactorBps: 1500
            })
        );
        pool.addAsset(
            address(usdc),
            LendingPool.RiskParams({ltvBps: 7000, liqThresholdBps: 7500, liqBonusBps: 500, borrowEnabled: true}),
            LendingPool.RateModel({
                baseRate: 0, slope1: 0.04e27, slope2: 0.6e27, optimalUtil: 0.9e27, reserveFactorBps: 1000
            })
        );
        vm.stopPrank();

        actors.push(makeAddr("actor0"));
        actors.push(makeAddr("actor1"));
        actors.push(makeAddr("actor2"));
        actors.push(makeAddr("actor3"));

        handler = new LendingPoolHandler(pool, usdc, weth, oracle, owner, treasury, actors);

        // Only the handler's functions get called by the fuzzer.
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = LendingPoolHandler.supply.selector;
        selectors[1] = LendingPoolHandler.withdraw.selector;
        selectors[2] = LendingPoolHandler.borrow.selector;
        selectors[3] = LendingPoolHandler.repay.selector;
        selectors[4] = LendingPoolHandler.liquidate.selector;
        selectors[5] = LendingPoolHandler.setEthPrice.selector;
        selectors[6] = LendingPoolHandler.warp.selector;
        selectors[7] = LendingPoolHandler.accrue.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // =====================================================================
    // Invariants
    // =====================================================================

    /// 1. Tracked cash equals the real token balance. Nothing in the handler donates
    ///    tokens, so any difference means the pool moved tokens without booking it.
    function invariant_CashMatchesBalance() public view {
        assertEq(usdc.balanceOf(address(pool)), pool.availableLiquidity(address(usdc)), "USDC cash");
        assertEq(weth.balanceOf(address(pool)), pool.availableLiquidity(address(weth)), "WETH cash");
    }

    /// 2. The per-user scaled balances add up to the reserve totals, exactly.
    ///    Holders: the actors plus the treasury (which receives the reserve factor).
    function invariant_ScaledBalancesSumToTotals() public view {
        for (uint256 i; i < 2; ++i) {
            address asset = handler.assetAt(i);
            uint256 sumSupply = pool.scaledSupplyOf(asset, treasury);
            uint256 sumDebt = pool.scaledDebtOf(asset, treasury);
            for (uint256 j; j < actors.length; ++j) {
                sumSupply += pool.scaledSupplyOf(asset, actors[j]);
                sumDebt += pool.scaledDebtOf(asset, actors[j]);
            }
            (,, uint256 totalScaledSupply, uint256 totalScaledDebt,,) = pool.reserve(asset);
            assertEq(sumSupply, totalScaledSupply, "scaled supply sum");
            assertEq(sumDebt, totalScaledDebt, "scaled debt sum");
        }
    }

    /// 3. Accounting solvency: everything suppliers can claim is backed by cash in the
    ///    pool plus debt owed to it. Rounding always favours the pool, so this should
    ///    hold with at most a few wei of slack.
    ///    NOTE: this counts bad debt as an asset. It proves the books balance, not that
    ///    every dollar of debt is collectable (see the bad-debt notes in LendingPool).
    function invariant_Solvency() public view {
        for (uint256 i; i < 2; ++i) {
            address asset = handler.assetAt(i);
            (uint256 totalSupply, uint256 totalDebt,,,) = pool.getReserveData(asset);
            uint256 cash = pool.availableLiquidity(asset);
            assertGe(cash + totalDebt + 2, totalSupply, "claims exceed cash + debt");
        }
    }

    /// 4. Indices start at 1.0 and never decrease.
    function invariant_IndicesMonotonic() public view {
        for (uint256 i; i < 2; ++i) {
            address asset = handler.assetAt(i);
            (uint256 li, uint256 bi,,,,) = pool.reserve(asset);
            assertGe(li, RAY, "liquidity index < 1");
            assertGe(bi, RAY, "borrow index < 1");
            assertGe(li, handler.ghostMaxLiquidityIndex(asset), "liquidity index decreased");
            assertGe(bi, handler.ghostMaxBorrowIndex(asset), "borrow index decreased");
        }
    }

    /// 5. No user-initiated borrow or withdraw ever left the user above their borrow power.
    function invariant_BorrowPowerEnforced() public view {
        assertFalse(handler.ghostBorrowPowerViolated(), "borrow/withdraw exceeded borrow power");
    }

    /// 6. Every successful liquidation reduced the borrower's debt and collateral,
    ///    and the liquidator received at least the value they repaid.
    function invariant_LiquidationSane() public view {
        assertFalse(handler.ghostLiquidationViolated(), "liquidation property violated");
    }

    /// 7. Utilization never exceeds 100% (debt can't be larger than cash + debt).
    function invariant_UtilizationBounded() public view {
        for (uint256 i; i < 2; ++i) {
            (,, uint256 u,,) = pool.getReserveData(handler.assetAt(i));
            assertLe(u, RAY, "utilization > 100%");
        }
    }

    /// Prints how often each action ran, so you can see liquidations actually happened.
    function afterInvariant() public view {
        console.log("supply            ", handler.calls("supply"));
        console.log("withdraw          ", handler.calls("withdraw"));
        console.log("borrow            ", handler.calls("borrow"));
        console.log("repay             ", handler.calls("repay"));
        console.log("liquidate         ", handler.calls("liquidate"));
        console.log("liquidate_revert  ", handler.calls("liquidate_revert"));
        console.log("setEthPrice       ", handler.calls("setEthPrice"));
        console.log("warp              ", handler.calls("warp"));
        console.log("accrue            ", handler.calls("accrue"));
    }
}
