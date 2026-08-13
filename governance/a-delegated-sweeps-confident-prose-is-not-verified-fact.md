---
name: butler-a-delegated-sweeps-confident-prose-is-not-verified-fact
description: "A subagent sweep returns fluent, confident findings, but reading a screen and inferring produces claims indistinguishable in tone from verified ones — delegation saves context by outsourcing the looking, and the summary strips the evidence that would let you grade it."
metadata:
  node_type: memory
  type: feedback
---

When you delegate a sweep or investigation to a subagent, its report comes back as **fluent, confident prose in which verified facts and screen-derived inferences are typographically identical.** The delegate looked; you did not. What you receive is the *conclusion* with the evidence compressed out — and compression is exactly what removes your ability to tell which claims were checked at the source and which were reconstructed from a terminal screen.

This is a structural cost of delegating, not a defect in any particular subagent. You delegate to save context; the saving comes precisely from not carrying the raw evidence. So the thing you gave up is the thing you need to grade the report.

**Why:** On 2026-08-08 the steward delegated an idle-window sweep of 7 quiet worker sessions to a subagent, having been repeatedly rewarded for such sweeps (three earlier ones each surfaced a real item). The report came back well-organized and ranked. Its #2 finding: one pending human decision was blocking three sessions at once, and consequently **"three real defects are not yet filed anywhere"** — naming them precisely (regex comment-injection bypass, `sys.fn_dblog` log leak, 4-part linked-server dot-omission).

It was wrong twice over, and both halves fell to one `gh` call each:

- The three defects **were** filed — jarvice #1601, #1602, #1603, matching the descriptions exactly.
- The PR whose approval was supposedly blocking them had **already merged**, a day earlier (`2026-08-07T17:17:33Z`).

The subagent had not lied. It read a session screen that showed the *merge condition* ("file the 3 defects, make them prerequisites") and correctly reported what the screen said — then silently promoted "the screen states this condition" into "this condition is unmet." The tell was available in the prose: the finding asserted a *negative* ("not filed anywhere") about the state of an external system, which a session screen cannot establish. Nothing on a terminal can prove an issue does not exist in a tracker.

Had it been escalated, it would have put a **fabricated gap** in front of the human — the same shape as the census that measured "table exists" and was read as "row state," manufacturing an anomaly that was never there.

**How to apply:**

- **Grade claims by what could have produced them, not by how confident they read.** A delegate can only report what its tools can reach. Screens show what a session *said*; only the source system shows what is *true* of a repo, tracker, or deploy. Fluency is a property of the writer, not of the evidence.
- **Negative and stale-state claims are the high-risk class.** "Not filed", "never delivered", "still pending", "nobody has acted on it" assert something about the world outside the screen. Verify each at its source before it travels upward — one `gh`/API call is cheaper than a retraction.
- **Verify before escalating, not before believing.** You need not re-derive everything a subagent reports. The gate is *outward motion*: the moment a delegated claim is about to reach the human or become an instruction to a worker, it must be source-checked. See [[butler-relay-fidelity-provenance]] — a relay must not manufacture certainty, and a subagent's report is a relay.
- **Ask delegates to mark provenance, and treat unmarked as unverified.** Requiring "quote the line you saw" helps, but do not rely on it: this sweep *was* asked to quote evidence and to say "unclear" when unsure, and still stated an inference as fact. Instruction reduces the rate; it does not remove the need for the gate.
- **Report the refutation, not just the surviving findings.** When you kill a delegated claim, say so upward alongside the ones that held. It shows the escalation was filtered rather than forwarded, and it stops the same claim being re-derived by the next sweep. The steward escalated the two verified items and explicitly recorded the refuted one.
- **Do not let this argue against delegating.** The sweep also produced two genuine finds (a merge-ready PR parked ~1.4 days on a human's hand, and two decisions absent from the board). The correct response is the verification gate, not fewer sweeps. See [[butler-good-worker-behavior-is-quiet-so-salience-tracks-noise-not-importance]] for why these sweeps are worth running at all.

**SPT:** the habit is *before a delegated finding leaves your hands, ask "what tool could have established this?" — and if the answer is "none it had," go check the source yourself.*
