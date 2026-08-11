#!/usr/bin/env bash
# Mandates live demo — a complete delegation lifecycle on a local chain.
#
#   ./demo.sh
#
# Requires Foundry (anvil, forge, cast): https://getfoundry.sh
#
# Cast of characters (standard anvil dev accounts — public test keys):
#   Alice   owner:    funds the vault, issues + revokes the mandate
#   Bob     agent:    holds the mandate capability, trades inside it
#   Mallory attacker: holds nothing, tries anyway
set -euo pipefail
cd "$(dirname "$0")"

RPC=http://127.0.0.1:8545
ALICE_PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
ALICE=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
BOB_PK=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
BOB=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
MALLORY=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC

bold=$(tput bold 2>/dev/null || true); dim=$(tput dim 2>/dev/null || true)
grn=$(tput setaf 2 2>/dev/null || true); red=$(tput setaf 1 2>/dev/null || true)
pnk=$(tput setaf 5 2>/dev/null || true); rst=$(tput sgr0 2>/dev/null || true)

step() { echo; echo "${bold}${pnk}▸ $1${rst}"; }
ok()   { echo "  ${grn}✓${rst} $1"; }
died() { echo "  ${red}✗ $1${rst}"; exit 1; }

for bin in anvil forge cast; do
  command -v $bin >/dev/null || died "$bin not found — install Foundry: https://getfoundry.sh"
done

step "Starting a local chain (anvil)"
anvil --disable-code-size-limit --silent &
ANVIL_PID=$!
trap 'kill $ANVIL_PID 2>/dev/null || true' EXIT
sleep 2
ok "chain up at $RPC"

step "Deploying the demo world (pool manager, book, mined hook, tokens, pool, Alice's mandate for Bob)"
OUT=$(forge script script/DemoSetup.s.sol --rpc-url $RPC --private-key $ALICE_PK --broadcast 2>&1) \
  || { echo "$OUT" | tail -20; died "setup failed"; }
eval "$(echo "$OUT" | grep -E '^\s*(BOOK|HOOK|TOKEN0|TOKEN1|MANDATE_ID)=' | tr -d ' ')"
ok "MandateBook $BOOK"
ok "MandateGuardHook $HOOK  ${dim}(low bits encode its beforeSwap|afterSwap permissions)${rst}"
ok "Mandate #$MANDATE_ID for Bob: 100 dTOK0/day, sell-only, 30 days, revocable"

# Named custom-error selectors, so rejections below are provably the right ones.
SEL_BUDGET=$(cast sig 'BudgetExceeded()');      SEL_BUDGET=${SEL_BUDGET#0x}
SEL_DIR=$(cast sig 'DirectionForbidden()');     SEL_DIR=${SEL_DIR#0x}
SEL_REVOKED=$(cast sig 'Revoked()');            SEL_REVOKED=${SEL_REVOKED#0x}
SEL_NOCAP=$(cast sig 'NotCapabilityHolder()');  SEL_NOCAP=${SEL_NOCAP#0x}

expect_reject() { # <error name> <selector> <from> <args...>
  local name=$1 sel=$2 from=$3; shift 3
  local out
  out=$(cast call $BOOK "execute(uint256,bool,uint256,uint256)" "$@" --from "$from" --rpc-url $RPC 2>&1) \
    && died "expected $name rejection, but the call SUCCEEDED"
  echo "$out" | grep -qi "$sel" \
    && ok "rejected on-chain with ${bold}$name${rst}" \
    || died "expected $name (selector 0x$sel), got: $(echo "$out" | head -2)"
}

budget()  { cast call $BOOK "remainingBudget(uint256)(uint256)" $MANDATE_ID --rpc-url $RPC; }
vault()   { cast call $BOOK "vaultBalance(address,address)(uint256)" $ALICE "$1" --rpc-url $RPC; }

step "Bob (the agent) trades 50 dTOK0 — inside his mandate"
cast send $BOOK "execute(uint256,bool,uint256,uint256)" $MANDATE_ID true 50ether 1 \
  --private-key $BOB_PK --rpc-url $RPC >/dev/null
ok "swap executed through the pool"
ok "budget remaining today: $(budget | awk '{print $1/1e18}') dTOK0"
ok "Alice's vault was credited the output: $(vault $TOKEN1 | awk '{print $1/1e18}') dTOK1"

step "Bob gets greedy: tries 60 more dTOK0 (only 50 left today)"
expect_reject BudgetExceeded $SEL_BUDGET $BOB $MANDATE_ID true 60ether 1

step "Bob tries the forbidden direction (buying dTOK0 back)"
expect_reject DirectionForbidden $SEL_DIR $BOB $MANDATE_ID false 10ether 1

step "Mallory (no capability) tries to execute Bob's mandate"
expect_reject NotCapabilityHolder $SEL_NOCAP $MALLORY $MANDATE_ID true 10ether 1

step "Alice pulls the kill switch: revoke"
cast send $BOOK "revoke(uint256)" $MANDATE_ID --private-key $ALICE_PK --rpc-url $RPC >/dev/null
ok "mandate revoked — one call, effective immediately"

step "Bob tries to keep trading anyway"
expect_reject Revoked $SEL_REVOKED $BOB $MANDATE_ID true 10ether 1

step "Alice withdraws everything — custody was never at risk"
T0_LEFT=$(vault $TOKEN0 | awk '{print $1}')
cast send $BOOK "withdraw(address,uint256)" $TOKEN0 $T0_LEFT \
  --private-key $ALICE_PK --rpc-url $RPC >/dev/null
ok "withdrew $(echo $T0_LEFT | awk '{print $1/1e18}') dTOK0 back to her wallet"

echo
echo "${bold}${grn}Demo complete.${rst} Every rejection above was enforced by the pool's hook"
echo "and the book's policy — Bob's software was never trusted with anything."
