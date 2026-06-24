# Proper Site — What Needs Doing

This is the punch list for graduating from the GitHub Pages pilot to a real production site.

---

## Copy / Messaging (from user feedback 2026-06-24)

Raised in a feedback DM thread with a first reader. See memory `project_pot.md` for the full triage.

- [ ] **Fix the Home-tier calculator/ladder inconsistency (concrete bug, live).** The page mixes "10 people / 10 months / $10,000" with "12 months / $12,000" at $1,000/mo (e.g. index.html ~line 1242 pairs "10 people" with "12 month"). The contract caps pools at **10 members** (`memberCount <= 10`), so a $12,000 Home tier at $1,000/mo — which needs 12 rounds = 12 people — is **impossible under the protocol**, not just inconsistent copy. Pick one: $10,000 / 10 months at $1,000/mo, or $1,200/mo × 10 = $12,000.
- [ ] **Lead the FAQ with the "why not just save the money myself?" objection.** Every susu faces it. Answer: forced savings via social commitment + early access to your cut without a loan.
- [ ] **Reframe positioning toward the real target user.** Consider leading with the accessible Seed ($250) tier rather than $1,000+ Home; make explicit this is for non-savers building the habit and for social lending (help cousin Becky without *giving* her money) — *not* for savvy investors who'd rather index. Be honest that early slots are worth more than late ones (time value) — see ARCHITECTURE.md gap #11.

---

## Domain / Hosting

- [ ] Move from GitHub Pages to CF Pages or a real server (needed for custom HTTP headers)
- [ ] Point moneycircle.finance to new host; update DNS at Porkbun
- [ ] Verify HTTPS enforced end-to-end (currently GitHub Pages handles this)

---

## Security Headers

GitHub Pages can't set these. Requires CF Pages, CF Worker, or nginx in front.

- [ ] `Content-Security-Policy` — lock down script/style/font sources
- [ ] `X-Frame-Options: DENY` — prevent clickjacking
- [ ] `Strict-Transport-Security` — force HTTPS for 1yr + subdomains
- [ ] `X-Content-Type-Options: nosniff`
- [ ] `Referrer-Policy: strict-origin-when-cross-origin`
- [ ] `Permissions-Policy` — disable camera/mic/geolocation

---

## Privacy / Legal

- [ ] **Privacy policy page** — required once waitlist form submits to a real backend. One-pager: what email is collected, how it's used, no selling, right to delete.
- [ ] **Terms of service** — required before anyone puts real money in a pool. Cover: pilot is experimental, not FDIC insured, not financial advice, smart contract risk disclosure.
- [ ] **Cookie banner** — NOT needed now (site sets zero cookies). Needed if analytics added.
- [ ] **GDPR/CCPA notice** — lightweight notice on waitlist form: "We'll only use your email to notify you when Pot launches."

---

## Security Files

- [ ] `security.txt` at `/.well-known/security.txt` — contact email for vuln disclosure, links to ARCHITECTURE.md audit targets
- [ ] `robots.txt` — allow all for now, revisit when app routes exist

---

## SEO / Discovery

- [ ] `sitemap.xml` — single-page for now, add app routes as they're built
- [ ] Submit to Google Search Console once sitemap is live
- [ ] OG image — currently no `og:image` tag; add a branded card (1200×630) for Twitter/Discord link previews

---

## Fonts

- [ ] Self-host Google Fonts (Playfair Display + Inter) to eliminate third-party request on load. Download WOFF2, serve from `/fonts/`, update CSS `@font-face`. Removes one external dependency and speeds up load.

---

## Waitlist / Backend

- [ ] Replace `mailto:` waitlist form with a real submission endpoint (Resend or simple Flask endpoint on HP)
- [ ] Store emails in a flat file or SQLite with timestamp + goal field
- [ ] Confirmation email on signup: "You're on the list. We'll reach out when the first circles form."
- [ ] Admin view: list of signups with goals (medical bill / car / down payment / etc.) — useful for sizing first pools

---

## App Integration

- [ ] Nav "Join the waitlist" CTA → swap for "Launch app" when app is live
- [ ] Add `/app` link in nav once frontend is deployed
- [ ] Pool invite links from the app should deep-link to a landing page explaining what the invitee is joining

---

## Analytics (Privacy-respecting)

- [ ] Add GoAccess or Plausible (no cookies, GDPR-compliant) once on a real server
- [ ] Track: page views, calculator usage (which mode, which tier), waitlist conversions

---

## Before Any Real Money

These are hard blockers — nothing goes to mainnet without them:

- [ ] Code4rena or equivalent audit of all three contracts
- [x] Chainlink VRF replacing `block.prevrandao` for rotation randomness — **DONE 2026-06-24** (VRF v2.5, two-phase start; see ARCHITECTURE.md gap #2). Ops blocker remains: fund the factory's VRF subscription before launch.
- [ ] Disband/refund accounting implemented in PotPool
- [ ] Stake deposit mechanism implemented
- [ ] Treasury wallet address locked in (passed to PotFactory constructor at deploy)
- [ ] Legal review of money transmission exposure in target launch states
