# Contributing to Pot

Thank you for looking under the hood. Pot holds people's savings, so the bar for changes is higher than a typical app. The single most useful thing you can do is help make the contracts safe enough to trust.

---

## The one principle: audit first

Pot is, at its core, a contract that custodies pooled money and releases it on a schedule. **A bug here is not a crash — it's lost savings.** Before any feature, optimization, or refactor:

1. **Correctness and safety come before everything.** A clever gas optimization that introduces a reentrancy surface is a regression, not an improvement.
2. **Every change to a contract needs a test that would have failed before the change.** No exceptions for "obvious" fixes.
3. **The known gaps in [ARCHITECTURE.md](ARCHITECTURE.md#known-gaps--audit-targets) are the priority backlog.** If you want to make the biggest impact, close one of those — with a test — before adding anything new.

We would rather merge a small, well-tested fix to an existing weakness than a large new feature.

---

## What we most want help with

In rough priority order:

1. **Audit findings.** If you're a Solidity auditor, the highest-value contribution is a written finding against the contracts — especially the items already flagged: weak rotation randomness, the full-wipeout payout path, the unimplemented stake-deposit and disband-refund accounting, and reentrancy verification on `_payout`.
2. **Test coverage.** The Foundry suite in [`test/PotPool.t.sol`](test/PotPool.t.sol) has real happy-path tests and clearly-marked `testTODO_*` stubs for each audit target. Turning a stub into a real, passing test is a perfect first contribution.
3. **The stake-deposit mechanism.** Specified but not yet on-chain: each member locks one round's contribution at join, released at close, forfeited to the remaining members if ejected post-payout. This needs a careful design and a full test of the lock → release → forfeit lifecycle.
4. **Chainlink VRF integration.** Replacing `block.prevrandao` for the rotation shuffle.
5. **Frontend / indexer.** There is no on-chain pool discovery beyond the factory's index; the frontend must index `PoolCreated`, `ContributionReceived`, `PotPaid`, and `MemberEjected` events. Help building that indexer is welcome.

---

## Development workflow

```bash
# Fork, clone, then:
npm install
npm run compile
npm test                # Hardhat
forge test -vvv         # Foundry (install forge-std + OZ first; see foundry.toml)
```

1. **Branch** off `main` with a descriptive name (`fix/payout-wipeout-guard`, `feat/stake-deposit`).
2. **Write the test first** where you can. For a bug fix, write the failing test, then fix it.
3. **Keep contract diffs small and legible.** Reviewers must be able to reason about every line touching money.
4. **Run the full test suite** before opening a PR. CI runs both Hardhat and Foundry.
5. **Open a PR** that explains *why*, not just *what* — and call out any new external-call surface or storage-layout change explicitly.

### Style

- Solidity `^0.8.20`, optimizer on, `viaIR` enabled (the pool's lifecycle methods are stack-heavy).
- Favor explicit `require` messages.
- Preserve **Checks-Effects-Interactions** ordering in any function that moves USDC. If you change the order, say so in the PR and justify it.
- Comment the *why* of a design decision, not the *what* of the syntax.

---

## Security disclosure

**Please do not open a public issue for a vulnerability that could lead to loss of funds.**

If you find a security issue in the contracts:

1. Email **laurens.whipple@gmail.com** with a description and, ideally, a proof-of-concept test.
2. Give us a reasonable window to respond and patch before any public disclosure.
3. We will credit you in the release notes for the fix unless you prefer to remain anonymous.

For non-sensitive bugs, design questions, or anything that can't move money, a public GitHub issue is the right place.

---

## Code of conduct

Be the kind of collaborator you'd want in your own savings circle: reliable, plain-spoken, and respectful. Assume good faith. Review code, not people.
