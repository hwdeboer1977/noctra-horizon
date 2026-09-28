#!/usr/bin/env bash
# Usage: 05_supply.sh [user] [asset] [amount]
#   no args: the demo setup -> alice supplies 50,000 USDC, bob supplies 1 WETH
source "$(dirname "$0")/_env.sh"
need POOL

supply() {
  tx "$(pk_of "$1")" "$POOL" "supply(address,uint256)" "$(token_of "$2")" "$(units "$3" "$(dec_of "$2")")"
  echo "✓ $1 supplied $3 $2"
}
if [[ $# -eq 0 ]]; then
  supply alice USDC 50000
  supply bob WETH 1
else
  supply "$1" "$2" "$3"
fi
