// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPriceOracle} from "./IPriceOracle.sol";

/// @title LendingPool — step 3: supply, withdraw, borrow, repay (no interest yet)
/// @notice Users supply tokens as collateral and borrow other (or the same) tokens
///         against it, up to a loan-to-value (LTV) limit per collateral asset.
///         All values are compared in USD (1e18) using an IPriceOracle.
/// @dev    Not yet: interest, liquidations. Without liquidations a price drop can
///         leave a position under-collateralized with nobody able to close it.
contract LendingPool is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------
    // Types & constants
    // ---------------------------------------------------------------------

    struct AssetConfig {
        bool supported; // accepted by the pool
        bool borrowEnabled; // can be borrowed
        uint16 ltvBps; // max borrow power per $1 of this collateral, e.g. 7500 = 75%
        uint8 decimals; // token decimals, read once at listing
    }

    /// @notice A user's position valued in USD, 1e18 scale.
    struct AccountData {
        uint256 collateralValue; // sum of supplied value, unweighted
        uint256 borrowPower; // sum of supplied value x LTV
        uint256 debtValue; // sum of borrowed value
    }

    uint256 internal constant BPS = 10_000;
    uint256 internal constant MAX_LTV_BPS = 9_000; // sanity cap for the admin
    uint256 internal constant MAX_ASSETS = 10; // bounds the loop in _accountData

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    /// @notice Price source for all value comparisons.
    IPriceOracle public oracle;

    mapping(address asset => AssetConfig) public assetConfig;
    address[] public assetList;

    /// @notice Supplied amounts, in the token's base units.
    mapping(address asset => mapping(address user => uint256)) public suppliedBalance;
    mapping(address asset => uint256) public totalSupplied;

    /// @notice Borrowed amounts, in the token's base units.
    mapping(address asset => mapping(address user => uint256)) public borrowedBalance;
    mapping(address asset => uint256) public totalBorrowed;

    // ---------------------------------------------------------------------
    // Events & errors
    // ---------------------------------------------------------------------

    event OracleSet(address indexed oracle);
    event AssetAdded(address indexed asset, uint16 ltvBps, bool borrowEnabled);
    event AssetConfigUpdated(address indexed asset, uint16 ltvBps, bool borrowEnabled);
    event Supplied(address indexed asset, address indexed user, uint256 amount);
    event Withdrawn(address indexed asset, address indexed user, uint256 amount);
    event Borrowed(address indexed asset, address indexed user, uint256 amount);
    event Repaid(address indexed asset, address indexed user, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error AssetNotSupported(address asset);
    error AssetAlreadySupported(address asset);
    error TooManyAssets();
    error InvalidLtv(uint256 ltvBps);
    error BorrowNotEnabled(address asset);
    error InsufficientBalance(uint256 available, uint256 requested);
    error InsufficientLiquidity(uint256 available, uint256 requested);
    error InsufficientCollateral(uint256 borrowPower, uint256 debtValue);
    error NoDebt(address asset);

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    /// @param initialOwner Admin (later: a multisig).
    /// @param oracle_      MockPriceOracle in tests, RelayedPriceOracle on Horizen.
    constructor(address initialOwner, address oracle_) Ownable(initialOwner) {
        if (oracle_ == address(0)) revert ZeroAddress();
        oracle = IPriceOracle(oracle_);
        emit OracleSet(oracle_);
    }

    // ---------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------

    function setOracle(address oracle_) external onlyOwner {
        if (oracle_ == address(0)) revert ZeroAddress();
        oracle = IPriceOracle(oracle_);
        emit OracleSet(oracle_);
    }

    /// @notice List a token. `ltvBps` = how much can be borrowed per $1 of it as collateral.
    function addAsset(address asset, uint16 ltvBps, bool borrowEnabled) external onlyOwner {
        if (asset == address(0)) revert ZeroAddress();
        if (assetConfig[asset].supported) revert AssetAlreadySupported(asset);
        if (assetList.length >= MAX_ASSETS) revert TooManyAssets();
        if (ltvBps > MAX_LTV_BPS) revert InvalidLtv(ltvBps);

        assetConfig[asset] = AssetConfig({
            supported: true, borrowEnabled: borrowEnabled, ltvBps: ltvBps, decimals: IERC20Metadata(asset).decimals()
        });
        assetList.push(asset);
        emit AssetAdded(asset, ltvBps, borrowEnabled);
    }

    /// @notice Change LTV / borrowability of a listed asset.
    /// @dev    Lowering LTV can make existing positions exceed their limit. They cannot
    ///         borrow more or withdraw, but nothing forces them to repay (no liquidations yet).
    function setAssetConfig(address asset, uint16 ltvBps, bool borrowEnabled) external onlyOwner {
        AssetConfig storage cfg = _supported(asset);
        if (ltvBps > MAX_LTV_BPS) revert InvalidLtv(ltvBps);
        cfg.ltvBps = ltvBps;
        cfg.borrowEnabled = borrowEnabled;
        emit AssetConfigUpdated(asset, ltvBps, borrowEnabled);
    }

    // ---------------------------------------------------------------------
    // Supply / withdraw
    // ---------------------------------------------------------------------

    /// @notice Deposit `amount` of `asset`. Counts as collateral. Approve the pool first.
    function supply(address asset, uint256 amount) external nonReentrant {
        _supported(asset);
        if (amount == 0) revert ZeroAmount();

        suppliedBalance[asset][msg.sender] += amount;
        totalSupplied[asset] += amount;

        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        emit Supplied(asset, msg.sender, amount);
    }

    /// @notice Take back supplied tokens. Use type(uint256).max for your full balance.
    /// @dev    Two new checks vs step 2:
    ///         - the pool must have the cash (some of it may be lent out)
    ///         - if you have debt, your remaining collateral must still cover it
    function withdraw(address asset, uint256 amount) external nonReentrant returns (uint256) {
        _supported(asset);
        if (amount == 0) revert ZeroAmount();

        uint256 balance = suppliedBalance[asset][msg.sender];
        if (amount == type(uint256).max) amount = balance;
        if (amount == 0) revert ZeroAmount();
        if (amount > balance) revert InsufficientBalance(balance, amount);

        uint256 cash = availableLiquidity(asset);
        if (amount > cash) revert InsufficientLiquidity(cash, amount);

        suppliedBalance[asset][msg.sender] = balance - amount;
        totalSupplied[asset] -= amount;

        // Only users with debt need a price check. Debt-free users can always
        // exit, even if the oracle is down.
        if (_hasDebt(msg.sender)) _requireBorrowCapacity(msg.sender);

        IERC20(asset).safeTransfer(msg.sender, amount);
        emit Withdrawn(asset, msg.sender, amount);
        return amount;
    }

    // ---------------------------------------------------------------------
    // Borrow / repay
    // ---------------------------------------------------------------------

    /// @notice Borrow `amount` of `asset` against your supplied collateral.
    /// @dev    Effects first, then the collateral check on the NEW state, then transfer.
    ///         If the check fails, the whole tx reverts, including the effects.
    function borrow(address asset, uint256 amount) external nonReentrant {
        AssetConfig storage cfg = _supported(asset);
        if (!cfg.borrowEnabled) revert BorrowNotEnabled(asset);
        if (amount == 0) revert ZeroAmount();

        uint256 cash = availableLiquidity(asset);
        if (amount > cash) revert InsufficientLiquidity(cash, amount);

        borrowedBalance[asset][msg.sender] += amount;
        totalBorrowed[asset] += amount;

        _requireBorrowCapacity(msg.sender);

        IERC20(asset).safeTransfer(msg.sender, amount);
        emit Borrowed(asset, msg.sender, amount);
    }

    /// @notice Pay back debt. Amounts above your debt (incl. type(uint256).max) repay it fully.
    /// @dev    No price check: repaying only ever makes a position safer.
    function repay(address asset, uint256 amount) external nonReentrant returns (uint256) {
        _supported(asset);
        if (amount == 0) revert ZeroAmount();

        uint256 debt = borrowedBalance[asset][msg.sender];
        if (debt == 0) revert NoDebt(asset);
        if (amount > debt) amount = debt;

        borrowedBalance[asset][msg.sender] = debt - amount;
        totalBorrowed[asset] -= amount;

        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        emit Repaid(asset, msg.sender, amount);
        return amount;
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice Tokens in the pool that are not lent out.
    function availableLiquidity(address asset) public view returns (uint256) {
        return totalSupplied[asset] - totalBorrowed[asset];
    }

    function getAccountData(address user) external view returns (AccountData memory) {
        return _accountData(user);
    }

    function assetCount() external view returns (uint256) {
        return assetList.length;
    }

    // ---------------------------------------------------------------------
    // Internal: valuation
    // ---------------------------------------------------------------------

    /// @dev Values every asset the user touches in USD (1e18):
    ///        value = amount * price / 10^decimals
    ///      Rounding favours the pool: collateral rounds down, debt rounds up.
    ///      The oracle is only called for assets where the user has a position.
    function _accountData(address user) internal view returns (AccountData memory a) {
        uint256 n = assetList.length;
        for (uint256 i; i < n; ++i) {
            address asset = assetList[i];
            uint256 supplied = suppliedBalance[asset][user];
            uint256 borrowed = borrowedBalance[asset][user];
            if (supplied == 0 && borrowed == 0) continue;

            AssetConfig storage cfg = assetConfig[asset];
            uint256 price = oracle.getPrice(asset);
            uint256 unit = 10 ** cfg.decimals;

            if (supplied != 0) {
                uint256 value = Math.mulDiv(supplied, price, unit);
                a.collateralValue += value;
                a.borrowPower += Math.mulDiv(value, cfg.ltvBps, BPS);
            }
            if (borrowed != 0) {
                a.debtValue += Math.mulDiv(borrowed, price, unit, Math.Rounding.Ceil);
            }
        }
    }

    function _requireBorrowCapacity(address user) internal view {
        AccountData memory a = _accountData(user);
        if (a.debtValue > a.borrowPower) revert InsufficientCollateral(a.borrowPower, a.debtValue);
    }

    function _hasDebt(address user) internal view returns (bool) {
        uint256 n = assetList.length;
        for (uint256 i; i < n; ++i) {
            if (borrowedBalance[assetList[i]][user] != 0) return true;
        }
        return false;
    }

    function _supported(address asset) internal view returns (AssetConfig storage cfg) {
        cfg = assetConfig[asset];
        if (!cfg.supported) revert AssetNotSupported(asset);
    }
}
