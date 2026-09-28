#!/usr/bin/env bash
# Usage: 12_liquidate.sh [user=bob] [collateral=WETH] [debt=USDC] [amount=max]
# Manual liquidation by the liquidator account (the bot does the same automatically).
source "$(dirname "$0")/_env.sh"
need POOL
USER=${1:-bob}; COLL=${2:-WETH}; DEBT=${3:-USDC}; AMOUNT=${4:-max}

[[ "$AMOUNT" == max ]] && RAW=$(cast max-uint) || RAW=$(units "$AMOUNT" "$(dec_of "$DEBT")")
before=$(call "$(token_of "$COLL")" "balanceOf(address)(uint256)" "$LIQUIDATOR")
tx "$LIQUIDATOR_PK" "$POOL" "liquidate(address,address,address,uint256,bool)" \
  "$(token_of "$COLL")" "$(token_of "$DEBT")" "$(addr_of "$USER")" "$RAW" true
after=$(call "$(token_of "$COLL")" "balanceOf(address)(uint256)" "$LIQUIDATOR")
echo "✓ liquidated $USER: liquidator received $(human "$(($(num "$after") - $(num "$before")))" "$(dec_of "$COLL")") $COLL"
