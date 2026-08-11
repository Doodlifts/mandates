# Mandates

**Hire anyone — or any AI — to trade your money, without trusting them.**

A mandate is what asset managers call scoped authority: *you may trade this
much, of this, here, until then*. This repo puts that on Ethereum mainnet
using Uniswap v4 hooks: the owner keeps custody, the executor holds a
revocable capability token, and **the pool itself enforces the policy** —
not the executor's software.

Design lineage: Flow/Cadence put authority in *objects* (capabilities +
entitlements on a Vault) rather than in actors. The EVM translation is
venue-side enforcement: even a fully compromised executor key can do nothing
outside the mandate, because `beforeSwap` rejects everything else.

## Contracts

| Contract | Role | Cadence ancestor |
|---|---|---|
| [`MandateBook`](src/MandateBook.sol) | Custody vault + ERC-6909 capability tokens + policy state + execution router | Resources & capabilities on a Vault |
| [`MandateHook`](src/MandateHook.sol) | Venue-side enforcement: re-validates and debits every mandate swap inside `beforeSwap` | Entitlement checks at the object |
| [`GuardHook`](src/GuardHook.sol) | Declarative pre/post conditions per pool: oracle deviation band + circuit breaker, fail-closed | `pre { } post { }` transaction blocks |
| [`MandateGuardHook`](src/MandateGuardHook.sol) | **The canonical production hook**: mandates + guards composed on one address (v4 allows one hook per pool) | Capabilities *and* pre/post blocks together |
| [`ChronoHook`](src/ChronoHook.sol) | Swap traffic as a clock: bounty-funded job ring swept in `afterSwap`, permissionless `poke()` fallback | Scheduled Transactions |
| [`ChainlinkSqrtPriceOracle`](src/oracle/ChainlinkSqrtPriceOracle.sol) | AggregatorV3 feeds → `sqrtPriceX96` reference prices for guards (decimals/invert/staleness handled) | — |

Shared guard logic lives in [`base/Guarded.sol`](src/base/Guarded.sol);
composition is by inheritance because a pool gets exactly one hook.

### The mandate envelope

```
createMandate(pool, executor, budgetPerEpoch, epochLength, start, expiry, direction)
```

- **Budget per epoch** — e.g. 100 USDC/day; debited in `beforeSwap`, resets each epoch
- **Direction** — optionally sell-only or buy-only
- **Expiry** — capabilities die on schedule
- **Revoke** — one call by the owner, effective immediately
- **Transferable** — the 6909 token *is* the capability; handing it over
  delegates (sub-agents), revocation always dominates

### Two-layer enforcement

1. **Custody-side** (`MandateBook.execute`): executors can only move vault
   balances through the policy path; owners can always withdraw.
2. **Venue-side** (`MandateHook.beforeSwap` → `enforceAndDebit`): the full
   policy is re-validated *inside the pool's execution path*. Forged mandate
   hookData from third-party routers is rejected at the pool. A v4 subtlety
   makes the split load-bearing: the PoolManager **skips hook callbacks when
   the swap caller is the hook itself** (`Hooks.sol`), so a combined
   vault+hook contract cannot self-enforce — the enforcer and the executor
   of record must be different addresses.

## Tests

33 tests, including the compromised-executor suite: budget overruns,
wrong-direction trades, post-revocation and post-expiry execution, forged
hookData via external routers, non-holder execution, executor withdrawal
attempts — all rejected. GuardHook proves a whole swap unwinds when its
post-condition fails. ChronoHook proves failing jobs never block swaps and
`poke()` keeps liveness without traffic.

```bash
forge test
```

## CLI

```bash
cd cli && npm install
MANDATE_RPC_URL=... MANDATE_BOOK=0x... MANDATE_PRIVATE_KEY=0x... \
  npx tsx src/index.ts status 1
```

Owner: `deposit`, `create`, `revoke`, `status`. Executor: `exec`, `run`
(a deliberately dumb DCA loop — the *contract* enforces the envelope, so a
buggy or malicious loop can't exceed it).

## Deploying

[`script/Deploy.s.sol`](script/Deploy.s.sol) deploys the stack with real
CREATE2 hook mining (vendored [`HookMiner`](script/utils/HookMiner.sol)):

```bash
POOL_MANAGER=0x... forge script script/Deploy.s.sol \
  --rpc-url $RPC --private-key $PK --broadcast
```

Unset `POOL_MANAGER` deploys a fresh PoolManager (dev chains only).
Rehearsed end-to-end against anvil: mined addresses verify their flag bits
(`…40C0` → beforeSwap|afterSwap, `…0040` → afterSwap) and `setHook` wiring
completes. Gas numbers in [GAS.md](GAS.md).

## Status / not yet done

Prototype. Before real funds: audit; ChronoHook `tx.origin` bounty routing
tradeoff; partial-fill accounting review; per-pool TWAP fallback oracle;
production bytecode profile (via-ir); protocol fee switch (see BUSINESS.md).

See [PRODUCT.md](PRODUCT.md) for how people use this (launchpad, CLI,
executor marketplace) and [BUSINESS.md](BUSINESS.md) for the
monetization-vs-public-good analysis.
