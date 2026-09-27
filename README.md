# Noctra on Horizen

A lending protocol for [Horizen](https://horizen.io), an OP Stack L3 on Base, and the price infrastructure it needs.

Horizen has no native Chainlink feeds, so prices are read from Chainlink on **Base** and relayed to Horizen by a k-of-n set of relayers:

```
 Base mainnet                 off-chain                    Horizen
┌──────────────────────┐     ┌──────────────────────┐     ┌──────────────────────────┐
│ Chainlink ETH / USD  │     │ backend/             │     │ RelayedPriceOracle       │
│ Chainlink USDC / USD │───► │  server    (read)    │     │   k-of-n exact-match     │
│ Sequencer uptime     │     │  relay     (write)   │───► │   vote → getPrice(asset) │
└──────────────────────┘     │  liquidate (write) ──┼──┐  └────────────┬─────────────┘
                             └──────────────────────┘  │               │ IPriceOracle
                                                       │  ┌────────────▼─────────────┐
                                                       └─►│ LendingPool              │
                                                          │   supply · withdraw ·    │
                                                          │   borrow · repay ·       │
                                                          │   interest · liquidate   │
                                                          └──────────────────────────┘
```

| Path | What it holds |
| --- | --- |
| `src/` | Solidity contracts (Foundry) |
| `test/` | Forge tests |
| `script/` | Deployment script (`DeployOracle.s.sol`) and the local anvil liquidation demo (`LiquidationDemo.s.sol`) |
| `backend/` | TypeScript price server, relayer and liquidator bot (viem) |
| `AUDIT.md` | Security review of the liquidation logic, with proof-of-concept tests |

---

## Smart contracts

Solidity `0.8.24`, built with [Foundry](https://book.getfoundry.sh/). Dependencies are git submodules in `lib/`: `forge-std` and `openzeppelin-contracts`.

### `LendingPool.sol`

Step 5 of the pool: **supply, withdraw, borrow, repay with interest, and liquidations**.

- `constructor(owner, oracle, treasury)`: the oracle is any `IPriceOracle` (`MockPriceOracle` in tests, `RelayedPriceOracle` on Horizen); the treasury receives the reserve factor.
- `addAsset(asset, riskParams, rateModel)` (owner only) lists a token. `setRiskParams` and `setRateModel` change them later; `setRateModel` accrues first so new rates never apply retroactively.
- **Risk parameters per asset:**
  - `ltvBps`: how much you may borrow per $1 of this collateral (checked on borrow and withdraw).
  - `liqThresholdBps`: the collateral weight in the health factor. Always ≥ LTV, so a position opened at max LTV has a buffer before it becomes liquidatable.
  - `liqBonusBps`: extra collateral a liquidator receives.
  - `borrowEnabled`.
  - Validation: `LTV ≤ threshold < 100%` and `threshold × (1 + bonus) < 100%`; otherwise every liquidation would create bad debt.
- **Health factor** = Σ(collateral value × liquidation threshold) / Σ(debt value). Below 1.0 a position can be liquidated. Returned by `getAccountData`.
- `liquidate(collateralAsset, debtAsset, user, debtToCover, receiveUnderlying)`: anyone repays part of an unhealthy position's debt and receives `debt value × (1 + bonus)` of its collateral.
  - Close factor: at most 50% of the debt per call, or 100% once the health factor is below 0.95.
  - If the collateral is not enough, the liquidator takes all of it and covers proportionally less debt.
  - `receiveUnderlying = false` delivers the collateral as a supply position instead of tokens (useful when the collateral is lent out).
- `supply` / `withdraw` / `borrow` / `repay`: `borrow`, and `withdraw` while you have debt, must keep your debt within your LTV borrow power. `type(uint256).max` withdraws or repays everything including interest. Repaying never needs a price.
- `accrue(asset)`: anyone can bring an asset's interest indices up to date (e.g. a keeper in quiet periods).
- Other admin functions: `setOracle` and `setTreasury`. Like `setRiskParams` and `setRateModel`, they take effect immediately (see [Known risks](#known-risks-and-limitations)).
- **Interest without loops.** Each asset has a `liquidityIndex` and a `borrowIndex` (RAY, start at 1.0). Users store scaled balances (`amount / index`); every action first accrues the indices for the elapsed time.
- **Kinked rate model** per asset: below the optimal utilization `borrowRate = base + slope1 × U / optimal`, above it `+ slope2 × (U − optimal) / (1 − optimal)`. `supplyRate = borrowRate × U × (1 − reserveFactor)`. Utilization is `debt / (cash + debt)` using tracked cash, so token donations cannot move rates.
- **Solvent by construction** on accrual: total supply grows by exactly what total debt grew. **Rounding** always favours the pool.
- Views: `supplyBalanceOf`, `debtBalanceOf`, `getAccountData` (incl. `healthFactor`), `getReserveData`, `borrowRateAt`, `availableLiquidity`.
- If the oracle reverts (stale price, tripped breaker) for **any** asset a user holds, `borrow`, `liquidate` and `withdraw` (if the user has debt) revert for that user, even when the liquidation uses other assets. Repaying and debt-free withdrawals keep working.

### `IPriceOracle.sol`

This interface is the only thing the pool will know about prices:

```solidity
function getPrice(address asset) external view returns (uint256); // USD per WHOLE token, 1e18
```

Implementations must revert instead of returning a zero or stale price. Because every oracle implements the same interface, you can swap one for another without changing the pool.

### `RelayedPriceOracle.sol`

Chainlink prices from Base, accepted on Horizen once enough relayers agree.

- **Exact-match quorum.** Every honest relayer reads the same Chainlink round, so a price is accepted once `quorum` distinct relayers have submitted identical `(asset, roundId, answer, updatedAt)`. This needs no median.
- **Vote key.** The key is `keccak256(abi.encode(epoch, asset, roundId, answer, updatedAt))`. `epoch` increments on every relayer or quorum change, so votes cast under an old relayer set never count toward a new one.
- **Checks on acceptance.** Malformed or replayed data reverts:
  - `answer > 0`
  - `updatedAt` is no more than 60 s in the future
  - the round is strictly newer than the newest known round (`pending` if tripped, else `latest`), which prevents replay
- **Scaling.** The Chainlink answer (8 decimals for USD feeds) is scaled to 1e18.
- **Circuit breaker (fails closed).** If an agreed round moves the price more than `maxDeviationBps` from the last trusted price, the call does **not** revert. Instead:
  - the asset is marked `tripped` and the round is parked in `pending`; `latest` stays untouched;
  - `getPrice` reverts with `CircuitBreakerActive` immediately, so the pool stops using the old price instead of keeping it alive until it goes stale;
  - newer agreed rounds keep updating `pending`, so the reviewer always sees the latest data;
  - the owner resolves it with `acceptPending(asset)` (the move was real: pending becomes trusted) or `resetBreaker(asset)` (the data was wrong: pending is discarded and the old price is usable again until it goes stale).
- **Reads.** `getPrice` reverts with `AssetNotEnabled`, `CircuitBreakerActive`, `NoPrice`, or `StalePrice` when the Chainlink `updatedAt` is older than the asset's `maxAge`. Staleness is measured from Chainlink's `updatedAt`, not from the relay time.
- **Public state.** `latest(asset)`, `pending(asset)`, `tripped(asset)`, `assetConfig(asset)`, `epoch`, `quorum`, `relayerCount`, `isRelayer(addr)`, `votes(key)`, `hasVoted(key, relayer)`.
- **Admin (owner, a multisig in production):** `addRelayer`, `removeRelayer`, `setQuorum`, `configureAsset(asset, feedDecimals, maxAge, maxDeviationBps)`, `acceptPending`, `resetBreaker`.

> **Trust model:** the contract cannot see Base. It trusts that at least `quorum` relayers are honest. Run relayer keys on separate infrastructure.

### Test and mock contracts

These are for tests and testnet only. **Never deploy them to mainnet.**

- `MockERC20.sol`: an ERC20 with configurable decimals and an open `mint` that works like a faucet. It stands in for WETH (18 decimals) and USDC (6 decimals).
- `MockPriceOracle.sol`: the owner sets every price by hand.

### Build and test

```shell
git submodule update --init --recursive   # first time only
forge build
forge test
forge fmt --check
```

CI (`.github/workflows/test.yml`) runs fmt, build and tests on every push and PR.

### Deploy to Horizen testnet

`script/DeployOracle.s.sol` deploys mock WETH, mock USDC and a `RelayedPriceOracle`. It then registers the relayers, sets the quorum and configures both assets:

| Asset | Feed decimals | `maxAge` | Max deviation |
| --- | --- | --- | --- |
| WETH | 8 | 4200 s (~1 h heartbeat + 10 min) | 20 % |
| USDC | 8 | 90 000 s (~24 h heartbeat + 1 h) | 50 % |

Check both heartbeats on Chainlink's feed pages before you rely on these values. `maxAge` must exceed the heartbeat: on a calm market a Chainlink price is legitimately many minutes (ETH) or up to a day (USDC) old. Keep the breaker loose for stablecoins: a depeg is real data the pool must see, not an error.

```shell
export PRIVATE_KEY=0x...                 # deployer; becomes the oracle owner
export RELAYERS=0xRelayer1,0xRelayer2    # comma-separated
export QUORUM=1                          # e.g. 1 for a solo test, 2 for 2-of-3
forge script script/DeployOracle.s.sol --rpc-url horizen_testnet --broadcast
```

The RPC aliases `horizen_testnet` and `horizen_mainnet` are defined in `foundry.toml`. The script logs the three deployed addresses. Copy them into `backend/.env`.

---

## Backend (`backend/`)

TypeScript on Node, using [viem](https://viem.sh), run with `tsx`.

```shell
cd backend
npm install
# then create backend/.env (see "Environment variables" below)
```

### Price server: `npm run server`

This is a read-only HTTP service. It sends no transactions.

Every `POLL_SECONDS`, it reads the Base sequencer uptime feed and each Chainlink feed in `src/config.ts`, keeps the latest readings in memory, and logs each new Chainlink round.

| Route | Response |
| --- | --- |
| `GET /prices` | Latest reading per feed: `roundId`, raw `answer`, `decimals`, `updatedAt`, human-readable `price`, `ageSeconds`, plus sequencer status and `lastPollAt`. Bigints are returned as strings. |
| `GET /health` | `200 {"status":"ok"}`, or `503 {"status":"degraded","problems":[...]}` when the last poll failed, the Base sequencer is down, or the sequencer is still in its 1-hour grace period after coming back up. |

The server listens on `http://localhost:8787` by default. Set `PORT` to change it.

### One-shot read: `npm run read`

Prints the sequencer status and every feed once, then exits. Use it to check the RPC connection and the feed configuration.

### Relayer: `npm run relay`

This is the write side. It pushes Chainlink rounds from Base into `RelayedPriceOracle` on Horizen. Each tick does the following:

1. Reads the sequencer and all feeds from Base. If the sequencer is down or in its grace period, it skips the tick.
2. For each feed, it skips the feed if the oracle already has that round or a newer one, or if this relayer already voted for it. It checks `hasVoted` with the same vote key the contract computes, so a restart never wastes gas.
3. It simulates `submit()` first, so a revert costs nothing, then sends the transaction and logs whether the vote reached quorum.
4. It reads `tripped(asset)` and compares against `pending(asset)` while tripped, and logs a warning when a circuit breaker is active on Horizen (owner review needed).

Without `RELAYER_PRIVATE_KEY`, the relayer runs in **dry-run** mode: it logs what it would submit and sends nothing. In production, run one process per relayer key, each on separate infrastructure.

### Liquidator: `npm run liquidate`

Keeps the pool solvent by liquidating positions with a health factor below 1.0. Each tick (`LIQ_POLL_SECONDS`):

1. **Borrower index.** Scans new `Borrowed` events (from `POOL_DEPLOY_BLOCK`, in chunks of `LOG_CHUNK_BLOCKS`) into a set of borrower addresses.
2. **Health check.** Calls `getAccountData(user)` for every borrower.
3. **Liquidate.** For each position with HF < 1 it picks the debt asset with the largest USD debt and the collateral asset with the largest USD value, and caps `debtToCover` by the close factor and by the wallet's balance of the debt asset. It approves the pool once, **simulates** `liquidate()` for exact amounts, and only sends if `profit − gas ≥ MIN_PROFIT_USD`.

Without `LIQUIDATOR_PRIVATE_KEY` it runs in **dry-run** mode and logs each opportunity with an estimated profit.

**Capital:** the wallet needs a **float of the debt asset** (e.g. USDC) plus a little ETH for gas. With `RECEIVE_UNDERLYING=true` seized collateral lands in the wallet as tokens; with `false` it stays in the pool as a supply position. Selling or rebalancing seized collateral is not automated.

**Known limitations** (not fixed yet):

- The health check uses `Promise.all`. If one borrower's `getAccountData` reverts because an oracle is down, the whole tick fails and **no** borrower is liquidated.
- Ticks run on `setInterval`, so a slow tick (waiting for receipts) can overlap the next one. That risks double attempts and nonce clashes. `relay.ts` has the same pattern.
- The gas cost is priced with the borrower's WETH row. For borrowers without WETH that price is `0`, so gas counts as $0 in the profit check. The OP-stack L1 data fee isn't included either.
- The bot always picks the largest collateral. It doesn't fall back to another collateral or to `receiveUnderlying=false` when that reserve lacks cash (`InsufficientLiquidity`).
- The event scan goes right up to the chain head (not reorg-safe), and the asset list is loaded only once at startup.

#### Local end-to-end demo (anvil)

`script/LiquidationDemo.s.sol` deploys mocks and the pool on a local anvil node, creates a borrower at max LTV and drops the ETH price so HF = 0.978.

```shell
anvil                                                              # terminal 1
forge script script/LiquidationDemo.s.sol --rpc-url http://127.0.0.1:8545 --broadcast   # terminal 2

cd backend                                                         # terminal 2
HORIZEN_NETWORK=local POOL_ADDRESS=<printed POOL_ADDRESS> POOL_DEPLOY_BLOCK=0 npm run liquidate      # dry-run
HORIZEN_NETWORK=local POOL_ADDRESS=<printed POOL_ADDRESS> POOL_DEPLOY_BLOCK=0 \
  LIQUIDATOR_PRIVATE_KEY=0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6 npm run liquidate   # live (anvil account #3)
```

Expected: `LIQUIDATED covered 1125 USDC, seized 0.4397… WETH, net ~$83`, after which the position is healthy again. The key above is anvil's public test key #3; never use it anywhere else.

### Feed configuration (`src/config.ts`)

| Symbol | Chainlink proxy on Base | Expected `description()` |
| --- | --- | --- |
| ETH | `0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70` | `ETH / USD` |
| USDC | `0x7e860098F58bBFC8648a4311b374B1D669a2bc6B` | `USDC / USD` |

The Base sequencer uptime feed is `0xBCF85224fc0756B9Fa45aA7892530B47e10b6433`, with a grace period of 3600 s. **This address is not verified yet** (unlike the two price feeds, it has no `description()` check); confirm it at [docs.chain.link](https://docs.chain.link/data-feeds/l2-sequencer-feeds) (network: Base).

As a safety net, `readFeed()` refuses any feed whose on-chain `description()` doesn't match the expected value. Verify addresses at [docs.chain.link](https://docs.chain.link/data-feeds/price-feeds/addresses) (network: Base).

### Environment variables (`backend/.env`)

| Variable | Used by | Default | Notes |
| --- | --- | --- | --- |
| `BASE_RPC_URL` | all | `https://mainnet.base.org` | The public endpoint is rate-limited. Use Alchemy, QuickNode or similar for long runs. |
| `POLL_SECONDS` | server, relay | `15` | |
| `PORT` | server | `8787` | |
| `HORIZEN_NETWORK` | relay, liquidate | `testnet` | `testnet`, `mainnet` or `local` (anvil) |
| `HORIZEN_RPC_URL` | relay, liquidate | public Caldera RPC (`local`: `http://127.0.0.1:8545`) | Optional override |
| `ORACLE_ADDRESS` | relay | required | From the deploy script |
| `HORIZEN_ASSET_ETH` | relay | required | Token address on Horizen, used as the oracle's asset key |
| `HORIZEN_ASSET_USDC` | relay | required | Same, for USDC |
| `RELAYER_PRIVATE_KEY` | relay | empty (dry-run) | **Never commit it.** Use a dedicated key per relayer, funded with a little ETH for gas. |
| `POOL_ADDRESS` | liquidate | required | The `LendingPool` address |
| `POOL_DEPLOY_BLOCK` | liquidate | `0` | Where the `Borrowed`-event scan starts |
| `LIQUIDATOR_PRIVATE_KEY` | liquidate | empty (dry-run) | **Never commit it.** Wallet needs a float of the debt asset + ETH for gas |
| `LIQ_POLL_SECONDS` | liquidate | `15` | |
| `MIN_PROFIT_USD` | liquidate | `1` | Skip if simulated profit minus gas is lower |
| `RECEIVE_UNDERLYING` | liquidate | `true` | `false`: receive collateral as a supply position |
| `LOG_CHUNK_BLOCKS` | liquidate | `5000` | Max block range per `eth_getLogs` |

Run `npm run typecheck` to type-check the backend.

---

## Known risks and limitations

See [`AUDIT.md`](AUDIT.md) for the full security review, severities and proof-of-concept tests.

- **Relayer trust.** If `quorum` relayer keys are compromised, the price is compromised. Keep keys on separate machines; the owner must be a Safe multisig.
- **Oracle down = pool frozen for affected users** (audit H-2). A tripped breaker or a stale price blocks borrows **and liquidations** for every user holding that asset, even when a liquidation would use other assets. The breaker trips on large moves, exactly when liquidations are needed. For the MVP there is no alerting: the relayer only logs it, so watch the relayer logs.
- **Bad debt** (audit H-1). If collateral falls below the debt before liquidators act, the leftover debt stays with nothing behind it. It keeps accruing interest, which inflates supplier and treasury balances that can never be paid out. Withdrawals are first-come, first-served, so the last suppliers to exit take the loss. There is no write-off or reserve fund yet.
- **Non-collateral can be seized, and the bonus is uncapped** (audit M-1). `liquidate` accepts any supplied asset as `collateralAsset`, including one with a liquidation threshold of 0. For such assets the bonus validation allows up to 655 %.
- **Instant admin changes** (audit M-2). `setOracle`, `setRiskParams` and `setRateModel` apply immediately. A compromised owner key could make every position liquidatable in one block. A timelock is needed before mainnet.
- **No emergency pause** for supply and borrow.
- **Standard ERC20s only.** Fee-on-transfer and rebasing tokens break the pool's `cash` bookkeeping.
- **USDC vs USDC.e.** Chainlink's USDC / USD prices native USDC. The pool on Horizen will hold USDC.e (bridged via Stargate), which the oracle cannot see depegging on its own. Mitigate with a lower LTV and supply caps.
- **Chainlink redistribution terms.** Check Chainlink's terms of use on relaying feed data to another chain before mainnet.
- **Liquidation needs liquidators and liquidity.** Someone must run a bot, and the seized collateral must be sellable on Horizen. Thin DEX liquidity means a higher bonus or lower LTVs. Small positions may never be worth liquidating.
- **Mocks.** `MockERC20` and `MockPriceOracle` are testnet-only.

## Roadmap

- [x] Mock ERC20 tokens
- [x] Lending pool: supply and withdraw
- [x] Lending pool: borrowing with LTV using `IPriceOracle`
- [x] Interest: indices, scaled balances, kinked rate model, reserve factor
- [x] Relayed Chainlink price oracle (k-of-n quorum)
- [x] Backend price server
- [x] Relayer (Base → Horizen), aligned with the oracle's circuit breaker (`tripped` / `pending`)
- [x] Circuit breaker that fails closed, with owner review (`acceptPending` / `resetBreaker`)
- [ ] Alerting when a breaker trips, prices go stale or relayers stop (post-MVP)
- [x] Liquidations: liquidation threshold, health factor, close factor, bonus
- [x] Liquidation bot (backend), tested end-to-end on anvil
- [x] Security review of liquidations ([`AUDIT.md`](AUDIT.md))
- [ ] Bad-debt handling (write-off / reserve fund)
- [ ] Audit fixes: reject zero-threshold collateral, cap the bonus, liquidations during oracle outages, timelock
- [ ] Liquidator bot fixes: `Promise.allSettled`, no overlapping ticks, gas pricing
- [ ] Deploy pool to Horizen testnet with `RelayedPriceOracle`
- [ ] v2: trust-minimized prices via storage proofs against Base's block hash (`L1Block` predeploy)
