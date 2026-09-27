// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {MockERC20} from "../src/MockERC20.sol";
import {MockPriceOracle} from "../src/MockPriceOracle.sol";

/// @notice LOCAL demo for the liquidator bot (anvil). Deploys mocks + pool, creates a
///         borrower at max LTV, then drops the ETH price so the position is liquidatable.
///
///   anvil                                              # terminal 1
///   forge script script/LiquidationDemo.s.sol \
///     --rpc-url http://127.0.0.1:8545 --broadcast      # terminal 2
///
/// Uses anvil's default accounts:
///   #0 deployer/owner, #1 alice (lender), #2 bob (borrower), #3 liquidator (gets a USDC float)
contract LiquidationDemo is Script {
    uint256 constant PK0 = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 constant PK1 = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 constant PK2 = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
    address constant LIQUIDATOR = 0x90F79bf6EB2c4f870365E785982E1f101E93b906; // anvil #3

    function run() external {
        address owner = vm.addr(PK0);
        address alice = vm.addr(PK1);
        address bob = vm.addr(PK2);

        vm.startBroadcast(PK0);
        MockERC20 weth = new MockERC20("Wrapped Ether (mock)", "WETH", 18);
        MockERC20 usdc = new MockERC20("USD Coin (mock)", "USDC", 6);
        MockPriceOracle oracle = new MockPriceOracle(owner);
        LendingPool pool = new LendingPool(owner, address(oracle), owner);

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

        usdc.mint(alice, 50_000e6);
        weth.mint(bob, 1e18);
        usdc.mint(LIQUIDATOR, 10_000e6); // the liquidator's float
        vm.stopBroadcast();

        vm.startBroadcast(PK1);
        usdc.approve(address(pool), type(uint256).max);
        pool.supply(address(usdc), 50_000e6);
        vm.stopBroadcast();

        vm.startBroadcast(PK2);
        weth.approve(address(pool), type(uint256).max);
        pool.supply(address(weth), 1e18);
        pool.borrow(address(usdc), 2_250e6); // max LTV
        vm.stopBroadcast();

        vm.startBroadcast(PK0);
        oracle.setPrice(address(weth), 2_750e18); // HF 1.067 -> 0.978
        vm.stopBroadcast();

        console2.log("POOL_ADDRESS   ", address(pool));
        console2.log("WETH           ", address(weth));
        console2.log("USDC           ", address(usdc));
        console2.log("borrower (bob) ", bob);
        console2.log("liquidator     ", LIQUIDATOR);
    }
}
