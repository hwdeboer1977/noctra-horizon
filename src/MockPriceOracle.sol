// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPriceOracle} from "./IPriceOracle.sol";

/// @title MockPriceOracle
/// @notice Manually set prices, for local tests and testnet.
/// @dev    WARNING: the owner decides every price. Never use on mainnet.
contract MockPriceOracle is IPriceOracle, Ownable {
    /// @notice USD price per whole token, 1e18 scale.
    mapping(address asset => uint256) public prices;

    event PriceSet(address indexed asset, uint256 price);

    error PriceNotSet(address asset);

    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @notice Set the USD price of `asset`. 0 means "unset" (getPrice will revert).
    function setPrice(address asset, uint256 price) external onlyOwner {
        prices[asset] = price;
        emit PriceSet(asset, price);
    }

    /// @inheritdoc IPriceOracle
    function getPrice(address asset) external view returns (uint256 price) {
        price = prices[asset];
        if (price == 0) revert PriceNotSet(asset);
    }
}
