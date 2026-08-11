#!/usr/bin/env node
// mandates-mcp — an MCP server that lets an AI agent hold and execute
// Uniswap v4 mandates.
//
// The design premise: the agent is UNTRUSTED. Every tool here can be called
// with maximum recklessness and the on-chain policy envelope still holds —
// budget, direction, pool, expiry, revocation are enforced by the pool's
// hook, not by this server. Tool descriptions tell the model that, so it
// can reason about failures ("BudgetExceeded" = you hit your allowance,
// not an error to retry).
//
// Env:
//   MANDATE_RPC_URL      — JSON-RPC endpoint
//   MANDATE_BOOK         — MandateBook contract address
//   MANDATE_PRIVATE_KEY  — the EXECUTOR key this agent acts as
//   MANDATE_CHAIN_ID     — optional, defaults to 1 (mainnet)

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import {
  createPublicClient,
  createWalletClient,
  http,
  formatEther,
  defineChain,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { mainnet, sepolia } from "viem/chains";
import { mandateBookAbi } from "./abi.js";

const DIRECTIONS = ["both", "sell-token0-only", "sell-token1-only"] as const;

function env(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`Missing env var ${name}`);
  return v;
}

function chainFor(id: number) {
  if (id === 1) return mainnet;
  if (id === 11155111) return sepolia;
  return defineChain({
    id,
    name: `chain-${id}`,
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [env("MANDATE_RPC_URL")] } },
  });
}

const chain = chainFor(Number(process.env.MANDATE_CHAIN_ID ?? "1"));
const book = env("MANDATE_BOOK") as Address;
const account = privateKeyToAccount(env("MANDATE_PRIVATE_KEY") as Hex);
const publicClient = createPublicClient({ chain, transport: http(env("MANDATE_RPC_URL")) });
const walletClient = createWalletClient({ chain, transport: http(env("MANDATE_RPC_URL")), account });

const server = new McpServer({ name: "mandates", version: "0.1.0" });

function text(data: unknown) {
  return { content: [{ type: "text" as const, text: JSON.stringify(data, null, 2) }] };
}

server.tool(
  "mandate_status",
  "Read a mandate's policy and live budget. A mandate is a scoped, revocable " +
    "permission to trade an owner's funds: per-epoch spend budget, allowed " +
    "direction, one pool, expiry. Check this before executing to see what " +
    "you're allowed to do right now.",
  { mandateId: z.string().describe("The mandate id (uint256 as string)") },
  async ({ mandateId }) => {
    const id = BigInt(mandateId);
    const [policy, remaining, epoch, held] = await Promise.all([
      publicClient.readContract({ address: book, abi: mandateBookAbi, functionName: "policies", args: [id] }),
      publicClient.readContract({ address: book, abi: mandateBookAbi, functionName: "remainingBudget", args: [id] }),
      publicClient.readContract({ address: book, abi: mandateBookAbi, functionName: "currentEpoch", args: [id] }),
      publicClient.readContract({
        address: book,
        abi: [
          {
            type: "function",
            name: "balanceOf",
            stateMutability: "view",
            inputs: [
              { name: "owner", type: "address" },
              { name: "id", type: "uint256" },
            ],
            outputs: [{ name: "", type: "uint256" }],
          },
        ] as const,
        functionName: "balanceOf",
        args: [account.address, id],
      }),
    ]);
    const [owner, poolId, budgetPerEpoch, epochLength, start, expiry, direction, revoked] = policy;
    const now = Math.floor(Date.now() / 1000);
    return text({
      mandateId,
      state: revoked ? "REVOKED" : now >= Number(expiry) ? "EXPIRED" : now < Number(start) ? "NOT_STARTED" : "ACTIVE",
      iHoldThisCapability: held > 0n,
      owner,
      poolId,
      direction: DIRECTIONS[Number(direction)],
      budgetPerEpoch: budgetPerEpoch.toString(),
      remainingThisEpoch: remaining.toString(),
      currentEpoch: epoch.toString(),
      epochLengthSeconds: Number(epochLength),
      startsAt: new Date(Number(start) * 1000).toISOString(),
      expiresAt: new Date(Number(expiry) * 1000).toISOString(),
      note: "remainingThisEpoch is denominated in the token being SOLD.",
    });
  }
);

server.tool(
  "mandate_execute",
  "Execute one swap inside a mandate's envelope, spending the owner's vault " +
    "balance. The contract enforces the policy on-chain: if this reverts with " +
    "BudgetExceeded / DirectionForbidden / Revoked / Expired, you attempted " +
    "something outside your mandate — that is a hard boundary, not a " +
    "transient error; do not retry the same call. amountIn is in RAW token " +
    "units of the token being sold.",
  {
    mandateId: z.string().describe("The mandate id"),
    sellToken0: z.boolean().describe("true = sell token0 for token1; false = the reverse"),
    amountIn: z.string().describe("Raw input amount (wei-style units)"),
    minAmountOut: z.string().default("1").describe("Minimum acceptable output, raw units"),
  },
  async ({ mandateId, sellToken0, amountIn, minAmountOut }) => {
    // Simulate first: surfaces policy violations as readable errors and
    // yields the expected output without spending anything.
    const { result, request } = await publicClient.simulateContract({
      address: book,
      abi: mandateBookAbi,
      functionName: "execute",
      args: [BigInt(mandateId), sellToken0, BigInt(amountIn), BigInt(minAmountOut)],
      account,
    });
    const hash = await walletClient.writeContract(request);
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    return text({
      status: receipt.status,
      txHash: hash,
      amountIn,
      expectedAmountOut: (result as bigint).toString(),
      gasUsed: receipt.gasUsed.toString(),
    });
  }
);

server.tool(
  "executor_info",
  "Who am I on-chain? Returns this agent's executor address, its ETH balance " +
    "(needed for gas), and the configured MandateBook. Capabilities (mandates) " +
    "this address holds are checked per-id via mandate_status.",
  {},
  async () => {
    const balance = await publicClient.getBalance({ address: account.address });
    return text({
      executorAddress: account.address,
      ethBalance: formatEther(balance),
      mandateBook: book,
      chainId: chain.id,
    });
  }
);

server.tool(
  "vault_balance",
  "Read an owner's vault balance inside the MandateBook for a given token. " +
    "Useful to see whether the mandate's owner has funds left to trade.",
  {
    owner: z.string().describe("Owner address"),
    token: z.string().describe("ERC-20 token address"),
  },
  async ({ owner, token }) => {
    const balance = await publicClient.readContract({
      address: book,
      abi: mandateBookAbi,
      functionName: "vaultBalance",
      args: [owner as Address, token as Address],
    });
    return text({ owner, token, rawBalance: balance.toString() });
  }
);

const transport = new StdioServerTransport();
await server.connect(transport);
console.error(`mandates-mcp ready — executor ${account.address}, book ${book}, chain ${chain.id}`);
