# Pot

**Money circles that work.**

Pot is a digital susu — a rotating savings and credit association (ROSCA). A small group of people each contribute the same amount every week or month, and each round one person receives the whole pot. The cycle repeats until everyone has been paid once. A smart contract enforces the rotation, holds the money, and keeps an on-chain record of who shows up.

> **Pot is what credit was supposed to be.** No interest. No approval process. No bank. The community is the underwriter.

---

## Why this exists

Susu is not a new idea. West African, Caribbean, and South Asian diaspora communities have run rotating savings circles for centuries — funding weddings, cars, businesses, and down payments out of nothing but pooled income and mutual trust. *Susu*, *partner*, *tanda*, *chit fund*, *hui*, *ajo*, *esusu* — every culture that got locked out of formal credit reinvented the same tool.

It works. It just never scaled past your social circle, because **trust doesn't scale.** You can only run a susu with people you already know well enough to vouch for.

Pot adds the one piece that was always missing: a **portable, on-chain record of reliability** — the Pot Score. It lets a stranger see that you've completed eleven circles on time, and lets you join theirs on that basis. The trust that used to live only inside a family or a church or a block now travels with you.

That's the whole thesis. Everything else is plumbing.

---

## The ladder

Pot is built to be climbed. You start small with people you know, build a record, and unlock larger circles as your reliability is proven.

| Tier   | Pool                  | Contribution | Payout    |
| ------ | --------------------- | ------------ | --------- |
| Seed   | 10 people · 10 weeks  | $25 / week   | **$250**  |
| Circle | 10 people · 10 weeks  | $100 / week  | **$1,000** |
| Fund   | 10 people · 10 months | $300 / month | **$3,000** |
| Major  | 10 people · 12 months | $500 / month | **$6,000** |
| Home   | 10 people · 12 months | $1,000 / month | **$12,000** |

Start with $25 a week. End with a down payment. Same mechanism, all the way up.

---

## How a circle works

1. **Create.** Someone sets the terms: 2–10 members, a contribution amount ($25 minimum), and an interval (weekly or monthly).
2. **Join.** Members join and lock in. Private circles are invite-only; public circles are gated by Pot Score.
3. **Rotate.** When the circle is full, a payout order is randomly assigned and **locked on-chain** — no one can change it, not even the creator.
4. **Contribute.** Each round runs for the full interval — a week or a month. Once everyone has paid in, the contract automatically releases the full pot to that round's recipient.
5. **Grace & ejection.** After the deadline, a 48-hour grace period covers late payers. Miss it and anyone can settle the round: defaulters are ejected — with a permanent mark on their Pot Score — and the pot is released to whoever's turn it is.
6. **Close.** The circle ends clean when every member has received the pot exactly once.

The person who receives the first payout isn't getting charity. They're receiving the trust of the other members, who chose to fund them first. Everyone contributes equally; everyone receives exactly what they put in. **Giving is asymmetric. Pot is symmetric.**

---

## The Pot Score

Reputation is the product. The Pot Score is a **soulbound** (non-transferable) token — one per wallet, permanent — that records your demonstrated reliability across every circle you've ever joined.

- **Builds on:** pools completed, on-time contribution rate, longest clean streak.
- **Damaged by:** missed rounds (a permanent mark) and ejections.
- **Gates access:**
  - Score 0 → friends-and-family circles only.
  - 1–2 clean pools → semi-open circles.
  - 3+ clean pools → public circles with strangers.

The composite score runs 0–1000:

```
score = (poolsCompleted × 50)
      + (onTimeRate% × 4)
      + (bestStreak × 10)
      - (missedRounds × 75)
```

You can't buy reputation. You can't transfer it. You can only earn it, one circle at a time, by showing up.

---

## Stack

| Layer            | Choice                                                       | Why                                                              |
| ---------------- | ----------------------------------------------------------- | --------------------------------------------------------------- |
| Chain            | **Base** (L2)                                                | Cheap gas, Coinbase-backed, USDC-native.                        |
| Settlement asset | **USDC**                                                    | A dollar is a dollar. No volatility, no crypto math for members. |
| Wallets          | **Privy** (email login → embedded wallet)                   | No seed phrases. You sign up with an email.                      |
| Contracts        | **Solidity** + Hardhat / Foundry                            | Three contracts, fully on-chain lifecycle.                      |
| Frontend         | **Next.js** + Tailwind                                       | Fintech aesthetic — dollars, not tokens; warmth, not chrome.    |

Members never see a block explorer, a gas fee, or the letters "USDC." They see dollars and a circle of people.

---

## Contracts

Three contracts, top-down:

- **[`PotFactory.sol`](contracts/PotFactory.sol)** — the single entry point. Deploys every pool, authorizes each one to write reputation, indexes them for discovery, and enforces score-gating on public-pool creation.
- **[`PotPool.sol`](contracts/PotPool.sol)** — one instance per circle. Owns the entire lifecycle: join → lock rotation → collect rounds → auto-payout → eject defaulters → close.
- **[`PotScore.sol`](contracts/PotScore.sol)** — the soulbound ERC-721 reputation registry. Lazily mints one token per wallet and accumulates the reliability record that gates everything else.

For the full technical walkthrough — design rationale, the trust invariant, and the explicit list of known gaps and audit targets — read **[ARCHITECTURE.md](ARCHITECTURE.md)**.

---

## Quickstart (local)

> Requires Node 18+. Foundry is optional but recommended for the test suite.

```bash
# 1. Install dependencies
npm install

# 2. Compile the contracts
npm run compile

# 3. Run the Hardhat test suite
npm test

# (Optional) Run the Foundry suite — richer lifecycle coverage
forge install foundry-rs/forge-std
forge install OpenZeppelin/openzeppelin-contracts
forge test -vvv

# 4. Spin up a local chain and deploy
npm run node            # in one terminal
PROTOCOL_TREASURY=0xYourTreasury npx hardhat run scripts/deploy.js --network localhost
```

To deploy to Base Sepolia (testnet), set `DEPLOYER_PRIVATE_KEY` and `PROTOCOL_TREASURY` in a local `.env` and run `npm run deploy:base-sepolia`. See [`hardhat.config.js`](hardhat.config.js) for all environment variables.

**Do not deploy to Base mainnet without a professional audit.** The known weak spots are listed plainly in [ARCHITECTURE.md](ARCHITECTURE.md#known-gaps--audit-targets) — read them first.

---

## Revenue

A **1% protocol fee** is taken from each payout, at the contract level, the moment a pot is released. At 1,000 concurrent circles, that's roughly **$50k / month** — earned by maintaining the rails, not by lending against anyone's income.

---

## Status

**v0.1 — pre-audit.** Contracts are written and unit-tested on the happy path, with edge-case stubs naming every audit target. Pilot circles (Seed tier: 10 people, $50/week, 10 weeks) are forming. This is open infrastructure: the contract holding the money is public, and that's the point.

## Contributing

We especially want eyes from auditors and Solidity engineers. Start with [CONTRIBUTING.md](CONTRIBUTING.md), which covers the contribution flow, the "audit first" principle, and how to report a security issue responsibly.

## License

MIT. See [LICENSE](LICENSE).
