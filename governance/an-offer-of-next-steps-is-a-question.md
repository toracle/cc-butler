---
name: an-offer-of-next-steps-is-a-question
description: "Track workers by 'is this one waiting on us?', not 'is this one idle?'. A busy worker can have a frozen sub-part, and a worker that proposes its own next steps ('I could pick up X or Y') has asked a question — but it reads as initiative, so nobody registers it as needing an answer. Both failure modes cost days while the worker looked perfectly healthy."
metadata:
  node_type: memory
  type: feedback
---

**Two instances in one night (steward, 2026-08-03), each costing days.**

*jarvice-1130 — busy, but partly frozen for four days.* It worked productively the whole time: investigating,
filing issues, answering dispatches. Meanwhile a *sub-part* of its state — a stash, an unresumed task, a staging
token it would not trust — stayed frozen awaiting an answer that had existed since 07-31. Nothing flagged it,
because every signal the steward tracked said "healthy and working."

*monocle-skills — six days on an offer nobody read as a question.* Its last message ended: *"I'm standing by; if
you like I can pick up the #69 router-free trigger sweep, or one of #67/#68/#70."* The steward's own handoff
recorded this session as **"nothing — genuinely out of work."** It was not out of work. It had proposed three
concrete next steps and was waiting for someone to pick one.

**Why an offer slips past.** A question ends in a question mark and creates an obligation. An offer reads as
*initiative* — the worker sounds self-sufficient, even generous, and the sentence pattern-matches to "no action
needed." But an offer of alternatives is strictly *more* blocked than a question: the worker has done the
analysis, produced the options, and cannot proceed precisely because choosing among them is the dispatcher's
call. **The better the worker's report, the more likely its request gets filed as a status update.**

**How to apply.**
1. **Make the tracking question "is this worker waiting on us — in whole or in part?"** not "has it run out of
   work?" Productivity is not evidence that nothing is stuck. Add a worker to the watch list the hour it reports
   holding *anything* pending your word, even while visibly busy on something else.
2. **Read the last paragraph of every worker report for an unanswered choice.** Offers hide there: "I could…",
   "if you like…", "unless you'd rather…", "standing by". Each is a question with the punctuation filed off.
3. **Answer offers explicitly, even to decline.** "Not that — do X instead" and "yes, take the first one" both
   cost one sentence. Silence is read by a well-behaved worker as *keep waiting*, which is exactly what makes a
   good worker sit longest.
4. **When choosing among a worker's proposed options, prefer the one that makes a parked decision decidable.**
   monocle-skills had three items blocked on the principal; the sweep it offered would produce the evidence one
   of those decisions needed. Waiting and gathering-what-the-decision-needs look similar from outside and are
   not the same.
5. **Own the miss out loud when you dispatch late.** Both workers were behaving correctly; the omission was the
   dispatcher's. Saying so keeps the worker offering next time, which is the behaviour you want.

**The general shape.** Idleness is easy to instrument and is the *wrong* signal — it catches the cheap case (a
worker with nothing to do, costing nothing) and misses the expensive one (a worker blocked on a one-sentence
answer, looking fine). Instrument the thing you actually care about: **unanswered asks**, whatever grammatical
form they arrived in.

Related: [[search-for-the-existing-decision-first]] (the closure that never landed — same night, and the answer
jarvice-1130 was frozen on already existed), [[report-up-is-a-push]] (the reporting direction; this note is the
receiving end of it), [[verify-delivery]].

**SPT:** the habit is *at every check-in ask "who is waiting on a sentence from me?" — and re-read the last
paragraph of each report for a question wearing an offer's clothes.*
