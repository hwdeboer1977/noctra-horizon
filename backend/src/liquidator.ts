import "dotenv/config";
import { BaseError, ContractFunctionRevertedError, formatUnits, getAddress, maxUint256, type Address, type Hex } from "viem";
import { makeHorizenClients } from "./horizen.js";
import { erc20Abi, lendingPoolAbi, oracleAbi } from "./pool.js";

/**
 * Liquidator bot for LendingPool on Horizen.
 *
 * Every LIQ_POLL_SECONDS:
 *   1. Borrower index: scan new `Borrowed` events -> set of addresses that ever borrowed.
 *   2. Health check: getAccountData(user) for every borrower.
 *   3. For each position with HF < 1:
 *        - pick the debt asset with the largest USD debt and the collateral asset
 *          with the largest USD value,
 *        - cap debtToCover by the close factor AND by our wallet balance (our float),
 *        - DRY-RUN: log the opportunity with an off-chain profit estimate,
 *          LIVE:    simulate liquidate() (exact amounts), check profit > gas + margin, send.
 *
 * Without LIQUIDATOR_PRIVATE_KEY it runs in DRY-RUN mode.
 *
 * Capital: liquidating needs a FLOAT of the debt asset (e.g. USDC) in this wallet.
 * With RECEIVE_UNDERLYING=true the seized collateral (e.g. WETH) lands in the wallet;
 * selling/rebalancing it is not automated here.
 */

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const env = (name: string, fallback?: string): string => {
  const v = process.env[name] ?? fallback;
  if (v === undefined || v === "") throw new Error(`Missing env var ${name}`);
  return v;
};

const NETWORK = env("HORIZEN_NETWORK", "testnet");
const POOL = getAddress(env("POOL_ADDRESS"));
const DEPLOY_BLOCK = BigInt(env("POOL_DEPLOY_BLOCK", "0"));
const POLL_SECONDS = Number(process.env.LIQ_POLL_SECONDS ?? 15);
const LOG_CHUNK = BigInt(process.env.LOG_CHUNK_BLOCKS ?? 5000);
const MIN_PROFIT_USD = Number(process.env.MIN_PROFIT_USD ?? 1);
const RECEIVE_UNDERLYING = (process.env.RECEIVE_UNDERLYING ?? "true") === "true";
const PRIVATE_KEY = process.env.LIQUIDATOR_PRIVATE_KEY as Hex | undefined;
const DRY_RUN = !PRIVATE_KEY;

const WAD = 10n ** 18n;
const BPS = 10_000n;
const FULL_LIQUIDATION_HF = 95n * 10n ** 16n; // 0.95, must match the contract
const CLOSE_FACTOR_BPS = 5_000n; // must match the contract

const { publicClient, walletClient, account } = makeHorizenClients(NETWORK, process.env.HORIZEN_RPC_URL, PRIVATE_KEY);
const pool = { address: POOL, abi: lendingPoolAbi } as const;
const log = (msg: string) => console.log(`[${new Date().toISOString()}] ${msg}`);

// ---------------------------------------------------------------------------
// Static pool info (loaded once)
// ---------------------------------------------------------------------------

interface AssetInfo {
  address: Address;
  symbol: string;
  decimals: number;
  liqBonusBps: bigint;
}

let ORACLE: Address;
let ASSETS: AssetInfo[] = [];

async function loadPoolInfo() {
  ORACLE = await publicClient.readContract({ ...pool, functionName: "oracle" });
  const n = await publicClient.readContract({ ...pool, functionName: "assetCount" });
  ASSETS = [];
  for (let i = 0n; i < n; i++) {
    const address = await publicClient.readContract({ ...pool, functionName: "assetList", args: [i] });
    const [, , , , liqBonusBps, decimals] = await publicClient.readContract({
      ...pool,
      functionName: "assetConfig",
      args: [address],
    });
    const symbol = await publicClient.readContract({ address, abi: erc20Abi, functionName: "symbol" });
    ASSETS.push({ address, symbol, decimals, liqBonusBps: BigInt(liqBonusBps) });
  }
  log(`Pool ${POOL}: oracle ${ORACLE}, assets ${ASSETS.map((a) => a.symbol).join(", ")}`);
}

