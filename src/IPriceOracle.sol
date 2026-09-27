// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IPriceOracle
/// @notice The only thing the lending pool knows about prices.
///         Implementations: MockPriceOracle (tests/testnet), StorkPriceOracle (Horizen),
///         possibly a Chainlink adapter later. Swapping one for another needs no pool changes.
interface IPriceOracle {
    /// @notice USD price of ONE WHOLE token (not one base unit), scaled to 1e18.
    ///         Example: ETH at $3,000 -> 3000e18. USDC at $1 -> 1e18.
    /// @dev    MUST revert rather than return a zero or stale price.
    function getPrice(address asset) external view returns (uint256);
}
