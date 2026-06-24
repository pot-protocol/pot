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
   smaller circle without waiting for every seat. It calls `_requestRotation`
   verbatim, so an early start is mechanically identical to a full-capacity start
   (same VRF request, same two-phase lock) and emits an extra `PoolStartedEarly`
   marker.

**Ordering mode (`fixedOrdering`).** How the payout order is set is a per-pool
choice, gated on `isPublic`. **RANDOM** (default) uses the VRF flow below.
**FIXED** (private pools only — construction reverts if `fixedOrdering ∧ isPublic`)
locks a creator-set order (`setRotationOrder`, a permutation of members so the
circle can arrange by *need*) or, if unset/stale, the join order — and **skips
VRF entirely**: no `Pending`, no subscription cost, instant `Active` via
`_lockFixedOrder`. FIXED pools don't auto-start on fill; the creator calls
`startEarly`, which is the window to set the order. The seam for both modes is
`_beginStart`. The rest of this section describes the RANDOM (VRF) path.

**Locking rotation (RANDOM mode — two-phase, Chainlink VRF v2.5).** Starting a
RANDOM pool is split into a request and a callback so the payout order is seeded
by *verifiable* randomness the trigger transaction cannot influence:

1. **`_requestRotation`** (phase 1) — fired when the roster fills, or by the
   creator via `startEarly`. It moves the pool to a new **`Pending`** state and
   asks the VRF coordinator for one random word. It does **not** compute any
   order. No member funds are held while `Pending` (`contribute` requires
   `Active`), so a pool awaiting fulfillment has nothing at risk.
2. **`fulfillRandomWords`** (phase 2, the VRF callback) — runs a Fisher-Yates
   shuffle seeded by the random word, writes `rotationOrder`, arms round 0, and
   flips the pool `Active`. It is request-scoped and idempotent: a callback for a
   superseded (retried) request, or any callback once the pool has left
   `Pending`, is ignored rather than reverted, so a late or stale fulfillment can
   never re-roll an already-locked order. Only the coordinator can reach it
   (`rawFulfillRandomWords` in `VRFConsumerBaseV2Plus`).

If a request is never fulfilled (e.g. the subscription ran dry), anyone may call
**`retryRotation`** after `RANDOMNESS_RETRY_WINDOW` to reissue it; the old
request id is retired. The factory owns one VRF subscription and adds every pool
it deploys as a consumer; fund it on the coordinator before pools start.

After the order is locked, two arrays are deliberately kept separate:

- `rotationOrder` — the payout schedule, never mutated after the VRF callback.
- `members` — the *live* roster, from which ejections remove entries.

Keeping them separate is what lets the contract eject a defaulter from `members`
while still walking the original payout schedule and correctly *skipping* the
ejected wallet's turn. Conflating them would corrupt the schedule on the first
ejection.

> **Randomness (resolved):** the rotation seed comes from **Chainlink VRF v2.5**
> (subscription method), delivered in a later block the start trigger cannot
> influence. This replaced the original `block.timestamp` + `block.prevrandao`
> shuffle, which the final joiner could simulate in-block and grind for an early
> slot. The shuffle algorithm is unchanged; only its seed moved from a gameable
> on-chain value to a verifiable off-chain one. See *Known gaps* row 2.

