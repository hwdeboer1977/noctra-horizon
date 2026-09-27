# Audit report: `LendingPool` liquidations

| | |
| --- | --- |
| **Date** | 2026-09-27 |
| **Scope** | `src/LendingPool.sol` (step 5: liquidations), and how it interacts with `src/RelayedPriceOracle.sol` |
| **Code version** | Uncommitted working tree on top of commit `426cd2d` |
| **Method** | Manual review, plus proof-of-concept Forge tests run in an isolated copy (see [Appendix](#appendix-proof-of-concept-tests)) |
| **Test status** | All 77 existing tests pass |
| **Reviewer** | AI audit agent (Claude). This is not a substitute for a professional audit before mainnet. |

## Summary

| ID | Severity | Title | PoC |
| --- | --- | --- | --- |
| H-1 | High | Bad debt keeps charging interest, and the last suppliers to withdraw take the loss | ✅ |
| H-2 | High | One failing price feed stops every liquidation for anyone holding that asset | ✅ |
| M-1 | Medium | Deposits that don't count as collateral can still be seized, and their bonus has no upper limit | ✅ |
| M-2 | Medium | The owner can change the oracle or risk settings instantly, with no delay | Not needed |
| L-1 … L-6 | Low / Info | See below | |

---

## High

### H-1. Bad debt keeps charging interest, and the last suppliers to withdraw take the loss

When a position's collateral is worth less than its debt, `liquidate` takes all the collateral and the rest of the debt stays in `scaledDebtOf`. Nothing ever writes it off. It keeps accruing interest, which raises `liquidityIndex`, so suppliers' balances and the treasury's share grow from interest nobody will ever pay.

Withdrawals are first-come, first-served against real `cash`. Early withdrawers get paid in full and the last ones find the pool empty. That gives everyone a reason to rush out once bad debt appears.

**PoC** (`test_poc_BadDebtInflatesSupplierClaims`): ETH drops to $1,500 and Bob's position is fully liquidated.

| | t = 0 | t = +1 year |
| --- | --- | --- |
| Supplier claims (USDC) | 50,000.00 | 50,000.65 |
| Bad debt (USDC) | 854.65 | 855.30 |
| Real cash (USDC) | 49,145.35 | 49,145.35 |

The contract comment admits the gap, but not that the bad debt keeps growing and paying out interest.

**Fix:** when a liquidation leaves zero collateral, write the remaining debt off. Cover it from the treasury or a reserve, or spread the loss across suppliers by lowering `liquidityIndex`.

### H-2. One failing price feed stops every liquidation for anyone holding that asset

`_accountData` calls `oracle.getPrice` for *every* asset the user holds, and `liquidate` depends on it. If any one of those feeds reverts (stale, tripped or unset), the borrower can't be liquidated at all, even through a different collateral/debt pair.

**PoC** (`test_poc_UnrelatedOracleBlocksLiquidation`): Bob is deeply underwater on WETH/USDC, and his small DAI deposit's feed reverts. `liquidate(weth, usdc, bob, …)` reverts.

This interacts badly with `RelayedPriceOracle`'s circuit breaker. It trips on moves over 20 % (ETH), which is exactly the kind of crash when liquidations are needed. Liquidations freeze until the owner acts, and bad debt (H-1) builds up in the meantime.

**Fix:**

- Decide explicitly how liquidations should behave while a breaker is tripped. One option: allow them at the `pending` price, or at the lower of the trusted and pending prices.
- Alert the owner automatically when a breaker trips.
- Consider leaving assets that are zero-weight or tiny out of the health-factor calculation.

---

## Medium

### M-1. Deposits that don't count as collateral can still be seized, and their bonus has no upper limit

`_computeLiquidation` lets a liquidator seize *any* supplied asset, even one with `liqThresholdBps = 0` that contributes nothing to the health factor.

`_validateRiskParams` only checks `threshold × (1 + bonus) < 100 %`. When the threshold is 0 that check passes for any bonus, up to `uint16` max (655 %). When the threshold is low, the allowed bonus is still huge.

**PoC** (`test_poc_NonCollateralSeizedWithHugeBonus`): DAI is listed with threshold 0 and bonus 65535. Bob is liquidatable because of his WETH/USDC position. A liquidator pays **132 USDC** and takes Bob's entire **$1,000 of DAI**.

**Fix:**

- Reject a `collateralAsset` whose `liqThresholdBps == 0`.
- Cap `liqBonusBps` directly, e.g. at 20 %.

### M-2. The owner can change the oracle or risk settings instantly, with no delay

`setOracle`, `setRiskParams` and `setRateModel` all take effect immediately. A compromised or malicious owner key could switch to a fake oracle, or cut `liqThresholdBps`, and liquidate every user in the same block. The code comment already says a timelock should come later.

**Fix:**

- Put these functions behind a Safe multisig plus a timelock.
- Optionally, make threshold decreases apply only to new borrows, or phase them in gradually.

---

## Low / informational

- **L-1. Prices can lag the market.** The relay adds delay on top of Chainlink's own heartbeat and deviation settings, and `maxAge` allows ETH prices up to 70 minutes old. During fast moves, people can borrow or liquidate at an outdated price. The gap between LTV and liquidation threshold helps, but only partly.
- **L-2. Small positions may never be liquidated.** No one will liquidate a position if the bonus is smaller than the gas cost. A 50 % close factor on a small debt can also leave uneconomic leftovers. Either way these remain as bad debt. A minimum borrow size or a rule against leaving tiny remainders would help.
- **L-3. Rounding favours the liquidator in one branch.** When a liquidation takes all of a collateral, `debtCovered = mulDiv(userColl, den, num)` rounds down, so the liquidator pays slightly less (wei-level). Rounding up would favour the pool.
- **L-4. The treasury's balance reads too low between updates.** `supplyBalanceOf(treasury)` and `getAccountData` leave out the treasury share not yet credited since the last update, so they under-report until someone triggers an update. This affects displayed values only.
- **L-5. No emergency pause.** There's no way to freeze supply or borrow during an incident while still allowing repay and liquidate.
- **L-6. Open from the earlier review:**
  - `setTreasury` doesn't catch up on interest first, so interest earned since the last update goes to the new treasury.
  - Fee-on-transfer and rebasing tokens would break the `cash` bookkeeping. List only standard ERC20s.

## Checked and fine

- **Reentrancy:** every entry point has `nonReentrant`, and state is updated before tokens move.
- **Self-liquidation:** no profit is possible.
- **Same asset as collateral and debt:** the `cash` bookkeeping stays correct.
- **Close-factor limits** and the check that a repay can't exceed the debt work as intended.
- **Arithmetic:** no overflow in `_seizeRatio` for realistic prices and decimals.
- **Health factor:** a position at maximum LTV has a buffer before it becomes liquidatable.
- **Inflation attack:** the classic first-depositor attack doesn't work, because donated tokens don't change `liquidityIndex`.
- **Partial liquidation and health factor:** a 50 % liquidation at HF 0.96 improved HF (0.960 → 0.965). The death-spiral case needs collateral/debt < 1 + bonus, and in that range a full liquidation is already allowed.

## Suggested fix order

1. **H-1:** write off bad debt.
2. **M-1:** reject zero-threshold collateral and cap the bonus.
3. **H-2:** decide how liquidations work during an oracle outage.
4. **M-2:** timelock before mainnet.

---

## Appendix: proof-of-concept tests

These tests extend `LendingPoolTest` from `test/LendingPool.t.sol`. To run them, save the file as `test/AuditPoC.t.sol` and run:

```shell
forge test --match-contract AuditPoC -vv
```

Once a finding is fixed, flip its assertions so the test keeps it fixed.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {LendingPoolTest} from "./LendingPool.t.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {MockERC20} from "../src/MockERC20.sol";
import {console2} from "forge-std/Test.sol";

contract AuditPoC is LendingPoolTest {
    MockERC20 dai;

    function _addDai(uint16 thr, uint16 bonus) internal {
        dai = new MockERC20("Dai", "DAI", 18);
        vm.startPrank(owner);
        oracle.setPrice(address(dai), 1e18);
        pool.addAsset(
            address(dai),
            LendingPool.RiskParams({ltvBps: 0, liqThresholdBps: thr, liqBonusBps: bonus, borrowEnabled: true}),
            _usdcModel()
        );
        vm.stopPrank();
        dai.mint(bob, 1_000e18);
        vm.startPrank(bob);
        dai.approve(address(pool), type(uint256).max);
        pool.supply(address(dai), 1_000e18);
        vm.stopPrank();
    }

    /// M-1: non-collateral asset (threshold 0) accepted with a 655% bonus and is seizable.
    function test_poc_NonCollateralSeizedWithHugeBonus() public {
        _bobAtMaxLtv();
        _addDai(0, type(uint16).max);
        _setEth(2_750e18); // HF < 1 because of WETH/USDC only
        vm.prank(carol);
        (uint256 covered, uint256 seized) = pool.liquidate(address(dai), address(usdc), bob, type(uint256).max, true);
        assertEq(seized, 1_000e18); // all $1,000 of DAI taken for ~$132 of debt
        assertLt(covered, 140e6);
    }

    /// H-2: an unrelated asset's oracle failing blocks liquidation of an underwater position.
    function test_poc_UnrelatedOracleBlocksLiquidation() public {
        _bobAtMaxLtv();
        _addDai(0, 0);
        _setEth(2_000e18); // deeply underwater on WETH/USDC
        vm.prank(owner);
        oracle.setPrice(address(dai), 0); // DAI feed down (stale / tripped)
        vm.prank(carol);
        vm.expectRevert();
        pool.liquidate(address(weth), address(usdc), bob, type(uint256).max, true);
    }

    /// H-1: bad debt keeps accruing interest; supplier claims grow past what exists.
    function test_poc_BadDebtInflatesSupplierClaims() public {
        _bobAtMaxLtv();
        _setEth(1_500e18); // 1 WETH ($1,500) vs 2,250 USDC debt
        vm.prank(carol);
        pool.liquidate(address(weth), address(usdc), bob, type(uint256).max, true);
        LendingPool.AccountData memory a = pool.getAccountData(bob);
        assertEq(a.collateralValue, 0);
        assertGt(a.debtValue, 0); // unbacked debt remains

        (uint256 s0,,,,) = pool.getReserveData(address(usdc));
        vm.warp(block.timestamp + 365 days);
        (uint256 s1,,,,) = pool.getReserveData(address(usdc));
        uint256 cash = pool.availableLiquidity(address(usdc));
        console2.log("supply claims t0", s0, "t1", s1);
        console2.log("real assets (cash)", cash);
        assertGt(s1 - cash, s0 - cash); // shortfall grows over time
    }
}
```
