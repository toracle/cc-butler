---
name: butler-report-up-is-a-push
description: "Reporting UP the chain (steward→butler, worker→steward) is an ACTIVE push, not a passive queue — when a task is dispatched with 'confirm receipt / report progress', send_to_session the dispatcher directly; escalate_to_butler (pull queue) + dashboard/log are the durable record, NOT the report"
metadata:
  node_type: memory
  type: feedback
---

Recurring failure (2026-07-13): the butler dispatched the steward two tasks that
explicitly said **"Report progress as you go"** and **"Confirm receipt."** The
steward did the work correctly, put both decisions in `pending_decisions` via
`escalate_to_butler`, wrote a durable plan doc, and refreshed dashboard + butler_log
— then considered the tasks "reported" and waited. It never actively reported back
to the butler. 정수님 caught it: *"I expected you to report to butler, but you didn't.
why? don't you have such a guideline?"* The butler was a **live session actively
waiting for the steward's report** (its screen: "steward가 저에게 올릴 겁니다 …
최종적으로 복원됨-vs-막힘 명부를 받아 보고드리겠습니다"), and the passive queue +
dashboard could have sat undrained indefinitely.

This is exactly [[butler-verify-delivery]] one hop DOWN the chain. Same failure mode:
a **pull surface treated as delivery**. There, badges/inbox ≠ delivery to the human;
here, `pending_decisions` + dashboard/log ≠ a report to the butler.

**Lessons (durable):**
1. **Reporting up is a PUSH, not a queue.** `escalate_to_butler` drops a decision into
   the butler's quiet *pull* queue; dashboard/log are *pull* records. Neither is a
   report. When the dispatcher asked for a report / confirmation, actively
   `send_to_session` it (the butler is a live session; the worker→steward analogue is
   `report_to_steward`).
2. **Confirm receipt immediately.** On being dispatched a task, acknowledge receipt to
   the dispatcher up front — don't jump silently into the work and surface only at the
   end.
3. **Push progress + the final result.** Report meaningful progress as you go and
   deliver the final roster/result to the dispatcher directly; point it at the durable
   doc rather than dumping everything, but the *report itself* is the active message.
4. **Queue + record are the durable backing, not the delivery.** Still use
   `escalate_to_butler` (so decisions are drainable) and dashboard/log (so state
   survives a clear) — but pair them with the active push, and tell the dispatcher the
   items are queued so it drains them.
5. **Relay-safe.** Before the push, `read_session_output` the target (a live menu means
   your Enter is dangerous — [[butler-relay-safe-worker-decisions]]) and afterward
   verify it landed ([[butler-verify-delivery]]).

**How to apply:** [as steward] when the butler dispatches a task, confirm receipt to the
butler immediately, push progress + the final result via `send_to_session`, and note that
decisions are in `pending_decisions` for it to drain — do NOT treat escalate + dashboard as
the report. [as worker] same shape toward the steward via `report_to_steward`. Related:
[[butler-verify-delivery]], [[butler-steward-routing]], [[butler-decision-routing]],
[[butler-institutionalize-learning]].
