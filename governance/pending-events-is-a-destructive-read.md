---
name: pending-events-is-a-destructive-read
description: "`pending_events` returns the steward's inbox AND clears it. Any session that calls it — including a worker developing cc-butler itself, exercising the tool to see what it does — silently destroys events the steward has not read yet. Workers use `check_inbox`; `pending_events` belongs to the steward alone. If you drain it by accident, forward the contents to the steward immediately rather than hoping they were unimportant."
metadata:
  node_type: memory
  type: feedback
---

**The incident (cc-butler worker, 2026-08-03).** A worker session working *on the cc-butler codebase*
called `pending_events` — the natural thing to do when developing or exercising the tool. The call
succeeded, returned the steward's undrained worker reports, and **cleared them**. Those events were
never delivered to the steward; from the steward's side, the workers that had reported simply appeared
to have gone quiet. The worker noticed, forwarded the drained contents to the steward, and flagged
`check_inbox` as the channel it should have used. That recovery is the only reason nothing was lost.

**Why this is easy to do and hard to notice.** `pending_events` reads like an inspection tool — a
"show me what's pending" verb. Nothing in the call site signals that it *consumes*. And the failure is
invisible from both ends: the steward sees an empty inbox, which is indistinguishable from a quiet
fleet, and the worker sees a successful call returning data. Nobody gets an error. **A destructive read
that looks like an inspection is the worst shape a shared-state tool can have** — the damage is silent
on both sides of the exchange.

The exposure is structural, not accidental: every session on this machine holds the full MCP toolset,
including the steward's own coordination tools. Role separation between butler / steward / worker is a
convention about *who calls what*, not a capability boundary — the same gap as
[[subagent-scope-is-not-self-enforcing]], one layer up. A worker whose task is literally "develop
cc-butler" will reach for these tools as a matter of course.

**How to apply.**
1. **Workers: use `check_inbox`.** `pending_events` is the steward's, and calling it drains a queue that
   is not yours. This holds even — especially — when your task is to develop or test cc-butler itself.
2. **To exercise inbox behaviour while developing cc-butler, do not use the live queue.** The live queue
   is production state for a running fleet. Reproduce against a fixture or a test session instead.
3. **If you drain it by accident, forward the full contents to the steward immediately**, verbatim, and
   say that you drained them. Do not triage them yourself, and do not decide they looked unimportant —
   you cannot see the dispatch state they belong to. Silence is the failure mode here; a prompt "I
   drained these, here they are" costs nothing and fully repairs it.
4. **Steward: an empty inbox is not proof of a quiet fleet.** If workers you expected to report have
   gone silent, consider that their events may have been drained elsewhere, and check their screens
   directly with `read_session_output` rather than inferring quiet from an empty queue. Same discipline
   as [[verify-delivery]] — confirm the fact, don't infer it from an absence.

Related: [[verify-delivery]], [[subagent-scope-is-not-self-enforcing]] (capability outlives the
instruction that says not to use it).

**SPT:** the habit is *before calling a coordination tool from a session that doesn't own that role, ask
whether the call mutates shared state — and if you already made it, say so out loud instead of hoping.*
