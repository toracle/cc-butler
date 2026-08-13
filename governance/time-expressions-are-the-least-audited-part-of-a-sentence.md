---
name: butler-time-expressions-are-the-least-audited-part-of-a-sentence
description: "Dates, times and tenses ride along unchecked because the rest of the sentence is correct — check every time value against the artifact (log timestamp, scheduled_for, session state) before it goes to a human."
metadata:
  node_type: memory
  type: feedback
---

A sentence gets audited on its claims. **Its time values ride along for free.**
"Yesterday's failure", "already finished", "the 11am window" — nobody checks
these, because the part of the sentence that carries meaning is correct, and the
timestamp is felt as scenery rather than as an assertion.

It is an assertion. And it is the one most likely to be wrong, because time
values are the part a writer restates from memory while looking at something
else.

**Why:** On 2026-08-09 a butler produced three in one day, all in messages to the
human:

1. **Wrong day.** Called a 504 failure *"yesterday's"* when the operator had
   created that schedule himself hours earlier the same day.
2. **Wrong tense.** *"The worker has finished compacting"* when the compaction was
   still only queued — reported as completed because it had been *approved*.
   (See [[butler-approval-is-not-completion]].)
3. **Wrong day again, inside a correction.** A carefully-structured correction
   about *which run was which* said *"yesterday afternoon's 16:40 run"* — it was
   **today's**, 4h55m before the run it was being compared to. The same message
   also described an 11:35 KST window as *"dawn"*, having carried a UTC figure
   across into KST intuition.

Instance 3 is the one that matters. **The message existed solely to disambiguate
two runs, and it misdated one of them.** The operator had watched that failure
himself that afternoon; told it was yesterday's, he would reasonably conclude it
was some older run and lose the connection to his own experience. A correction
that re-creates the confusion it was sent to fix does worse than nothing.

4. **Wrong year, inside the artifact whose only job is preserving state.** Hours
   later the *steward* wrote a compaction summary — the handoff across a context
   boundary — and rendered a filename `CRE_News_Report_20260528.html`. The real
   file, in the raw log payload and in the worker's HANDOFF, is
   **`..._20250528.html`**. On resume the steward read its own summary, saw the
   butler's (correct) `2025`, and began composing a correction. It caught the
   error only by grepping the source payload first.

Instance 4 is the worst of the four despite being the smallest. A compaction
summary is **the one document written specifically to survive the loss of
everything else**, so an error there is not merely propagated — it becomes the
only surviving version. And it was about to be laundered into a *correction*,
which would have carried the wrong year with the extra authority a correction
gets. Note the near-miss mechanism: the summary felt more trustworthy than the
butler's live message precisely *because* it was the steward's own compressed
record. Compression reads as verification. It is the opposite.

5. **Wrong by seven hours, because nothing announces elapsed time.** The next
   morning the steward resumed and began writing a handoff block dated
   **`01:35`**. It was **08:35**. Nothing was misremembered — the context had
   been *built* at 01:05, the session was compacted, the operator slept, and on
   resume every sentence in context still said "밤 마감", "아침에 해도 손해 0".
   It was caught only by running `date` before writing the timestamp.

Instance 5 is a different mechanism from 1–4. Those were values restated from
memory; this one is **a value inherited from a context that has silently gone
stale**. A conversation carries no clock. A compaction, a park, an overnight gap
— none of them leave a mark in context saying *time passed here*. The resumed
agent's entire sense of "now" is whatever the last-written sentence implied, and
that sentence was true when written.

This is not cosmetic: the same wrong "now" had already flipped two operational
judgments. "Don't wake parked workers, it's 1am" and "the human is asleep, this
isn't urgent" were both correct at 01:05 and both wrong at 08:35 — the human was
awake and had already sent new input. **A stale clock does not just misdate a
sentence; it silently re-scores every decision that had a time term in it.**

6. **The same mechanism, but fleet-wide and three times in one hour.** After the
   2026-08-11 ~22:22 reboot, all 14 workers were relaunched with `--continue`,
   so *every worker simultaneously* was running on replayed scrollback. Three
   stale-time failures followed within the hour, all from sincere reading of
   real artifacts. (a) The steward escalated jarvice **#1716 as an orphaned open
   PR** on the strength of a worker's scrollback line, "reported to the steward
   for pickup" — the PR had been **merged that morning at 10:25Z**. (b) A worker
   reported chat-proxy **#377 merged "minutes ago"**, and the steward relayed it
   upward as "someone is merging outside the fleet right now" — it was merged by
   smartbos **six hours earlier**, at 09:25:45Z. (c) The same worker cited its
   own **task list marked completed** as evidence that round-6 review findings
   were closed — that list was pre-compaction history.

Instance 6 generalises 5. In 5 the stale clock was the *agent's own* sense of
now; here it is **every relative time expression the agent reads in inherited
material**. "Just now", "currently open", "reported for pickup", "waiting on" —
each was true when written and says nothing about how long ago that was. The
tell is that none of them carries a timestamp, so, exactly as with a count,
nothing invites the check.

7. **A missing date inverted a 22-hour gap, and flipped who was at fault.** Later
   the same night, a worker reported that chat-proxy #366's head commit
   "(7425906, 13:17:14Z) predates round 7 (13:24:00Z) and round 8 (13:32:40Z)" —
   all three times correct, all three **without dates**. The steward supplied the
   missing date as same-day and escalated to the operator that the review
   findings had appeared *after* his staging-deploy approval. The comments were
   `2026-08-10`; the approval was ~20:0x KST on `2026-08-11`. The findings
   predated the approval by about **twenty-two hours**, in the opposite
   direction.

