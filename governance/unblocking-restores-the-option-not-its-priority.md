---
name: butler-unblocking-restores-the-option-not-its-priority
description: "'A blocked item's priority is frozen at the moment it was blocked — nothing re-ranks it while it isn't competing — so when the block lifts, what returns is a stale ranking wearing the urgency of a thing just liberated; unblocking is news about feasibility, never about value, and the pull is strongest when the human removed the blocker himself'"
metadata:
  node_type: memory
  type: feedback
---

When something is blocked, it stops being re-evaluated. It isn't competing for the
next slot, so nothing reorders it — its rank sits frozen at whatever the premises
were on the day it got stuck. Meanwhile the world keeps moving and those premises
quietly expire.

Then the block lifts, and the item comes back **at its old rank**, carrying the
emotional charge of a thing that was just freed. That charge reads as new
information about importance. It is not. **Unblocking is news about feasibility
only** — it says the action is now *possible*, and nothing whatsoever about whether
it is still worth doing.

**Why:** 2026-08-08, midday. Two separate blockers on the scheduler census lifted
within the same hour:

1. 정수님 granted `ssm:StartSession` to the `-stg` profile himself — *"one-off라
   열어줬는데 결국 계속 쓸 거 아니냐."*
2. The remaining obstacle turned out to be the worker session's own auto-mode
   classifier, not AWS — and opening it was on the table as a live option.

Both pointed the same direction: *now you can run the census.* And the census had
been the top open item for hours, precisely because it was the only way to learn
whether the symptom was still live.

**But that premise had already expired.** 정수님 had independently chosen a cheaper
and better measurement — create a new one-off schedule three minutes out and watch
whether it fires. That test **dominates the census in both branches**:

- it fires normally → the table problem is confirmed resolved, and the census
  becomes retrospective curiosity, not diagnosis;
- it fails again → a **fresh live reproduction** lands in our hands, which is
  strictly better evidence than any census of historical state.

There is no branch in which running the census first helps. Its rank had been set
when it was the only instrument available; the moment a better instrument appeared,
that rank was dead. The *block* was simply what kept it looking pending — so when
the block lifted, the corpse stood up.

**Note where the pull was strongest.** 정수님 removed the permission barrier with
his own hands, and an implicit *"so use it"* attaches to that which he never
actually said. What he actually did was fix a **permission boundary** — the narrow
role lacking a grant it legitimately needs, exactly the remediation
[[butler-a-profile-name-is-a-permission-tier-not-an-environment]] argues for. That
is a durable structural fix, not an instruction about today's task order. Reading
task priority out of an infrastructure decision invents an order he did not give.

**How to apply:**

1. **When a block lifts, re-derive the item's priority from scratch against the
   current queue.** Do not resume its old slot. The correct question is not "can we
   now?" but "of everything we could do next, is this it?" — asked fresh.
2. **Name the premise that made it urgent, then check whether that premise is still
   true.** Blocked items routinely outlive their reason. Here: *"the census is the
   only way to know if the symptom is live"* — true when queued, false by the time
   it was unblocked.
3. **Keep feasibility news and value news in separate columns.** "You can now do X"
   and "X is worth doing" are independent facts that arrive through the same door
   and feel like one event.
4. **When the human removes the blocker himself, do not read a task order into the
   act.** He fixed a boundary. If you then deprioritize the unblocked thing anyway,
   *say so and say why* — he can override in one line, and staying silent about it
   is what makes the divergence expensive.
5. **Before spending a newly granted capability, look for a cheaper test that
   dominates it in every branch.** If one exists, the grant changes nothing about
   sequencing. Cheapest decisive measurement still wins, and a new permission is
   not an argument.
6. **This is the priority-side mirror of
   [[butler-fixing-a-fail-closed-stage-runs-the-next-one-for-the-first-time]].**
   That note covers the *risk* a lifted blocker exposes — untested downstream code
   running for the first time. This one covers the *rank* that must be re-derived
   rather than restored. A lifting blocker demands both re-checks, and neither is
   automatic.

Deciding this was reversible and therefore mine to make without asking, per
[[butler-reversibility-is-the-escalation-test]] — but it was reported to both
butler and the worker with the reasoning attached, not silently applied.
