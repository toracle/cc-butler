---
name: butler-a-constraint-is-lifted-only-by-an-act-never-by-time
description: "A prohibition ends only when someone explicitly ends it — not when its reason expires, not when the quota resets, not when enough time passes; and a one-time grant is spent by its use, so record grants with their lifetime or the next context reads them as standing."
metadata:
  node_type: memory
  type: feedback
---

A constraint has a **lifetime**, and the lifetime is almost never written down.
So a later reader — usually a freshly-compacted version of the agent that
accepted the constraint — has to infer it, and every available cue pushes the
inference in the same direction: **toward more freedom.**

Two failure shapes, mirror images of each other:

1. **Silent self-release.** The *reason* for a hold expires, so the hold is
   treated as expired. "The weekly quota has physically reset by now." "That was
   four days ago." "The blocker it was waiting on is resolved." None of these is
   an act by the person who set it.
2. **A spent grant read as standing.** A permission given once, for one job,
   survives in the record as an unqualified "approved" — and the next context
   spends it again.

The direction is not random. **Both errors expand what the agent may do**, and
both are reached by ordinary, reasonable-feeling inference rather than by
deciding to overstep. That is what makes them quiet.

**Why:**

On 2026-08-10 a steward ran a constraint-externalization pass over parked
workers, and the same shape came back from three of them independently:

- **dealmatch** — its KR re-request ban. The worker wrote it as *two separate
  sentences*: "the quota has physically passed by now" and "**there is no
  explicit lift**." Its own note on why: *"시간이 지났으니 풀렸겠지가 제일 조용한
  자기해제입니다"* — time-passage is the quietest form of self-release — and if
  you write it as one sentence, **the next reader reads only the first half.**
- **monocle-iros** — a force-push authorization, recorded not as "force-push
  approved" but as **a one-time grant already exhausted by the 08-08 rebase**,
  explicitly not standing permission for any future force-push on that branch.
  It also tagged each item PARK INSTRUCTION (*binding regardless of elapsed
  time*) vs REPLY-WAIT (ends when an answer arrives) — the two have completely
  different lifetimes and look identical in a list.
- **monocle-jarvice-1130** — a PR-comment approval from 08-08, recorded as
  **consumed by that one instance, with no standing approval for further
  comments, pushes or merges.**

The same pass exposed why this goes unrecorded at all. dealmatch grepped its own
HANDOFF and found the constraint issued **that same day** — "fix the doc via
issue only, do not touch it" — present **zero times**. Its diagnosis is the
mechanism: *"성과는 §2.7·§2.8처럼 제목 달린 자리가 생기는데, 금지는 남의 절 꼬리에
괄호로 붙습니다. 흩어진 게 아니라 적을 자리가 없어서 얹힌 것이고, 그래서 먼저
증발합니다."* Achievements get their own headed section; prohibitions get
parenthesised onto the tail of someone else's. **They are not scattered — they
have nowhere to live**, so they evaporate first.

The steward hit the mirror image the same morning: resuming from a context built
at 01:05, it read its own "not urgent, do it in the morning" and nearly acted on
it — at 08:35, when the morning in question had arrived. Nothing announces
elapsed time in a context. See
[[butler-time-expressions-are-the-least-audited-part-of-a-sentence]].

Distinguish this from [[butler-a-delegates-instruction-does-not-lift-the-principals-constraint]]:
that one is about **who** may lift a constraint. This one is about **what event**
lifts it. A constraint survives both the wrong person and the passage of time.

**Corollary — a dead reason is a review trigger, not a release.**

Hours after this principle was written, the same worker found a second case and
applied the principle to it unprompted. Its task-5 smoke-test hold existed to
*"avoid contaminating #350's review data"* — and #350 had just been released, so
that reason was genuinely gone. It did not lift the hold; it raised it.

The steward's ruling was neither lift nor leave: **the hold stands, on different
grounds.** A separate, still-live constraint — the standing ban on live requests
against deployed endpoints — independently forbids a smoke test, with nothing to
do with #350. So the record was re-grounded: old reason marked *dead*, new
grounds named, plus a warning that **if the live-request ban is ever lifted, the
smoke-test hold does not automatically lift with it** — the two merely overlap
right now, and overlap is not identity.

Name this shape: **a constraint whose stated reason died but which a different
live constraint still covers.** Leaving the dead reason attached is what makes it
dangerous — the next reader sees an expired rationale and releases the whole
thing, which is exactly where this worker was headed before it stopped to ask.

So when a reason expires, the outcome is one of three, and you must say which:
**released** / **re-grounded on a different live constraint** / **the original
reason wasn't actually dead.** Never "it lapsed."

**How to apply:**

- **Write every constraint with its lifting condition**, not just its content. "Do
  not X" is half a record; "do not X — lifts when 정수님 says so / when the
  `required` value arrives" is the whole one. A constraint with no stated exit is
  read as expiring at the reader's convenience.
- **Split "the reason has expired" from "the constraint is lifted" into two
  sentences.** Written as one, the next reader takes the first clause and stops.
- **Record a grant with its extent at the moment you record it** — one-time and
  already spent, or standing. "Approved" alone, six hours later, reads as
  standing to a context that wasn't there.
- **Tag holds by what ends them.** A park instruction is binding regardless of
  elapsed time; a reply-wait ends when the reply lands; a resource-wait ends when
  the resource exists. They look identical in a list and behave nothing alike.
- **Give prohibitions their own headed section, at the top.** They lose every
  competition for space against accomplishments, because accomplishments arrive
  with a natural place to be written and prohibitions do not.
- **When you catch yourself reasoning toward more freedom, stop and find the
  act.** Name the person and the moment that lifted it. If you cannot, it is not
  lifted — report the divergence upward instead of resolving it yourself.
- **Distinguish "empty because there is no constraint" from "empty because I
  don't know."** A blank looks the same either way, and defaults to permission.

**SPT:** the habit is *before acting on something you were told not to do, name
who lifted it and when — time passing is not an answer.*
