#!/usr/bin/env bash
# Usage: 09_time_travel.sh [days=30]
# Moves the chain clock forward, mines a block, and accrues interest on both reserves.
source "$(dirname "$0")/_env.sh"
need POOL WETH USDC
DAYS=${1:-30}

cast rpc --rpc-url "$RPC" evm_increaseTime $((DAYS * 86400)) >/dev/null
cast rpc --rpc-url "$RPC" evm_mine >/dev/null
tx "$OWNER_PK" "$POOL" "accrue(address)" "$WETH"
tx "$OWNER_PK" "$POOL" "accrue(address)" "$USDC"
echo "✓ jumped $DAYS day(s) ahead and accrued interest"
