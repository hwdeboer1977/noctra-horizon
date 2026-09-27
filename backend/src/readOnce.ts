import "dotenv/config";
import { FEEDS, SEQUENCER_UPTIME_FEED, SEQUENCER_GRACE_PERIOD_SECONDS } from "./config.js";
import { makeBaseClient, readFeed, readSequencer } from "./chainlink.js";

/** One-shot: read all feeds once and print them. `npm run read` */
async function main() {
  const client = makeBaseClient(process.env.BASE_RPC_URL ?? "https://mainnet.base.org");

  // Start ALL reads in the same tick so viem merges them into a single multicall.
  const [seq, ...readings] = await Promise.all([
    readSequencer(client, SEQUENCER_UPTIME_FEED, SEQUENCER_GRACE_PERIOD_SECONDS),
    ...FEEDS.map((cfg) => readFeed(client, cfg)),
  ]);

  console.log(
    `Base sequencer: ${seq.up ? "UP" : "DOWN"} for ${seq.sinceSeconds}s` +
      (seq.inGracePeriod ? " (in grace period, prices not yet trusted)" : ""),
  );

  for (const r of readings) {
    console.log(
      `${r.description.padEnd(11)} $${r.price.padEnd(14)} round ${r.roundId}  ` +
        `updated ${new Date(Number(r.updatedAt) * 1000).toISOString()} (${r.ageSeconds}s ago)  ` +
        `raw ${r.answer} (${r.decimals} dec)`,
    );
  }
}

main().catch((err) => {
  // Short message instead of viem's full dump; set DEBUG=1 for the whole error.
  if (process.env.DEBUG) console.error(err);
  else console.error(`Error: ${err?.shortMessage ?? err?.message ?? err}${err?.details ? ` (${err.details})` : ""}`);
  process.exit(1);
});
