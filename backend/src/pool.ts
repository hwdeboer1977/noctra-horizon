/**
 * Minimal LendingPool + ERC20 ABIs: only what the liquidator uses.
 * (Kept by hand for readability. Alternative: import from forge's out/LendingPool.sol/LendingPool.json.)
 */

export const lendingPoolAbi = [
  {
    type: "event",
    name: "Borrowed",
    inputs: [
      { name: "asset", type: "address", indexed: true },
      { name: "user", type: "address", indexed: true },
      { name: "amount", type: "uint256", indexed: false },
    ],
  },
  { type: "function", name: "oracle", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "assetCount", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  {
    type: "function",
    name: "assetList",
    stateMutability: "view",
    inputs: [{ name: "i", type: "uint256" }],
    outputs: [{ type: "address" }],
  },
  {
    type: "function",
    name: "assetConfig",
    stateMutability: "view",
    inputs: [{ name: "asset", type: "address" }],
    outputs: [
      { name: "supported", type: "bool" },
      { name: "borrowEnabled", type: "bool" },
      { name: "ltvBps", type: "uint16" },
      { name: "liqThresholdBps", type: "uint16" },
      { name: "liqBonusBps", type: "uint16" },
      { name: "decimals", type: "uint8" },
    ],
  },
  {
    type: "function",
    name: "getAccountData",
    stateMutability: "view",
    inputs: [{ name: "user", type: "address" }],
    outputs: [
      {
        type: "tuple",
        components: [
          { name: "collateralValue", type: "uint256" },
          { name: "borrowPower", type: "uint256" },
          { name: "liquidationCollateral", type: "uint256" },
          { name: "debtValue", type: "uint256" },
          { name: "healthFactor", type: "uint256" },
        ],
      },
    ],
  },
  {
    type: "function",
    name: "supplyBalanceOf",
    stateMutability: "view",
    inputs: [
      { name: "asset", type: "address" },
      { name: "user", type: "address" },
    ],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "debtBalanceOf",
    stateMutability: "view",
    inputs: [
      { name: "asset", type: "address" },
      { name: "user", type: "address" },
    ],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "liquidate",
    stateMutability: "nonpayable",
    inputs: [
      { name: "collateralAsset", type: "address" },
      { name: "debtAsset", type: "address" },
      { name: "user", type: "address" },
      { name: "debtToCover", type: "uint256" },
      { name: "receiveUnderlying", type: "bool" },
    ],
    outputs: [
      { name: "debtCovered", type: "uint256" },
      { name: "collateralSeized", type: "uint256" },
    ],
  },
  // Custom errors so simulation failures are readable
  { type: "error", name: "PositionHealthy", inputs: [{ name: "healthFactor", type: "uint256" }] },
  { type: "error", name: "NoDebt", inputs: [{ name: "asset", type: "address" }] },
  {
    type: "error",
    name: "InsufficientLiquidity",
    inputs: [
      { name: "available", type: "uint256" },
      { name: "requested", type: "uint256" },
    ],
  },
  { type: "error", name: "ZeroAmount", inputs: [] },
] as const;

export const oracleAbi = [
  {
    type: "function",
    name: "getPrice",
    stateMutability: "view",
    inputs: [{ name: "asset", type: "address" }],
    outputs: [{ type: "uint256" }],
  },
] as const;

export const erc20Abi = [
  {
    type: "function",
    name: "balanceOf",
    stateMutability: "view",
    inputs: [{ name: "a", type: "address" }],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "allowance",
    stateMutability: "view",
    inputs: [
      { name: "o", type: "address" },
      { name: "s", type: "address" },
    ],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "approve",
    stateMutability: "nonpayable",
    inputs: [
      { name: "s", type: "address" },
      { name: "v", type: "uint256" },
    ],
    outputs: [{ type: "bool" }],
  },
  { type: "function", name: "symbol", stateMutability: "view", inputs: [], outputs: [{ type: "string" }] },
] as const;
