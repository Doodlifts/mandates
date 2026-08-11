# How people use Mandates

Three surfaces, one protocol: a **launchpad** (web) for owners, a **CLI/SDK**
for executors and power users, and a **marketplace** that emerges where the
two meet.

## 1. The Mandate Launchpad (web app)

The launchpad is to mandates what app.uniswap.org is to swaps — nobody is
forced to use it, but it's where normal humans live. Core flows:

### "Issue a mandate" wizard
1. **Pick funds** — deposit into your vault (USDC, ETH, whatever the pool pair needs).
2. **Pick a policy from templates**, then tweak:
   - *DCA*: "buy $500 of ETH weekly for 6 months"
   - *Agent allowance*: "my bot may trade ≤1 ETH/day, sells only, 30 days"
   - *Treasury diversification*: "TWAP 500k USDC → ETH over 60 days, price-banded"
   - *Exit ladder*: "sell 10% of my position per week above $X"
3. **Pick an executor**:
   - paste an address (your own agent, a friend),
   - or choose from the **executor directory** (see marketplace below),
   - or "no executor yet" — mint to yourself and transfer later.
4. **Review the envelope in plain English** — "The most this executor can
   ever spend is 100 USDC per day. It cannot buy. It dies on March 1.
   You can revoke at any time. Your funds never leave your vault contract."
   That sentence is the entire product.
5. Sign two transactions (deposit, create). Done.

### The dashboard
- Live mandates with budget bars (spent/remaining this epoch), execution
  history (from `MandateExecuted` events), realized price vs oracle.
- One giant red **REVOKE** button per mandate. It has to feel like a kill
  switch, because it is one.
- Guard status per pool: deviation band, breaker state.
- Chrono jobs: next due time, bounty balance, run history.

### Notifications
"Your DCA executed: 500 USDC → 0.21 ETH", "Mandate #12 expires in 3 days",
"Guard breaker tripped on ETH/USDC" — email/push/telegram. This is where a
hosted product earns its keep.

## 2. The CLI / SDK

Already scaffolded in [`cli/`](cli/). The CLI serves:

- **Executor operators**: `mandate run <id>` is the hello-world agent. Real
  operators replace the loop's brain (when/what to trade) and keep the
  contract as the safety envelope. The pitch to agent developers: *you
  cannot rug your users even if your model goes insane* — which means users
  who would never fund your agent will fund a mandate to it.
- **Power-user owners**: script mandate creation, batch revokes, export
  history.
- **CI for strategies**: because policies are on-chain data, a strategy repo
  can integration-test against a fork with its exact production envelope.

The SDK layer (extract from the CLI) is what the launchpad and third-party
agent frameworks (LangChain tools, Claude MCP servers, ElizaOS plugins)
build on. An **MCP server exposing `mandate.status` / `mandate.exec`** makes
any Claude/GPT agent a mandate executor in an afternoon — that's the
FlowClaw bridge.

## 3. The executor marketplace (the network effect)

Because enforcement is at the venue, executors need **zero trust** — which
means listing them is safe by construction. The directory ranks executors
(strategy operators, agent services) by verifiable on-chain history:
mandates served, volume, realized-price-vs-TWAP, revocation rate (owners
firing you is public!), uptime on chrono jobs.

- New operators bootstrap reputation with small public mandates.
- Owners comparison-shop executors like Morpho curators or validator lists.
- Executor fees are a policy field in v2 (bps of volume, paid from output);
  the protocol takes its cut there.

The marketplace is the moat: contracts are forkable, but a directory of
reputations and a two-sided market of owners and executors is not.

## Adoption sequencing (realistic)

1. **Agent-wallet niche first** — ship the MCP server + CLI, court AI-agent
   devs who have the "how do I let it touch money" problem *today*. Small
   mandates, high novelty tolerance.
2. **DCA/standing orders** as the first normie template on the launchpad
   (works without any third-party executor — chrono jobs or self-execution).
3. **DAO treasury mandates** once audited — this is where size arrives.
4. Executor marketplace last — it needs both sides warm.
