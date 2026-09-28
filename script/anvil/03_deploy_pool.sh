#!/usr/bin/env bash
# Deploy LendingPool and list WETH + USDC with risk params and rate models.
source "$(dirname "$0")/_env.sh"
need WETH USDC ORACLE

save POOL "$(deploy src/LendingPool.sol:LendingPool "$OWNER" "$ORACLE" "$TREASURY")"

SIG="addAsset(address,(uint16,uint16,uint16,bool),(uint256,uint256,uint256,uint256,uint16))"
ray() { units "$1" 27; } # 0.03 -> 3% in RAY

# RiskParams (ltv, liqThreshold, liqBonus, borrowEnabled)   RateModel (base, slope1, slope2, optimal, reserveFactor)
tx "$OWNER_PK" "$POOL" "$SIG" "$WETH" "(7500,8000,750,true)" "(0,$(ray 0.03),$(ray 0.8),$(ray 0.8),1500)"
tx "$OWNER_PK" "$POOL" "$SIG" "$USDC" "(7000,7500,500,true)" "(0,$(ray 0.04),$(ray 0.6),$(ray 0.9),1000)"
echo "✓ POOL $POOL"
echo "  WETH: LTV 75%, liq. threshold 80%, bonus 7.5% | 3% -> kink 80% -> +80%"
echo "  USDC: LTV 70%, liq. threshold 75%, bonus 5%   | 4% -> kink 90% -> +60%"
