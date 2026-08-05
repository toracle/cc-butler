---
name: butler-a-pr-body-states-intent-verify-the-closure
description: "''Closes monocle#443 / jarvice#1534' in a merged PR closed neither issue — and the steward reported the issue as CLOSED without checking. A PR body declares intent; issue state is a separate fact you must read.'"
metadata:
  node_type: memory
  type: feedback
---

A PR body says what someone **meant** to happen. It is not evidence that it happened. "Closes #123" is a request to a parser, and a request can silently fail — wrong syntax, wrong branch, insufficient permissions, or a keyword that only bound to the first of several references. Before reporting an issue as closed, **read the issue's state**, not the PR's prose.

**Why:** On 2026-08-05 the steward reported to the butler that `jarvice#1534` was not orphaned but already implemented, merged as `#1555`, and **CLOSED**. The first two claims were right and were themselves a good correction of an earlier wrong report. The third was wrong, and it was wrong because the steward read the PR body's closing line and treated it as the outcome.

Measured later the same night, **11.5 hours after the merge**: `#1555` MERGED into `devel` (which *is* this repo's default branch, so auto-close was available), yet `jarvice#1534` OPEN with no `closedAt`, and `monocle#443` OPEN with no `closedAt`. **Neither issue closed. The line closed nothing at all.**

The line was:
```
Closes monocle#443 / jarvice#1534.
```
Two independent defects in one sentence:
- **Bare repo names are not references.** GitHub's closing keywords bind to `#123`, `GH-123`, or `owner/repo#123`. `monocle#443` has no owner and is not parsed as a cross-repo reference; `jarvice#1534`, written from inside `jarvice`, is not a valid same-repo reference either — that one is plain `#1534`.
- **The keyword does not distribute.** `Closes A / B` binds to `A` at best. Each reference needs its own keyword: `Closes #1534` *and* `Closes warmblood-kr/monocle#443`.

The syntax is the trivia. The principle is the reading error: **an artifact that declares an outcome was mistaken for the outcome.** This is the same shape as [[butler-a-tools-success-check-covers-only-its-own-layer]] (a success string is about the layer it checked) and [[butler-externalizing-is-not-delivering]] — and the steward had spent that entire night insisting on exactly this distinction to others before making it itself.

**How to apply:**

- **To report an issue closed, read the issue.** `gh issue view N --json state,closedAt`. The PR body, the commit message, and the changelog all state intent; only the issue's own state is the fact.
- **Write closing lines so they can actually fire:** one keyword per reference, `owner/repo#N` for anything cross-repo. Then **verify after the merge** rather than assuming — the parser gives no failure signal, which is why this rots silently.
- **Auto-close only fires on merge into the default branch.** If a repo's flow merges into a long-lived integration branch that is *not* the default, closing keywords never fire at all and every such issue stays open forever. Check which branch is default before trusting the mechanism.
- **Sweep for the inverse drift periodically:** issues assumed closed because their PR shipped. Work-shipped-but-tracker-open is quieter than the reverse and accumulates. Compare with [[butler-the-tracker-keeps-claiming-work-that-already-shipped]], which is the same desync running the other way.
- **Do not close on discovery.** Finding that a fix shipped is not proof the fix covered the issue's full scope — `#1534` named three audio call sites and nobody had checked all three. A wrongly closed issue loses work. Route it to whoever did the work to verify scope, then close.

**SPT:** the habit is *"Closes #N" is a wish; open the issue and look before you say it closed.*