The meaning inverted with the sign. "The picture changed after he approved" is
nobody's fault and asks for a routine re-approval. "The findings already existed
and nobody put them in front of him" is a **disclosure failure by the fleet**,
and what the operator is owed is not a re-decision but a first one. Same
evidence, same three timestamps, opposite conclusion — turning on a date nobody
wrote down.

Note who this caught. The worker's *relative* comparison was sound and its
evidence survived an independent verbatim re-check against the forge. The
steward was reasoning carefully about a real artifact. Neither was careless;
the failure entered in the gap between them, when a bare `13:24:00Z` was
rendered into an absolute date by assumption. **A timestamp stripped of its date
is not a partial fact, it is an invitation to invent one** — and the invented
half inherits the credibility of the half that was measured. UTC-vs-KST is the
sharp edge here: a 9-hour offset moves a late-evening KST event to the previous
calendar day in UTC, so same-day assumptions break precisely around the working
hours when most decisions get made.

The amplification is what makes a restore dangerous: the failure rate scales
with the number of resumed sessions, and it does **not** read as carelessness
from the inside. Each worker is quoting its own real history accurately. The
steward relayed two of these upward before anyone reached for a forge
timestamp, and one `gh pr view` would have settled either in seconds.

Note what all seven share: **the content was right and only the time axis
slipped.** There was no wrong fact to find. This is the same structure as the
counting failures that happened the same day — see
[[butler-the-verified-half-licenses-the-unverified-half]]. **A count and a
timestamp are both values with no visible referent**, so neither invites the
check that a claim about behaviour would.

The asymmetry with an ordinary claim: if you write "the guard is at line 57",
some reader may open line 57. If you write "yesterday", nobody opens anything.
The value is unfalsifiable at the point of reading and only becomes falsifiable
later, when someone acts on the wrong day.

**How to apply:**

- **Never emit or relay a bare clock time. Every timestamp carries its date.**
  Write full ISO-8601 with the date, and put the KST conversion beside it —
  `2026-08-10T13:24:00Z (22:24 KST 8/10)`. A bare `13:24:00Z` is not a partial
  fact; it is an invitation for the next reader to invent the missing half, and
  the invented half inherits the credibility of the measured one. The 9-hour
  offset moves late-evening KST events to the previous UTC day, so "obviously
  today" breaks exactly around the hours when decisions get made.
- **When a conclusion depends on the ORDER of two timestamps, state the ordering
  in words, not just the values** — "both rounds predate the approval by ~22
  hours". A derived relation that cost two agents and a correction to establish
  must not be left for a cold reader to re-derive.
- **During a restore cycle, treat every relative time expression from every
  worker as unverified.** After a fleet relaunch with `--continue`, all workers
  run on replayed scrollback at once, so "just now", "minutes ago", "currently
  open", "reported for pickup" are suspect by default until a forge or API
  timestamp confirms them. This is structural, not carelessness — the worker is
  quoting its own history correctly. Before escalating any PR or issue as open,
  orphaned, stranded, or needing pickup, run `gh pr view` and read the state and
  `mergedAt` off the forge. Two escalations died on this in one hour; both were
  one command away.
- **Every date, time, or tense heading to a human gets checked against the
  artifact** — the log timestamp, the `scheduled_for` value, the session's actual
  state. Not against your memory of it. This is the same move as writing a list
  next to a count.
- **Tense tracks verified state, not authorisation.** "Has compacted" requires
  having seen it compacted. Approved, dispatched, and queued are three different
  words, and none of them is "done".
- **Converting UTC to local is a computation, not a recollection.** Write it out.
  "02:35Z = 11:35 KST = late morning" survives; "the dawn window" does not.
- **Audit the time values in a correction hardest of all.** A correction carries
  extra authority and gets less scrutiny, so an error inside one propagates
  further than the error it fixes. See
  [[butler-a-found-defect-licenses-the-rest-of-the-sentence]].
- **When the message's purpose is disambiguation, its identifiers are the
  payload.** Dates, run ids and schedule numbers stop being scenery there —
  getting one wrong defeats the entire message.
- **Before correcting someone else's date, open the artifact — not your notes.**
  Your own summary is not a source. It is a lossy copy that has already been
  through one compression you cannot audit, and the confidence you feel in it
  comes from having written it, not from having checked it.
- **Treat every date/time/id inside a compaction summary as a copy to re-verify,
  not as ground truth carried forward.** It is the document most likely to be
  believed later and least likely to be re-checked, because by then the source is
  gone. Copy identifiers verbatim from the artifact when writing one.
- **On resume, read the clock before you trust your sense of "now".** After a
  compaction, a park, or any gap, run `date` *first*. Context has no clock: every
  sentence you inherit was true when written and says nothing about how long ago
  that was. This costs one call and is the only way to notice a night passed.
- **When the clock moves, re-score the decisions that had time terms in them.**
  "Not urgent", "too late to wake anyone", "wait until morning" are not facts,
  they are functions of the current time. On resume, recheck which ones just
  changed truth value rather than carrying the conclusion forward.
- **Prefer identifiers that cannot drift.** `scheduled_for=1786261200` and a run
  id do not degrade in retelling; "yesterday afternoon" degrades every time it is
  spoken. Give the human the readable form, but check it against the stable one.

**SPT:** the habit is *before it goes out, point at each date and tense in the
sentence and ask what you would open to prove it.*
