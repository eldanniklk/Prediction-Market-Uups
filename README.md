# PredictionMarket UUPS (Foundry)

**A “Polymarket-style” prediction market isn’t a sportsbook: it’s a mechanism to discover real probabilities, without dominant intermediaries.**  
👉 For the full vision (what problem it solves and why Polkadot can do it better): **[docs/VISION.md](docs/VISION.md)**

Daily **UP/DOWN** prediction market for **BTC, ETH, and DOT** on **Paseo (EVM)**, featuring:

- **Native collateral** on Paseo (`msg.value`, **PAS** token)
- **Off-chain orderbook** with **EIP-712** signatures (no AMM)
- **Matcher-based execution** (a relayer/service that fills orders)
- **Upgradeable** contract using the **UUPS** pattern

This repo is prepared for the **next phase**:
- Integrate a **web UI** (UI + EIP-712 order signing)
- Add a **bot/oracle runner** that publishes real-time prices to open and resolve **epochs**

---

## 1. Current status

Already implemented and tested:

- Main UUPS contract: `src/PredictionMarketUpgradeable.sol`
- V2 contract for upgrade testing: `src/PredictionMarketUpgradeableV2.sol`
- Foundry deploy/upgrade scripts
- Solidity E2E tests (Foundry)

Functional model:

- **Daily** markets per asset (`EPOCH_DURATION = 1 day`)
- Outcomes per epoch: **UP / DOWN**
- Share price in `priceBps` (valid `1..9999`)
- Final payout: winning share = **1:1**, losing share = **0**
- Users **do not mint** shares
- `mint` and `merge` are restricted to **owner** or **treasury**, using treasury balance

---

## 3. Operational flow

Recommended flow:

1. **Owner/oracle** pushes prices (`pushPrice`) and opens epochs with `bootstrapDailyEpochs`.
2. **Treasury** deposits PAS and creates inventory (`mint`) to provide liquidity.
3. The **user** deposits PAS (`depositCollateral`).
4. User/treasury sign **EIP-712** orders off-chain.
5. The **matcher** executes `matchOrdersPolymarketStyle`.
6. At day close, the owner resolves the epoch (`resolveEpoch` / `rollDaily`).
7. Users get paid via `claim` and can withdraw via `withdrawCollateral`.

> Note: this follows a “Polymarket-style” approach: the orderbook lives off-chain, while the chain validates signatures and updates balances.

---

## 5. Requirements

- Foundry (`forge`, `cast`)
- Paseo RPC: `https://eth-rpc-testnet.polkadot.io/`
- An account with enough **PAS** for deploy/operation

---

## 7. Build and tests

```bash
forge clean
forge build
forge test -vv

## 11. Roadmap (next steps)

- **Web (UI):** deposit/withdraw, sign EIP-712 orders, view orderbook/position, claim.
- **Price bot:** publish prices, open epochs, resolve epochs automatically.

---

## 12. Security and operations

Recommendations for a more production-like phase:

- Keep `owner` and `treasury` behind a multisig for production
- Restrict and monitor `matcherAddress`
- Use separate keys for deploy/admin/oracle bot
- Record and audit UUPS upgrades
- Never expose keys in logs, CI, or `.env` files

### MEV / “sandwich” (quick view)

- There is no AMM, so the classic “sandwich” (moving the pool price) doesn’t apply in the same way.
- However, you can still have:
  - **Execution sniping** (executing an order at a bad time if it has no protections)
  - **Last-block positioning** (entering right before epoch close)
  - **Feeder/oracle risk** (trust model)

### Typical mitigations (future work)

- Add `deadline` to EIP-712 orders
- Add bounds like `minFill` / `maxPriceBps`
- Cutoff window: disallow opening positions in the last **N seconds** of an epoch