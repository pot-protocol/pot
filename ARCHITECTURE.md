# Architecture

This document is the top-down technical walkthrough of Pot for engineers and
agents. If you've read the [README](README.md), you know *what* Pot is. This
explains *how* it's built, *why* each decision was made, and — most importantly
— *where the weak spots are*.

---

## The concept, in one paragraph

Pot runs rotating savings circles (susus / ROSCAs) on-chain. A group of 2–10
people each contribute an equal amount of USDC every interval; each round, the
full pot is released to one member, until everyone has been paid once. The
novel part is not the savings circle — that's centuries old — it's the
**portable reputation layer** (the Pot Score, a soulbound ERC-721) that lets a
stranger trust your reliability the way a family or congregation used to. The
software's job is to make the rotation mechanically trustworthy so the *social*
trust that limited susus to your inner circle is no longer the binding
constraint.

## The key invariant

> **The contract is the trust layer. Once a pool is `Active`, no participant —
> not even the creator — can alter the rotation order, skip a recipient,
> withhold a payout, or move USDC along any path not encoded in `PotPool`.**

Everything in the design serves that invariant. The rotation order is locked at
start and stored in an array that is never mutated afterward. Payouts are
computed and released by the contract, triggered either automatically (when the
last member contributes) or permissionlessly (when anyone calls `settle` after
the grace period). There is no admin key that can redirect funds. The only
privileged role in the whole system is the `onlyOwner` on `PotScore`, and that
ownership is handed to the factory so it can do exactly one thing: authorize a
freshly-deployed pool to write reputation.

If you are auditing Pot, your job is to find any path that violates that
invariant.

---

## The three-contract system

```
                         ┌─────────────────────────────────────┐
                         │             PotFactory              │
                         │  (singleton entry point + index)    │
                         │                                     │
        createPool() ───▶│  • validates terms                  │
                         │  • deploys a PotPool                 │
                         │  • authorizePool() on PotScore  ────┼──┐
                         │  • indexes pool (allPools, byCreator)│  │
                         └───────────────┬─────────────────────┘  │
                                         │ new PotPool(...)         │
                                         ▼                          │
                         ┌─────────────────────────────────────┐   │ owner-gated
                         │              PotPool                 │   │ authorization
                         │     (one per circle, lifecycle)     │   │
                         │                                     │   │
                         │  Forming → Active → Complete        │   │
                         │  join / invite / contribute /       │   │
                         │  settle / _payout / _ejectMissers   │   │
                         │                                     │   │
                         │  fires reputation hooks ────────────┼──▶│
                         └─────────────────────────────────────┘   │
                                                                    ▼
                         ┌─────────────────────────────────────┐
                         │             PotScore                 │
                         │  (soulbound ERC-721 reputation)     │
                         │                                     │
                         │  onPoolStarted / onContribution /   │
                         │  onMiss / onPayout / onPoolComplete │
                         │  getScore() → 0–1000 composite      │
                         └─────────────────────────────────────┘
```

### 1. `PotFactory` — why a singleton + per-pool deployment

**Decision: one factory, one pool contract instance per circle.**

A single shared pool contract holding all circles' money would be a honeypot
with a huge blast radius — one bug drains everyone. Instead each circle gets its
own `PotPool` instance, so a flaw in one pool's *state* can never touch another
pool's funds. The factory exists to (a) make deployment uniform and validated,
(b) keep a discoverable on-chain index (`allPools`, `poolsByCreator`,
`isPool`), and (c) be the holder of `PotScore` ownership so it can wire up
authorization atomically.

