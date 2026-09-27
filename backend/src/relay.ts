import "dotenv/config";
import { getAddress, type Address, type Hex } from "viem";
import { FEEDS, SEQUENCER_UPTIME_FEED, SEQUENCER_GRACE_PERIOD_SECONDS } from "./config.js";
import { makeBaseClient, readFeed, readSequencer, type FeedReading } from "./chainlink.js";
import { makeHorizenClients, relayedOracleAbi, voteKey } from "./horizen.js";

/**
 * Relayer: Chainlink on Base -> RelayedPriceOracle on Horizen.
 *
 * Every POLL_SECONDS:
 *   1. Read Base sequencer + all feeds (one multicall).
 *   2. Skip everything if the Base sequencer is down or in its grace period.
 *   3. Per feed: skip if the oracle already has this round (or a newer one),
 *      or if THIS relayer already voted for it. Otherwise submit().
 *
 * Without RELAYER_PRIVATE_KEY it runs in DRY-RUN mode: it logs what it would submit.
 * Run one process per relayer key, on separate machines in production.
 */

const env = (name: string, fallback?: string): string => {
  const v = process.env[name] ?? fallback;
  if (v === undefined || v === "") throw new Error(`Missing env var ${name}`);
  return v;
};

const POLL_SECONDS = Number(process.env.POLL_SECONDS ?? 15);
const NETWORK = env("HORIZEN_NETWORK", "testnet");
const ORACLE = getAddress(env("ORACLE_ADDRESS"));
const PRIVATE_KEY = process.env.RELAYER_PRIVATE_KEY as Hex | undefined;
const DRY_RUN = !PRIVATE_KEY;

const base = makeBaseClient(process.env.BASE_RPC_URL ?? "https://mainnet.base.org");
const horizen = makeHorizenClients(NETWORK, process.env.HORIZEN_RPC_URL, PRIVATE_KEY);

// symbol -> token address on Horizen (the oracle's asset key)
const ASSETS: Record<string, Address> = Object.fromEntries(
  FEEDS.map((f) => [f.symbol, getAddress(env(f.horizenAssetEnv))]),
);

const log = (msg: string) => console.log(`[${new Date().toISOString()}] ${msg}`);

/** Newest round the oracle knows about: pending if tripped, else latest. */
async function oracleLastRound(asset: Address): Promise<{ roundId: bigint; tripped: boolean }> {
  const tripped = await horizen.publicClient.readContract({
    address: ORACLE, abi: relayedOracleAbi, functionName: "tripped", args: [asset],
  });
  const [, roundId] = await horizen.publicClient.readContract({
    address: ORACLE, abi: relayedOracleAbi, functionName: tripped ? "pending" : "latest", args: [asset],
  });
  return { roundId, tripped };
}

async function relayOne(r: FeedReading, epoch: bigint) {
  const asset = ASSETS[r.symbol];
  const { roundId: onChainRound, tripped } = await oracleLastRound(asset);

  if (tripped) log(`${r.symbol}: circuit breaker TRIPPED on Horizen, owner review needed`);
  if (onChainRound >= r.roundId) return; // oracle already has this round or newer

  if (DRY_RUN) {
    log(`${r.symbol}: [dry-run] would submit round ${r.roundId} answer ${r.answer} ($${r.price}) updatedAt ${r.updatedAt}`);
    return;
  }

  const me = horizen.account!.address;
  const key = voteKey(epoch, asset, r.roundId, r.answer, r.updatedAt);
  const already = await horizen.publicClient.readContract({
    address: ORACLE, abi: relayedOracleAbi, functionName: "hasVoted", args: [key, me],
  });
  if (already) return; // voted before (e.g. before a restart); waiting for other relayers

  // simulate first: a revert (e.g. NotNewer, InvalidAnswer) is caught here, costing no gas
  const { request, result } = await horizen.publicClient.simulateContract({
    account: horizen.account!,
    address: ORACLE,
    abi: relayedOracleAbi,
    functionName: "submit",
    args: [asset, r.roundId, r.answer, r.updatedAt],
  });
  const hash = await horizen.walletClient!.writeContract(request);
  const receipt = await horizen.publicClient.waitForTransactionReceipt({ hash });

  log(
    `${r.symbol}: submitted round ${r.roundId} ($${r.price}) tx ${hash} ` +
      `status ${receipt.status} ${result ? "-> ACCEPTED (quorum reached)" : "-> vote recorded"}`,
  );
}

async function tick() {
  try {
    const [seq, ...readings] = await Promise.all([
      readSequencer(base, SEQUENCER_UPTIME_FEED, SEQUENCER_GRACE_PERIOD_SECONDS),
      ...FEEDS.map((cfg) => readFeed(base, cfg)),
    ]);

    if (!seq.up || seq.inGracePeriod) {
      log(`Base sequencer ${seq.up ? "in grace period" : "DOWN"}; not relaying`);
      return;
    }

    const epoch = await horizen.publicClient.readContract({
      address: ORACLE, abi: relayedOracleAbi, functionName: "epoch",
    });

    // Sequential on purpose: one tx at a time keeps nonces simple.
    for (const r of readings) {
      try {
        await relayOne(r, epoch);
      } catch (err) {
        const e = err as { shortMessage?: string; message?: string };
        log(`${r.symbol}: relay failed: ${e.shortMessage ?? e.message ?? String(err)}`);
      }
    }
  } catch (err) {
    const e = err as { shortMessage?: string; details?: string; message?: string };
    log(`tick failed: ${e.shortMessage ?? e.message ?? String(err)}${e.details ? ` (${e.details})` : ""}`);
  }
}

async function main() {
  log(`Relayer starting: network=${NETWORK} oracle=${ORACLE} mode=${DRY_RUN ? "DRY-RUN" : "LIVE"}`);
  if (!DRY_RUN) {
    const me = horizen.account!.address;
    const ok = await horizen.publicClient.readContract({
      address: ORACLE, abi: relayedOracleAbi, functionName: "isRelayer", args: [me],
    });
    if (!ok) throw new Error(`${me} is not a registered relayer on ${ORACLE}`);
    log(`Relayer address ${me} is registered`);
  }
  await tick();
  setInterval(tick, POLL_SECONDS * 1000);
}

main().catch((err) => {
  console.error(err instanceof Error ? err.message : err);
  process.exit(1);
});
