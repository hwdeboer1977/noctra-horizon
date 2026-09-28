#!/usr/bin/env bash
# Usage: 11_withdraw.sh [user=alice] [asset=USDC] [amount=max]
source "$(dirname "$0")/_env.sh"
need POOL
USER=${1:-alice}; ASSET=${2:-USDC}; AMOUNT=${3:-max}

[[ "$AMOUNT" == max ]] && RAW=$(cast max-uint) || RAW=$(units "$AMOUNT" "$(dec_of "$ASSET")")
tx "$(pk_of "$USER")" "$POOL" "withdraw(address,uint256)" "$(token_of "$ASSET")" "$RAW"
echo "✓ $USER withdrew $AMOUNT $ASSET"