// ---------------------------------------------------------------------------
// 1. Borrower index from events
// ---------------------------------------------------------------------------

const borrowers = new Set<Address>();
let scannedUpTo = DEPLOY_BLOCK - 1n;

async function scanBorrowers() {
  const head = await publicClient.getBlockNumber();
  while (scannedUpTo < head) {
    const from = scannedUpTo + 1n;
    const to = from + LOG_CHUNK - 1n < head ? from + LOG_CHUNK - 1n : head;
    const logs = await publicClient.getContractEvents({
      ...pool,
      eventName: "Borrowed",
      fromBlock: from,
      toBlock: to,
    });
    for (const l of logs) if (l.args.user) borrowers.add(getAddress(l.args.user));
    scannedUpTo = to;
  }
}

// ---------------------------------------------------------------------------
// 2 + 3. Health checks and liquidation
// ---------------------------------------------------------------------------

const usd = (v: bigint) => Number(formatUnits(v, 18)).toFixed(2);
const toUsd = (amount: bigint, price: bigint, decimals: number) => (amount * price) / 10n ** BigInt(decimals);

function revertReason(err: unknown): string {
  if (err instanceof BaseError) {
    const r = err.walk((e) => e instanceof ContractFunctionRevertedError);
    if (r instanceof ContractFunctionRevertedError) return r.data?.errorName ?? r.shortMessage;
    return err.shortMessage;
  }
  return String(err);
}

