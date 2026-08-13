---
name: butler-confirm-the-thing-exists-before-explaining-why-it-was-not-processed
description: "'Why didn't the system pick X up?' presupposes X existed in the state the picker reads — verify that first, or you will audit the whole downstream pipeline to explain an absence that has no downstream cause"
metadata:
  node_type: memory
  type: feedback
---

When a report is "the system didn't process X," the question smuggles in a
premise: **X existed, in the form and state the processor actually reads.** Test
that premise *before* opening the processor. Otherwise every hour spent reading
the pipeline is spent explaining an absence that has no cause inside it — and
the code will keep coming back clean, which feels like the mystery deepening
when it is actually the premise failing.

The tell is a diagnosis that only produces exonerations. Ruling out the fourth
consecutive code-level cause is not progress toward a fifth; it is evidence that
the defect is not in the layer being searched.

**Why:** 2026-08-04→08-07, monocle#16 scheduler e2e. Reported symptom: a
schedule 정수님 created never fired — no run record, no in-progress indicator.
Three days of investigation walked the pipeline: deploy regression (ruled out by
clean code diff), tenant feature flag (ruled out, then correctly re-opened when
the steward caught itself citing an 08-06 observation as current state),
`get_due_schedules` boundary conditions and timezone math (ruled out by direct
reading), `dispatch_all_tenants` iteration and skip logic (ruled out — no skip
branch exists). It consumed a worker for days, produced an escalation asking
정수님 for a CloudWatch query and a Stark console check, and drove a subagent
into three consecutive classifier blocks trying to reach a production AWS profile
for dispatcher logs.

The break came when the worker stopped reading the pipeline and **listed the
schedules**: today's row was simply not there. 정수님 then identified it
immediately — *"아, 제가 8월 7일 20시 20분 이라고 해야 되는데 8월 6 일 이
0시 20분으로 스케줄을 만들었었네요."* The schedule had been created with a past
timestamp. It never had a future fire time, so no due row ever existed. The
dispatcher not picking it up was correct behavior.

Every exoneration along the way was *true*. That is the trap: a chain of correct
negative findings reads as narrowing, and it is not — none of them could ever
have been positive. One `list_scheduled_tasks` call on day one would have ended
it, and would have cost nothing.

Note what the false premise also cost sideways: it justified reaching for
production logs (see [[workers-must-not-reach-aws-profiles]]) and it put two
useless checks into 정수님's queue. A wrong premise does not stay in the
investigation; it spends other people's attention and pushes on safety
boundaries.

**How to apply:**

1. On any "X wasn't processed" report, **first** query for X in the store the
   processor reads, and look at the *specific fields the processor filters on*
   (here: the fire time, not merely "does a row exist"). Do this before reading
   any processor code.
2. Treat a run of clean code-level findings as a signal to **change layer**, not
   to search deeper. Two or three exonerations in a row: stop and re-test the
   premise.
3. When the artifact was created by a human through a UI, the creation inputs
   are part of the state to verify — not a trusted given. Ask to see what was
   actually entered or stored, not what was intended.
4. If an investigation is about to spend a human's attention or push on a safety
   boundary (production credentials, prod console access), re-verify the premise
   *before* paying that price. Cheap premise checks come before expensive
   access requests, always.
5. When the premise turns out false, retract the asks it generated along the
   propagation path — the queue does not clean itself. On 2026-08-07 the steward
   had butler pull both 정수님-facing checks the moment the cause was known.
6. Root cause found ≠ verification done. Here the code was exonerated, but the
   e2e chain still had never been walked end to end. Say which one you have.
