# Gas notes (prototype, pre-optimization)

Measured with `forge test --gas-report`, solc 0.8.26, optimizer 200 runs,
no via-ir. Hooks are etched in tests (`deployCodeTo`), so the report
itemizes MandateBook and the oracle; hook overhead shows up inside the
end-to-end numbers below.

## MandateBook (deployment: ~2.05M gas, 9.4KB)

| Function | Avg | Max | Notes |
|---|---|---|---|
| `execute` | 123k | 240k | Full mandate swap: unlock → swap → hook enforcement → settle/take. Max is the first-touch path (cold storage). |
| `createMandate` | 190k | 197k | Policy storage + PoolKey copy + 6909 mint |
| `deposit` | 81k | 81k | ERC-20 pull + balance slot |
| `enforceAndDebit` | 25k | 25k | The venue-side re-validation, per mandate swap |
| `revoke` | 27k | 30k | The kill switch — cheap by design |
| `withdraw` | 30k | 36k | |
| capability `transfer` | 48k | 48k | Delegation to a sub-agent |

## End-to-end context (from test gas totals)

- Ordinary swap on a mandate pool (empty hookData): ~140k via the test
  router — the pass-through hook adds only the callback dispatch + one
  calldata length check.
- Mandate execution (`execute`, warm): ~80-125k typical, ~240k worst case.
- Composed MandateGuardHook adds two `getSlot0` reads + one oracle
  `sqrtPriceX96` call (~26-42k for the Chainlink adapter) per guarded swap.

## ChainlinkSqrtPriceOracle (deployment: ~570k gas)

| Function | Avg | Max |
|---|---|---|
| `sqrtPriceX96` | 26k | 42k |
| `setFeed` | 50k | 53k |

## Reading for mainnet

At 1 gwei and $4k ETH, a worst-case mandate execution (~240k gas) is
~$0.96; typical ~$0.40. The product targets mandates of meaningful size
(see PRODUCT.md), where enforcement costs are noise relative to spread on
a five-figure trade. Optimization headroom left on the table: policy
struct packing, transient-storage scratch for the unlock round-trip,
skipping the second `getSlot0` when beforeSwap already read it (pass via
tstore), via-ir + higher optimizer runs for production bytecode.
