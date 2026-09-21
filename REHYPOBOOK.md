# RehypoBook — design doc (pre-code, adversarial-first)

Status: **design only. No code implements this yet.** This doc exists to be
attacked before anything is built. If you're reviewing this repo: the most
useful thing you can do is break the invariants in §7 on paper.

## 0. One paragraph

Today, MandateBook vault balances idle. RehypoBook makes one pot of money do
several jobs at once: earn lending yield while it waits, back any number of
standing claims (mandates, subscriptions, third-party protocols), and
materialize **just-in-time** — atomically, inside the transaction that needs
it. This is rehypothecation rebuilt on the EVM's one honest guarantee:
claims may overlap freely, but *exercise* is sequential, and any exercise
that would leave the pot short reverts. TradFi rehypothecation fails in
court, years later; this fails at the end of the transaction, instantly,
with a named error.

## 1. Claim inventory

Everything below is a claim on the same per-owner, per-currency pot:

| Tier | Claim | Holder | Exercise path | Blocked by illiquidity? |
|---|---|---|---|---|
| **S0** | Principal withdrawal | Owner | cash → divest → **in-kind shares** | **Never** (in-kind fallback) |
| **S1** | Envelope pulls (mandates, generalized claims) | Capability holders | cash → divest | Yes — reverts, retry later |
| **S2** | Protocol fee / yield skim | Protocol | harvested yield only | Yes, and never touches principal |

