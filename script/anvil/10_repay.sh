#!/usr/bin/env bash
# Usage: 10_repay.sh [user=bob] [asset=USDC] [amount=max]
source "$(dirname "$0")/_env.sh"
need POOL
USER=${1:-bob}; ASSET=${2:-USDC}; AMOUNT=${3:-max}

[[ "$AMOUNT" == max ]] && RAW=$(cast max-uint) || RAW=$(units "$AMOUNT" "$(dec_of "$ASSET")")
tx "$(pk_of "$USER")" "$POOL" "repay(address,uint256)" "$(token_of "$ASSET")" "$RAW"
echo "✓ $USER repaid $AMOUNT $ASSET"
