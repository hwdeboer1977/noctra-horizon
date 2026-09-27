// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title LendingPool — step 2: supply + withdraw
/// @notice Users deposit supported tokens into the pool and can take them back.
///         The pool records how much each user supplied per asset. No interest yet.
contract LendingPool is Ownable {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    /// @notice Which tokens the pool accepts (e.g. WETH, USDC).
    mapping(address asset => bool) public isSupported;

    /// @notice How much of `asset` each user has supplied, in the token's base units.
    mapping(address asset => mapping(address user => uint256)) public suppliedBalance;

    /// @notice Sum of all users' supplied balances per asset.
    mapping(address asset => uint256) public totalSupplied;

    // ---------------------------------------------------------------------
    // Events & errors
    // ---------------------------------------------------------------------

    event AssetAdded(address indexed asset);
    event Supplied(address indexed asset, address indexed user, uint256 amount);
    event Withdrawn(address indexed asset, address indexed user, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error AssetNotSupported(address asset);
    error AssetAlreadySupported(address asset);
    error InsufficientBalance(uint256 available, uint256 requested);

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    /// @param initialOwner Admin who can add assets (later: a multisig).
    constructor(address initialOwner) Ownable(initialOwner) {}

    // ---------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------

    /// @notice Allow a token to be supplied to the pool.
    function addAsset(address asset) external onlyOwner {
        if (asset == address(0)) revert ZeroAddress();
        if (isSupported[asset]) revert AssetAlreadySupported(asset);
        isSupported[asset] = true;
        emit AssetAdded(asset);
    }

    // ---------------------------------------------------------------------
    // User actions
    // ---------------------------------------------------------------------

    /// @notice Deposit `amount` of `asset` into the pool.
    /// @dev Caller must first call `IERC20(asset).approve(pool, amount)`.
    ///      Follows checks-effects-interactions: validate, update state, then transfer.
    function supply(address asset, uint256 amount) external {
        // 1. Checks
        if (!isSupported[asset]) revert AssetNotSupported(asset);
        if (amount == 0) revert ZeroAmount();

        // 2. Effects
        suppliedBalance[asset][msg.sender] += amount;
        totalSupplied[asset] += amount;

        // 3. Interaction — pull tokens from the user. Reverts (and undoes step 2)
        //    if allowance or balance is insufficient.
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);

        emit Supplied(asset, msg.sender, amount);
    }

    /// @notice Take back `amount` of `asset` you previously supplied.
    /// @param amount Use type(uint256).max to withdraw your full balance.
    /// @return withdrawn The amount actually sent to the caller.
    /// @dev Same checks-effects-interactions order as supply: the balance is
    ///      reduced BEFORE tokens leave the pool, so a reentrant call would see
    ///      the already-reduced balance.
    function withdraw(address asset, uint256 amount) external returns (uint256 withdrawn) {
        // 1. Checks
        if (!isSupported[asset]) revert AssetNotSupported(asset);
        if (amount == 0) revert ZeroAmount();

        uint256 balance = suppliedBalance[asset][msg.sender];
        if (amount == type(uint256).max) amount = balance;
        if (amount == 0) revert ZeroAmount(); // max-withdraw with nothing supplied
        if (amount > balance) revert InsufficientBalance(balance, amount);

        // 2. Effects
        suppliedBalance[asset][msg.sender] = balance - amount;
        totalSupplied[asset] -= amount;

        // 3. Interaction — push tokens to the user.
        IERC20(asset).safeTransfer(msg.sender, amount);

        emit Withdrawn(asset, msg.sender, amount);
        return amount;
    }
}
