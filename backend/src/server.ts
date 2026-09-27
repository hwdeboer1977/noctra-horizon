import "dotenv/config";
import { createServer } from "node:http";
import { FEEDS, SEQUENCER_UPTIME_FEED, SEQUENCER_GRACE_PERIOD_SECONDS } from "./config.js";
import { makeBaseClient, readFeed, readSequencer, type FeedReading, type SequencerStatus } from "./chainlink.js";

/**
 * Minimal backend: polls Chainlink on Base, keeps the latest readings in memory,
 * logs every new Chainlink round, and serves them over HTTP.
 *
 *   GET /prices  -> latest readings (JSON)
 *   GET /health  -> ok / degraded + reason
 *
 * No writes to any chain yet. Relaying to Horizen is the next step.
 */
const RPC = process.env.BASE_RPC_URL ?? "https://mainnet.base.org";
const POLL_SECONDS = Number(process.env.POLL_SECONDS ?? 15);
const PORT = Number(process.env.PORT ?? 8787);

const client = makeBaseClient(RPC);

const state: {
  readings: Record<string, FeedReading>;
  sequencer?: SequencerStatus;
  lastPollAt?: string;
  lastError?: string;
} = { readings: {} };

async function poll() {
  try {
    state.sequencer = await readSequencer(client, SEQUENCER_UPTIME_FEED, SEQUENCER_GRACE_PERIOD_SECONDS);
    for (const cfg of FEEDS) {
      const r = await readFeed(client, cfg);
      const prev = state.readings[cfg.symbol];
      if (!prev || prev.roundId !== r.roundId) {
        console.log(`[${new Date().toISOString()}] ${r.description} new round ${r.roundId}: $${r.price}`);
      }
      state.readings[cfg.symbol] = r;
    }
    state.lastPollAt = new Date().toISOString();
    state.lastError = undefined;
  } catch (err) {
    state.lastError = err instanceof Error ? err.message : String(err);
    console.error(`[${new Date().toISOString()}] poll failed: ${state.lastError}`);
  }
}

/** JSON.stringify cannot serialize bigint; send them as strings. */
function toJson(value: unknown): string {
  return JSON.stringify(value, (_k, v) => (typeof v === "bigint" ? v.toString() : v), 2);
}

const server = createServer((req, res) => {
  res.setHeader("content-type", "application/json");

  if (req.url === "/prices") {
    res.end(toJson({ lastPollAt: state.lastPollAt, sequencer: state.sequencer, prices: state.readings }));
    return;
  }

  if (req.url === "/health") {
    const problems: string[] = [];
    if (state.lastError) problems.push(`last poll failed: ${state.lastError}`);
    if (!state.sequencer?.up) problems.push("Base sequencer down or unknown");
    if (state.sequencer?.inGracePeriod) problems.push("Base sequencer in grace period");
    res.statusCode = problems.length ? 503 : 200;
    res.end(toJson({ status: problems.length ? "degraded" : "ok", problems }));
    return;
  }

  res.statusCode = 404;
  res.end(toJson({ error: "not found", routes: ["/prices", "/health"] }));
});

await poll();
setInterval(poll, POLL_SECONDS * 1000);
server.listen(PORT, () => {
  console.log(`Price server on http://localhost:${PORT}  (polling Base every ${POLL_SECONDS}s)`);
});
