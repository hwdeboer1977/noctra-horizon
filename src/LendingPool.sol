// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPriceOracle} from "./IPriceOracle.sol";

/// @title LendingPool — step 5: liquidations
/// @notice Supply, withdraw, borrow, repay with interest, and liquidations:
///         anyone can repay part of an unhealthy position's debt and receive the
///         borrower's collateral plus a bonus.
///
///         TWO RATIOS PER COLLATERAL ASSET:
///         - LTV (e.g. 75%): how much you may BORROW against it. Checked on borrow/withdraw.
///         - Liquidation threshold (e.g. 80%): when you can be LIQUIDATED. Always > LTV,
///           so a fresh position at max LTV has a buffer before it is liquidatable.
///
///         HEALTH FACTOR = sum(collateral value x liquidation threshold) / sum(debt value)
///           HF >= 1 : safe          HF < 1 : liquidatable
///
///         HOW INTEREST WORKS (no loops over users):
///         - Each asset has two global indices that start at 1.0 (RAY = 1e27):
///             liquidityIndex  grows with the interest suppliers earn
///             borrowIndex     grows with the interest borrowers owe
///         - Users store SCALED balances:  scaled = amount / index  (at the time of the action)
///         - Real balance at any moment:   amount = scaled * currentIndex
///         - Every action first calls _accrue(asset), which moves both indices forward
///           for the time elapsed since the last update.
///
///         RATE MODEL (per asset, "kinked"): utilization U = debt / (cash + debt)
///           U <= optimal: borrowRate = base + slope1 * U / optimal
///           U >  optimal: borrowRate = base + slope1 + slope2 * (U - optimal) / (1 - optimal)
///           supplyRate  = borrowRate * U * (1 - reserveFactor)
///
/// @dev    Known gap: BAD DEBT. If collateral is worth less than the debt, a liquidation
///         seizes all collateral and the rest of the debt stays on the books with nothing
///         behind it. Suppliers implicitly absorb it. No write-off / reserve fund yet.
contract LendingPool is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------
    // Types & constants
    // ---------------------------------------------------------------------

    /// @notice Interest rate model parameters. Rates are per YEAR, in RAY (1e27 = 100%).
    struct RateModel {
        uint256 baseRate; // borrow rate at 0% utilization
        uint256 slope1; // added between 0% and optimal utilization
        uint256 slope2; // added between optimal and 100% (steep)
        uint256 optimalUtil; // the kink, in RAY, e.g. 0.9e27 = 90%
        uint16 reserveFactorBps; // share of interest to the treasury, e.g. 1000 = 10%
    }

    /// @notice Risk parameters per asset, set by the owner.
    struct RiskParams {
        uint16 ltvBps; // max borrow power per $1 of this collateral, e.g. 7500 = 75%
        uint16 liqThresholdBps; // collateral weight in the health factor, e.g. 8000 = 80%
        uint16 liqBonusBps; // extra collateral a liquidator receives, e.g. 750 = 7.5%
        bool borrowEnabled; // can be borrowed
    }

    struct AssetConfig {
        bool supported;
        bool borrowEnabled;
        uint16 ltvBps;
        uint16 liqThresholdBps;
        uint16 liqBonusBps;
        uint8 decimals; // token decimals, read once at listing
    }

    struct ReserveState {
        uint256 liquidityIndex; // RAY, starts at 1e27
        uint256 borrowIndex; // RAY, starts at 1e27
        uint256 totalScaledSupply;
        uint256 totalScaledDebt;
        uint256 cash; // tokens in the pool for this asset (tracked, not balanceOf)
        uint40 lastUpdate; // timestamp of last accrual
    }

    /// @notice A user's position valued in USD, 1e18 scale, including accrued interest.
    struct AccountData {
        uint256 collateralValue; // unweighted
        uint256 borrowPower; // collateral x LTV
        uint256 liquidationCollateral; // collateral x liquidation threshold
        uint256 debtValue;
        uint256 healthFactor; // 1e18 = 1.0; type(uint256).max if no debt
    }

    /// @dev Scratch space for liquidate() (avoids "stack too deep").
    struct LiqVars {
        uint256 userDebtScaled;
        uint256 userCollScaled;
        uint256 debtCovered;
        uint256 collateralSeized;
        uint256 debtScaledBurn;
        uint256 collScaledMove;
    }

    uint256 internal constant RAY = 1e27;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;
    uint256 internal constant MAX_LTV_BPS = 9_000;
    uint256 internal constant MAX_ASSETS = 10;
    /// @dev Sanity cap for the admin: 1000% APR max borrow rate.
    uint256 internal constant MAX_RATE = 10 * RAY;
    uint256 internal constant WAD = 1e18;
    /// @dev Above this HF a liquidator may repay at most CLOSE_FACTOR of the debt per call;
    ///      below it, the whole debt (the position is too far gone to close in halves).
    uint256 internal constant FULL_LIQUIDATION_HF = 0.95e18;
    uint256 internal constant CLOSE_FACTOR_BPS = 5_000;

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    IPriceOracle public oracle;
    address public treasury;

    mapping(address asset => AssetConfig) public assetConfig;
    mapping(address asset => RateModel) public rateModel;
    mapping(address asset => ReserveState) public reserve;
    address[] public assetList;

    /// @notice Scaled balances. Use supplyBalanceOf / debtBalanceOf for real amounts.
    mapping(address asset => mapping(address user => uint256)) public scaledSupplyOf;
    mapping(address asset => mapping(address user => uint256)) public scaledDebtOf;

    // ---------------------------------------------------------------------
    // Events & errors
    // ---------------------------------------------------------------------

    event OracleSet(address indexed oracle);
    event TreasurySet(address indexed treasury);
    event AssetAdded(address indexed asset);
    event RiskParamsSet(
        address indexed asset, uint16 ltvBps, uint16 liqThresholdBps, uint16 liqBonusBps, bool borrowEnabled
    );
    event RateModelSet(address indexed asset);
    event Accrued(address indexed asset, uint256 liquidityIndex, uint256 borrowIndex, uint256 treasuryScaled);
    event Supplied(address indexed asset, address indexed user, uint256 amount);
    event Withdrawn(address indexed asset, address indexed user, uint256 amount);
    event Borrowed(address indexed asset, address indexed user, uint256 amount);
    event Repaid(address indexed asset, address indexed user, uint256 amount);
    event Liquidated(
        address indexed user,
        address indexed liquidator,
        address collateralAsset,
        address debtAsset,
        uint256 debtCovered,
        uint256 collateralSeized,
        bool receivedUnderlying
    );

    error ZeroAddress();
    error ZeroAmount();
    error AssetNotSupported(address asset);
    error AssetAlreadySupported(address asset);
    error TooManyAssets();
    error InvalidRiskParams();
    error InvalidRateModel();
    error BorrowNotEnabled(address asset);
    error InsufficientBalance(uint256 available, uint256 requested);
    error InsufficientLiquidity(uint256 available, uint256 requested);
    error InsufficientCollateral(uint256 borrowPower, uint256 debtValue);
    error NoDebt(address asset);
    error PositionHealthy(uint256 healthFactor);

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    /// @param initialOwner Admin (later: a multisig).
    /// @param oracle_      MockPriceOracle in tests, RelayedPriceOracle on Horizen.
    /// @param treasury_    Receives the reserve factor as a supply position.
    constructor(address initialOwner, address oracle_, address treasury_) Ownable(initialOwner) {
        if (oracle_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        oracle = IPriceOracle(oracle_);
        treasury = treasury_;
        emit OracleSet(oracle_);
        emit TreasurySet(treasury_);
    }

    // ---------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------

    function setOracle(address oracle_) external onlyOwner {
        if (oracle_ == address(0)) revert ZeroAddress();
        oracle = IPriceOracle(oracle_);
        emit OracleSet(oracle_);
    }

    /// @dev Only affects future accruals; the old treasury keeps what it earned.
    function setTreasury(address treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    function addAsset(address asset, RiskParams calldata risk, RateModel calldata model) external onlyOwner {
        if (asset == address(0)) revert ZeroAddress();
        if (assetConfig[asset].supported) revert AssetAlreadySupported(asset);
        if (assetList.length >= MAX_ASSETS) revert TooManyAssets();
        _validateRiskParams(risk);
        _validateRateModel(model);

        assetConfig[asset] = AssetConfig({
            supported: true,
            borrowEnabled: risk.borrowEnabled,
            ltvBps: risk.ltvBps,
            liqThresholdBps: risk.liqThresholdBps,
            liqBonusBps: risk.liqBonusBps,
            decimals: IERC20Metadata(asset).decimals()
        });
        rateModel[asset] = model;
        reserve[asset] = ReserveState({
            liquidityIndex: RAY,
            borrowIndex: RAY,
            totalScaledSupply: 0,
            totalScaledDebt: 0,
            cash: 0,
            lastUpdate: uint40(block.timestamp)
        });
        assetList.push(asset);
        emit AssetAdded(asset);
        emit RiskParamsSet(asset, risk.ltvBps, risk.liqThresholdBps, risk.liqBonusBps, risk.borrowEnabled);
        emit RateModelSet(asset);
    }

    /// @dev Lowering the liquidation threshold can make existing positions liquidatable
    ///      instantly. Announce such changes (and later: put them behind a timelock).
    function setRiskParams(address asset, RiskParams calldata risk) external onlyOwner {
        AssetConfig storage cfg = _supported(asset);
        _validateRiskParams(risk);
        cfg.ltvBps = risk.ltvBps;
        cfg.liqThresholdBps = risk.liqThresholdBps;
        cfg.liqBonusBps = risk.liqBonusBps;
        cfg.borrowEnabled = risk.borrowEnabled;
        emit RiskParamsSet(asset, risk.ltvBps, risk.liqThresholdBps, risk.liqBonusBps, risk.borrowEnabled);
    }

    /// @notice Change the rate model. Accrues FIRST, so the old rates apply to the
    ///         time already elapsed and the new rates only from now on.
    function setRateModel(address asset, RateModel calldata model) external onlyOwner {
        _supported(asset);
        _validateRateModel(model);
        _accrue(asset);
        rateModel[asset] = model;
        emit RateModelSet(asset);
    }

    // ---------------------------------------------------------------------
    // Supply / withdraw
    // ---------------------------------------------------------------------

    function supply(address asset, uint256 amount) external nonReentrant {
        _supported(asset);
        if (amount == 0) revert ZeroAmount();
        ReserveState storage r = _accrue(asset);

        // Round DOWN: the user gets slightly less claim, never more.
        uint256 scaled = _rayDivDown(amount, r.liquidityIndex);
        if (scaled == 0) revert ZeroAmount();

        scaledSupplyOf[asset][msg.sender] += scaled;
        r.totalScaledSupply += scaled;
        r.cash += amount;

        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        emit Supplied(asset, msg.sender, amount);
    }

    /// @param amount type(uint256).max withdraws your full balance INCLUDING interest earned
    ///               up to this block (which you cannot know exactly when sending the tx).
    function withdraw(address asset, uint256 amount) external nonReentrant returns (uint256) {
        _supported(asset);
        if (amount == 0) revert ZeroAmount();
        ReserveState storage r = _accrue(asset);

        uint256 userScaled = scaledSupplyOf[asset][msg.sender];
        uint256 balance = _rayMulDown(userScaled, r.liquidityIndex);
        if (amount == type(uint256).max) amount = balance;
        if (amount == 0) revert ZeroAmount();
        if (amount > balance) revert InsufficientBalance(balance, amount);
        if (amount > r.cash) revert InsufficientLiquidity(r.cash, amount);

        // Round UP: burn slightly more scaled balance, never less. Full exit burns everything.
        uint256 scaledBurn = amount == balance ? userScaled : _rayDivUp(amount, r.liquidityIndex);
        if (scaledBurn > userScaled) scaledBurn = userScaled;

        scaledSupplyOf[asset][msg.sender] = userScaled - scaledBurn;
        r.totalScaledSupply -= scaledBurn;
        r.cash -= amount;

        if (_hasDebt(msg.sender)) _requireBorrowCapacity(msg.sender);

        IERC20(asset).safeTransfer(msg.sender, amount);
        emit Withdrawn(asset, msg.sender, amount);
        return amount;
    }

    // ---------------------------------------------------------------------
    // Borrow / repay
    // ---------------------------------------------------------------------

    function borrow(address asset, uint256 amount) external nonReentrant {
        AssetConfig storage cfg = _supported(asset);
        if (!cfg.borrowEnabled) revert BorrowNotEnabled(asset);
        if (amount == 0) revert ZeroAmount();
        ReserveState storage r = _accrue(asset);
        if (amount > r.cash) revert InsufficientLiquidity(r.cash, amount);

        // Round UP: the borrower owes slightly more, never less.
        uint256 scaled = _rayDivUp(amount, r.borrowIndex);
        scaledDebtOf[asset][msg.sender] += scaled;
        r.totalScaledDebt += scaled;
        r.cash -= amount;

        _requireBorrowCapacity(msg.sender);

        IERC20(asset).safeTransfer(msg.sender, amount);
        emit Borrowed(asset, msg.sender, amount);
    }

    /// @param amount Anything >= current debt (incl. type(uint256).max) repays everything,
    ///               including interest accrued up to this block.
    function repay(address asset, uint256 amount) external nonReentrant returns (uint256) {
        _supported(asset);
        if (amount == 0) revert ZeroAmount();
        ReserveState storage r = _accrue(asset);

        uint256 userScaled = scaledDebtOf[asset][msg.sender];
        if (userScaled == 0) revert NoDebt(asset);
        uint256 debt = _rayMulUp(userScaled, r.borrowIndex);

        uint256 scaledBurn;
        if (amount >= debt) {
            amount = debt;
            scaledBurn = userScaled;
        } else {
            // Round DOWN: a partial repay clears slightly less debt, never more.
            scaledBurn = _rayDivDown(amount, r.borrowIndex);
        }

        scaledDebtOf[asset][msg.sender] = userScaled - scaledBurn;
        r.totalScaledDebt -= scaledBurn;
        r.cash += amount;

        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        emit Repaid(asset, msg.sender, amount);
        return amount;
    }

    // ---------------------------------------------------------------------
    // Liquidation
    // ---------------------------------------------------------------------

    /// @notice Repay part of an unhealthy position's debt and receive its collateral + bonus.
    ///
    ///         Example: Bob owes 2,250 USDC against 1 WETH. ETH falls to $2,750, so
    ///         HF = 2,750 x 80% / 2,250 = 0.98 < 1. A liquidator repays 1,125 USDC (50%)
    ///         and receives 1,125 x 1.075 / 2,750 = 0.4398 WETH ($1,209.38): an $84 profit.
    ///
    /// @param debtToCover        Upper bound. Clamped to the close factor (50% of the debt,
    ///                           or 100% if HF < 0.95) and to what the collateral can pay for.
    /// @param receiveUnderlying  true: receive collateral tokens (needs free cash in that
    ///                           reserve). false: receive it as a supply position in the pool.
    function liquidate(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        bool receiveUnderlying
    ) external nonReentrant returns (uint256 debtCovered, uint256 collateralSeized) {
        _supported(collateralAsset);
        _supported(debtAsset);
        if (debtToCover == 0) revert ZeroAmount();
        ReserveState storage cr = _accrue(collateralAsset);
        ReserveState storage dr = _accrue(debtAsset);

        LiqVars memory v = _computeLiquidation(collateralAsset, debtAsset, user, debtToCover);
        debtCovered = v.debtCovered;
        collateralSeized = v.collateralSeized;

        // Debt side: burn the borrower's debt; the repaid tokens become cash.
        scaledDebtOf[debtAsset][user] = v.userDebtScaled - v.debtScaledBurn;
        dr.totalScaledDebt -= v.debtScaledBurn;
        dr.cash += debtCovered;

        // Collateral side: take it from the borrower.
        scaledSupplyOf[collateralAsset][user] = v.userCollScaled - v.collScaledMove;
        if (receiveUnderlying) {
            if (collateralSeized > cr.cash) revert InsufficientLiquidity(cr.cash, collateralSeized);
            cr.totalScaledSupply -= v.collScaledMove;
            cr.cash -= collateralSeized;
        } else {
            scaledSupplyOf[collateralAsset][msg.sender] += v.collScaledMove; // total unchanged
        }

        IERC20(debtAsset).safeTransferFrom(msg.sender, address(this), debtCovered);
        if (receiveUnderlying) IERC20(collateralAsset).safeTransfer(msg.sender, collateralSeized);

        emit Liquidated(user, msg.sender, collateralAsset, debtAsset, debtCovered, collateralSeized, receiveUnderlying);
    }

    /// @dev Bookkeeping math for liquidate(). Assumes both reserves are accrued.
    function _computeLiquidation(address collateralAsset, address debtAsset, address user, uint256 debtToCover)
        internal
        view
        returns (LiqVars memory v)
    {
        uint256 hf = _accountData(user).healthFactor;
        if (hf >= WAD) revert PositionHealthy(hf);

        v.userDebtScaled = scaledDebtOf[debtAsset][user];
        if (v.userDebtScaled == 0) revert NoDebt(debtAsset);
        uint256 borrowIndex = reserve[debtAsset].borrowIndex;
        uint256 userDebt = _rayMulUp(v.userDebtScaled, borrowIndex);

        // 1. Close factor
        uint256 maxClose = hf < FULL_LIQUIDATION_HF ? userDebt : Math.mulDiv(userDebt, CLOSE_FACTOR_BPS, BPS);
        v.debtCovered = debtToCover > maxClose ? maxClose : debtToCover;

        // 2. Collateral to seize: debt value x (1 + bonus), in collateral units
        (uint256 num, uint256 den) = _seizeRatio(collateralAsset, debtAsset);
        v.collateralSeized = Math.mulDiv(v.debtCovered, num, den);

        // 3. Not enough of this collateral: seize all of it, cover proportionally less.
        //    Debt left with no collateral behind it is BAD DEBT (see contract notes).
        uint256 liquidityIndex = reserve[collateralAsset].liquidityIndex;
        v.userCollScaled = scaledSupplyOf[collateralAsset][user];
        uint256 userColl = _rayMulDown(v.userCollScaled, liquidityIndex);
        if (v.collateralSeized > userColl) {
            v.collateralSeized = userColl;
            v.debtCovered = Math.mulDiv(userColl, den, num);
        }
        if (v.debtCovered == 0 || v.collateralSeized == 0) revert ZeroAmount();

        // 4. Scaled amounts (rounding in the pool's favour)
        v.debtScaledBurn = v.debtCovered >= userDebt ? v.userDebtScaled : _rayDivDown(v.debtCovered, borrowIndex);
        // A dust repay (e.g. 1 wei once borrowIndex > 1) rounds down to 0 scaled debt burned.
        // Without this check the borrower would lose collateral while their debt stays the same.
        if (v.debtScaledBurn == 0) revert ZeroAmount();
        v.collScaledMove =
            v.collateralSeized == userColl ? v.userCollScaled : _rayDivUp(v.collateralSeized, liquidityIndex);
        if (v.collScaledMove > v.userCollScaled) v.collScaledMove = v.userCollScaled;
    }

    /// @dev collateral units = debt units x num / den, where
    ///        num = priceDebt x (1 + bonus) x 10^collDecimals
    ///        den = priceColl x 1           x 10^debtDecimals
    function _seizeRatio(address collateralAsset, address debtAsset) internal view returns (uint256 num, uint256 den) {
        AssetConfig storage cc = assetConfig[collateralAsset];
        num = oracle.getPrice(debtAsset) * (BPS + cc.liqBonusBps) * (10 ** cc.decimals);
        den = oracle.getPrice(collateralAsset) * BPS * (10 ** assetConfig[debtAsset].decimals);
    }

    /// @notice Anyone can move the indices forward (e.g. a keeper during quiet periods,
    ///         so interest compounds more often).
    function accrue(address asset) external {
        _supported(asset);
        _accrue(asset);
    }

    // ---------------------------------------------------------------------
    // Views (all include interest accrued up to now)
    // ---------------------------------------------------------------------

    function supplyBalanceOf(address asset, address user) public view returns (uint256) {
        (uint256 li,,) = _previewAccrual(asset);
        return _rayMulDown(scaledSupplyOf[asset][user], li);
    }

    function debtBalanceOf(address asset, address user) public view returns (uint256) {
        (, uint256 bi,) = _previewAccrual(asset);
        return _rayMulUp(scaledDebtOf[asset][user], bi);
    }

    function availableLiquidity(address asset) external view returns (uint256) {
        return reserve[asset].cash;
    }

    /// @return totalSupply  all suppliers' claims incl. treasury (underlying units)
    /// @return totalDebt    all borrowers' debt (underlying units)
    /// @return utilization  RAY
    /// @return borrowRate   RAY per year
    /// @return supplyRate   RAY per year
    function getReserveData(address asset)
        external
        view
        returns (uint256 totalSupply, uint256 totalDebt, uint256 utilization, uint256 borrowRate, uint256 supplyRate)
    {
        ReserveState storage r = reserve[asset];
        (uint256 li, uint256 bi, uint256 treasuryScaled) = _previewAccrual(asset);
        totalSupply = _rayMulDown(r.totalScaledSupply + treasuryScaled, li);
        totalDebt = _rayMulUp(r.totalScaledDebt, bi);
        utilization = _utilization(totalDebt, r.cash);
        borrowRate = borrowRateAt(asset, utilization);
        supplyRate =
            Math.mulDiv(Math.mulDiv(borrowRate, utilization, RAY), BPS - rateModel[asset].reserveFactorBps, BPS);
    }

    /// @notice The kinked curve, exposed so frontends/tests can plot it.
    function borrowRateAt(address asset, uint256 utilization) public view returns (uint256) {
        RateModel storage m = rateModel[asset];
        if (utilization <= m.optimalUtil) {
            return m.baseRate + Math.mulDiv(m.slope1, utilization, m.optimalUtil);
        }
        return m.baseRate + m.slope1 + Math.mulDiv(m.slope2, utilization - m.optimalUtil, RAY - m.optimalUtil);
    }

    function getAccountData(address user) external view returns (AccountData memory) {
        return _accountData(user);
    }

    function assetCount() external view returns (uint256) {
        return assetList.length;
    }

    // ---------------------------------------------------------------------
    // Internal: interest accrual
    // ---------------------------------------------------------------------

    /// @dev Writes the previewed indices to storage and mints the treasury's share.
    function _accrue(address asset) internal returns (ReserveState storage r) {
        r = reserve[asset];
        if (r.lastUpdate == block.timestamp) return r;

        (uint256 li, uint256 bi, uint256 treasuryScaled) = _previewAccrual(asset);
        r.liquidityIndex = li;
        r.borrowIndex = bi;
        r.lastUpdate = uint40(block.timestamp);
        if (treasuryScaled != 0) {
            scaledSupplyOf[asset][treasury] += treasuryScaled;
            r.totalScaledSupply += treasuryScaled;
        }
        emit Accrued(asset, li, bi, treasuryScaled);
    }

    /// @dev Computes the indices as they WOULD be now, without writing anything.
    ///
    ///      1. rate      = borrowRateAt(utilization at last update)
    ///      2. borrowIdx = borrowIdx * (1 + rate * dt / year)        (linear between accruals)
    ///      3. interest  = how much total debt grew
    ///      4. split:    treasury gets interest * reserveFactor, suppliers the rest
    ///      5. liqIdx   += supplierShare / totalScaledSupply           (spread over all suppliers)
    ///
    ///      Total supply grows by EXACTLY what total debt grew (supplier share + treasury
    ///      share), so claims on the pool never exceed cash + debt: solvent by construction.
    function _previewAccrual(address asset)
        internal
        view
        returns (uint256 liquidityIndex, uint256 borrowIndex, uint256 treasuryScaled)
    {
        ReserveState storage r = reserve[asset];
        liquidityIndex = r.liquidityIndex;
        borrowIndex = r.borrowIndex;

        uint256 dt = block.timestamp - r.lastUpdate;
        if (dt == 0 || r.totalScaledDebt == 0 || r.totalScaledSupply == 0) {
            return (liquidityIndex, borrowIndex, 0);
        }

        uint256 totalDebt = _rayMulDown(r.totalScaledDebt, borrowIndex);
        uint256 rate = borrowRateAt(asset, _utilization(totalDebt, r.cash));

        uint256 newBorrowIndex = _rayMulDown(borrowIndex, RAY + (rate * dt) / SECONDS_PER_YEAR);
        uint256 interest = _rayMulDown(r.totalScaledDebt, newBorrowIndex) - totalDebt;
        if (interest == 0) return (liquidityIndex, newBorrowIndex, 0);

        uint256 treasuryShare = Math.mulDiv(interest, rateModel[asset].reserveFactorBps, BPS);
        uint256 supplierShare = interest - treasuryShare;

        liquidityIndex += Math.mulDiv(supplierShare, RAY, r.totalScaledSupply);
        borrowIndex = newBorrowIndex;
        treasuryScaled = _rayDivDown(treasuryShare, liquidityIndex);
    }

    /// @dev U = debt / (cash + debt). Uses tracked cash, so donating tokens to the
    ///      contract cannot push rates down.
    function _utilization(uint256 totalDebt, uint256 cash) internal pure returns (uint256) {
        if (totalDebt == 0) return 0;
        return Math.mulDiv(totalDebt, RAY, cash + totalDebt);
    }

    /// @dev LTV <= threshold < 100%, and liquidating at HF = 1 must not pay out more
    ///      collateral than exists: threshold x (1 + bonus) < 100%. Otherwise every
    ///      liquidation would create bad debt.
    function _validateRiskParams(RiskParams calldata r) internal pure {
        if (r.ltvBps > MAX_LTV_BPS) revert InvalidRiskParams();
        if (r.ltvBps > r.liqThresholdBps || r.liqThresholdBps >= BPS) revert InvalidRiskParams();
        if (uint256(r.liqThresholdBps) * (BPS + r.liqBonusBps) >= BPS * BPS) revert InvalidRiskParams();
    }

    function _validateRateModel(RateModel calldata m) internal pure {
        if (m.optimalUtil == 0 || m.optimalUtil >= RAY) revert InvalidRateModel();
        if (m.reserveFactorBps > BPS) revert InvalidRateModel();
        if (m.baseRate + m.slope1 + m.slope2 > MAX_RATE) revert InvalidRateModel();
    }

    // ---------------------------------------------------------------------
    // Internal: valuation
    // ---------------------------------------------------------------------

    /// @dev Uses PREVIEWED indices for every asset, so interest on reserves not touched
    ///      in this tx is still counted. Rounding favours the pool.
    function _accountData(address user) internal view returns (AccountData memory a) {
        uint256 n = assetList.length;
        for (uint256 i; i < n; ++i) {
            address asset = assetList[i];
            uint256 sSupply = scaledSupplyOf[asset][user];
            uint256 sDebt = scaledDebtOf[asset][user];
            if (sSupply == 0 && sDebt == 0) continue;

            AssetConfig storage cfg = assetConfig[asset];
            (uint256 li, uint256 bi,) = _previewAccrual(asset);
            uint256 price = oracle.getPrice(asset);
            uint256 unit = 10 ** cfg.decimals;

            if (sSupply != 0) {
                uint256 value = Math.mulDiv(_rayMulDown(sSupply, li), price, unit);
                a.collateralValue += value;
                a.borrowPower += Math.mulDiv(value, cfg.ltvBps, BPS);
                a.liquidationCollateral += Math.mulDiv(value, cfg.liqThresholdBps, BPS);
            }
            if (sDebt != 0) {
                a.debtValue += Math.mulDiv(_rayMulUp(sDebt, bi), price, unit, Math.Rounding.Ceil);
            }
        }
        a.healthFactor = a.debtValue == 0 ? type(uint256).max : Math.mulDiv(a.liquidationCollateral, WAD, a.debtValue);
    }

    function _requireBorrowCapacity(address user) internal view {
        AccountData memory a = _accountData(user);
        if (a.debtValue > a.borrowPower) revert InsufficientCollateral(a.borrowPower, a.debtValue);
    }

    function _hasDebt(address user) internal view returns (bool) {
        uint256 n = assetList.length;
        for (uint256 i; i < n; ++i) {
            if (scaledDebtOf[assetList[i]][user] != 0) return true;
        }
        return false;
    }

    function _supported(address asset) internal view returns (AssetConfig storage cfg) {
        cfg = assetConfig[asset];
        if (!cfg.supported) revert AssetNotSupported(asset);
    }

    // ---------------------------------------------------------------------
    // Internal: RAY math with explicit rounding
    // ---------------------------------------------------------------------

    function _rayMulDown(uint256 a, uint256 b) internal pure returns (uint256) {
        return Math.mulDiv(a, b, RAY);
    }

    function _rayMulUp(uint256 a, uint256 b) internal pure returns (uint256) {
        return Math.mulDiv(a, b, RAY, Math.Rounding.Ceil);
    }

    function _rayDivDown(uint256 a, uint256 b) internal pure returns (uint256) {
        return Math.mulDiv(a, RAY, b);
    }

    function _rayDivUp(uint256 a, uint256 b) internal pure returns (uint256) {
        return Math.mulDiv(a, RAY, b, Math.Rounding.Ceil);
    }
}
