#!/usr/bin/env bash
# Stop anvil and forget all deployed addresses.
source "$(dirname "$0")/_env.sh"

if [[ -f "$HERE/anvil.pid" ]]; then
  kill "$(cat "$HERE/anvil.pid")" 2>/dev/null || true
  rm -f "$HERE/anvil.pid"
else
  pkill -x anvil 2>/dev/null || true
fi
rm -f "$STATE"
echo "✓ anvil stopped, state cleared"
