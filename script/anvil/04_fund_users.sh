#!/usr/bin/env bash
# Mint test tokens and approve the pool for everyone.
#   alice      50,000 USDC           (lender)
#   bob        1 WETH + 1,000 USDC   (borrower; USDC to pay interest)
#   liquidator 10,000 USDC           (float for liquidations)
source "$(dirname "$0")/_env.sh"
need WETH USDC POOL

tx "$OWNER_PK" "$USDC" "mint(address,uint256)" "$ALICE" "$(units 50000 6)"
tx "$OWNER_PK" "$WETH" "mint(address,uint256)" "$BOB" "$(units 1 18)"
tx "$OWNER_PK" "$USDC" "mint(address,uint256)" "$BOB" "$(units 1000 6)"
tx "$OWNER_PK" "$USDC" "mint(address,uint256)" "$LIQUIDATOR" "$(units 10000 6)"

MAX=$(cast max-uint)
for who in alice bob liquidator owner; do
  for t in "$WETH" "$USDC"; do tx "$(pk_of $who)" "$t" "approve(address,uint256)" "$POOL" "$MAX"; done
done
echo "✓ funded alice/bob/liquidator and approved the pool"
