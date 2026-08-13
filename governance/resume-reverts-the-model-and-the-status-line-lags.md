---
name: butler-resume-reverts-the-model-and-the-status-line-lags
description: "Resume/--continue reverts a worker to its ORIGINAL model (a pre-restart /model line in scrollback is replayed history), and the status line lags until a redraw is forced — but note this was ALREADY recorded in model-switch-lands-after-compaction and still went unrecalled, so the live failure is recall, not absence."
metadata:
  node_type: memory
  type: feedback
---

**Read this first: the mechanism below was already in the store, and we re-derived it from scratch anyway. That recall failure is the more important half of this note.**

Two facts about restoring a fleet:

1. **`--continue`/resume does not preserve a mid-session model switch.** A resumed session comes back on its ORIGINAL/default model. A `/model sonnet` line in the resumed scrollback is *replayed history from before the restart*, not evidence of the live model.
2. **The status line lags a model switch** until something forces a redraw. A model figure on screen is a claim, not an observation.

So the **post-resume model sweep is required every time**, verified with `/model <name>` then `/context` to force the redraw.

**Why — and the part that actually matters:** After the 2026-08-11 ~22:22 reboot, the butler relaunched 14 workers with `--continue`, saw the canary (monocle-iros) come back on Sonnet-5, and told 정수님 the model-reset step was "no longer necessary." Five workers had silently reverted to Opus-5 — real money at a budget-cycle tail. The canary proved nothing: Sonnet was *already iros's original model*, so it was never a test of preservation. n=1, and a true observation licenses only its own scope.

The steward caught the drift by diffing the live session list against the 19:14 dashboard, then mis-assigned the mechanism — seeing `/model sonnet` "succeed" while the status line still read Opus-5, it concluded "the confirmation message lies, verify by the status line." Backwards, and asserted while the butler's own CTX=0 finding (that same status line failing to recompute after `/compact`) was already pointing the other way. The butler settled it with a clean control on an untouched Opus worker: alias + `/context` → Sonnet-5. The alias works; the confirmation line was truthful; the status line was the stale instrument.

**And then, on review, the store already contained [[model-switch-lands-after-compaction]]: "Compaction and resume restore the session to its previous model; pre-compaction switches are silently reverted."** The answer was written down before the evening started. Two agents ran a controlled experiment to rediscover it, and the butler asserted the opposite to 정수님 while the correct principle sat in the store unread. Nobody searched first — despite [[search-for-the-existing-decision-first]] also being in the store.

This store now holds ~180 principles, four of them on model-switching alone ([[model-display-may-differ-from-requested-model]], [[model-switch-lands-after-compaction]], [[switching-a-sessions-model-invalidates-its-cache-and-opens-a-wizard]], this one). Past a certain size, writing another note is not the fix — it lowers recall for every note. Treat that as a live structural problem, not a filing question.

**How to apply:**
- **Before recording a new principle or running an experiment to establish a fact, grep the governance store.** Tonight's cost was not ignorance; it was 180 notes and no lookup.
- After ANY resume of a fleet, re-sweep every worker's model. Never accept canary evidence — a worker whose target model equals its default is not a test of preservation.
- Verify with `/model X` then `/context`. Never read the status line as fresh.
- Detect drift by diffing the live session list against the last dashboard snapshot; that diff is what surfaced this.
- Do NOT blanket-convert every off-default worker. A deliberate hold (monocle-security on Opus) may itself be an open question before 정수님 — converting it silently moots his decision. Convert only what DRIFTED; surface the rest.
- When a resumed worker just finished compacting, reverting its model costs a re-read; that expense makes it the human's call.
- When two instruments disagree, build the control that separates them rather than picking the liar by intuition — but only after checking whether the answer is already recorded.

Related: [[a-true-observation-licenses-only-its-own-scope]], [[check-the-artifact-before-the-instrument]], [[two-views-of-one-sensor-are-not-corroboration]], [[institutionalize-learning]].
