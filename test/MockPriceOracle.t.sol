// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MockPriceOracle} from "../src/MockPriceOracle.sol";
import {MockERC20} from "../src/MockERC20.sol";

contract MockPriceOracleTest is Test {
    MockPriceOracle oracle;
    MockERC20 weth;
    MockERC20 usdc;
    address owner = makeAddr("owner");
    address alice = makeAddr("alice");

    function setUp() public {
        oracle = new MockPriceOracle(owner);
        weth = new MockERC20("Wrapped Ether (mock)", "WETH", 18);
        usdc = new MockERC20("USD Coin (mock)", "USDC", 6);
    }

    function test_SetAndGetPrice() public {
        vm.prank(owner);
        oracle.setPrice(address(weth), 3000e18);
        assertEq(oracle.getPrice(address(weth)), 3000e18);
    }

    function test_PriceUpdate() public {
        vm.startPrank(owner);
        oracle.setPrice(address(weth), 3000e18);
        oracle.setPrice(address(weth), 2100e18); // -30% crash
        vm.stopPrank();
        assertEq(oracle.getPrice(address(weth)), 2100e18);
    }

    function test_SetPriceEmitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(address(oracle));
        emit MockPriceOracle.PriceSet(address(weth), 3000e18);
        oracle.setPrice(address(weth), 3000e18);
    }

    /// Price is per WHOLE token, independent of decimals. The consumer does the
    /// conversion: value = amount * price / 10**decimals.
    function test_ValueCalculationAcrossDecimals() public {
        vm.startPrank(owner);
        oracle.setPrice(address(weth), 3000e18);
        oracle.setPrice(address(usdc), 1e18);
        vm.stopPrank();

        uint256 wethValue = 2e18 * oracle.getPrice(address(weth)) / 10 ** weth.decimals(); // 2 WETH
        uint256 usdcValue = 6000e6 * oracle.getPrice(address(usdc)) / 10 ** usdc.decimals(); // 6000 USDC

        assertEq(wethValue, 6000e18); // $6,000
        assertEq(usdcValue, 6000e18); // $6,000 -> comparable despite 18 vs 6 decimals
    }

    function test_RevertGetPriceNotSet() public {
        vm.expectRevert(abi.encodeWithSelector(MockPriceOracle.PriceNotSet.selector, address(weth)));
        oracle.getPrice(address(weth));
    }

    function test_RevertSetPriceNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        oracle.setPrice(address(weth), 1e18);
    }
}
