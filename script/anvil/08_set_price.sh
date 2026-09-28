#!/usr/bin/env bash
# Usage: 08_set_price.sh [asset=WETH] [usd=2750]
#   default: ETH $3,000 -> $2,750, which puts bob (at max LTV) at HF 0.978
source "$(dirname "$0")/_env.sh"
need ORACLE
ASSET=${1:-WETH}; USD=${2:-2750}

tx "$OWNER_PK" "$ORACLE" "setPrice(address,uint256)" "$(token_of "$ASSET")" "$(units "$USD" 18)"
echo "✓ $ASSET price set to \$$USD"
