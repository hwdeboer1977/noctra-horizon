import { createPublicClient, http, formatUnits, type Address, type PublicClient } from "viem";
import { base } from "viem/chains";
import type { FeedConfig } from "./config.js";

/** Minimal Chainlink AggregatorV3Interface ABI: only what we call. */
export const aggregatorV3Abi = [
  {
    type: "function",
    name: "latestRoundData",
    stateMutability: "view",
    inputs: [],
    outputs: [
      { name: "roundId", type: "uint80" },
      { name: "answer", type: "int256" },
      { name: "startedAt", type: "uint256" },
      { name: "updatedAt", type: "uint256" },
      { name: "answeredInRound", type: "uint80" },
    ],
  },
  { type: "function", name: "decimals", stateMutability: "view", inputs: [], outputs: [{ type: "uint8" }] },
  { type: "function", name: "description", stateMutability: "view", inputs: [], outputs: [{ type: "string" }] },
] as const;

export function makeBaseClient(rpcUrl: string): PublicClient {
  return createPublicClient({ chain: base, transport: http(rpcUrl) }) as PublicClient;
}

/**
 * Exactly what a relayer will later submit to RelayedPriceOracle.submit():
 * roundId, answer (raw, feed decimals) and updatedAt (Chainlink's timestamp).
 * `price` and `ageSeconds` are for humans only.
 */
export interface FeedReading {
  symbol: string;
  feed: Address;
  description: string;
  decimals: number;
  roundId: bigint;
  answer: bigint;
  updatedAt: bigint;
  price: string; // human-readable, e.g. "2987.45"
  ageSeconds: number;
}

export async function readFeed(client: PublicClient, cfg: FeedConfig): Promise<FeedReading> {
  // Three reads in parallel. (A multicall would make it one RPC request.)
  const [description, decimals, round] = await Promise.all([
    client.readContract({ address: cfg.address, abi: aggregatorV3Abi, functionName: "description" }),
    client.readContract({ address: cfg.address, abi: aggregatorV3Abi, functionName: "decimals" }),
    client.readContract({ address: cfg.address, abi: aggregatorV3Abi, functionName: "latestRoundData" }),
  ]);

  // Safety net against a wrong address in config.ts.
  if (description !== cfg.expectedDescription) {
    throw new Error(
      `${cfg.symbol}: feed ${cfg.address} describes itself as "${description}", expected "${cfg.expectedDescription}"`,
    );
  }

  const [roundId, answer, , updatedAt] = round;
  if (answer <= 0n) throw new Error(`${cfg.symbol}: non-positive answer ${answer}`);

  return {
    symbol: cfg.symbol,
    feed: cfg.address,
    description,
    decimals,
    roundId,
    answer,
    updatedAt,
    price: formatUnits(answer, decimals),
    ageSeconds: Math.floor(Date.now() / 1000) - Number(updatedAt),
  };
}

export interface SequencerStatus {
  up: boolean;
  sinceSeconds: number; // how long the current status has lasted
  inGracePeriod: boolean; // up, but not long enough to trust prices yet
}

export async function readSequencer(
  client: PublicClient,
  feed: Address,
  gracePeriodSeconds: number,
): Promise<SequencerStatus> {
  const [, answer, startedAt] = await client.readContract({
    address: feed,
    abi: aggregatorV3Abi,
    functionName: "latestRoundData",
  });
  const up = answer === 0n;
  const sinceSeconds = Math.floor(Date.now() / 1000) - Number(startedAt);
  return { up, sinceSeconds, inGracePeriod: up && sinceSeconds < gracePeriodSeconds };
}
