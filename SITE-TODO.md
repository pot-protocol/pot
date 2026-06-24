# Proper Site — What Needs Doing

This is the punch list for graduating from the GitHub Pages pilot to a real production site.

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
- [ ] Chainlink VRF replacing `block.prevrandao` for rotation randomness
- [ ] Disband/refund accounting implemented in PotPool
- [ ] Stake deposit mechanism implemented
- [ ] Treasury wallet address locked in (passed to PotFactory constructor at deploy)
- [ ] Legal review of money transmission exposure in target launch states
