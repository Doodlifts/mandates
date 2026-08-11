// Hand-trimmed ABIs for the CLI. Regenerate from `forge build` artifacts
// (out/MandateBook.sol/MandateBook.json) when the contracts change.

export const mandateBookAbi = [
  {
    type: "function",
    name: "deposit",
    stateMutability: "nonpayable",
    inputs: [
      { name: "currency", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "withdraw",
    stateMutability: "nonpayable",
    inputs: [
      { name: "currency", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "createMandate",
    stateMutability: "nonpayable",
    inputs: [
      {
        name: "key",
        type: "tuple",
        components: [
          { name: "currency0", type: "address" },
          { name: "currency1", type: "address" },
          { name: "fee", type: "uint24" },
          { name: "tickSpacing", type: "int24" },
          { name: "hooks", type: "address" },
        ],
      },
      { name: "executor", type: "address" },
      { name: "budgetPerEpoch", type: "uint128" },
      { name: "epochLength", type: "uint32" },
      { name: "start", type: "uint40" },
      { name: "expiry", type: "uint40" },
      { name: "direction", type: "uint8" },
    ],
    outputs: [{ name: "mandateId", type: "uint256" }],
  },
  {
    type: "function",
    name: "revoke",
    stateMutability: "nonpayable",
    inputs: [{ name: "mandateId", type: "uint256" }],
    outputs: [],
  },
  {
    type: "function",
    name: "execute",
    stateMutability: "nonpayable",
    inputs: [
      { name: "mandateId", type: "uint256" },
      { name: "zeroForOne", type: "bool" },
      { name: "amountIn", type: "uint256" },
      { name: "minAmountOut", type: "uint256" },
    ],
    outputs: [{ name: "amountOut", type: "uint256" }],
  },
  {
    type: "function",
    name: "policies",
    stateMutability: "view",
    inputs: [{ name: "mandateId", type: "uint256" }],
    outputs: [
      { name: "owner", type: "address" },
      { name: "poolId", type: "bytes32" },
      { name: "budgetPerEpoch", type: "uint128" },
      { name: "epochLength", type: "uint32" },
      { name: "start", type: "uint40" },
      { name: "expiry", type: "uint40" },
      { name: "direction", type: "uint8" },
      { name: "revoked", type: "bool" },
    ],
  },
  {
    type: "function",
    name: "remainingBudget",
    stateMutability: "view",
    inputs: [{ name: "mandateId", type: "uint256" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "currentEpoch",
    stateMutability: "view",
    inputs: [{ name: "mandateId", type: "uint256" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function",
    name: "vaultBalance",
    stateMutability: "view",
    inputs: [
      { name: "owner", type: "address" },
      { name: "currency", type: "address" },
    ],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "event",
    name: "MandateExecuted",
    inputs: [
      { name: "mandateId", type: "uint256", indexed: true },
      { name: "executor", type: "address", indexed: true },
      { name: "zeroForOne", type: "bool", indexed: false },
      { name: "amountIn", type: "uint256", indexed: false },
      { name: "amountOut", type: "uint256", indexed: false },
    ],
  },
] as const;

export const erc20Abi = [
  {
    type: "function",
    name: "approve",
    stateMutability: "nonpayable",
    inputs: [
      { name: "spender", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    type: "function",
    name: "decimals",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint8" }],
  },
] as const;
