#!/usr/bin/env bash
# Usage: 13_run_liquidator_bot.sh [live]
# Runs backend/ liquidator against anvil. Without "live": dry-run. Stop with Ctrl+C.
source "$(dirname "$0")/_env.sh"
need POOL

export HORIZEN_NETWORK=local POOL_ADDRESS="$POOL" POOL_DEPLOY_BLOCK=0 LIQ_POLL_SECONDS=5
[[ "${1:-}" == live ]] && export LIQUIDATOR_PRIVATE_KEY="$LIQUIDATOR_PK"
cd "$ROOT/backend" && npm run liquidate
