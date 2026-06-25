# Design — savings mode (v1.1.x fast-follow)

Status: **spec, build AFTER the v1.1 audit clears.** Deliberately *not* in v1.1: it's
a second mechanism, and the v1.1 lesson (a red-team Critical hid in the rotating
payout path) is to freeze + prove that surface before extending it. This builds on
the audited core, cleanly isolated.

## Why
A rotating circle extends **uncollateralized credit** to whoever gets paid early — the
structural default risk. Savings mode removes the credit entirely: everyone
contributes each period, **nobody is paid early**, and at close each member withdraws
**their own** accumulated contributions. Your money is always your own.

It is the **zero-counterparty-risk** product: a circle of strangers (or anyone who
doesn't want the early-access risk) gets a social-accountability savings club — the
"forced discipline" product — with no way to lose money to someone else's default. It
is also the on-ramp the v2 reputation-gated rotating mode graduates *from*.

## Key properties (what makes it the safest mode in the system)
- **Sybil-immune by construction.** There's no pot to extract early, so a ring of
  sockpuppets in a savings circle only "scams" itself. → **no stake required**, even
  for public/stranger savings circles, and **no reputation gate** (that's the v2 thing).
- **No credit, so no slashing, no disband-stranding class of bug.** Each member's
  funds are always individually theirs.
- **No VRF, no rotation order.** Nobody gets an early payout, so there's no order to
  randomize → skip the whole VRF two-phase start.

## Mechanism
- **Creator-chosen at creation** (a pool *type*, not reputation-gated). A pool is
  either rotating (today's `PotPool`) or savings.
- **Lifecycle:** join → contribute each round (each member's total accrues, held in
  the contract) → after the creator-set number of rounds, the pool **Closes** → each
  member calls `withdraw()` for `contributedTotal[member]`.
- **Default = reputation only.** A missed contribution marks the member's Pot Score
  (the social-accountability signal — they broke the commitment) but **never costs
  them money**: they can always withdraw what they actually saved. No ejection-with-
  forfeiture, no slashing — there's no counterparty to harm.
- **Balance-exact trivially:** held = Σ `contributedTotal`; each member withdraws
  exactly their own. No pooling, no shares, no dust.

## The one real architecture decision — and the call
**Build it as a SEPARATE contract (`SavingsPool`), not a `savingsMode` flag on
`PotPool`.** The entire rationale for fast-following (instead of v1.1) was to keep the
audited rotating payout/refund lifecycle *frozen*. A mode flag would thread
`if (savingsMode)` branches through `join`/`contribute`/`_payout`/`claimRefund` — the
exact code that just produced a Critical. A separate contract keeps that code untouched
and makes savings mode trivially auditable on its own (it's ~a third the surface — no
VRF, no stake, no slash, no rotation).
- Share the small common parts via a minimal base or library: member roster (`join`,
  `isMember`, `everMember`), the Pot Score hooks, USDC handling, `ReentrancyGuard`.
- `PotFactory` gains a `createSavingsPool(...)` that deploys + authorizes a `SavingsPool`
  (same score-authorization wiring; no VRF subscription needed for it).

## Test plan (mirror the v1.1 rigor)
- Happy path: N members contribute K rounds → close → each withdraws exactly their total.
- A member who misses some rounds: Pot Score marked, withdraws exactly what they paid.
- A member who never contributes: nothing to withdraw, no revert-trap.
- No early withdrawal before Close; no double-withdraw (`withdrawn` guard, CEI).
- Reentrancy (the malicious-token test).
- Balance: pool empties to exactly 0 after all withdrawals.
- Public savings pool: no stake required (assert), Sybil ring only self-affects.

## Sequencing
1. **v1.1** — ship the audited rotating core (ROSCA + stake), launch.
2. **v1.1.x (this)** — `SavingsPool` as an isolated fast-follow; focused delta-audit; ship.
3. **v2** — **reputation-gated early access**: a fresh circle *defaults* to savings mode,
   and a Sybil-resistant Pot Score (which needs the deferred proof-of-personhood work)
   *unlocks* rotating mode. v1.1.x is the foundation that v2 graduates from. See the v2
   roadmap in `DESIGN-fairness-and-sybil.md`.
