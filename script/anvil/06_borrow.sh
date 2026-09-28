#!/usr/bin/env bash
# Usage: 06_borrow.sh [user=bob] [asset=USDC] [amount=2250]
#   default: bob borrows 2,250 USDC = exactly 75% LTV of 1 WETH @ $3,000
source "$(dirname "$0")/_env.sh"
need POOL
USER=${1:-bob}; ASSET=${2:-USDC}; AMOUNT=${3:-2250}

tx "$(pk_of "$USER")" "$POOL" "borrow(address,uint256)" "$(token_of "$ASSET")" "$(units "$AMOUNT" "$(dec_of "$ASSET")")"
echo "✓ $USER borrowed $AMOUNT $ASSET"
