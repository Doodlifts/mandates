#!/usr/bin/env node
// mandate — CLI for capability-scoped delegated trading on Uniswap v4.
//
// Two audiences share this tool:
//   OWNERS  create/fund/revoke mandates:   deposit, create, revoke, status
//   EXECUTORS act inside the envelope:      exec, run (the agent loop)
//
// Config via env: MANDATE_RPC_URL, MANDATE_BOOK, MANDATE_PRIVATE_KEY
// (the key is the wallet acting — owner or executor depending on command).

import { Command } from "commander";
import {
  createPublicClient,
  createWalletClient,
  http,
  parseUnits,
  formatUnits,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { mainnet } from "viem/chains";
import { mandateBookAbi, erc20Abi } from "./abi.js";

const DIRECTIONS = ["both", "sell0", "sell1"] as const;

function env(name: string): string {
  const v = process.env[name];
  if (!v) {
    console.error(`Missing env var ${name}`);
    process.exit(1);
  }
  return v;
}

function clients() {
  const rpc = env("MANDATE_RPC_URL");
  const book = env("MANDATE_BOOK") as Address;
  const account = privateKeyToAccount(env("MANDATE_PRIVATE_KEY") as Hex);
  const publicClient = createPublicClient({ chain: mainnet, transport: http(rpc) });
  const walletClient = createWalletClient({ chain: mainnet, transport: http(rpc), account });
  return { publicClient, walletClient, book, account };
}

const program = new Command()
  .name("mandate")
  .description("Capability-scoped delegated trading on Uniswap v4")
  .version("0.1.0");

// ---------------------------------------------------------------- owner side

program
  .command("deposit")
  .description("Fund your vault balance (approve + deposit)")
  .requiredOption("--token <address>", "ERC-20 to deposit")
  .requiredOption("--amount <amount>", "human units, e.g. 1000")
  .action(async (opts) => {
    const { publicClient, walletClient, book } = clients();
    const token = opts.token as Address;
    const decimals = await publicClient.readContract({
      address: token, abi: erc20Abi, functionName: "decimals",
    });
    const amount = parseUnits(opts.amount, decimals);

    let hash = await walletClient.writeContract({
      address: token, abi: erc20Abi, functionName: "approve", args: [book, amount],
    });
    await publicClient.waitForTransactionReceipt({ hash });

    hash = await walletClient.writeContract({
      address: book, abi: mandateBookAbi, functionName: "deposit", args: [token, amount],
    });
    await publicClient.waitForTransactionReceipt({ hash });
    console.log(`Deposited ${opts.amount} into the vault. tx: ${hash}`);
  });

program
  .command("create")
  .description("Create a mandate: mint a scoped capability to an executor")
  .requiredOption("--pool <c0,c1,fee,spacing,hook>", "pool key, comma-separated")
  .requiredOption("--executor <address>", "who receives the capability token")
  .requiredOption("--budget <amount>", "spend budget per epoch (raw units)")
  .option("--epoch <seconds>", "budget epoch length", "86400")
  .option("--days <n>", "mandate lifetime in days", "30")
  .option("--direction <dir>", `one of: ${DIRECTIONS.join(", ")}`, "both")
  .action(async (opts) => {
    const { publicClient, walletClient, book } = clients();
    const [c0, c1, fee, spacing, hook] = opts.pool.split(",");
    const direction = DIRECTIONS.indexOf(opts.direction);
    if (direction < 0) throw new Error(`direction must be one of ${DIRECTIONS.join(", ")}`);

    const now = Math.floor(Date.now() / 1000);
    const hash = await walletClient.writeContract({
      address: book,
      abi: mandateBookAbi,
      functionName: "createMandate",
      args: [
        {
          currency0: c0 as Address,
          currency1: c1 as Address,
          fee: Number(fee),
          tickSpacing: Number(spacing),
          hooks: hook as Address,
        },
        opts.executor as Address,
        BigInt(opts.budget),
        Number(opts.epoch),
        now,
        now + Number(opts.days) * 86400,
        direction,
      ],
    });
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    console.log(`Mandate created. tx: ${hash} (block ${receipt.blockNumber})`);
    console.log(`The executor now holds the capability token. Revoke anytime with: mandate revoke <id>`);
  });

program
  .command("revoke <mandateId>")
  .description("Instantly revoke a mandate (owner only)")
  .action(async (mandateId) => {
    const { publicClient, walletClient, book } = clients();
    const hash = await walletClient.writeContract({
      address: book, abi: mandateBookAbi, functionName: "revoke", args: [BigInt(mandateId)],
    });
    await publicClient.waitForTransactionReceipt({ hash });
    console.log(`Mandate ${mandateId} revoked. The capability is dead from this block onward.`);
  });

program
  .command("status <mandateId>")
  .description("Show a mandate's policy, budget, and lifecycle state")
  .action(async (mandateId) => {
    const { publicClient, book } = clients();
    const id = BigInt(mandateId);
    const [policy, remaining, epoch] = await Promise.all([
      publicClient.readContract({ address: book, abi: mandateBookAbi, functionName: "policies", args: [id] }),
      publicClient.readContract({ address: book, abi: mandateBookAbi, functionName: "remainingBudget", args: [id] }),
      publicClient.readContract({ address: book, abi: mandateBookAbi, functionName: "currentEpoch", args: [id] }),
    ]);
    const [owner, poolId, budgetPerEpoch, epochLength, start, expiry, direction, revoked] = policy;
    const state = revoked
      ? "REVOKED"
      : Date.now() / 1000 >= Number(expiry)
        ? "EXPIRED"
        : "ACTIVE";
    console.log({
      state,
      owner,
      poolId,
      direction: DIRECTIONS[Number(direction)],
      budgetPerEpoch: budgetPerEpoch.toString(),
      remainingThisEpoch: remaining.toString(),
      epoch: epoch.toString(),
      epochLength: `${epochLength}s`,
      window: `${new Date(Number(start) * 1000).toISOString()} → ${new Date(Number(expiry) * 1000).toISOString()}`,
    });
  });

// ------------------------------------------------------------- executor side

program
  .command("exec <mandateId>")
  .description("Execute one swap inside the mandate envelope")
  .requiredOption("--amount-in <raw>", "input amount (raw units)")
  .option("--sell1", "sell token1 for token0 (default sells token0)")
  .option("--min-out <raw>", "minimum output", "1")
  .action(async (mandateId, opts) => {
    const { publicClient, walletClient, book } = clients();
    const hash = await walletClient.writeContract({
      address: book,
      abi: mandateBookAbi,
      functionName: "execute",
      args: [BigInt(mandateId), !opts.sell1, BigInt(opts.amountIn), BigInt(opts.minOut)],
    });
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    console.log(`Executed. tx: ${hash} (status: ${receipt.status})`);
  });

program
  .command("run <mandateId>")
  .description("Simple DCA executor loop: spend the budget in slices each epoch")
  .option("--slice <raw>", "amount per execution (raw units)", "0")
  .option("--interval <seconds>", "seconds between attempts", "3600")
  .action(async (mandateId, opts) => {
    const { publicClient, walletClient, book } = clients();
    const id = BigInt(mandateId);
    console.log(`Executor loop for mandate ${mandateId} — ctrl-c to stop.`);
    // The loop is intentionally dumb: the CONTRACT enforces the envelope.
    // A crashed, buggy, or malicious version of this loop can never exceed
    // the budget, trade the wrong direction, or act after revocation.
    for (;;) {
      try {
        const remaining = await publicClient.readContract({
          address: book, abi: mandateBookAbi, functionName: "remainingBudget", args: [id],
        });
        const slice = opts.slice === "0" ? remaining : BigInt(opts.slice);
        const amount = remaining < slice ? remaining : slice;
        if (amount > 0n) {
          const hash = await walletClient.writeContract({
            address: book, abi: mandateBookAbi, functionName: "execute", args: [id, true, amount, 1n],
          });
          console.log(`[${new Date().toISOString()}] executed ${amount} — ${hash}`);
        } else {
          console.log(`[${new Date().toISOString()}] budget exhausted this epoch; waiting`);
        }
      } catch (err) {
        console.error(`[${new Date().toISOString()}] ${(err as Error).message.split("\n")[0]}`);
      }
      await new Promise((r) => setTimeout(r, Number(opts.interval) * 1000));
    }
  });

program.parseAsync();
