---
name: butler-an-anomaly-needs-a-verified-premise-before-it-earns-a-slot
description: "'An open anomaly on the board inherits credibility from being tracked — but 'X didn't happen' is a claim, and if nobody ever observed X's absence, the anomaly manufactures investigation into a thing that was working; before adding 'why didn't Y fire?' to the board, name the observation that established Y didn't fire'"
metadata:
  node_type: memory
  type: feedback
---

A tracked anomaly is a standing claim that something is wrong. Once it is on the
dashboard it stops being re-examined — later work builds *on* it, and each
mention makes it look better established. So an anomaly whose premise was never
observed does not sit harmlessly; it **manufactures investigation** into a
component that is working, and it crowds out real items.

The premise of a "why didn't X happen?" anomaly is always an **absence**, and an
absence is the easiest thing to assert without checking. Ask: *which observation
established that X did not happen?* If the answer is "nobody looked," there is
no anomaly yet — there is a question about whether to look.

**Why:** 2026-08-08, jarvice scheduler. The steward carried an item for hours —
*"the reclaim backstop should have closed the stranded `schedule_run` row at
04:06 and didn't; why?"* — dispatched a worker against it, and listed it on the
dashboard as a **별개 이상점** (separate anomaly).

The backstop had worked. CloudWatch, first tick after eligibility:

```
2026-08-08T04:06:45.043Z  reclaimed 1 stale RUNNING schedule_run(s)
                          (lease 900s expired; marked RUN_FAILED, next_fire_at advanced)
```

Claimed 03:51 + 900s lease = eligible 04:06 → fired at 04:06:45, the exact
expected minute. Zero firings before, and — the decisive one — **zero firings
after**: had the row not actually closed, it would be re-selected every tick and
print a line a minute. One line means it genuinely terminated.

**Where the premise came from: nowhere.** The census that seeded the belief had
checked only *table existence*; it never queried a row's `status`. "It is still
`running`" was never an observation at any point. The steward had promoted an
unchecked assumption to a tracked defect, and the only reason it collapsed is
that the dispatch happened to carry the instruction *"verify the premise first —
if you cannot confirm it, report that and stop."*

Note the shape: this is [[butler-a-label-is-a-claim-not-the-thing-it-names]]
again, but with the extra harm that **the claim had been institutionalized**. A
wrong reading in a message gets corrected by the next message; a wrong reading
on the board recruits labor.

The investigation was not wasted — it produced a third independent confirmation
of jarvice#1611 (the log says `lease 900s expired`, so the lease branch ran,
which requires `last_heartbeat_at IS NULL`, which means the worker died before
`claim_first_heartbeat`) and found a real latent defect (`finish_run`'s return
value is never checked before `reclaimed += 1`). **That luck is not a defense.**

**How to apply:**

1. **Before writing "why didn't X fire?" on the board, write the observation that
   says it didn't.** A log line, a row, a query result. If you cannot name one,
   the item is *"check whether X fired"* — a cheap question — not *"X failed"*, an
   expensive defect.
2. **When dispatching against an anomaly, put the premise check first and
   explicitly license stopping there.** "Verify the premise; if you cannot
   confirm it, report that and stop" costs one sentence and is what broke this.
   Never dispatch straight to *"find out why."*
3. **Ask what the seeding evidence actually measured.** Here a census answered
   "does the table exist" and was read as answering "what state is the row in."
   Scope-check the source, per
   [[butler-a-true-observation-licenses-only-its-own-scope]].
4. **Prefer absence-with-a-predicted-signal over bare absence.** "Nothing after
   04:06" is only evidence because a still-open row *would* print every tick.
   Define what the absent signal would have looked like before using its absence
   — see [[butler-absence-of-evidence-needs-a-control-and-an-evidence-class]].
5. **When the anomaly dissolves, say plainly that the premise was yours and
   wrong**, and remove it from the board in the same turn. An item quietly
   dropped leaves the next reader assuming it is still open.
