import "dotenv/config";
import { FEEDS, SEQUENCER_UPTIME_FEED, SEQUENCER_GRACE_PERIOD_SECONDS } from "./config.js";
import { makeBaseClient, readFeed, readSequencer } from "./chainlink.js";

/** One-shot: read all feeds once and print them. `npm run read` */
async function main() {
  const client = makeBaseClient(process.env.BASE_RPC_URL ?? "https://mainnet.base.org");

  const seq = await readSequencer(client, SEQUENCER_UPTIME_FEED, SEQUENCER_GRACE_PERIOD_SECONDS);
  console.log(
    `Base sequencer: ${seq.up ? "UP" : "DOWN"} for ${seq.sinceSeconds}s` +
      (seq.inGracePeriod ? " (in grace period, prices not yet trusted)" : ""),
  );

  for (const cfg of FEEDS) {
    const r = await readFeed(client, cfg);
    console.log(
      `${r.description.padEnd(11)} $${r.price.padEnd(14)} round ${r.roundId}  ` +
        `updated ${new Date(Number(r.updatedAt) * 1000).toISOString()} (${r.ageSeconds}s ago)  ` +
        `raw ${r.answer} (${r.decimals} dec)`,
    );
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
