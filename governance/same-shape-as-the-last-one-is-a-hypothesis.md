---
name: butler-same-shape-as-the-last-one-is-a-hypothesis
description: "'It's the same shape as that thing we just found' is pattern-matching presented as observation — two identical-looking symptoms routinely have different causes and different fixes"
metadata:
  node_type: memory
  type: feedback
---

Recognising that a new problem resembles one you just solved feels like expertise, and it is the cheapest kind of wrong. **A resemblance is a hypothesis about cause, not an observation of it.** Two things can present identically — same symptom, same surface, same conditions — and have different causes, which means different answers to "so what do we do."

The recent finding is the dangerous one. A pattern you learned an hour ago is vivid, feels earned, and gets applied with more confidence than one from a textbook.

**Why:** On 2026-08-05, jarvice PR #1551 had an empty GitHub Checks tab because its base was a feature branch rather than `devel`, so the test workflow never triggered — CI had in fact passed, run manually. A few hours later, monocle PR #450 also showed an empty Checks tab, also based on a non-default branch. The steward said "same shape as #1551," the butler relayed it to 정수님 as fact, and it went into his queue as "monocle has the same CI trap."

It does not. The worker checked by listing the directory rather than reasoning from similarity: **`warmblood-kr/monocle` has no `.github/workflows/` at all.** It is a compose/bootstrap repo, not a code repo. #1551's empty tab is a *trigger* problem with a workflow that exists; #450's is the absence of any CI. Identical screens, unrelated causes — and the remedies diverge completely: #1551 needed its base merged first, #450 needs a line in the PR body so an empty tab is not misread as "untested."

The same investigation produced the companion error in the other direction: noticing that both `cc-butler` and `monocle` lack CI and nearly filing them together. One is a genuine gap (filed as cc-butler#51); the other is correct by design. Grouping by symptom would have manufactured a problem.

**How to apply:**

- When you or anyone says **"this is the same as X"**, treat that sentence as the claim under test, not as the finding. Name what would distinguish the two causes, and check it. It is almost always one cheap command — here, listing a directory.
- Weight *recent* analogies as more suspect, not less. Vividness is not evidence.
- Distinguish **identical symptom** from **identical mechanism**. If the remedies would differ, the mechanisms differ, and the analogy has already failed.
- A manager relaying an analogy strips its epistemic status: it arrives at the next reader as a finding. If you cannot personally verify it, relay it as *"reportedly, unverified"* — or check it first.
- Symmetrically, do not group two things because they share an absence. "Neither has CI" was true and useless; one absence was a defect and the other was the design.

See also [[butler-known-flaky-is-a-claim-not-a-diagnosis]], [[butler-a-fork-is-usually-inherited-not-derived]], [[butler-steward-relay-claims-with-their-status]], [[butler-your-own-assumption-returns-as-corroboration]].