**Why the factory must own `PotScore`.** A pool needs permission to write
reputation (`onlyPool` hooks). That permission is granted by
`PotScore.authorizePool`, which is `onlyOwner`. If a human owner had to manually
authorize each pool, there'd be a race where a pool exists but can't start. So
`createPool` calls `authorizePool` itself — which requires the factory to *be*
the owner. The deploy script transfers `PotScore` ownership to the factory right
after both are deployed. **This was a flagged gap in the original spec** (the
factory didn't authorize new pools); it's now wired in, and the ownership
transfer is the deployment invariant that makes it work. If the transfer is
skipped, `createPool` reverts at the authorize step — a fail-*closed* posture,
which is the correct way to fail.

**Score-gating on creation.** Creating a *public* pool requires the creator's
own Pot Score to clear `minScoreRequired`. This stops a score-0 wallet from
spinning up "public" stranger pools it has no record to back.

### 2. `PotPool` — the lifecycle, and why it's shaped this way

A pool is a small state machine: `Forming → Active → Complete` (with `Cancelled`
as the wipeout escape hatch).

**Forming.** The creator auto-joins at construction. Private pools gate joins on
an invite mapping; public pools gate on Pot Score. The pool **auto-starts the
instant the roster hits `maxMembers`** — there's no separate "start"
transaction a creator could forget or grief by withholding.

`Forming` is not a single dead-end state — it has three exits, so a pool that
never reaches `maxMembers` is never stuck:

1. **Filling** — the normal path: members keep joining until the roster is full
   and the pool auto-starts into `Active`.
2. **Expired → Cancelled (with refund).** A `formingDeadline` is fixed at
   construction (`block.timestamp + FORMING_WINDOW`, 7 days). Once it passes with
   the roster still incomplete, **anyone** may call `cancelIfExpired` (it's
   permissionless on purpose, like `settle`) to flip the pool to `Cancelled`.
   Members then call `claimRefund` — guarded by a `refundClaimed` mapping against
   double-claims — to recover their stake. (The refund *transfer* is a stub today
   because stake deposits aren't held on-chain yet; it lands with gaps #5/#6.)
3. **Started early by the creator.** The creator can call `startEarly` at any
   point while `Forming` once **two or more** members are in, kicking off a
   smaller circle without waiting for every seat. It calls `_start` verbatim, so
   an early start is mechanically identical to a full-capacity start (same
   shuffle, same round arming) and emits an extra `PoolStartedEarly` marker.

**Locking rotation (`_start`).** The payout order is set by a Fisher-Yates
shuffle and written to `rotationOrder`, which is then treated as immutable. Two
arrays are deliberately kept separate:

- `rotationOrder` — the payout schedule, never mutated after `_start`.
- `members` — the *live* roster, from which ejections remove entries.

Keeping them separate is what lets the contract eject a defaulter from `members`
while still walking the original payout schedule and correctly *skipping* the
ejected wallet's turn. Conflating them would corrupt the schedule on the first
ejection.

> **Randomness caveat (audit target):** the shuffle seeds on
> `block.timestamp` + `block.prevrandao`. `prevrandao` is influenceable by block
> proposers and is **not** a secure VRF. Acceptable for v0.1 testnet pilots;
> must be replaced with Chainlink VRF before mainnet. See *Known gaps*.

**Contributing.** `contribute` requires the member to have pre-approved the pool
for `contributionAmount` USDC. It records on-time vs. grace-period status
(stamped into the Pot Score), pulls the USDC, then calls `_trySettle`. The last
member to pay in a round triggers settlement automatically — the common case
needs no `settle` call at all.

**Settlement and ejection.** If the grace period
(`roundDeadline + GRACE_PERIOD`) expires with members still unpaid, *anyone* can
call `settle` — it's permissionless on purpose, so a circle can always close
even if no insider acts. `_ejectMissers` removes every non-contributor from
`members` (swap-and-pop, O(n)) and stamps a permanent miss on each one's score.

**Payout (`_payout`).** It advances past any ejected recipient to find the next
live member on the schedule, then splits the pot: 1% to the protocol treasury,
the rest to the recipient. Critically, **all state is finalized before any USDC
moves** (Checks-Effects-Interactions): score hooks fire, the round advances, and
the pool's `state` flips to `Complete` if the schedule is exhausted — *then* the
transfers execute. When the schedule isn't exhausted, the next round's deadline
is armed.

### 3. `PotScore` — soulbound reputation, in technical terms

`PotScore` is an **ERC-721 made non-transferable** by overriding the OZ v5
`_update` hook:

```solidity
function _update(address to, uint256 tokenId, address auth)
    internal override returns (address)
{
    address from = _ownerOf(tokenId);
    require(from == address(0) || to == address(0), "Soulbound: non-transferable");
    return super._update(to, tokenId, auth);
}
```

`_update` is the single chokepoint through which OZ v5 routes mints, transfers,
and burns. A mint has `from == address(0)`; a burn has `to == address(0)`; a
real transfer has both non-zero — which is exactly what we reject. So tokens can
be minted to a wallet and (in a future version) burned, but never moved between
two wallets. Reputation is bound to the identity that earned it.

**Lazy minting.** A wallet's token is minted the first time it touches any pool
(`_ensureMinted`), via the `onPoolStarted` / `onContribution` / `onMiss` hooks.
No separate registration step.

**The score is derived, not stored.** Only the raw counters live in storage
(`poolsCompleted`, `totalRounds`, `onTimeRounds`, `missedRounds`,
`currentStreak`, `bestStreak`). `getScore` computes the 0–1000 composite on
read:

```
positive = poolsCompleted*50 + onTimeRate%*4 + bestStreak*10
penalty  = missedRounds*75
score    = clamp(positive - penalty, 0, 1000)
```

> **Underflow fix (applied):** the original spec computed `positive - penalty`
> directly. In Solidity 0.8+, a wallet whose penalty exceeds its positive points
> (e.g. a brand-new member with a single miss and no completed pools) would
> trigger an arithmetic-underflow panic — and because `getScore` is called by
> the gating logic and the UI, that panic would be a denial of service on any
> view touching that wallet. `getScore` now checks `penalty >= positive` and
> returns 0, preserving the intended "a damaged record bottoms out at zero"
> semantics without ever reverting.

**Authorization model.** Every mutating hook is `onlyPool`, and a pool is only a
pool if the factory authorized it. Reputation therefore can't be forged by an
arbitrary contract — only by a pool the factory deployed.

---

## Money flow, end to end

1. Member calls `usdc.approve(pool, contributionAmount)` (frontend abstracts
   this).
2. Member calls `pool.contribute()` → USDC moves member → pool; score updated.
3. When the round is fully funded (auto) or grace expires (`settle`), `_payout`
   runs:
   - `fee = pot * 1% ` → treasury
   - `payout = pot - fee` → recipient
4. Repeat for each round; on the final round the pool flips to `Complete` and
   every surviving member is credited a completed pool.

The protocol's only revenue is the 1% skim at step 3 — taken from the flow, not
lent against anyone's balance.

---

## Known gaps / audit targets

These are stated plainly so a technical reader knows exactly where to look. They
are tracked as `testTODO_*` stubs in
[`test/PotPool.t.sol`](test/PotPool.t.sol) and prioritized in
[CONTRIBUTING.md](CONTRIBUTING.md).

| # | Gap | Status | Severity |
|---|-----|--------|----------|
| 1 | **Pool authorization wiring.** Factory must authorize each new pool on `PotScore`, which requires the factory to own `PotScore`. | **Fixed** — `createPool` calls `authorizePool`; deploy script transfers ownership. | — |
| 2 | **Weak rotation randomness.** `_start` seeds on `block.prevrandao`, which block proposers can bias. | **Open** — acceptable for v0.1 testnet; replace with Chainlink VRF before mainnet. | High (fairness) |
| 3 | **Full-wipeout payout.** If every remaining member misses the same round, `_ejectMissers` empties `members` and the original `_payout` would index out of bounds / pay a ghost. | **Mitigated** — `_payout` now cancels the pool (`Cancelled`) when no live recipient exists; the eject loop's index-0 underflow is guarded. Refund accounting for the cancelled funds is still TODO (#5). | High |
| 4 | **Reentrancy on `_payout`.** CEI ordering is in place and USDC is a known non-reentrant token, but this has not been formally audited, and a future non-USDC pool would reopen the surface. | **Open** — needs audit + a reentrant-token test. Consider adding OZ `ReentrancyGuard` defensively. | Medium |
| 5 | **Disband / refund accounting.** Spec calls for returning *net* contributions (total in − total received) on early cancellation. Not implemented; cancelled pools currently strand their balance. | **Open** — needs design + reconciliation math + tests. | High |
| 6 | **Stake deposit.** Spec calls for each member to lock one round's contribution at join, released at close, forfeited to remaining members if ejected post-payout. | **Open** — not yet on-chain. | Medium |
| 7 | **On-chain pool discovery.** Beyond the factory's index there's no rich query layer; the frontend must index events (`PoolCreated`, `ContributionReceived`, `PotPaid`, `MemberEjected`). | **By design** — build an off-chain indexer. | Low |
| 8 | **Hardcoded USDC address.** `PotPool` hardcodes Base mainnet USDC, which makes unit testing awkward (the test suite uses `vm.etch` to work around it). | **Open** — recommend taking the token address as a constructor arg so tests and other chains are first-class. | Low |
| 9 | **Lobby / expiry mechanics.** A pool that never filled used to sit in `Forming` forever, stranding whoever joined early with no recourse. | **Added (this pass)** — `formingDeadline` (7-day `FORMING_WINDOW`) + permissionless `cancelIfExpired`, creator-only `startEarly` (2+ members, reuses `_start`), and a `claimRefund` stub guarded by `refundClaimed`. The refund **transfer** is still a stub (no stakes held on-chain yet) and lands with #5/#6. | — |

**Do not deploy to mainnet until #2, #4, #5, and #6 are closed and the system
has a third-party audit.**

---

## Spinning up a local instance from scratch

```bash
# Prerequisites: Node 18+. Foundry optional (recommended for the test suite).

git clone <this-repo> && cd pot
npm install
npm run compile

# Unit tests (Hardhat)
npm test

# Richer lifecycle tests (Foundry)
forge install foundry-rs/forge-std
forge install OpenZeppelin/openzeppelin-contracts
forge test -vvv

# Local chain + deploy
npm run node                                  # terminal 1: a local node
PROTOCOL_TREASURY=0xYourTreasuryAddress \
  npx hardhat run scripts/deploy.js --network localhost   # terminal 2
```

The deploy script prints the `PotScore`, `PotFactory`, and treasury addresses
and the `hardhat verify` commands. To target Base Sepolia, set
`DEPLOYER_PRIVATE_KEY` and `PROTOCOL_TREASURY` in a local `.env` and run
`npm run deploy:base-sepolia`. All configuration lives in
[`hardhat.config.js`](hardhat.config.js).

### Deployment order (and why it matters)

1. `PotScore` (deployer is initial owner).
2. `PotFactory(scoreAddress, treasury)`.
3. `score.transferOwnership(factory)` — **mandatory**, or every `createPool`
   reverts at the `authorizePool` step.

That ownership transfer is the linchpin of the whole authorization model. It's
the first thing to check if pools won't start.
