# mandates-mcp

An MCP server that lets any MCP-capable AI agent (Claude Code, Claude
Desktop, or anything speaking the protocol) **hold and execute Uniswap v4
mandates** — scoped, revocable, on-chain trading permissions.

The design premise: **the agent is untrusted.** Every tool can be called
recklessly and the envelope still holds, because budget, direction, pool,
expiry, and revocation are enforced by the pool's hook — not by this
server, and not by the model's judgment.

## Tools

| Tool | What it does |
|---|---|
| `mandate_status` | Policy + live budget + whether this agent holds the capability |
| `mandate_execute` | One swap inside the envelope (simulates first; policy violations surface as named errors) |
| `executor_info` | The agent's executor address, gas balance, configured book |
| `vault_balance` | The owner's in-book balance for a token |

## Wiring into Claude Code

```bash
claude mcp add mandates \
  -e MANDATE_RPC_URL=https://... \
  -e MANDATE_BOOK=0xYourMandateBook \
  -e MANDATE_PRIVATE_KEY=0xExecutorKey \
  -e MANDATE_CHAIN_ID=1 \
  -- npx tsx /path/to/mandates/mcp/src/index.ts
```

Or in `mcpServers` config:

```json
{
  "mcpServers": {
    "mandates": {
      "command": "npx",
      "args": ["tsx", "/path/to/mandates/mcp/src/index.ts"],
      "env": {
        "MANDATE_RPC_URL": "https://...",
        "MANDATE_BOOK": "0x...",
        "MANDATE_PRIVATE_KEY": "0x...",
        "MANDATE_CHAIN_ID": "1"
      }
    }
  }
}
```

## Key handling

`MANDATE_PRIVATE_KEY` is the **executor** key — the wallet that holds the
6909 capability token. It is deliberately NOT the owner's key: the worst a
leaked executor key can do is trade inside the mandate until the owner
revokes. It still needs ETH for gas, and it should be a dedicated key used
for nothing else.

## Suggested agent prompt fragment

> You hold mandate #N via the `mandates` tools. Check `mandate_status`
> before trading. A revert naming BudgetExceeded, DirectionForbidden,
> Revoked, or Expired means you attempted something outside your mandate —
> that boundary is enforced on-chain and retrying will not change it.
