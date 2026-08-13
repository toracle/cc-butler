---
name: butler-a-precondition-sent-with-its-approval-is-not-a-gate
description: "Approval and precondition in one message means the approval is read first and acted on; and backgrounding the approved work removes the last point where the precondition could still have stopped it."
metadata:
  node_type: memory
  type: feedback
---

A gate only works if there is a moment where the work has *not yet started* and
someone can still stop it. Two ordinary habits destroy that moment while looking
like efficiency:

1. **Bundling the precondition with the approval.** "Approved — and before you
   start, check X" reads as approval plus advice. The approval is the actionable
   part, it comes first, and the recipient may already be moving.
2. **Backgrounding the approved work.** Running it detached looks like saving
   wait time. What it actually removes is the interval in which an arriving
   instruction could still land before the irreversible part.

**Send the approval only after the precondition has been reported met.** Two
messages, not one. The cost is one round-trip; the thing bought is a point where
stopping is still possible.

**Why:** On 2026-08-09 the steward approved 271 external HTTP requests for a
dealmatch verification and, **in the same message**, instructed the worker to
first confirm whether the collectors validated HTTP status codes — the precise
defect behind issue #1126, where a collector parsed a 429 error body and returned
`None`, making 148 silent failures indistinguishable from 20 real collections.

By the time that message arrived, both collections had already finished. The
worker had backgrounded them and moved on. The check became a post-hoc
observation, and it *found the defect present*: no status-code validation
anywhere in the file, and **7 of 49 NICE failures were HTTP 500 returning a
silent `None`** — intermittently, hitting a different set of companies on each
run. It happened to be recoverable this time. The gate did not function.

The worker's own framing is the durable part: *"backgrounding an external request
looks like saving wait time, but it actually removes the point of intervention."*
And the steward's share was the message layout — a precondition placed under an
approval is decoration.

A second instance the same hour, same shape: told not to retry the 7 failed
companies while the non-deterministic-write bug (#1127) was open, the worker
named exactly why it wanted to and why it wouldn't — *"staging is valuable right
now not because the data is complete but because a before/after snapshot records
what went where and why; writing 7 more rows under #1127 trades a little
completeness for traceability."*

**The mirror image: an approval for a *queued* action is a statement about the
state at approval time, and it expires.** Later that day the steward asked a
worker whether it could be compacted; the worker said yes — *"externalization is
finished"* — and the steward queued it. Minutes later 정수님 stepped into that
session directly and authorized starting a fix. A branch was cut and a subagent
began a 62k-token investigation. **The clearance was still queued, and it was now
false**: firing at the next idle moment would discard work that had never been
written down.

Queuing separates the moment of judgement from the moment of action, so anything
that changes in between silently invalidates the judgement. And here it could not
be withdrawn — a queued compaction has no cancel, only a 30-minute expiry.

That constraint forced the more robust move, which is the transferable part:
**when you cannot prevent the action, make it harmless instead.** Rather than
fighting to stop the compaction, the steward told the worker to externalize its
state to HANDOFF *before going idle*. Then the compaction is safe whenever it
lands, and the fix no longer depends on winning a race.

**How to apply:**

- **Two messages: gate, then go.** Approve only after receiving the precondition
  result. If that feels slow, weigh it against the cost of the irreversible act
  proceeding unchecked.
- **Ask what the precondition is protecting against, and whether it can still
  protect after the work starts.** If not, it is not a precondition — it is a
  post-mortem.
- **Treat backgrounding as a decision about controllability, not speed.** It is
  correct for polling and waiting; it is wrong for the leading edge of an
  irreversible or externally-visible action, because it deletes the interval in
  which a late instruction could still arrive.
- **When a check runs late anyway, say the gate failed even if the result was
  clean.** A good outcome from an ungated action is luck, and recording it as
  success teaches the wrong lesson. See
  [[butler-name-the-command-a-check-that-resembles-the-gate-is-not-the-gate]].
- **Re-check a queued action's premise before it fires, not when you queued it.**
  "Safe to compact/deploy/delete now" describes *now*. If anything started in
  between — especially work authorized by someone else — the clearance is stale.
- **Know whether the thing you queued can be cancelled, before you queue it.**
  If it cannot, you have committed to an action whose conditions you no longer
  control.
- **When you cannot stop it, make it harmless.** Externalize the state it would
  destroy, so it becomes a no-op instead of a loss. A defense that does not
  depend on winning a race beats one that does.
- **Prefer traceability over completeness while a correctness bug is open.**
  More writes under a known non-deterministic path buy marginal coverage and
  destroy the clean record that makes the next fix verifiable.

**SPT:** the habit is *before sending an approval, ask whether anything in the
same message is supposed to stop it — and if so, send that alone and wait.*
