# Design — rotation fairness & Sybil resistance (v1.1)

Decisions recorded 2026-06-24 (Opus 4.8, with Luke). Both resolve onto a single axis the contract already has: **`isPublic` (private/friend vs public/stranger)**.

- **Private/friend pools:** trust is social → flexible ordering, no Sybil machinery, can skip VRF.
- **Public/stranger pools:** trustless → forced VRF ordering, stake-slashing on default, opt-in proof-of-personhood.

Why this axis: the two problems both reduce to "trust comes from the relationship vs trust comes from the protocol." Friend pools already have the relationship, so the protocol should get out of the way. Public pools have nothing but the protocol, so the protocol must carry all the weight — and must be honest about what it can and can't do.

---

## #11 — Positional value → **ordering is a per-pool choice** (IMPLEMENTING this pass)

**Why not the original "no-repeat-last" idea:** it's a fig leaf — slot N−1 is nearly as bad as N, so "never last twice" doesn't fix the economics; it conflates heterogeneous pools (last in a 3-person weekly ≠ last in a 10-person monthly); and it re-biases the shuffle we just made provably fair. The real fix is to stop trying to engineer fairness into a *random* order and instead let the people who *can* be fair (a friend circle, by need) choose the order — while keeping randomness mandatory where no one can be trusted to choose.

**Decision — `fixedOrdering` flag per pool:**

| | RANDOM (default) | FIXED |
|---|---|---|
| Order source | Chainlink VRF shuffle | Creator-set, or join order |
| Allowed for | any pool | **private pools only** (`!isPublic`) |
| Start | auto on fill, or `startEarly` | creator calls `startEarly` (gives an ordering window) |
| VRF | yes (two-phase `Pending`) | **skipped** — no request, no `Pending`, no LINK/ETH cost, instant start |

Rules:
- **Public pools force RANDOM.** Construction reverts if `fixedOrdering ∧ isPublic` — a stranger pool's creator must never be able to hand themselves slot 1.
- **FIXED order = creator-set permutation, else join order.** `setRotationOrder(address[])` (creator-only, while `Forming`, FIXED-only) stores a permutation of the current members so the circle can arrange by *need* (Becky's wedding first). If unset or stale at start, it falls back to join order — both are valid rotations.
- **FIXED pools don't auto-start on fill** (unlike RANDOM); the creator starts them, which is what creates the window to set the order. This matches the friend-pool model (creator-coordinated).
- FIXED skipping VRF is a real win: friend circles, the common case, become cheaper (no VRF subsidy) and simpler (no async wait).

This deletes the constrained-shuffle idea entirely; ordering becomes a flag + an optional creator call, and the seam is the existing `isPublic`.

---

## #10 — Sybil / reputation farming → **defend the harm, not the farming** (design only — needs build + audit)

**The unwinnable part:** on-chain, a real friend group and a Sybil ring are the *same graph* — a closed clique pooling repeatedly. So any "detect fake circles" metric (incl. the counterparty-diversity idea, now **dropped**) false-positives your best users and only speed-bumps a capitalized attacker. Reputation farming itself is also *harmless* — sockpuppets paying each other hurt no one. The harm only happens when farmed reputation is *used to default on a real counterparty in a public pool*. So price **that**.

**Decision:**
1. **Friend/invite pools are the launch product** — Sybil-immune by construction (scam your own sockpuppets, scam only yourself). Ship with zero Sybil machinery.
2. **Public pools gate on stake-at-risk, slashed on default** — folds into the existing stake-deposit gap (ARCHITECTURE #6). This makes *using* farmed reputation costly; it targets the harm, not the (harmless) farming, and it's on-chain-feasible.
3. **Proof-of-personhood = opt-in, per-pool, deferred** — the *only* robust defense for truly-open stranger pools, but it costs trustlessness + adds friction, so a public-pool creator *opts into* requiring it (World ID etc.). Escape hatch for if/when open stranger pools are real demand.
4. **Drop counterparty-diversity weighting** — false-positives real families; defeatable.
5. **Off-chain cluster indexer = advisory only**, never a gate (a trusted judge contradicts the pitch); pairs with the event-indexer gap (#7).

**The thesis survives and improves.** "Reputation lets you pool with strangers" still holds, but the reputation that unlocks public pools is **skin-in-the-game (stake) + optional personhood**, not a farmable pool-count. You're trusted because you have something to lose, not because of a number anyone can mint — a *stronger* "credit as it should have been."

**Honest limit:** trustless AND Sybil-resistant-open-stranger-pools may be fundamentally incompatible. If open pools ever truly matter, personhood is the price, and it costs some of the decentralization story. Until then, friend-pools + stake-gated public pools is the defensible posture.

---

## Build status
- **#11 ordering-mode:** implemented (`PotPool.fixedOrdering`, `setRotationOrder`, public-forces-random invariant, FIXED skips VRF) + tests.
- **#10 stake-slashing:** implemented for public pools (`stake()`/atomic-on-`join`, slash in `_ejectMissers`, split among survivors in `claimRefund`; `_payout` pays the exact round pot so stakes aren't swept; a stuck-`Pending` pool can be cancelled to recover stakes). Folds in the stake-deposit gap (#6). **Proof-of-personhood** (opt-in per public pool) remains deferred — the only robust defense for truly-open pools, accepting it costs some trustlessness.
- Residual: two fund-stranding edges (full wipeout, last-slot default) are **closed** as of the v1.1 hardening pass (disband reconciliation); lifetime net-position accounting across many partial rounds remains the only #5 residual.
- **All of the above is audit-gated** — nothing merges to a fund-holding deploy without a Code4rena pass. Threat model + invariants for that audit are in `AUDIT-PREP.md`.

## Roadmap (deliberately out of v1.1, not gaps)
v1.1's Sybil posture is **complete on its own**: friend/invite pools are immune by
construction, and public pools are stake-gated with slashing-on-default. The following
are intentional later choices, gated on real demand — not unfinished work:

**v1.1.x fast-follow:**
- **Savings mode** — a creator-choice, Sybil-immune, zero-credit pool type (no early
  payout; withdraw your own at close). Builds on the audited core as a *separate*
  contract. Full spec: [`DESIGN-savings-mode.md`](DESIGN-savings-mode.md).

**v2:**
- **Proof-of-personhood**, opt-in per public pool (World ID / BrightID / Gitcoin Passport)
  — the only robust defense for *truly open* stranger pools, accepting that it costs some
  trustlessness and adds friction. Build it when open stranger pools are real demand.
- **Reputation-bidding for slot position** (bid score, not cash) — a richer fairness lever
  than the v1.1 ordering choice, deferred until the incentive design is worked out.
- **Lifetime net-position reconciliation** — a full per-member in-minus-received ledger
  for disbands across many partial rounds (v1.1 reconciles the cancelled round + stakes).
