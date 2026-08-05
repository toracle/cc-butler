---
name: butler-a-threshold-is-not-a-cliff-check-the-denominator
description: "'The steward raised an urgent 'we'll lose the session mid-fix' alarm off a 285k/300k reading — 285k was 29% of a 1M window and 300k was a policy trigger, not a wall. Before escalating a number, establish its unit, denominator, and whether the limit is a cliff or a nudge.'"
metadata:
  node_type: memory
  type: feedback
---

A number is not a signal until you know its **denominator** and what kind of limit it is being compared against. A **policy threshold** (a nudge: "time to tidy up") and a **hard limit** (a cliff: "past here you lose the work") produce identical-looking "X of Y" readings and warrant completely different responses. Escalating the first as if it were the second manufactures urgency, and urgency is expensive — it reorders other people's work.

**Why:** On 2026-08-05 the steward watched the scheduler session climb from 270k to 285k against `session_status`'s displayed "Threshold: 300k" and raised a time-sensitive alarm to the butler: *"픽스 도중에 천장을 치면 가장 비싼 순간에 잃습니다"* — recommending the session be compacted right before implementation, mid-track, on the one live thread of the night.

The session's own statusline read `CTX=285272 29%`. **285k was 29% of an approximately 1M window** — roughly 71% still free. The 300k figure was cc-butler's *policy* trigger for when compaction is worth doing, not a model wall. Nothing was about to be lost. The recommended intervention — interrupting a healthy session mid-investigation, while the human was live in it — would have been pure cost.

The steward caught it by finally reading the percentage that had been on screen the whole time, and retracted the alarm in the same channel, withdrawing the interrupt-before-implementation proposal while keeping the file-the-issue-first recommendation (which was correct for an unrelated reason: the issue body *is* the externalization).

This was the **second instance the same night** of the same shape. Earlier, `git diff` reported 13 governance files as divergent from the preservation branch; a byte-level comparison showed only 2 genuinely differed — the other 11 were an index artifact of diffing against untracked paths. That one was caught *before* reporting. This one was caught *after*.

**How to apply:**

- **Before turning a number into an alarm, establish three things:** its unit, its denominator, and whether the limit it approaches is a cliff or a nudge. "285k against a 300k threshold" and "29% of capacity" are the same measurement with opposite implications.
- **Read the whole instrument.** The percentage was already on the statusline next to the raw figure. The failure was not missing data; it was reading the field that confirmed the worry and stopping there.
- **Treat a displayed "Threshold" as a policy default until you learn otherwise.** Tools surface thresholds to prompt routine maintenance far more often than to warn of loss. Ask what happens *at* the number before acting as if it were catastrophic.
- **Weigh the cost of the intervention, not just the risk.** The proposed remedy was to interrupt the night's only live track, mid-investigation, with the human present. A remedy that disruptive deserves a verified premise. See [[butler-an-anomaly-may-be-the-humans-own-hand]] — same discipline, one step earlier.
- **Retract in the channel you alarmed in, and say what changes.** Not just "I was wrong": name which recommendation dies (compact before implementation) and which survives on independent grounds (file the issue first, because the issue body is the externalization). A vague retraction leaves the recipient unsure what to still act on.
- Related: [[butler-establish-content-identity-before-assuming-divergence]], [[butler-known-flaky-is-a-claim-not-a-diagnosis]].

**SPT:** the habit is *when a number alarms you, find its denominator before you find your audience.*
