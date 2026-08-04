---
name: butler-classify-before-you-preserve
description: "Under data-loss alarm the instinct is to preserve first and understand later — and preserving an unclassified working tree can COMMIT A MASS REVERSION. A dirty tree may be BEHIND HEAD, not ahead of it. Classify read-only first: is this content the tree is ahead on, or content it is missing?"
metadata:
  node_type: memory
  type: feedback
---

When you find uncommitted work and think "this is at risk, preserve it" — **classify read-only FIRST, preserve second.** A dirty working tree can be *behind* HEAD rather than ahead of it, and committing it then reverts real work.

The alarm itself is what makes this dangerous: data-loss urgency pushes toward preserve-first-understand-later, and that ordering is precisely backwards.

**The question to answer before any commit:** is this content the tree is AHEAD on (genuinely at risk), or content the tree is MISSING (a stale snapshot, where preserving means reverting)? `git status --porcelain` cannot tell you — it shows *that* a path differs, never *which direction*. An `A` (added) line looks identical whether the file is new work or a stale re-add of something already upstream.

**Why:** 2026-08-04. The steward found 368 uncommitted entries in a shared jarvice checkout, saw `A backend/open_webui/cli/backfill_chat_turns.py` among them, and escalated it as "real Phase 0 work sitting unversioned — live data-loss exposure," instructing the worker to preserve the real work.

It was backwards. The worker classified first and found every diff was a removal/reversion relative to HEAD, with zero additions — the tree was an older snapshot, not ahead of anything. The chat_turn files were byte-identical (sha256-verified) to content already pushed on two origin branches, so nothing had ever been uniquely at risk.

**Had the preserve instruction been executed faithfully, it would have committed a mass reversion:**
- reintroduced a documented alembic inline-comment bug (#1472),
- removed a `TEST_POSTGRES_URL` env var, silently *skipping* cross-tenant isolation tests in CI,
- stripped six live sections out of `CLAUDE.md`.

A self-inflicted regression across three axes, from an instruction whose stated purpose was safety. The only reason it cost nothing was that the same dispatch had specified classify-read-only-first — so the ordering, not the judgement, is what saved it.

**The underlying error was inferring from a signal instead of checking the referent.** Porcelain status letters are a signal that a path differs; they are not the content. The same steward had, hours earlier, quoted a human's words off a truncated terminal screen and lost the clause that carried the whole meaning. Same shape: a signal treated as the thing it signals.

## How to apply

- Before preserving anything: diff against HEAD and ask **which direction**. All-removals means the tree is behind — preserving would revert.
- Verify whether the content already exists upstream. `sha256sum` against the same path on candidate origin branches settles it in seconds; "it looks like real work" does not.
- If it IS at risk, preserve to **git, pushed to origin** — not to `/tmp` scratch, which does not survive a session boundary.
- Keep the destructive step separate and scoped: tracked files only, no `git clean -fdx`, list untracked leftovers before removing them (untracked is the one category a "tree is behind" analysis cannot cover — an untracked file has no HEAD counterpart to be behind).
- A stale *shared* checkout is not neutral even when nothing is at risk: every reader, including your own subagents, gets the old snapshot. That is a reason to reset it, independent of the data-loss question.

Related: [[quote-from-the-transcript-not-the-screen]] (the same signal-vs-referent error), [[the-tracker-keeps-claiming-work-that-already-shipped]] (records that misdescribe reality in the safe-seeming direction), [[subagent-destructive-op-scoping]] (scoping the reset once it is justified).
