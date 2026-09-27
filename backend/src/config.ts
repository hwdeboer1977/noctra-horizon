import type { Address } from "viem";

/**
 * Chainlink feeds on BASE MAINNET.
 * Verify every address at https://docs.chain.link/data-feeds/price-feeds/addresses
 * (network: Base). As a runtime safety net, readFeed() checks that the on-chain
 * description() matches `expectedDescription` and refuses to use the feed otherwise.
 */
export interface FeedConfig {
  symbol: string; // our own label
  address: Address; // Chainlink proxy on Base
  expectedDescription: string; // what description() must return
}

export const FEEDS: FeedConfig[] = [
  {
    symbol: "ETH",
    address: "0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70",
    expectedDescription: "ETH / USD",
  },
  {
    symbol: "USDC",
    address: "0x7e860098F58bBFC8648a4311b374B1D669a2bc6B",
    expectedDescription: "USDC / USD",
  },
];

/**
 * Base L2 sequencer uptime feed. answer 0 = sequencer up, 1 = down.
 * Verify at https://docs.chain.link/data-feeds/l2-sequencer-feeds (network: Base).
 */
export const SEQUENCER_UPTIME_FEED: Address = "0xBCF85224fc0756B9Fa45aA7892530B47e10b6433";

/** After the sequencer comes back up, wait this long before trusting prices again. */
export const SEQUENCER_GRACE_PERIOD_SECONDS = 3600;
