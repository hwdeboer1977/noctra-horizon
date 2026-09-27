# Noctra on Horizen

A lending protocol for [Horizen](https://horizen.io), an OP Stack L3 on Base, and the price infrastructure it needs.

Horizen has no native Chainlink feeds, so prices are read from Chainlink on **Base** and relayed to Horizen by a k-of-n set of relayers:

```
 Base mainnet                      off-chain                       Horizen
┌──────────────────────┐     ┌──────────────────┐     ┌──────────────────────────┐
│ Chainlink ETH / USD  │     │ backend/         │     │ RelayedPriceOracle       │
│ Chainlink USDC / USD │───► │  server  (read)  │     │   k-of-n exact-match     │
│ Sequencer uptime     │     │  relay   (write) │───► │   vote → getPrice(asset) │
└──────────────────────┘     └──────────────────┘     └────────────┬─────────────┘
                                                                   │ IPriceOracle
                                                      ┌────────────▼─────────────┐
                                                      │ LendingPool (future use) │
                                                      └──────────────────────────┘
```

| Path | What it holds |
| --- | --- |
| `src/` | Solidity contracts (Foundry) |
| `test/` | Forge tests |
| `script/` | Deployment scripts |
| `backend/` | TypeScript price server and relayer (viem) |

---

## Smart contracts

Solidity `0.8.24`, built with [Foundry](https://book.getfoundry.sh/). Dependencies are git submodules in `lib/`: `forge-std` and `openzeppelin-contracts`.

### `LendingPool.sol`

Step 2 of the pool: **supply and withdraw only**. It has no borrowing, interest or price checks yet.

- `addAsset(asset)` (owner only) whitelists a token.
- `supply(asset, amount)` pulls tokens from the caller. Approve the pool first.
- `withdraw(asset, amount)` returns tokens. Pass `type(uint256).max` to withdraw your full balance.
- The pool tracks `suppliedBalance[asset][user]` and `totalSupplied[asset]`.
- Both user functions follow checks-effects-interactions and use `SafeERC20`.

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
| `HORIZEN_NETWORK` | relay | `testnet` | `testnet` or `mainnet` |
| `HORIZEN_RPC_URL` | relay | public Caldera RPC | Optional override |
| `ORACLE_ADDRESS` | relay | required | From the deploy script |
| `HORIZEN_ASSET_ETH` | relay | required | Token address on Horizen, used as the oracle's asset key |
| `HORIZEN_ASSET_USDC` | relay | required | Same, for USDC |
| `RELAYER_PRIVATE_KEY` | relay | empty (dry-run) | **Never commit it.** Use a dedicated key per relayer, funded with a little ETH for gas. |

Run `npm run typecheck` to type-check the backend.

---

## Known risks and limitations

- **Relayer trust.** If `quorum` relayer keys are compromised, the price is compromised. Keep keys on separate machines; the owner must be a Safe multisig.
- **Tripped breaker stops the pool.** A tripped ETH breaker blocks borrows and liquidations until the owner acts. The relayer only logs it; alerting (Telegram/Discord) is still to do.
- **USDC vs USDC.e.** Chainlink's USDC / USD prices native USDC. The pool on Horizen will hold USDC.e (bridged via Stargate), which the oracle cannot see depegging on its own. Mitigate with a lower LTV and supply caps.
- **Chainlink redistribution terms.** Check Chainlink's terms of use on relaying feed data to another chain before mainnet.
- **Mocks.** `MockERC20` and `MockPriceOracle` are testnet-only.

## Roadmap

- [x] Mock ERC20 tokens
- [x] Lending pool: supply and withdraw
- [x] Relayed Chainlink price oracle (k-of-n quorum)
- [x] Backend price server
- [x] Relayer (Base → Horizen), aligned with the oracle's circuit breaker (`tripped` / `pending`)
- [x] Circuit breaker that fails closed, with owner review (`acceptPending` / `resetBreaker`)
- [ ] Alerting when a breaker trips or relayers stop
- [ ] Lending pool: borrowing, collateral and health factor using `IPriceOracle`
- [ ] Interest rates and liquidations
- [ ] v2: trust-minimized prices via storage proofs against Base's block hash (`L1Block` predeploy)
