// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {RelayedPriceOracle} from "../src/RelayedPriceOracle.sol";
import {MockERC20} from "../src/MockERC20.sol";

/// @notice Horizen TESTNET: deploy mock WETH + mock USDC and a RelayedPriceOracle.
///
/// Env:
///   PRIVATE_KEY   deployer (becomes oracle owner; use a Safe on mainnet)
///   RELAYERS      comma-separated relayer addresses, e.g. 0xabc...,0xdef...
///   QUORUM        e.g. 1 for a single-relayer test, 2 for 2-of-3
///
/// Run:
///   forge script script/DeployOracle.s.sol --rpc-url horizen_testnet --broadcast
contract DeployOracle is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address[] memory relayers = vm.envAddress("RELAYERS", ",");
        uint256 quorum = vm.envUint("QUORUM");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);

        MockERC20 weth = new MockERC20("Wrapped Ether (mock)", "WETH", 18);
        MockERC20 usdc = new MockERC20("USD Coin (mock)", "USDC", 6);
        RelayedPriceOracle oracle = new RelayedPriceOracle(deployer);

        for (uint256 i; i < relayers.length; ++i) {
            oracle.addRelayer(relayers[i]);
        }
        oracle.setQuorum(quorum);

        // maxAge must exceed Chainlink's heartbeat for the Base feed (+ relay margin).
        // VERIFY both heartbeats on Chainlink's feed pages before relying on these.
        oracle.configureAsset(address(weth), 8, 4200, 2000); // ETH: ~1h + 10m, 20% breaker
        oracle.configureAsset(address(usdc), 8, 90_000, 5000); // USDC: ~24h + 1h, 50% breaker

        vm.stopBroadcast();

        console2.log("WETH (mock)       ", address(weth));
        console2.log("USDC (mock)       ", address(usdc));
        console2.log("RelayedPriceOracle", address(oracle));
    }
}