Seniority is not a liquidation waterfall (there's no leverage here); it is a
**liveness waterfall**: who can always exit, who can be temporarily refused,
and who only ever eats from realized yield.

The load-bearing S0 rule: the owner can always exit **in-kind** — take their
pro-rata strategy shares directly and walk. In-kind redemption is a pure
internal transfer; no external call can block it. This single rule deletes
the bank-run problem for principal: a run on cash degrades into "everyone
holds their own Aave shares now," not "last one out gets nothing."

## 2. Architecture

```
                 ┌────────────────────────────────────────┐
                 │              RehypoBook                │
  deposit ───▶   │  cash buffer (per currency)            │ ──▶ ERC-4626
  withdraw ◀───  │  internal shares (per owner, currency) │ ◀── strategy
                 │  claim registry (6909 + envelopes)     │     (allowlisted)
                 └───────────────┬────────────────────────┘
                                 │ pullFor(claimId, amt): JIT materialize
                                 ▼
                  mandate execute / subscription / 3rd-party protocol
                                 │
                                 ▼
                     PoolManager.unlock → swap → settle
```

### 2.1 Internal share accounting

When funds are deployed, the book holds strategy shares; owners hold
**internal shares** per currency (per-owner claim on `buffer +
strategyAssets`). Yield accrues by share appreciation — no harvest events,
no distribution loop, nothing to sandwich. Internal shares use a virtual-
offset (dead shares) scheme against the classic 4626 inflation/donation
attack at our layer.

**Opt-in earn.** Per owner, per currency, `earnMode` is a toggle, default
OFF. Off = pure cash claim, zero strategy exposure, exactly today's
MandateBook semantics. On = the owner's balance joins the deployed pot and
takes pro-rata strategy risk. This is the consent line TradFi
rehypothecation erased, and it's per-claim-holder, not per-protocol.
Non-earn balances NEVER route through a strategy — they are a segregated
cash liability, senior to everything by construction.

### 2.2 Buffer policy

Per currency: `bufferTarget` (e.g. 10% of earn-mode assets). Deposits fill
the buffer first, overflow deploys. JIT pulls drain buffer first, then
divest the shortfall in the same transaction. Refill is lazy (on deposit)
plus an optional ChronoHook job (the scheduler rebalancing the vault that
funds it — the composition pays for itself).

### 2.3 JIT materialization

`execute()` (and any claim pull) becomes:

1. need = amountIn; take min(need, buffer) from cash
2. shortfall → `strategy.withdraw(shortfall)` — **before** `unlock`, never
   inside the v4 callback (§6.5)
3. proceed exactly as today: unlock → swap with hookData → settle → credit
   output to owner

If step 2 reverts (utilization, pause, strategy exploit-freeze): the whole
transaction reverts with `LivenessFault`. Fail-closed. A mandate that can't
materialize simply doesn't trade this block. Only S0 has the in-kind escape.

### 2.4 Generalized claims (the multi-protocol part)

Mandates generalize. A **Claim** is: an ERC-6909 capability token + an
envelope `{budgetPerEpoch, epochLength, expiry, purpose, tier}` + a
`puller` (the contract allowed to call `pullFor`). A mandate is then just a
claim whose purpose is "swap on pool P via the book." Other purposes:
subscription streaming, an insurance backstop, collateral top-ups for a
lending position, ChronoHook bounty escrow.

**Envelopes may oversubscribe the balance.** Σ(envelopes) > balance is
allowed — that is the feature, not a bug. The same 1,000 USDC can
simultaneously back a 500/day mandate, a 100/month subscription, and a
1,000 one-shot insurance claim. The invariants that make this sane:

- per-exercise solvency (a pull that exceeds the live balance reverts),
- per-claim velocity bounds (epoch budgets — a "run" can move at most
  Σ(epoch budgets) per epoch, a number the owner chose),
- universal revocation (one call kills any claim, always senior to pulls),
- explicit tiering (S0 can always leave; juniors race first-come-first-served
  and losers revert — publicly, deterministically).

## 3. Loss model

If a strategy takes a loss (bad debt, exploit, negative rebase): losses
socialize **pro-rata across earn-mode share-holders in that currency**, by
marking internal shares to the strategy's redemption price. Not
first-withdrawer-wins. Non-earn cash balances are untouched — they were
never in the pot. Future option (v3+): a junior yield tranche that takes
first loss in exchange for a yield multiple — at that point this becomes
honest on-chain credit structuring, priced instead of hidden.

## 4. Strategy admission rules

1. Allowlisted, per currency, with a **hard allocation cap** (launch: one
   strategy, ≤50% of earn-mode assets deployed; the rest is buffer).
2. **Cash-equivalent redemption only**: the strategy must redeem in the
   same asset without trading (Aave/Morpho supply positions: yes;
   LP-token vaults: no). A strategy that must *sell* to redeem can move the
   very pool a mandate is about to trade, mid-transaction (§6.9).
3. `previewRedeem` treated as an estimate, never as truth; solvency checks
   use actual received amounts (measure balances before/after).

## 5. What stays out of scope, permanently

**The atomic boundary is a wall.** Every safety claim in this doc lives
inside one transaction on one chain. No cross-chain claims on the pot, no
optimistic/async settlement, no "unified liquidity" bridges. The moment a
claim settles asynchronously you have real rehypothecation with real
Lehman dynamics, and none of this document's arguments apply.

## 6. Adversarial catalog (attack → design answer)

1. **Liveness cascade** — strategy at 100% utilization freezes all JIT pulls
   at once. → buffer target absorbs routine flow; allocation cap bounds the
   frozen fraction; S0 exits in-kind; S1 degrades to retry-later, envelopes
   unaffected.
2. **Malicious/compromised 4626** — misreported `totalAssets` (inflated:
   early exiters drain; deflated: deposit arbitrage), withdrawal fees,
   reentrancy from `withdraw`. → allowlist + cap; balance-delta accounting
   (never trust preview/return values); reentrancy guard around all
   strategy calls; loss socialization via mark-to-redemption removes the
   early-exit subsidy.
3. **Share inflation (donation) attack** on our internal shares. → virtual
   shares/asset offset, first-depositor dead shares.
4. **Harvest sandwich** — deposit before yield lands, exit after. → no
   harvest events exist; value accrues continuously via share price.
5. **v4 unlock interference** — divesting inside `unlockCallback` nests
   external calls (some tokens/strategies reenter) into flash accounting. →
   hard rule + test: strategy calls happen strictly before `unlock`;
   invariant I7.
6. **Pull-race griefing** — a junior claim races to drain the balance and
   starve mandates. → that's owner-chosen oversubscription; velocity bounds
   cap damage per epoch; revocation is instant; racing is visible on-chain
   (a griefing claim gets revoked and reputationally torched in the
   executor directory).
7. **Reentrancy via token hooks** during materialize→settle. → CEI +
   guards; the book already debits before external calls today; keep that
   discipline through the new path.
8. **Buffer arbitrage** — deposit/withdraw cycling to force divest churn and
   grief gas / extract via strategy entry-exit spreads. → same-block
   deposit→withdraw for earn-mode goes through the same share pricing (no
   spread to capture); optional small divest cooldown per owner if needed.
9. **Strategy-moves-the-pool** — an LP-based strategy redeems by selling
   into the pool a guard is watching, tripping (or gaming) the deviation
   band mid-tx. → admission rule 4.2 (cash-equivalent redemption only)
   makes this unrepresentable.
10. **Envelope-sum panic** — observers see Σ envelopes ≫ balance and call it
    insolvency. → it isn't; publish the distinction loudly (envelopes are
    authorization ceilings, not liabilities; liabilities are share
    balances, and those are always ≤ assets by I3).

