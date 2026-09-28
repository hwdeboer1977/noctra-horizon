// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {LendingPool} from "../../src/LendingPool.sol";
import {MockERC20} from "../../src/MockERC20.sol";
import {MockPriceOracle} from "../../src/MockPriceOracle.sol";

/// @title LendingPoolHandler
/// @notice The fuzzer calls these functions in random order with random inputs.
///         Each function bounds its inputs to something sensible, picks an actor,
///         and calls the pool. Calls that the pool rejects (e.g. borrow above LTV)
///         simply revert; with fail_on_revert = false the run continues.
///
///         After EVERY call, forge checks all invariant_* functions in the test contract.
///
///         Ghost variables record things the pool itself does not store, so the
///         invariants can check them (e.g. "the index never went down").
contract LendingPoolHandler is Test {
    LendingPool public pool;
    MockERC20 public usdc;
    MockERC20 public weth;
    MockPriceOracle public oracle;
    address public owner;
    address public treasury;

    address[] public actors;
    address[2] public assets;

    // ---------------------------------------------------------------------
    // Ghost state
    // ---------------------------------------------------------------------

    /// @dev Highest index seen so far per asset. Indices must never decrease.
    mapping(address asset => uint256) public ghostMaxLiquidityIndex;
    mapping(address asset => uint256) public ghostMaxBorrowIndex;

    /// @dev Set to true if a user-initiated borrow/withdraw SUCCEEDED but left the
    ///      user with debt > borrow power. The pool must make this impossible.
    bool public ghostBorrowPowerViolated;

    /// @dev Set to true if a successful liquidation did not reduce the borrower's
    ///      debt, or did not reduce their collateral, or made the liquidator lose value.
    bool public ghostLiquidationViolated;

    /// @dev Call counters, printed at the end so you can see the fuzzer actually
    ///      exercised every path (a suite where liquidate never succeeds proves little).
    mapping(bytes32 => uint256) public calls;

    uint256 internal constant WAD = 1e18;

    constructor(
        LendingPool pool_,
        MockERC20 usdc_,
        MockERC20 weth_,
        MockPriceOracle oracle_,
        address owner_,
        address treasury_,
        address[] memory actors_
    ) {
        pool = pool_;
        usdc = usdc_;
        weth = weth_;
        oracle = oracle_;
        owner = owner_;
        treasury = treasury_;
        actors = actors_;
        assets = [address(weth_), address(usdc_)];

        for (uint256 i; i < 2; ++i) {
            (uint256 li, uint256 bi,,,,) = pool.reserve(assets[i]);
            ghostMaxLiquidityIndex[assets[i]] = li;
            ghostMaxBorrowIndex[assets[i]] = bi;
        }
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _asset(uint256 seed) internal view returns (address) {
        return assets[seed % 2];
    }

    /// @dev Realistic amount range per asset: 0.001 - 100 WETH, 1 - 200k USDC.
    function _boundAmount(address asset, uint256 amount) internal view returns (uint256) {
        return asset == address(weth) ? bound(amount, 1e15, 100e18) : bound(amount, 1e6, 200_000e6);
    }

    function _mintAndApprove(address actor, address asset, uint256 amount) internal {
        MockERC20(asset).mint(actor, amount);
        vm.prank(actor);
        MockERC20(asset).approve(address(pool), type(uint256).max);
    }

    function _updateIndexGhosts() internal {
        for (uint256 i; i < 2; ++i) {
            (uint256 li, uint256 bi,,,,) = pool.reserve(assets[i]);
            if (li > ghostMaxLiquidityIndex[assets[i]]) ghostMaxLiquidityIndex[assets[i]] = li;
            if (bi > ghostMaxBorrowIndex[assets[i]]) ghostMaxBorrowIndex[assets[i]] = bi;
        }
    }

    /// @dev Called after a user action that the pool must only allow within borrow power.
    function _checkBorrowPower(address actor) internal {
        LendingPool.AccountData memory a = pool.getAccountData(actor);
        if (a.debtValue > a.borrowPower) ghostBorrowPowerViolated = true;
    }

    // ---------------------------------------------------------------------
    // Actions
    // ---------------------------------------------------------------------

    function supply(uint256 actorSeed, uint256 assetSeed, uint256 amount) external {
        address actor = _actor(actorSeed);
        address asset = _asset(assetSeed);
        amount = _boundAmount(asset, amount);
        _mintAndApprove(actor, asset, amount);

        vm.prank(actor);
        pool.supply(asset, amount);
        calls["supply"]++;
        _updateIndexGhosts();
    }

    function withdraw(uint256 actorSeed, uint256 assetSeed, uint256 amount, bool max) external {
        address actor = _actor(actorSeed);
        address asset = _asset(assetSeed);
        uint256 bal = pool.supplyBalanceOf(asset, actor);
        if (bal == 0) return;
        amount = max ? type(uint256).max : bound(amount, 1, bal);

        vm.prank(actor);
        pool.withdraw(asset, amount);
        calls["withdraw"]++;
        _checkBorrowPower(actor);
        _updateIndexGhosts();
    }

    /// @dev Borrows a random fraction (50-100%) of the actor's remaining borrow power:
    ///      always within LTV, and biased toward near-max positions so that price moves
    ///      and interest actually push them under water.
    function borrow(uint256 actorSeed, uint256 assetSeed, uint256 fractionBps) external {
        address actor = _actor(actorSeed);
        address asset = _asset(assetSeed);

        LendingPool.AccountData memory a = pool.getAccountData(actor);
        if (a.borrowPower <= a.debtValue) return;
        uint256 headroomUsd = a.borrowPower - a.debtValue; // 1e18 USD
        fractionBps = bound(fractionBps, 5_000, 10_000);

        (,,,,, uint8 dec) = pool.assetConfig(asset);
        uint256 price = oracle.getPrice(asset);
        uint256 amount = headroomUsd * fractionBps / 10_000 * (10 ** dec) / price;
        uint256 cash = pool.availableLiquidity(asset);
        if (amount > cash) amount = cash;
        if (amount == 0) return;

        vm.prank(actor);
        pool.borrow(asset, amount);
        calls["borrow"]++;
        _checkBorrowPower(actor);
        _updateIndexGhosts();
    }

    function repay(uint256 actorSeed, uint256 assetSeed, uint256 amount, bool max) external {
        address actor = _actor(actorSeed);
        address asset = _asset(assetSeed);
        uint256 debt = pool.debtBalanceOf(asset, actor);
        if (debt == 0) return;
        amount = max ? type(uint256).max : bound(amount, 1, debt);
        _mintAndApprove(actor, asset, max ? debt : amount);

        vm.prank(actor);
        pool.repay(asset, amount);
        calls["repay"]++;
        _updateIndexGhosts();
    }

    /// @dev Finds the first unhealthy actor (starting at a random one) and liquidates the
    ///      first (collateral, debt) pair it holds. Scanning all actors instead of picking
    ///      one at random makes liquidations happen far more often in a run.
    function liquidate(uint256 liqSeed, uint256 userSeed, uint256 amount, bool receiveUnderlying) external {
        uint256 n = actors.length;
        for (uint256 i; i < n; ++i) {
            address user = actors[(userSeed + i) % n];
            if (pool.getAccountData(user).healthFactor >= WAD) continue;

            address liquidator = _actor(liqSeed);
            if (liquidator == user) liquidator = _actor(liqSeed + 1);
            if (_liquidateUser(liquidator, user, amount, receiveUnderlying)) return;
        }
    }

    /// @dev Liquidates the first (collateral, debt) pair the user holds. False if none.
    function _liquidateUser(address liquidator, address user, uint256 amount, bool receiveUnderlying)
        internal
        returns (bool)
    {
        for (uint256 d; d < 2; ++d) {
            address debtAsset = assets[d];
            uint256 debt = pool.debtBalanceOf(debtAsset, user);
            if (debt == 0) continue;
            for (uint256 c; c < 2; ++c) {
                address collAsset = assets[c];
                if (pool.supplyBalanceOf(collAsset, user) == 0) continue;
                _liquidateOne(liquidator, user, collAsset, debtAsset, bound(amount, 1, debt), receiveUnderlying);
                return true;
            }
        }
        return false;
    }

    function _liquidateOne(
        address liquidator,
        address user,
        address collAsset,
        address debtAsset,
        uint256 amount,
        bool receiveUnderlying
    ) internal {
        _mintAndApprove(liquidator, debtAsset, amount);

        uint256 debtBefore = pool.debtBalanceOf(debtAsset, user);
        uint256 collBefore = pool.supplyBalanceOf(collAsset, user);

        vm.prank(liquidator);
        try pool.liquidate(collAsset, debtAsset, user, amount, receiveUnderlying) returns (
            uint256 covered, uint256 seized
        ) {
            calls["liquidate"]++;
            if (pool.debtBalanceOf(debtAsset, user) >= debtBefore) ghostLiquidationViolated = true;
            if (pool.supplyBalanceOf(collAsset, user) >= collBefore) ghostLiquidationViolated = true;

            // Liquidator must receive at least what they paid, in USD.
            // Tolerance: `seized` is rounded DOWN to whole collateral base units (in the
            // borrower's favour), so the liquidator can lose up to one base unit of
            // collateral. For USDC that is $0.000001, which matters for dust liquidations.
            (,,,,, uint8 cDec) = pool.assetConfig(collAsset);
            (,,,,, uint8 dDec) = pool.assetConfig(debtAsset);
            uint256 collPrice = oracle.getPrice(collAsset);
            uint256 paidUsd = covered * oracle.getPrice(debtAsset) / (10 ** dDec);
            uint256 gotUsd = seized * collPrice / (10 ** cDec);
            uint256 oneUnitUsd = collPrice / (10 ** cDec) + 1;
            if (gotUsd + oneUnitUsd < paidUsd) ghostLiquidationViolated = true;
        } catch {
            calls["liquidate_revert"]++;
        }
        _updateIndexGhosts();
    }

    /// @dev ETH moves within $500 - $6,000. USDC stays at $1.
    function setEthPrice(uint256 price) external {
        price = bound(price, 500e18, 6_000e18);
        vm.prank(owner);
        oracle.setPrice(address(weth), price);
        calls["setEthPrice"]++;
    }

    function warp(uint256 dt) external {
        dt = bound(dt, 1, 30 days);
        vm.warp(block.timestamp + dt);
        calls["warp"]++;
    }

    function accrue(uint256 assetSeed) external {
        pool.accrue(_asset(assetSeed));
        calls["accrue"]++;
        _updateIndexGhosts();
    }

    // ---------------------------------------------------------------------
    // Views for the invariant contract
    // ---------------------------------------------------------------------

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function assetAt(uint256 i) external view returns (address) {
        return assets[i];
    }
}
