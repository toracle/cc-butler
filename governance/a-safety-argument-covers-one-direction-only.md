---
name: butler-a-safety-argument-covers-one-direction-only
description: "'The real gate is downstream' justifies letting a weaker upstream check stand only for things wrongly getting THROUGH — it says nothing about things wrongly being kept OUT, because the downstream gate never runs for those. Ask which direction a scope argument actually covers before accepting it."
metadata:
  node_type: memory
  type: feedback
---

When someone justifies leaving a check weak or approximate with **"that's not the authoritative gate —
the real one is downstream,"** the argument is usually sound. But it is sound in **exactly one direction**:
it covers something bad wrongly getting *through*, because the downstream gate will still catch it.

It says nothing about something legitimate being wrongly **kept out**. And the downstream gate cannot help
there, because **the rejected case never reaches it.** A false-positive at an upstream gate is terminal by
construction.

So a scope argument names a *direction*, not a *territory*. Accepting it as covering both is how a real
defect gets filed as out-of-scope with everyone nodding.

**Why:** jarvice#978, MySQL support (2026-08-05). The wiring worker documented a deliberate boundary: the
save-time SQL pre-check stays on **Postgres dialect regardless of engine**, because "the authoritative gate
remains execution-time re-validation with the real engine." True — a query Postgres parses as safe but MySQL
would treat as dangerous still gets caught at execution. The dangerous direction was genuinely closed.

The other direction was wide open. Postgres dialect **cannot parse ordinary MySQL syntax**: backtick
identifiers (`` SELECT `id` FROM `orders` ``) raise `ParseError`, which becomes `HTTPException(400)`, with no
`try/except` between it and the admin handler. The tool never saves. Execution-time re-validation is
irrelevant — **the user never reaches execution.** A MySQL admin writing a completely ordinary query, on the
feature's very first touchpoint, is simply blocked. (Backticks are near-mandatory in MySQL for reserved-word
columns: `order`, `key`, `group`.)

The boundary was written honestly and reasoned carefully. It was one-directional and read as total.

Two useful sub-lessons from the same incident:
- **A disproved suspicion does real work.** Two syntaxes were checked: backticks (broken) and MySQL-style
  `LIMIT 10, 20` (parses fine). The *negative* result collapsed the scope from "MySQL dialect support may be
  broadly broken" to "identifier quoting only," which is what made the fix small. People under-report checks
  that came back clean; those are half the value.
- **Fixing a false-positive must not manufacture a new one.** The natural fix — resolve the engine, pass it in —
  invited copying the neighbouring endpoint's error handling, which raises **500** on decrypt failure or missing
  `db_url`. Ported to the save path that breaks saves that work today. The save path falls back to the current
  Postgres default instead — justified by *the worker's own original argument*: a pre-check that cannot
  determine the engine should do what it does today, not block the save.

**How to apply:** When you meet a scope boundary — yours or someone else's — do not ask only *"what does this
block?"* Ask **"which direction does this argument cover, and who covers the opposite one?"** For any
"the real gate is downstream" claim, state explicitly what happens to a **legitimate** input the weak upstream
check rejects; if the answer is "it never reaches the real gate," the argument does not cover that case and the
gap is real. Especially suspect this when the weak check is a *parser*, *validator*, or *allowlist* — those
fail closed, so their errors are false-positives by default, precisely the direction a downstream gate cannot
reach.

Related: [[a-fork-is-usually-inherited-not-derived]] (a boundary inherited from a description rather than
derived from code), [[a-test-that-cannot-fail-is-not-evidence]] (an argument locally valid, applied one axis
too far), [[new-variant-completeness]]-style thinking (adding an engine means auditing every place the old
one was assumed).
