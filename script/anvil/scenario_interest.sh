#!/usr/bin/env bash
# Full story: deploy -> lend -> borrow -> 1 year passes -> repay with interest -> lender exits with profit.
set -euo pipefail
cd "$(dirname "$0")"
./00_start_anvil.sh && ./01_deploy_tokens.sh && ./02_deploy_oracle.sh && ./03_deploy_pool.sh && ./04_fund_users.sh
./05_supply.sh && ./06_borrow.sh bob USDC 2000
echo; echo "== day 0 =="; ./07_status.sh
./09_time_travel.sh 365
echo; echo "== after 1 year =="; ./07_status.sh
./10_repay.sh && ./11_withdraw.sh alice USDC max && ./11_withdraw.sh bob WETH max && ./11_withdraw.sh treasury USDC max
echo; echo "== everyone exited =="; ./07_status.sh
