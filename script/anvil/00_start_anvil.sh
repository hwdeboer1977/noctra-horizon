#!/usr/bin/env bash
# Start a fresh local chain in the background (logs: scripts/anvil/anvil.log).
source "$(dirname "$0")/_env.sh"

if cast block-number --rpc-url "$RPC" >/dev/null 2>&1; then
  echo "anvil already running on $RPC (block $(cast block-number --rpc-url "$RPC"))"
  exit 0
fi
rm -f "$STATE" # new chain = old addresses are meaningless
nohup anvil >"$HERE/anvil.log" 2>&1 &
echo $! >"$HERE/anvil.pid"
for _ in {1..20}; do cast block-number --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 0.25; done
echo "✓ anvil started on $RPC (pid $(cat "$HERE/anvil.pid"))"