async function tryLiquidate(user: Address, hf: bigint) {
  // Per-asset balances and prices for this user
  const rows = await Promise.all(
    ASSETS.map(async (a) => {
      const [debt, coll] = await Promise.all([
        publicClient.readContract({ ...pool, functionName: "debtBalanceOf", args: [a.address, user] }),
        publicClient.readContract({ ...pool, functionName: "supplyBalanceOf", args: [a.address, user] }),
      ]);
      const price =
        debt > 0n || coll > 0n
          ? await publicClient.readContract({ address: ORACLE, abi: oracleAbi, functionName: "getPrice", args: [a.address] })
          : 0n;
      return { a, debt, coll, price, debtUsd: toUsd(debt, price, a.decimals), collUsd: toUsd(coll, price, a.decimals) };
    }),
  );

  const debtRow = rows.filter((r) => r.debt > 0n).sort((x, y) => (y.debtUsd > x.debtUsd ? 1 : -1))[0];
  const collRow = rows.filter((r) => r.coll > 0n).sort((x, y) => (y.collUsd > x.collUsd ? 1 : -1))[0];
  if (!debtRow || !collRow) {
    log(`${user}: HF ${formatUnits(hf, 18)} but no debt/collateral pair found (bad debt only?)`);
    return;
  }

  // Close factor (mirrors the contract) and our available float
  const maxClose = hf < FULL_LIQUIDATION_HF ? debtRow.debt : (debtRow.debt * CLOSE_FACTOR_BPS) / BPS;
  const float = account
    ? await publicClient.readContract({ address: debtRow.a.address, abi: erc20Abi, functionName: "balanceOf", args: [account.address] })
    : maxClose; // dry-run: pretend we have enough
  const debtToCover = maxClose < float ? maxClose : float;

  const tag = `${user} HF ${Number(formatUnits(hf, 18)).toFixed(4)}: repay ${debtRow.a.symbol}, seize ${collRow.a.symbol}`;
  if (debtToCover === 0n) {
    log(`${tag}: NO FLOAT (wallet holds 0 ${debtRow.a.symbol}); top up to liquidate`);
    return;
  }

  // Off-chain estimate: profit ~ covered value x bonus (capped by available collateral)
  const coverUsd = toUsd(debtToCover, debtRow.price, debtRow.a.decimals);
  let seizeUsd = (coverUsd * (BPS + collRow.a.liqBonusBps)) / BPS;
  if (seizeUsd > collRow.collUsd) seizeUsd = collRow.collUsd;
  const estProfitUsd = seizeUsd - (seizeUsd * BPS) / (BPS + collRow.a.liqBonusBps);

  if (DRY_RUN) {
    log(`${tag}: [dry-run] would cover ~$${usd(coverUsd)}, seize ~$${usd(seizeUsd)}, est. profit ~$${usd(estProfitUsd)}`);
    return;
  }

  // Allowance for the debt asset (once, max)
  const me = account!.address;
  const allowance = await publicClient.readContract({
    address: debtRow.a.address,
    abi: erc20Abi,
    functionName: "allowance",
    args: [me, POOL],
  });
  if (allowance < debtToCover) {
    const hash = await walletClient!.writeContract({
      address: debtRow.a.address,
      abi: erc20Abi,
      functionName: "approve",
      args: [POOL, maxUint256],
      account: account!,
      chain: walletClient!.chain,
    });
    await publicClient.waitForTransactionReceipt({ hash });
    log(`approved ${debtRow.a.symbol} for the pool (tx ${hash})`);
  }

  // Simulate: exact amounts from the contract, and a revert here costs nothing
  const { request, result } = await publicClient.simulateContract({
    ...pool,
    account: account!,
    functionName: "liquidate",
    args: [collRow.a.address, debtRow.a.address, user, debtToCover, RECEIVE_UNDERLYING],
  });
  const [covered, seized] = result;
  const profitUsd =
    toUsd(seized, collRow.price, collRow.a.decimals) - toUsd(covered, debtRow.price, debtRow.a.decimals);

  // Gas cost in USD (gas is paid in ETH on Horizen; price it with the pool's WETH price if listed)
  const gas = await publicClient.estimateContractGas({ ...request, account: account! });
  const gasPrice = await publicClient.getGasPrice();
  const weth = rows.find((r) => r.a.symbol.toUpperCase().includes("ETH"));
  const ethPrice =
    weth?.price ??
    (await publicClient.readContract({ address: ORACLE, abi: oracleAbi, functionName: "getPrice", args: [ASSETS.find((a) => a.symbol.toUpperCase().includes("ETH"))!.address] }));
  const gasUsd = (gas * gasPrice * ethPrice) / WAD;

  const netUsd = Number(formatUnits(profitUsd - gasUsd, 18));
  if (netUsd < MIN_PROFIT_USD) {
    log(`${tag}: skip, net profit $${netUsd.toFixed(2)} < MIN_PROFIT_USD $${MIN_PROFIT_USD}`);
    return;
  }

  const hash = await walletClient!.writeContract(request);
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  log(
    `${tag}: LIQUIDATED covered ${formatUnits(covered, debtRow.a.decimals)} ${debtRow.a.symbol}, ` +
      `seized ${formatUnits(seized, collRow.a.decimals)} ${collRow.a.symbol}, net ~$${netUsd.toFixed(2)}, ` +
      `tx ${hash} status ${receipt.status}`,
  );
}

async function tick() {
  try {
    await scanBorrowers();
    const list = [...borrowers];
    const data = await Promise.all(
      list.map((user) => publicClient.readContract({ ...pool, functionName: "getAccountData", args: [user] })),
    );

    let unhealthy = 0;
    for (let i = 0; i < list.length; i++) {
      const { debtValue, healthFactor } = data[i];
      if (debtValue === 0n || healthFactor >= WAD) continue;
      unhealthy++;
      try {
        await tryLiquidate(list[i], healthFactor);
      } catch (err) {
        log(`${list[i]}: liquidation failed: ${revertReason(err)}`);
      }
    }
    log(`tick: ${list.length} borrower(s), ${unhealthy} unhealthy, scanned to block ${scannedUpTo}`);
  } catch (err) {
    // Typical cause: the oracle reverts (stale price / breaker) -> getAccountData reverts.
    log(`tick failed: ${revertReason(err)}`);
  }
}

async function main() {
  log(`Liquidator starting: network=${NETWORK} pool=${POOL} mode=${DRY_RUN ? "DRY-RUN" : "LIVE"}`);
  if (account) log(`Liquidator address ${account.address}`);
  await loadPoolInfo();
  await tick();
  setInterval(tick, POLL_SECONDS * 1000);
}

main().catch((err) => {
  console.error(err instanceof Error ? err.message : err);
  process.exit(1);
});
