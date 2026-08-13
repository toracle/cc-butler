---
name: butler-a-blacklist-gate-is-one-step-behind-the-instrument
description: "A guarantee that correctly certifies the absence of every hazard it NAMES gets read as certifying correctness — blacklist gates, and any true-but-scoped assurance whose key word quietly does quantifier work. Prefer a positive equivalence check asserting what the output must equal"
metadata:
  node_type: memory
  type: feedback
---

A validity gate written as **a list of known-bad signatures** — "check for odd quotes, check for trailing dashes, check for these stderr warnings" — is structurally **one step behind the instrument it guards**. It can only catch failure modes already observed when the gate was frozen. A defect introduced afterward passes cleanly, and the pass is read as validation.

Prefer a **positive equivalence check**: assert what the output *must equal*, derived from its source. That is a property of correctness rather than a catalogue of known wrongs, so it catches failure modes nobody anticipated — including the next one.

## The general shape (this is the part that transfers)

**A statement that is precisely correct about the hazard it names is the one most likely to be over-trusted about the hazard it does not.** The error is never in a proposition — every clause checks out. It lives in **the scope of a word doing quiet quantifier work**, and it survives review because the reviewer verifies the clause, and the clause is true.

Two instances from one night, 2026-08-13, which is what exposed the shape:

- **A blacklist gate** correctly certifies the absence of every defect it lists, and is read as certifying *correctness*.
- **The steward told a worker** that since two audit rounds shared the same estimator bias, "the delta is the meaningful quantity" — safe. True of **bias**. The word "safe" silently extended the guarantee to **noise**, which it never covered: if instrument variance is wide, an unchanged `6/24 → 6/24` is exactly as uninformative as a moved one. The worker caught it and named why it endures: *"it survives review because the reviewer checks the clause that's true."*

So the defense is not "check the claim" — the claim is fine. It is: **name the hazards the guarantee does NOT cover, in the same breath as the guarantee.**

## Why (the originating incident)

The `monocle-skills` #69 trigger-eval audit. Gate condition A2 was a blacklist: zero odd-quote signatures, zero truncation signatures, zero stderr WARNs. It passed **literally and completely — all three counts 0 across 104 prompts**, both pre-run and post-run.

It was not valid. `clean_prompt()` collects every `"…"` span in a bullet and joins them, and commit `b6e68ce` (#95) had made `extract()` join continuation lines — pulling each bullet's own `**Checks:**` commentary into the bullet, so the commentary's quoted phrases were appended to the transmitted prompt:

    verify-first__pos1 → "How will we know this is done? how will we know it's done"

The appended text is **the skill's own quoted trigger phrases — the very thing under test.**

**Then the measurement showed this is worse than bias.** Of `verify-first`'s three cases, the two contaminated ones **fired** and the one clean case **missed**. The summary table prints `verify-first 2/3`, which reads as one of the corpus's better performers. The honest result is **n=1, 0/1 — a miss**. Contamination did not tilt the result; it **manufactured** it and pointed it *opposite* to the clean case. The instrument emitted a confident, plausible, well-formatted, **green-gated, exactly-backwards** result.

Note also that #95 was itself a fix for an *earlier* prompt-construction defect (truncation). It traded one defect for another, and the gate — frozen before #95 landed — had no entry for the new one. A positive equivalence check (*the transmitted prompt must equal the first quoted span of its source bullet*) would have caught **both**, knowing about neither in advance.

## How to apply

- Writing or reviewing a gate: ask *does this enumerate known wrongs, or assert a required property?* If the former, find the invariant it approximates and assert that.
- Treat "the blacklist passed" as **weak** evidence and say it that way in the record: "none of the failures we already knew about," never "valid."
- **State a guarantee's uncovered hazards beside it.** "Both rounds share the bias" is fine; "so the delta is safe" is not, unless noise has also been bounded.
- A gate frozen at time T cannot cover a change landed after T. When the instrument changes, the gate's coverage silently shrinks — check what it does *not* ask about, not merely whether it passed.
- Be most alert where a defect biases toward the *expected* answer, and where the affected case is a **first** measurement with no baseline — together, nothing downstream will ever contradict the bad number.
- Gate changes are not the executing agent's to make. File the equivalence check as a **proposal with its evidence** (here: warmblood-kr/skills #99, #100); do not apply it mid-run.
- When a result is discarded as instrument-contaminated, **report the surviving n explicitly** (`n=1, 0/1`, never `2/3`) and record *why* in the results themselves, not only in a defect write-up — a reader finding a bare `n=1` later assumes oversight and either discards it or re-runs to "fix" it.

Related: [[butler-a-true-observation-licenses-only-its-own-scope]] (the sibling failure — a true *observation* whose conclusion covers more ground than the evidence; this note is about a true *guarantee* covering fewer hazards than it is read to), [[butler-a-test-that-cannot-fail-is-not-evidence]] (the same session's wrapper `echo` would have reported canary success regardless of the script's real exit code), [[butler-fixing-one-instrument-flaw-does-not-validate-the-instrument]], [[butler-a-banner-reading-is-not-a-measurement]].
