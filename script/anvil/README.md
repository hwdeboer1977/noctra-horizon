# Anvil test scripts

Small, numbered bash scripts to click through the protocol on a local chain with `cast`.
Each step can be run on its own; deployed addresses are kept in `.state.env` (gitignored).

Run from the repo root, for example `./scripts/anvil/07_status.sh`.

| Script | Does | Args (defaults) |
| --- | --- | --- |
| `00_start_anvil.sh` | Start anvil in the background, clear old state | |
| `01_deploy_tokens.sh` | Mock WETH (18 dec) + USDC (6 dec) | |
| `02_deploy_oracle.sh` | `MockPriceOracle`, ETH $3,000, USDC $1 | |
| `03_deploy_pool.sh` | `LendingPool` + list both assets (risk params, rate models) | |
| `04_fund_users.sh` | Mint to alice / bob / liquidator, approve the pool | |
| `05_supply.sh` | Supply | `[user] [asset] [amount]`; none = alice 50k USDC + bob 1 WETH |
| `06_borrow.sh` | Borrow | `[bob] [USDC] [2250]` (= max LTV) |
| `07_status.sh` | Prices, utilization, APRs, positions, health factors | |
| `08_set_price.sh` | Change an oracle price | `[WETH] [2750]` |
| `09_time_travel.sh` | Jump ahead + accrue interest | `[30]` days |
| `10_repay.sh` | Repay | `[bob] [USDC] [max]` |
| `11_withdraw.sh` | Withdraw | `[alice] [USDC] [max]` |
| `12_liquidate.sh` | Manual liquidation by the liquidator account | `[bob] [WETH] [USDC] [max]` |
| `13_run_liquidator_bot.sh` | Run the backend bot against anvil | `[live]`; none = dry-run |
| `99_stop_anvil.sh` | Stop anvil, clear state | |
| `scenario_liquidation.sh` | 00 → 08 → 12 with status in between | |
| `scenario_interest.sh` | Borrow, 1 year passes, everyone exits | |

Accounts are anvil's defaults: #0 owner/treasury, #1 alice, #2 bob, #3 liquidator.
Their keys are public test keys: never use them anywhere else.

Example session:

```shell
./scripts/anvil/scenario_liquidation.sh      # or step by step:
./scripts/anvil/08_set_price.sh WETH 2600    # deeper crash: full liquidation allowed
./scripts/anvil/13_run_liquidator_bot.sh live
./scripts/anvil/99_stop_anvil.sh
```

Requirements: `anvil`, `cast` and `forge` on your PATH (Foundry). Extra `forge create` flags can be passed with `FORGE_FLAGS`, e.g. `FORGE_FLAGS="--offline"`.

Add to the repo's root `.gitignore`:

```
scripts/anvil/.state.env
scripts/anvil/anvil.log
scripts/anvil/anvil.pid
```
