#!/usr/bin/env bash
# Shared settings + helpers for the anvil scripts. Sourced by every numbered script.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" # this scripts folder, wherever it lives
ROOT="$HERE"                                         # repo root = first parent with foundry.toml
while [[ "$ROOT" != "/" && ! -f "$ROOT/foundry.toml" ]]; do ROOT="$(dirname "$ROOT")"; done
[[ -f "$ROOT/foundry.toml" ]] || { echo "✗ foundry.toml not found above $HERE"; exit 1; }
RPC="${RPC:-http://127.0.0.1:8545}"
STATE="$HERE/.state.env" # deployed addresses, written by 01-03 (gitignored)

# ---- anvil default accounts (public test keys: NEVER use them anywhere else) ----
OWNER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
OWNER_PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
ALICE=0x70997970C51812dc3A010C7d01b50e0d17dc79C8 # lender
ALICE_PK=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
BOB=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC # borrower
BOB_PK=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a
LIQUIDATOR=0x90F79bf6EB2c4f870365E785982E1f101E93b906
LIQUIDATOR_PK=0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6
TREASURY=$OWNER

[[ -f "$STATE" ]] && source "$STATE"

# ---- helpers -----------------------------------------------------------------

# save KEY VALUE  -> persist a deployed address for the next scripts
save() {
  touch "$STATE"
  sed -i "/^$1=/d" "$STATE"
  echo "$1=$2" >>"$STATE"
  export "$1=$2"
}

need() { # need VAR... -> fail early if an earlier script was skipped
  for v in "$@"; do
    [[ -n "${!v:-}" ]] || { echo "✗ $v not set: run the earlier scripts first (see README)"; exit 1; }
  done
}

addr_of() { # alice|bob|liquidator|owner|treasury -> address
  case "${1,,}" in
    alice) echo "$ALICE" ;; bob) echo "$BOB" ;; liquidator) echo "$LIQUIDATOR" ;;
    owner | treasury) echo "$OWNER" ;; *) echo "unknown user $1" >&2; exit 1 ;;
  esac
}
pk_of() {
  case "${1,,}" in
    alice) echo "$ALICE_PK" ;; bob) echo "$BOB_PK" ;; liquidator) echo "$LIQUIDATOR_PK" ;;
    owner | treasury) echo "$OWNER_PK" ;; *) echo "unknown user $1" >&2; exit 1 ;;
  esac
}
token_of() { # WETH|USDC -> address
  case "${1^^}" in WETH) need WETH; echo "$WETH" ;; USDC) need USDC; echo "$USDC" ;; *) echo "unknown asset $1" >&2; exit 1 ;; esac
}
dec_of() { case "${1^^}" in WETH) echo 18 ;; USDC) echo 6 ;; esac; }

num() { awk '{print $1}' <<<"$1"; }                     # "123 [1.2e2]" -> "123"
units() { cast parse-units "$1" "$2"; }                  # human -> base units
human() { cast format-units "$(num "$1")" "$2"; }        # base units -> human
usd() { awk -v v="$(human "$1" 18)" 'BEGIN { printf "%.2f", v }'; } # 1e18 USD -> "1234.56"
pct() { awk -v r="$(num "$1")" 'BEGIN { printf "%.3f%%", r / 1e25 }'; } # RAY -> %

deploy() { # deploy <path:Contract> [constructor args...] -> prints address
  local target=$1; shift
  (cd "$ROOT" && forge create "$target" --rpc-url "$RPC" --private-key "$OWNER_PK" --broadcast ${FORGE_FLAGS:-} \
    ${1:+--constructor-args "$@"}) | awk '/Deployed to:/ {print $3}'
}

tx() { # tx <private key> <to> <signature> [args...]
  local pk=$1; shift
  cast send --rpc-url "$RPC" --private-key "$pk" "$@" >/dev/null
}

call() { cast call --rpc-url "$RPC" "$@"; }

hr() { printf '%s\n' "------------------------------------------------------------"; }
