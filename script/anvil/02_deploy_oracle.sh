#!/usr/bin/env bash
# Deploy MockPriceOracle and set ETH = $3,000, USDC = $1.
source "$(dirname "$0")/_env.sh"
need WETH USDC

save ORACLE "$(deploy src/MockPriceOracle.sol:MockPriceOracle "$OWNER")"
tx "$OWNER_PK" "$ORACLE" "setPrice(address,uint256)" "$WETH" "$(units 3000 18)"
tx "$OWNER_PK" "$ORACLE" "setPrice(address,uint256)" "$USDC" "$(units 1 18)"
echo "✓ ORACLE $ORACLE  (WETH \$3000, USDC \$1)"