## 7. Invariants (the future test suite, in prose)

- **I1** Per owner+currency: `claimable = cash (non-earn) + shares ×
  redemptionPrice (earn)`; no other path to value.
- **I2** Σ internal shares (per currency) maps 1:1 onto book-held strategy
  shares + earn-mode buffer; no orphan or phantom shares.
- **I3** After every transaction: `buffer + strategyAssets ≥ Σ earn-mode
  liabilities` at mark-to-redemption (losses recognized, never hidden).
- **I4** S0 in-kind exit is executable with zero external calls — nothing a
  strategy or token does can block it.
- **I5** Per claim, per epoch: Σ pulls ≤ envelope budget; debits monotonic;
  revocation is effective from the next exercise, unconditionally.
- **I6** No path changes share balances without a matching, measured asset
  movement — except explicit loss recognition, which only decreases
  redemption price.
- **I7** No strategy external call occurs inside a PoolManager unlock.
- **I8** Non-earn balances are bit-for-bit unaffected by any strategy event,
  including total strategy loss.

## 8. Phasing

| Phase | Ships | New attack surface admitted |
|---|---|---|
| **v0** | Buffer-only refactor: pull path + claim registry, no strategy | Claim registry logic only |
| **v1** | One allowlisted 4626 (Morpho/Aave), opt-in earn, in-kind exit | §6.1–6.5 |
| **v2** | Generalized claims: third-party pullers, purposes beyond swaps | §6.6, §6.10 |
| **v3** | Multi-strategy allocation; optional junior yield tranche | Allocation logic; tranche pricing |

Each phase is independently shippable and independently auditable. v0
changes today's semantics not at all (every balance is a cash balance);
it exists so the pull path and registry get audited before any yield
exists to steal.

## 9. Open questions (genuinely open — argue with these)

1. Loss socialization vs. first-loss tranche from day one? (Socialization
   is simpler; the tranche is more honest price discovery but is a whole
   product.)
2. Who curates the strategy allowlist — protocol governance, or does each
   owner opt into strategies individually (maximal consent, maximal
   gas/complexity)?
3. Should S1 claims get an optional "in-kind" mode too (a mandate that
   accepts aTokens)? It weakens the S0/S1 distinction but improves
   liveness for sophisticated executors.
4. Does the protocol fee (S2) live here or stay in the (still zero-set)
   swap-path fee switch? Two switches invite double-charging accusations.
5. Buffer target as governance parameter vs. per-owner preference —
   per-owner buffers fragment the gas savings that motivated pooling.

## 10. Lineage note

Flow/Cadence forbids money existing in two places (linear resources) but
happily issues many *capabilities* against one vault — overlapping claims,
one pot, first-exerciser-wins. The EVM arrives at the same place from the
opposite direction: money is ledger entries, so overlap is native, and the
discipline comes from the settlement invariant. RehypoBook is that
symmetry, written down: **claims may overlap; exercise may not.**
