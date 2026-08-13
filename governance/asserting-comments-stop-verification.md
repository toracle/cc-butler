---
name: butler-asserting-comments-stop-verification
description: "A comment, doc, or citation that asserts a safety property is where checking stops — the claim reads as settled, so nobody tests it, and it survives precisely because it sounds authoritative."
metadata:
  node_type: memory
  type: feedback
---

Prose that asserts a property — a code comment, a CLAUDE.md line, a citation to
another file — does not merely fail to verify that property. **It actively
prevents verification**, because a reader who encounters a confident claim treats
the question as already answered and moves on.

The danger scales with how authoritative the prose sounds. *"An unrecognised ENV
is treated as production"* reads like someone thought about it. *"This is
hard-gated"* reads like someone checked. Neither is evidence.

**Why:** Four instances on 2026-08-09, all in one PR's neighbourhood, three of
them by a worker that was otherwise catching its own errors continuously:

1. **A comment asserting fail-closed, on code that was fail-open.** The author
   wrote *"an unrecognised ENV is treated as production"* — then never checked
   what an **unset** ENV does. It defaults to `"dev"`, which was inside the
   allowlist. Their own words: *"the comment asserting fail-closed is what made
   me stop looking."*
2. **A project doc read as a fact about runtime.** `CLAUDE.md` said
   *"LoggingIntegration is not configured"* — true only as "not explicitly
   listed." It is active as a **default** integration, which the same worker had
   **empirically proven hours earlier** by tracing an exception into Sentry. The
   doc's phrasing beat its own measurement, and nearly shipped a test comment
   contradicting a dependency filed on two issues.
3. **A comment claiming another file was safe.** *"That code is hard-gated"* —
   discovered false only when the author deleted their own copy of the hatch.
   That third file gated on `ENV == "prod"` while deployment sets `prd`.
4. **A citation to a line nobody reopened.** Arguing a file was unaffected, the
   author cited `mcp_client.py:50`, which does handle `{"prod","prd"}` correctly
   — but that line is a **cache TTL**. The real gate is line 446, broken the same
   way. Citing without reopening nearly lost an SSRF-guard bypass.

Instance 4 happened **while documenting instances 1-3.** Naming the pattern
conferred no immunity — see [[butler-naming-a-trap-precisely-is-not-avoiding-it]].

The tell across all four: the claim and the code were written by the same person
at the same time, so the comment records **what they intended**, not what the
code does. Later readers — including the author — read intent as fact.

**How to apply:**

- **Treat an assertive comment as an unverified hypothesis with a citation
  attached.** The stronger it sounds, the more it has suppressed checking.
- **Assert properties in tests, not prose.** *"Unset ENV must not open the dev
  hatch"* belongs in a test that fails, not a sentence that reassures.
- **Reopen the line before citing it.** A file that is right in one place can be
  wrong three hundred lines down; correctness is not a property of files.
- **When your own measurement contradicts a doc, the measurement wins** — then go
  fix the doc, because it will mislead the next person exactly as it misled you.
  (Here: a separate issue was filed for the CLAUDE.md wording.)
- **Suspect prose most where it defends.** Comments explaining *why something is
  safe* are where this concentrates, because nobody re-derives a reassurance.
- **When a fix invalidates a comment, treat the comment as a finding.** Deleting
  the hatch is what exposed the "hard-gated" claim — an edit that makes prose
  false is a signal to check what else that prose was holding up.

**SPT:** the habit is *when a comment tells you something is safe, ask what test
would fail if it weren't — and if none exists, you have found the gap, not the
guarantee.*
