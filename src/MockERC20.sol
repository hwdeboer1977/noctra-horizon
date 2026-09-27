// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockERC20
/// @notice Test token for local tests and Horizen testnet.
///         Used as a stand-in for WETH (18 decimals) and USDC.e (6 decimals),
///         because USDC.e has no official testnet deployment on Horizen.
/// @dev    WARNING: anyone can mint. Never deploy this to mainnet.
contract MockERC20 is ERC20 {
    /// @dev Number of decimals, fixed at deploy time.
    uint8 private immutable DECIMALS;

    /// @param name_     Full name, e.g. "USD Coin (mock)"
    /// @param symbol_   Ticker, e.g. "USDC"
    /// @param decimals_ 18 for WETH, 6 for USDC
    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        DECIMALS = decimals_;
    }

    /// @notice Overrides OpenZeppelin's default of 18.
    function decimals() public view override returns (uint8) {
        return DECIMALS;
    }

    /// @notice Creates `amount` new tokens for `to`. Open to everyone (faucet behaviour).
    /// @param amount In base units: 1 USDC = 1_000_000, 1 WETH = 1e18.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
