#!/usr/bin/env bash
# Print prices, reserves (utilization, rates) and every user's position + health factor.
source "$(dirname "$0")/_env.sh"
need WETH USDC ORACLE POOL

echo "block $(cast block-number --rpc-url "$RPC")  |  $(date -u -d @"$(cast block --rpc-url "$RPC" -f timestamp)" '+%Y-%m-%d %H:%M UTC')"
hr
for A in WETH USDC; do
  T=$(token_of $A); D=$(dec_of $A)
  mapfile -t R < <(call "$POOL" "getReserveData(address)(uint256,uint256,uint256,uint256,uint256)" "$T")
  price=$(human "$(call "$ORACLE" "getPrice(address)(uint256)" "$T" 2>/dev/null || echo 0)" 18)
  cash=$(call "$POOL" "availableLiquidity(address)(uint256)" "$T")
  printf "%-5s price \$%-10s supply %-14s debt %-14s cash %-14s\n" "$A" "$price" "$(human "${R[0]}" $D)" "$(human "${R[1]}" $D)" "$(human "$cash" $D)"
  printf "      utilization %-10s borrow APR %-10s supply APR %s\n" "$(pct "${R[2]}")" "$(pct "${R[3]}")" "$(pct "${R[4]}")"
done
hr
for U in alice bob liquidator treasury; do
  a=$(addr_of $U)
  mapfile -t D < <(call "$POOL" "getAccountData(address)(uint256,uint256,uint256,uint256,uint256)" "$a")
  hf_raw=$(num "${D[4]}")
  if [[ "$hf_raw" == "$(cast max-uint)" ]]; then hf="∞ (no debt)"; else hf=$(awk -v v="$(human "$hf_raw" 18)" 'BEGIN{printf "%.4f", v}'); fi
  flag=""; [[ "$hf" != ∞* ]] && awk -v h="$hf" 'BEGIN{exit !(h<1)}' && flag="  ⚠ LIQUIDATABLE"
  printf "%-10s collateral \$%-12s borrow power \$%-12s debt \$%-12s HF %s%s\n" \
    "$U" "$(usd "${D[0]}")" "$(usd "${D[1]}")" "$(usd "${D[3]}")" "$hf" "$flag"
  for A in WETH USDC; do
    T=$(token_of $A); Dd=$(dec_of $A)
    s=$(call "$POOL" "supplyBalanceOf(address,address)(uint256)" "$T" "$a")
    d=$(call "$POOL" "debtBalanceOf(address,address)(uint256)" "$T" "$a")
    w=$(call "$T" "balanceOf(address)(uint256)" "$a")
    [[ "$(num "$s")$(num "$d")$(num "$w")" == "000" ]] && continue
    printf "           %-5s supplied %-16s borrowed %-16s wallet %s\n" "$A" "$(human "$s" $Dd)" "$(human "$d" $Dd)" "$(human "$w" $Dd)"
  done
done
