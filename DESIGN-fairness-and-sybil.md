# Design proposal — rotation fairness & Sybil resistance (v1.1)

Status: **proposal, not implemented.** Both touch money-handling contracts (`PotScore`, `PotPool`) and need your direction + a Code4rena pass before merge. Written 2026-06-24 (Opus 4.8) from the user-feedback triage; tracks ARCHITECTURE.md known-gaps **#10 (Sybil)** and **#11 (positional value)**.

The two are independent. #11 is a bounded, shippable feature once you pick a model. #10 is a research-grade problem where the honest answer is *defense-in-depth that raises the cost, not a silver bullet.*

---

## #11 — Positional value (the "someone's always last" problem)

**The real issue.** Even with a perfectly fair VRF draw, slot *k* is not worth the same as slot 1. Whoever draws slot 1 gets an interest-free advance from the group; whoever draws slot *N* funds everyone else first and collects last, eating *N−1* periods of opportunity cost. VRF fixed draw *integrity*; it does nothing for positional *value*. This is intrinsic to every ROSCA — the friend's S&P point is correct and we should not pretend otherwise.

**Options considered**

| Option | What | Verdict |
|---|---|---|
| A. **No-repeat-last** | A member who was last in their previous completed pool is never assigned the last slot again. | **Recommended for v1.1.** Bounded, understandable, directly answers the complaint. |
| B. Lifetime position-balancing | Bias each member's draw toward equalizing their *average* slot across all pools. | Defer — most "fair," most complex, hardest to explain. |
| C. Cash auction for early slots | Members bid \$ to jump the queue; surplus to those who wait. | **Rejected** — reintroduces money/yield → the banking-compliance burden the 0%-fee design exists to avoid (your call in the thread). |
| D. Reputation bidding | Bid Pot Score (not cash) for earlier slots. | Defer to v2 — needs careful incentive design or it becomes "rich get richer" / punishes newcomers who may need early access most. |
| E. Honesty in copy | Just tell people late slots trade time for discipline. | **Do now (free)** — already partly done via the new FAQ; reinforces trust. |

**Recommended: A (no-repeat-last) + E (honesty).**

**Implementation sketch (A).**
- `PotScore` records, per wallet, `lastPoolWasLastSlot: bool` (set on pool completion in the payout/complete hook).
- In `PotPool.fulfillRandomWords`, after the Fisher-Yates shuffle, if `rotationOrder[N-1]` is a wallet flagged `lastPoolWasLastSlot`, swap it with a uniformly-random earlier slot. Re-check once; if the swapped-in wallet is *also* flagged, accept (don't loop).
- Degenerate guard: if *every* member is flagged (rare), skip the constraint — it can't be satisfied and must not revert the VRF callback.
- Cost: one extra cross-contract read in the VRF callback (gas — callback limit already set generously at 1.5M) + a small `PotScore` field + hook. All inside the existing two-phase start; no new external surface.
- **Honesty caveat to surface:** "never last twice running" is a gesture, not true equalization (slot *N−1* is nearly as bad as *N*). Market it as exactly that — a guarantee against the worst-case streak, not a promise that every turn is equal.

**Decision needed from you:** ship A for v1.1, or hold the whole positional question for a v2 with B/D? A is ~a day of careful contract work + tests + audit-note.

---

## #10 — Sybil / reputation farming (the dangerous one)

**The attack.** One person spins up K wallets, runs fake circles among them, everyone "pays on time," all K harvest high Pot Scores cheaply, then use that inflated reputation to enter public stranger pools (to look trustworthy, or to set up a rug). This attacks the reputation layer that is the *entire* trust thesis ("Pot is what credit was supposed to be"). It is currently unaddressed and not even on the audit table until this pass.

**Why it's hard.** Wallets are free and pseudonymous; a ring of 10 sockpuppets is on-chain indistinguishable from 10 real friends. Stake deposits (gap #6) don't help — a ring that never defaults never gets slashed. So you cannot fully *prevent* it on-chain; you can make farmed reputation **expensive to earn and worthless to use.**

**Layered mitigations (defense in depth)**

1. **Counterparty-diversity weighting in `PotScore` — the core on-chain defense (recommended).** Reputation earned by completing pools with the *same* small set of wallets is worth little; reputation earned with *distinct, previously-unseen, themselves-reputable* counterparties is worth much more. A ring's counterparties are always the same sockpuppets → their diversity score stays near zero → their farmed reputation can't clear the gate for diverse public pools.
   - On-chain shape: `PotScore` tracks, per wallet, the set of distinct counterparties (store a count + a rolling commitment/bloom of addresses seen, to bound gas). `getScore` becomes `f(clean_pools, on_time_rate, streak, distinct_reputable_counterparties)` with diversity heavily weighted for the *public-pool* gate.
   - This is a real `PotScore` redesign → money contract → audit required. It's the highest-leverage trustless move.

2. **Off-chain cluster-detection indexer (recommended, practical).** An indexer over `PoolCreated`/`PotPaid`/membership events flags tightly-connected wallet clusters (high mutual-pool overlap, low external edges) and assigns a risk score. Not trustless, but it's the strongest *detection* and can power a "⚠ looks like a closed ring" signal shown to a public-pool creator before they accept a joiner. Pairs with the existing event-indexer gap (#7).

3. **Bounded reputation velocity.** Diminishing returns on rapid sequential pools / a cap on score gained per unit time, so farming many fast fake pools yields sublinear reputation. Cheap to add; blunts the economics.

4. **Optional proof-of-personhood for public pools (defer).** Let a public-pool *creator* require a humanity proof (World ID / BrightID / Gitcoin Passport) to join. Strongest anti-Sybil, but adds friction, an external dependency, and privacy questions — make it opt-in per pool, not global.

**Recommended path:** redefine the public-pool gate around **(1) counterparty-diversity** as the on-chain core, backed by **(2) an off-chain cluster indexer** as detection, plus **(3) velocity bounds** as a cheap economic blunt. Treat **(4) PoP** as opt-in v2. Friend-only (invite) pools need none of this — the trust is social; Sybil resistance only matters for the *public/stranger* tier.

**Decision needed from you:** is counterparty-diversity the v1.1 direction for the score redesign, or do you want to gate public pools behind opt-in proof-of-personhood instead (simpler contract, heavier UX)? This one genuinely shapes the product, so I'm not picking it unilaterally.

---

## What's safe to do now vs. needs you

- **Shipped this pass (safe, reversible):** calculator/ladder tier fix, the "why not just save?" FAQ.
- **Ready to build once you pick a model:** #11 no-repeat-last (bounded); #10 counterparty-diversity OR PoP gate (pick one).
- **Hard rule:** neither contract change merges to a fund-holding deploy without a Code4rena pass (ARCHITECTURE.md mainnet gate).
