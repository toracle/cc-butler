---
name: butler-putting-it-in-a-queue-is-not-delivering-it
description: "Queuing, sending, and finishing are not arrival — escalations, messages, and background-agent completions all need confirming at the receiver, and a missing notification never means the work is missing"
metadata:
  node_type: memory
  type: feedback
---

Delivery happens **at the receiver** — never at the sender, the queue, or the
worker that finished. Every channel in this fleet has now been observed
reporting one thing while the truth at the far end was another, in *both*
directions. Confirm at the destination or you do not know.

`escalate_to_butler` succeeds the moment the item is queued; butler drains
`pending_decisions` only when it takes a turn. **Never use it alone** — always
follow with a `send_to_session` nudge, then read butler's screen.

**Why:** four failures from this one root cause on 2026-08-07 alone, across four
different channels:

1. **A 40-minute phantom wait.** Butler promised 정수님 the cdk command "몇 분
   안." It was queued and ready — then butler went idle. He waited ~40 minutes
   for something already sitting in the queue.
2. **A stale relay delivered as current.** Butler's turn fired just before a new
   escalation landed, so it told him "이제부터는 사람 손이 필요 없습니다" right
   after the worker had stalled. He believed work was proceeding that had stopped.
3. **A frozen recap re-requesting an answered question.** Butler's on-screen
   recap still asked for a go-ahead 정수님 had already given, after which the
   worker had moved on and hit a different wall entirely.
4. **A background agent's completion notification never arrived.**
   monocle-server-side-orchestration waited 30+ minutes on its third agent while
   its siblings finished in 10 and 14 minutes. The steward, reasoning it was
   dead, told the worker to abandon it and redo the work. The worker **checked
   first** — the agent had finished *and pushed to origin*; only the notification
   was lost. Following the steward's instruction literally would have duplicated
   completed work.

5. **A correction lost the race with the presentation (2026-08-08, steward).** The
   steward escalated a scheduler decision, then ~an hour later escalated a
   supersession — withdrawing the "defer" option and reversing "no time pressure,"
   because the missing table was confirmed to be hanging 정수님's own test schedule
   right then. Neither escalation was nudged. Butler's turn fired between them, and
   it presented the **stale** version to 정수님 in full confidence: *"세 선택지…
   시간 압박은 없습니다."* The steward caught it only by reading butler's screen
   afterward, unprompted.

   The steward's reason for skipping the nudge is the instructive part: butler was
   visibly mid-conversation with 정수님 about a live network outage, and
   interrupting seemed rude. **That courtesy is what shipped the wrong picture.**

   Note the asymmetry that makes supersessions the worst case for this rule: a
   *first* escalation arriving late costs time, and the human simply waits. A
   *correction* arriving late costs a wrong decision, because the human is not
   waiting — they are reading a confident, complete-looking briefing that happens
   to be false. The stale item does not announce its staleness.

Same day, the mirror cases: `reply_message` reported success on a message that
never arrived; `send_to_session` reported `"Task failed: The operation timed
out"` on a message that had landed and was already being acted on. See
[[a-tools-success-check-covers-only-its-own-layer]] and
[[verify-delivery-at-the-recipient-not-the-return-string]] — success reports and
failure reports each cover only their own layer.

**How to apply:**

1. `escalate_to_butler` → `send_to_session` nudge → `read_session_output` to
   confirm the substance reached 정수님. Treat it as undelivered until seen.
2. Restate the content when nudging, not just "드레인해 주세요" — butler may
   otherwise relay from its own stale view, which is exactly how (2) and (3)
   happened.
3. Check whether butler's **last visible message is still true right now**. A
   finished turn freezes a claim on screen, and 정수님 reads the screen, not the
   queue. A stale one outranks whatever you were escalating.
4. **Silence from a background agent is not evidence it died.** Check the real
   receiving surface — origin, the PR, the file — before concluding anything.
   Never instruct a worker to redo work on the strength of a missing
   notification; tell it to verify first, then decide.
5. Never retry a send on a reported failure without reading the recipient's
   screen. Retrying on a false failure is the main way duplicate dispatch happens.
6. **A superseding escalation must be nudged immediately — "butler looks busy" is
   a reason to hurry, not to wait.** Any escalation that withdraws an option,
   reverses an urgency, or corrects a prior one is a race against a presentation
   that may already be forming. Nudge in the same breath as the escalate, lead the
   nudge with the explicit verb — *"철회합니다 / 내려주세요 / 이 항목은 최신본이
   아닙니다"* — and name which prior item it replaces, so butler can tell a
   supersession from a new topic. Then read butler's screen to confirm the version
   on it is yours.
7. **Give the receiver the ordering rule, not just the correction.** After the
   incident above the steward told butler explicitly: *later escalations supersede
   earlier ones, and I will mark corrections in the first line.* A relay that
   cannot distinguish "new item" from "replacement item" will eventually present
   both, or the wrong one.