**Staking (public pools only).** A public-pool member locks a stake equal to
`contributionAmount` — joiners stake atomically in `join`, the creator (who
auto-joined at construction, before the pool address existed to approve) stakes
via `stake()`. A public pool can't start until the roster is full **and** every
member has staked. The stake is the Sybil/default deterrent (#10): it is held in
the contract from `Forming` onward, **slashed** if the member defaults and is
ejected, and the slashed total is split equally among the survivors at
completion via `claimRefund`. Critically, `_payout` pays the *exact* round pot
(`members.length × contributionAmount`), not `balanceOf`, so held stakes are
never swept into a payout. Private pools require no stake (trust is social).

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
live member on the schedule, then releases the pot. `PROTOCOL_FEE_BPS` is **0** —
the protocol takes nothing and the recipient receives the **full** pot ("put in
$X, get back $X"). The fee is a parameterized constant with the treasury-transfer
path already in place (guarded by `if (fee > 0)`), so a future non-zero fee is a
one-line change, not a re-architecture. Critically, **all state is finalized
before any USDC moves** (Checks-Effects-Interactions): score hooks fire, the
round advances, and
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
| 2 | **Weak rotation randomness.** The original `_start` seeded the shuffle on `block.timestamp` + `block.prevrandao`, which the final joiner could simulate in-block and grind for an early slot. | **Resolved (this pass)** — replaced with Chainlink VRF v2.5: two-phase start (`_requestRotation` → `Pending` → `fulfillRandomWords` locks the order), permissionless `retryRotation` escape hatch, stale-callback no-op guard, factory-owned subscription. No funds are held while `Pending`. Verify coordinator/key-hash addresses against docs.chain.link before mainnet, and confirm the subscription is funded. | High (fairness) |
| 3 | **Full-wipeout payout.** If every remaining member misses the same round, `_ejectMissers` empties `members` and the original `_payout` would index out of bounds / pay a ghost. | **Mitigated** — `_payout` now cancels the pool (`Cancelled`) when no live recipient exists; the eject loop's index-0 underflow is guarded. Refund accounting for the cancelled funds is still TODO (#5). | High |
| 4 | **Reentrancy.** CEI ordering plus USDC being non-reentrant already covered this; a future non-USDC pool would have reopened the surface. | **Hardened (this pass)** — OZ `ReentrancyGuard` now wraps every fund-moving external (`join`, `stake`, `contribute`, `settle`, `claimRefund`); a malicious reentrant-ERC20 test proves a re-entrant `claimRefund` is blocked. Still wants a third-party audit sign-off. | Low |
| 5 | **Disband / refund accounting (residual edges).** Most paths now reconcile (stakes refund on completion/cancellation, slashed stakes split among survivors), but two edges still strand funds: a **full wipeout** (every member misses the same round → all ejected, no survivors to pay) and a **last-slot default** (the final rotation recipient is ejected → `_payout` cancels). In both, ejected members are not `isMember` so they can't `claimRefund`, and their net contributions/stakes strand. | **Open (narrowed)** — needs net-contribution reconciliation math + tests for these two cases. | Medium |
| 6 | **Stake deposit.** Each member locks one round's contribution at join, released at close, forfeited if ejected post-default. | **Implemented for PUBLIC pools (this pass)** — `stake()`/atomic-on-`join`, held from `Forming`, slashed in `_ejectMissers` and split among survivors via `claimRefund` at completion. `_payout` pays the exact round pot (`members.length × contributionAmount`) so held stakes are never swept. Private pools require no stake (social trust). Edge reconciliation lands with #5. | High (compensation) |
| 7 | **On-chain pool discovery.** Beyond the factory's index there's no rich query layer; the frontend must index events (`PoolCreated`, `ContributionReceived`, `PotPaid`, `MemberEjected`). | **By design** — build an off-chain indexer. | Low |
| 8 | **Hardcoded USDC address.** `PotPool` used to hardcode Base mainnet USDC, awkward for tests/other chains. | **Resolved (this pass)** — the token address is now a `PotFactory` + `PotPool` constructor arg (per-network in `deploy.js`, env-overridable). Tests pass a `MockUSDC` directly; the `vm.etch` hack is gone. | — |
| 9 | **Lobby / expiry mechanics.** A pool that never filled used to sit in `Forming` forever, stranding whoever joined early with no recourse. | **Added (this pass)** — `formingDeadline` (7-day `FORMING_WINDOW`) + permissionless `cancelIfExpired`, creator-only `startEarly` (2+ members, reuses `_requestRotation`), and a `claimRefund` stub guarded by `refundClaimed`. The refund **transfer** is still a stub (no stakes held on-chain yet) and lands with #5/#6. | — |
| 10 | **Sybil / reputation farming.** A ring of colluding wallets can farm Pot Scores via fake circles, then use that reputation to enter/abuse public stranger pools. Attacks the reputation layer that is the trust thesis. | **Partially addressed (this pass) — "defend the harm, not the farming."** Detecting fake circles is unwinnable (a real friend group ≡ a Sybil ring on-chain), so instead: **public** pools now require **stake-at-risk slashed on default** (gap #6) — farmed reputation is harmless until *used to default on a real counterparty*, and that now costs the attacker their stake (paid to the victims). **Friend/invite** pools are Sybil-immune by construction (no stake needed). Remaining: **proof-of-personhood** as an *opt-in* per-public-pool gate (the only robust defense for truly-open pools) is deferred; counterparty-diversity weighting was considered and **rejected** (false-positives real families). See `DESIGN-fairness-and-sybil.md`. | High |
| 11 | **Rotation positional value (fairness beyond the draw).** Even with a perfectly fair VRF draw, the time value of money makes early slots genuinely worth more than late ones, so being "last" is a real economic loss. VRF fixes draw *integrity*, not positional *value*. | **Partially addressed (this pass)** — shipped per-pool ordering choice (`PotPool.fixedOrdering`): **private** pools may use a creator-set or join order so the circle arranges by *need* (and skip VRF); **public** pools are forced to VRF. This reframes the problem (return fairness to the humans who can express need) rather than engineering a constrained shuffle, which was rejected as a fig leaf — slot N−1 ≈ slot N. Lifetime position-balancing / reputation-bidding deferred to v2. See `DESIGN-fairness-and-sybil.md`. | Medium (product) |

**Do not deploy to mainnet until #4 and #5 are closed, #10's proof-of-personhood
posture is decided, and the system has a third-party audit.** (#2 randomness
resolved via Chainlink VRF; #6 stake deposit implemented; #10 harm-defense
(stake-slashing) implemented for public pools.)

Design proposals for the two newest gaps — **#10 Sybil/reputation-farming** and
**#11 positional fairness** — with options, recommendations, and the decisions
that need your call, are in
[`DESIGN-fairness-and-sybil.md`](DESIGN-fairness-and-sybil.md).

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
