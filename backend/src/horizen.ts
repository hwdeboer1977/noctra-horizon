import {
  createPublicClient,
  createWalletClient,
  defineChain,
  encodeAbiParameters,
  http,
  keccak256,
  type Address,
  type Hex,
  type PublicClient,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

/** Horizen chains (OP Stack L3 on Base). Gas is paid in ETH. */
export const horizenTestnet = defineChain({
  id: 2651420,
  name: "Horizen Testnet",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["https://horizen-testnet.rpc.caldera.xyz/http"] } },
  testnet: true,
});

export const horizenMainnet = defineChain({
  id: 26514,
  name: "Horizen",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["https://horizen.calderachain.xyz/http"] } },
});

/** Only the RelayedPriceOracle functions the relayer uses. */
export const relayedOracleAbi = [
  {
    type: "function",
    name: "submit",
    stateMutability: "nonpayable",
    inputs: [
      { name: "asset", type: "address" },
      { name: "roundId", type: "uint80" },
      { name: "answer", type: "int256" },
      { name: "updatedAt", type: "uint64" },
    ],
    outputs: [{ name: "accepted", type: "bool" }],
  },
  {
    type: "function",
    name: "latest",
    stateMutability: "view",
    inputs: [{ name: "asset", type: "address" }],
    outputs: [
      { name: "price", type: "uint256" },
      { name: "roundId", type: "uint80" },
      { name: "updatedAt", type: "uint64" },
    ],
  },
  {
    type: "function",
    name: "pending",
    stateMutability: "view",
    inputs: [{ name: "asset", type: "address" }],
    outputs: [
      { name: "price", type: "uint256" },
      { name: "roundId", type: "uint80" },
      { name: "updatedAt", type: "uint64" },
    ],
  },
  { type: "function", name: "tripped", stateMutability: "view", inputs: [{ name: "asset", type: "address" }], outputs: [{ type: "bool" }] },
  { type: "function", name: "epoch", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "isRelayer", stateMutability: "view", inputs: [{ name: "r", type: "address" }], outputs: [{ type: "bool" }] },
  {
    type: "function",
    name: "hasVoted",
    stateMutability: "view",
    inputs: [
      { name: "key", type: "bytes32" },
      { name: "relayer", type: "address" },
    ],
    outputs: [{ type: "bool" }],
  },
] as const;

export function pickChain(name: string) {
  if (name === "testnet") return horizenTestnet;
  if (name === "mainnet") return horizenMainnet;
  throw new Error(`HORIZEN_NETWORK must be "testnet" or "mainnet", got "${name}"`);
}

export function makeHorizenClients(network: string, rpcUrl: string | undefined, privateKey?: Hex) {
  const chain = pickChain(network);
  const transport = http(rpcUrl ?? chain.rpcUrls.default.http[0], { retryCount: 3, retryDelay: 1000 });
  const publicClient = createPublicClient({ chain, transport }) as PublicClient;
  const account = privateKey ? privateKeyToAccount(privateKey) : undefined;
  const walletClient = account ? createWalletClient({ chain, transport, account }) : undefined;
  return { chain, publicClient, walletClient, account };
}

/**
 * Same vote key as the contract:
 *   keccak256(abi.encode(epoch, asset, roundId, answer, updatedAt))
 * Lets the relayer check hasVoted() before sending, so a restart never
 * wastes gas on an AlreadyVoted revert.
 */
export function voteKey(epoch: bigint, asset: Address, roundId: bigint, answer: bigint, updatedAt: bigint): Hex {
  return keccak256(
    encodeAbiParameters(
      [{ type: "uint256" }, { type: "address" }, { type: "uint80" }, { type: "int256" }, { type: "uint64" }],
      [epoch, asset, roundId, answer, updatedAt],
    ),
  );
}
