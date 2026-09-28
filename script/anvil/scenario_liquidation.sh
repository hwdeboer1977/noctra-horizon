#!/usr/bin/env bash
# Full story: deploy -> lend -> borrow at max LTV -> ETH drops -> liquidate -> healthy again.
set -euo pipefail
cd "$(dirname "$0")"
./00_start_anvil.sh && ./01_deploy_tokens.sh && ./02_deploy_oracle.sh && ./03_deploy_pool.sh && ./04_fund_users.sh
./05_supply.sh && ./06_borrow.sh
echo; echo "== after borrowing at max LTV =="; ./07_status.sh
./08_set_price.sh WETH 2750
echo; echo "== ETH at \$2,750 =="; ./07_status.sh
./12_liquidate.sh
echo; echo "== after liquidation =="; ./07_status.sh
