---
name: butler-instrument-before-verdict
description: "An unverified measuring instrument cannot outrank a direct human observation — verify the instrument before its readings decide anything, and keep at least one pre-registered acceptance criterion that does not pass through any instrument"
metadata:
  node_type: memory
  type: feedback
---

A log line, a trace field, a status probe is **not evidence — it is an instrument
that produces evidence.** Until the instrument itself has been verified, its
readings cannot overrule a direct observation of the world. When the two
disagree, the first suspect is the instrument, not the world.

And when you pre-register acceptance criteria (which you should — it stops you
from re-interpreting results to match your hope), **at least one of them must not
read an instrument.** Physics, distance, a thing a human can see happen.

**Why:** on 2026-08-03, mobile-app#113's Bluetooth mic-routing fix was verified on
a real device. The boss reported the headset mic working. The app's own
`VADTRACE input_device` field said "Built-in microphone" for all six turns. The
butler and the steward both sided with the instrument and were about to record a
*working* fix as failed. What actually settled it was the boss saying he had been
**10 metres from the phone** — a distance at which the built-in mic physically
cannot pick up speech. No log was read to reach that verdict.

Two failures stacked, and both are worth naming:

- The butler treated "the corrected instrumentation commit is in this build" as
  "therefore the instrumentation is correct." Confirming *which* implementation is
  running says nothing about whether that implementation is right. (The bug: it
  read the *first* recording configuration on the system rather than this app's,
  and it read it at turn start, returning early before ever reaching the branch
  that would have answered "Bluetooth".)
- The steward reasoned "the old implementation over-reported, the symptom is
  under-reporting, so the old bug doesn't explain it — **therefore the new one is
  correct**." That last step has no support. It ruled out one known defect and
  never put "the new implementation is independently wrong" on the candidate list.

The pre-registration made it worse rather than better. The registered criterion
was `input_device == Bluetooth` — a criterion that **reads the instrument.** So
when the instrument lied, pre-registration did not catch the error; it *lent the
error authority*, because "the acceptance criterion we fixed in advance failed" is
a hard sentence to argue with. Half the force pushing toward the wrong verdict
came from there.

**How to apply:**

1. Before an instrument's reading decides anything, ask what would make *the
   instrument* wrong, and check that. "The fix for it is in this commit" is not a
   check.
2. Every pre-registered criteria set gets **at least one instrument-independent
   member** — one that a person can adjudicate without reading any output the
   system produced about itself. Ten metres. The app is on screen. The file
   exists. If every criterion reads an instrument, the instrument has quietly
   become the judge, and nobody is judging the judge.
3. When a human's direct observation and an instrument disagree, do **not** pick a
   side from the armchair. Ask what the human actually did — the experimental
   conditions are usually the missing variable ([[butler-justification-is-not-observation]]).
4. Once the world and the instrument disagree and the world wins, the instrument
   becomes the bug, and it outranks the original task: every verdict built on it
   is now suspect.

Ties to [[butler-evaluation-independence]] (who judges, and are they independent),
[[butler-a-control-that-cannot-fail-is-not-a-control]] (a check that cannot go red
is decoration), and [[butler-verify-delivery]] (the gesture is not the outcome).
