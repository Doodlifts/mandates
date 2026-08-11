# Verifying Mandates yourself

Everything below is reproducible on a laptop in about ten minutes. No
funds, no API keys, no trust required — that's rather the point.

## Prerequisites

- [Foundry](https://getfoundry.sh) (`anvil`, `forge`, `cast`)
- Node 18+ (only for the CLI / MCP server, optional)

## 1. Clone and run the test suite (~2 min)

```bash
git clone --recurse-submodules https://github.com/Doodlifts/mandates
cd mandates
forge test
```

Expected: **48 tests, 0 failures** across five suites. The ones worth
reading first are the compromised-executor scenarios in
[`test/Mandates.t.sol`](test/Mandates.t.sol) — every `test_RevertWhen_*`
is a thing a hostile or buggy agent might try, rejected on-chain:

| Test | What it proves |
|---|---|
| `RevertWhen_BudgetExceeded` / `SingleSwapOverBudget` | per-epoch spend cap holds |
| `RevertWhen_WrongDirection` | sell-only mandates can't buy |
| `RevertWhen_Revoked` / `Expired` | the kill switch and the clock win |
| `RevertWhen_NotCapabilityHolder` | no token, no trade |
| `RevertWhen_ForgedHookDataViaExternalRouter` | can't route around the rules |
| `RevertWhen_ExecutorTriesToWithdraw` | custody never moves |
| `CapabilityTransferDelegates` | the ERC-6909 token *is* the permission |

[`test/MandateGuardHook.t.sol`](test/MandateGuardHook.t.sol) adds the
composed layer: a budget-legal trade whose price impact would break the
oracle band **unwinds entirely** (`MandateExecutionBlockedByPostCondition`).

## 2. Watch the whole lifecycle live (~1 min)

```bash
./demo.sh
```

Spins up anvil, deploys everything (including CREATE2-mined hook
addresses), then plays out: Alice funds a vault and issues Bob a
sell-only 100/day mandate → Bob trades inside it → Bob over-spends
(rejected: `BudgetExceeded`) → Bob buys back (rejected:
`DirectionForbidden`) → Mallory tries without the capability (rejected:
`NotCapabilityHolder`) → Alice revokes → Bob is dead (`Revoked`) → Alice
withdraws everything. Each rejection is matched against the actual
custom-error selector, not just "it failed".

## 3. Point an AI agent at it (optional)

[`mcp/`](mcp/README.md) is an MCP server exposing
`mandate_status` / `mandate_execute` / `executor_info` / `vault_balance`.
Wire it into Claude Code with the executor key from the demo and let the
model try to misbehave — the envelope holds regardless of what it does.

## What to scrutinize (please do)

- `MandateBook.execute` + `unlockCallback` settlement math (partial fills
  refund unconsumed input — is the accounting airtight?)
- The `sender != address(book)` check in `MandateHook.beforeSwap` — the
  anti-forgery boundary
- Epoch arithmetic in `enforceAndDebit` (budget reset boundaries)
- `Guarded._deviationBps` — sqrt-price-space bps, oracle assumptions
- ChronoHook's `tx.origin` bounty routing (known tradeoff, documented)

## Known limitations (we'll say it before you find it)

Unaudited prototype. No protocol fee switch yet. GuardHook needs a TWAP
fallback for oracle-less pairs. ChronoHook bounties pay `tx.origin`.
Production bytecode profile (via-ir) not yet enabled. Do not use with
real funds.
