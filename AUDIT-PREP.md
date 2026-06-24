# Pot Protocol — audit preparation

Turnkey scope/threat-model/invariants package for a third-party audit (Code4rena or
equivalent). The audit is the hard gate before any fund-holding mainnet deploy. As
of v1.1: `forge test` = 29 passing / 0 skipped; `npx hardhat compile` clean (evm
target `cancun`).

## In scope
- `contracts/PotPool.sol` — one circle's full lifecycle; holds USDC.
- `contracts/PotFactory.sol` — deploys pools, owns the VRF subscription + PotScore.
- `contracts/PotScore.sol` — soulbound (non-transferable) ERC-721 reputation.

## Out of scope (trusted)
- USDC (assumed an honest, non-fee-on-transfer ERC-20 on Base; a fee/rebasing token
  would break pot/stake accounting — pools should only ever be deployed with canonical USDC).
- Chainlink VRF coordinator (assumed honest; only it can call `rawFulfillRandomWords`).
- OpenZeppelin + Chainlink library code.

## Roles & trust
- **Factory deployer/owner** — owns the VRF subscription; must fund it; owns PotScore
  (transferred to the factory at deploy so it can authorize pools).
- **Creator** — deploys a pool (auto-joins slot 0); for FIXED pools may set the order;
  for public pools must `stake()`. Cannot mutate a started pool's order or skip payouts.
- **Member** — joins, stakes (public), contributes, claims.
- **Anyone (permissionless)** — `settle`, `cancelIfExpired`, `retryRotation` are open by
  design so a pool can always progress/close without an insider.

## Core invariants (the audit should try to break these)
1. **Solvency / no over-pay.** A round pays exactly `members.length × contributionAmount`
   (computed, NOT `balanceOf`), so held stakes are never swept into a payout. The
   contract never transfers out more than it holds in any single call.
2. **Stake accounting balances.** At every end state, distributable = Σ stakes + the
   cancelled round's contributions, and `claimRefund` distributes exactly that:
   - Complete: each survivor gets `stake + totalSlashed/survivors`.
   - Cancelled (disband): each participant (incl. ejected, via `everMember`) gets
     `stake (if staked) + contribution (if they paid the cancelled round)`; no slashing.
3. **Rotation integrity.** `rotationOrder` is set once at start, is a permutation of the
   members at that moment, and is never mutated after. Public pools are ALWAYS VRF-ordered
   (constructor + factory both reject `fixedOrdering ∧ isPublic`); a late/stale/duplicate
   VRF callback is a no-op (cannot re-roll a locked order).
4. **No payout to a non-member / ghost.** `_payout` advances past ejected recipients;
   a full wipeout or unpayable last slot cancels cleanly (no revert, no ghost pay).
5. **Public-pool gating.** A public pool cannot start until the roster is full AND every
   member has staked. No roster slot exists without a stake (atomic in `join`; creator via `stake`).
6. **0% protocol fee.** `PROTOCOL_FEE_BPS == 0`; the treasury-transfer branch is dead
   (`if (fee > 0)`); the recipient receives the full pot.
7. **Reentrancy.** CEI ordering everywhere + OZ `ReentrancyGuard` (`nonReentrant`) on every
   fund-moving external (`join`, `stake`, `contribute`, `settle`, `claimRefund`).
8. **Soulbound score.** PotScore tokens can be minted/burned but never transferred between
   two non-zero addresses.

## Known residual gaps (deliberately out of v1.1 — see ARCHITECTURE.md "Known gaps")
- **#5 lifetime net-position accounting.** The disband refund returns the *cancelled
  round's* contributions + stakes (balance-exact), NOT a full per-member in-minus-received
  ledger across many partial rounds. A member who defaulted in an *earlier* (viable) round
  loses that round's contribution (the ROSCA risk), as intended.
- **#10 proof-of-personhood.** Deliberately a **v2** item, not a gap — see "v2 roadmap"
  in DESIGN-fairness-and-sybil.md. v1.1's Sybil posture (friend-pools immune + public-pool
  stake-slashing) is complete on its own.
- Pre-mainnet ops (not code): fund the VRF subscription; re-verify the Chainlink coordinator/
  key-hash + USDC addresses for the target network.

## Build / test
```
forge test -vvv          # 29 passing, 0 skipped (foundry)
npx hardhat compile      # primary toolchain, evm target cancun
```
Coverage spans: forming/invite/score-gating, VRF two-phase start + retry + stale-callback
no-op + spoof rejection, ordering modes (random/fixed, public-forces-random), the full
contribute→settle→payout lifecycle, ejection + slashing + survivor split, disband
reconciliation (full wipeout + last-slot default), stake gating + refunds, reentrancy, and
the soulbound property.
