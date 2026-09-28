#!/usr/bin/env bash
# 00_reset.sh — reset local anvil chain to genesis
set -euo pipefail

RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"

cast rpc anvil_reset --rpc-url "$RPC_URL" >/dev/null
echo "chain reset — block $(cast block-number --rpc-url "$RPC_URL")"