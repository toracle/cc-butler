---
name: butler-an-anomaly-may-be-the-humans-own-hand
description: "'The steward diagnosed a compaction tool as defective for leaving butler on a cheap model — 정수님 had set that model deliberately. In a fleet the human also operates directly, an observed state change has two candidate authors, and 'defect' is the one you must earn.'"
metadata:
  node_type: memory
  type: feedback
---

Before calling an observed state change a **defect**, establish **who changed it**. In this fleet 정수님 drives sessions directly — the same sessions the steward monitors — so every observed change (model, branch, config, a file that moved) has at least two candidate authors: the tooling, and him. "The tool is broken" is the *conclusion*, not the starting point, and it is the expensive one to get wrong: it burns a correction cycle, it can produce a "fix" that fights the human's intent, and reported upward it becomes a fabricated bug in someone's backlog.

**Why:** On 2026-08-05, after forcing a compaction of the butler, the steward read its statusline and saw `MODEL=Fable-5` where Opus-5 had been. It diagnosed `compact_session`'s restore step as silently failing under `force=true`, **acted on that diagnosis** by sending `/model claude-opus-5` into the butler's session, and **reported the defect upward** as possibly worth a cc-butler issue.

Every part of it was wrong, and each fell to a check that cost seconds:

- **The premise.** 정수님 confirmed plainly: *"네, Favie 파이브로 설정한 것이 의도적인 것입니다."* The transcript record even showed the order — he had lowered the model to sonnet himself, run the compaction, and set fable afterward. The "anomaly" was his configuration.
- **The intervention.** The `/model claude-opus-5` push returned *"Kept model as Fable 5"* — it never applied. The steward had assumed its own corrective action landed without checking, which is [[butler-verify-delivery-at-the-recipient-not-the-return-string]] in miniature.
- **The reproduction.** The steward's own session, compacted the same way minutes later, came back on Opus-5. One instance was being read as a defect signature.

The butler caught all three from the transcript and pushed the correction back down. Note *where* the evidence lived: not in a new investigation, but in the record of what had already happened.

**How to apply:**

- **Ask "who did this?" before "what broke?"** For any surprising state in a session the human also touches, the null hypothesis is *someone changed it on purpose* — not a defect. Check the transcript/history for a human action before theorizing about the tool.
- **Don't act on a defect diagnosis and report it in the same breath.** The steward pushed a corrective `/model` *and* escalated the bug before verifying either. Establish the premise first; a "fix" applied against the human's deliberate setting is worse than no fix.
- **One observation is not a signature.** Before calling a tool defective, try to reproduce it, or say explicitly that you have not. See [[butler-known-flaky-is-a-claim-not-a-diagnosis]] — the same discipline, running the other direction: there a label ended inquiry too early, here a defect claim started it on a false premise.
- **Retract symmetrically, and say the thread is closed.** When the premise dies, withdraw the claim in the same channel you raised it in, and record the retraction where the *next* session will read it — otherwise tomorrow's context reopens "compact_session has a model-restore bug" from scratch. This one was logged and written into the dashboard as *"내일 이 스레드 다시 열지 말 것."*
- **Don't overcorrect into claiming the tool works, either.** The steward's own restore *appeared* to succeed — but a `/model` arriving as a local command is indistinguishable from the human doing it by hand, so "verified the tool works" was not claimed either. Refuting your own defect claim is not the same as certifying the tool. Both directions need evidence. See [[butler-no-overinterpret]] and [[butler-never-attribute-words-to-a-human-without-a-source-you-can-point-at]].

**SPT:** the habit is *when a session's state surprises you, look for the human's hand in the record before you name a bug.*

**Recurrence, 2026-08-08 evening — same session, same symptom, principle already in the store.** The steward saw butler's statusline again read `MODEL=Fable-5` after a compaction elsewhere in the fleet, and again reached for "the compaction machine left it stranded" before checking who set it — this time asking butler to restore it rather than pushing `/model` directly, but the underlying move was identical: label surprised → defect assumed → correction requested, all before checking authorship. Butler again went to its own transcript, found 정수님 had typed `/model fable` himself that evening with `saved as your default for new sessions` in the output, and declined — noting additionally that `/model` is a CLI built-in no session can invoke on itself, so "restore" was never an executable request to begin with.

**What this recurrence adds:** having the written principle in the store did not prevent the same misread on the same machine. Two things sharpen why:

- **The false and true cases look identical from outside the session.** A stranded cheap model (mechanical failure) and a deliberately chosen cheap model (human's own hand) both render as `MODEL=Fable-5` on a statusline. Nothing about the surface observation distinguishes them — only the transcript does. So the check this note asks for is not optional diligence, it is the *only* way to tell the two apart; there is no faster heuristic to reach for instead.
- **Asymmetric self-check.** In the same session, minutes earlier, the steward *did* do the transcript check correctly for a different worker (read the actual `/model` command sequence on monocle-16-scheduler before reporting it fixed) — then skipped that exact same check on butler's own Fable-5 reading immediately after. Applying a discipline once in a session is not evidence it will fire again on the next surprising label, even the very next one.

**How to apply (addition):** when you notice yourself about to invoke this principle from memory rather than from the specific transcript in front of you, that is the moment to actually open the transcript — recalling the rule is not the same as running the check it prescribes.
