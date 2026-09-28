#!/usr/bin/env bash
# Deploy mock WETH (18 decimals) and mock USDC (6 decimals).
source "$(dirname "$0")/_env.sh"

save WETH "$(deploy src/MockERC20.sol:MockERC20 "Wrapped Ether (mock)" WETH 18)"
save USDC "$(deploy src/MockERC20.sol:MockERC20 "USD Coin (mock)" USDC 6)"
echo "✓ WETH $WETH"
echo "✓ USDC $USDC"
