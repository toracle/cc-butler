---
name: butler-verify-the-citations-you-hand-down
description: "File:line references carried forward in a long session drift while the symbol name still matches, so they read as correct — ask the delegate to verify your citations and report drift, and never strip an unrequested caveat they add."
metadata:
  node_type: memory
  type: feedback
---

A citation you hand to someone else is an **unverified claim wearing the clothes
of a fact**. `foo.py:263` looks checked. It looks like the output of a lookup,
because once it was.

In a long session, citations get carried forward from memory while the file moves
underneath them. The tell is that **the symbol name still matches** — you cite
`middleware.py:2272` for a condition that is now at `:2281`, and every reader who
opens it finds the right code nearby and never notices the number was wrong.
Refactors, merges, and your own edits all move lines; nothing announces it.

**Why:** On 2026-08-09 a worker running a long investigation handed file:line
references to its subagents repeatedly. **Four of them were wrong. Subagents
caught all four. The worker caught none.** Its own summary:

> *"긴 세션에서 인용을 이월하는데 심볼명이 맞아서 맞아 보입니다."*
> (In a long session you carry citations forward, and because the symbol name
> matches, they look right.)

The asymmetry is structural, not a skill gap: **the receiver opens the file, the
sender does not.** Whoever acts on a citation is better positioned to check it
than whoever wrote it — so the verification belongs on the receiving end, and it
only happens if you ask for it.

One drift was load-bearing. An issue asserted *"no logging exists for this path."*
A subagent found `middleware.py:263` — `log.debug(f"{tool_call=}")` — absent from
the brief, and **added it unrequested**, with the caveat that it is `log.debug` on
the legacy prompt-based path rather than native function calling. Without that
line, the first reviewer to find it would have dismissed the entire issue on a
technicality. The unrequested caveat is what made the issue survive contact.

A sibling case the same hour: a steward endorsed a worker's phrasing — *"scheduled
runs are exactly the case where nobody is watching the socket"* — and said it would
go to the human **verbatim**. It was wrong: the socket layer does deliver, via a
`USER_POOL` Redis fallback; the **client** discards the event when the message id
is not local to that tab. Endorsing a formulation is adopting it, and an
endorsement adds credibility without adding verification.

**A correction can be the contamination.** Later the same day the same worker
prepared a comment fixing a file path in a published issue — and **the issue had
never contained the wrong path.** The bad path came from the worker's own checklist
handed to an agent; the agent correctly reported *"this path exists in no tree,"*
and the worker re-read that as *"the issue cites this path."* It never opened the
issue. A subagent refused to publish, on the grounds that the premise was false.

That refusal is the whole lesson. Publishing would have planted, in the team's
own issue, **a correction of an error that did not exist** — a comment fixing a
miscitation which is itself a miscitation. Corrections carry more authority than
ordinary claims, because they arrive wearing the costume of diligence, and nobody
audits a self-correction.

**The steward approved it without opening the issue either** — and then did
something worse. It ran the check *afterward*, saw `layout/` absent and the correct
path present, and read that as *"the fix landed"*, reporting that the body "**now**"
carried the right path. The same observation is fully consistent with **the error
never having existed.** Having the tool and using it did not help, because the
result was interpreted against expectation rather than tested against both
explanations.

So: **absence of an error is not evidence that the error was fixed.** Before
publishing a correction, confirm the defect is actually present in the artifact,
not merely present in the report about the artifact.

This is the sixth citation failure in one day and the only one of its species: the
first five were *"the citation is wrong"*; this was *"the claim that the citation is
wrong is wrong."*

**Evidence strength is not a duplicate check — and authorising harder is the tell.**

2026-08-10. A worker proposed filing a finding: a comment asserting a security
boundary (*"schedule runs enable only web_search"*) that the code contradicts.
The steward reviewed it, judged the evidence unusually solid — verbatim comment,
contradicting code path, control cases proving the gating works elsewhere — and
authorised it **more** strongly than usual: *file it directly, no pre-review,
this one closes in code.*

The issue already existed. **#1633, open, same finding, same argument, same two
remedies.** And the steward's authorisation had endorsed one further claim from
the worker's brief — that `tool_ids` also flows into schedule turns — which
**#1633 had already retracted in its own self-correction section** (producer
writes camelCase, consumer reads snake_case; measured zero matching rows). Filing
as instructed would have **reinjected, into the team's own tracker, an error that
tracker had already corrected.**

Only the standing "check for duplicates first" clause in the delegation caught
it. The worker's subagent ran the check and stopped.

Two things went wrong, and they compound:

1. **Strong evidence answered the wrong question.** "Is this claim true?" and
   "does this already exist?" are independent, and the steward used the first
   answer for both. Nothing about a well-evidenced finding makes it novel.
2. **Confidence relaxed the process exactly where the process was the only
   remaining guard.** The stronger the evidence felt, the more review got waived
   — so the check that would have caught it was removed by the very quality that
   made it feel unnecessary.

The steward had applied the correct discipline hours earlier, telling a different
worker to fold a finding into existing issue #1124 *"rather than inflating it
into a new one."* Same steward, same morning, opposite handling — because that
finding arrived as an extension of a known issue, and this one arrived feeling
like a discovery.

**An issue number is a citation too — and it drifts by rescoping, not by moving.**

2026-08-10. A steward sent a worker to investigate a prompt-growth defect and
framed the deliverable as a single question: *"is this the same phenomenon as
#758, yes or no?"* — a deliberately tight scope, chosen so the answer could not
end in "seems related."

**#758 had been rescoped three days earlier.** A parent issue was split into
three axes (tools / system / messages); #758 was narrowed to the *messages* axis
alone, and the *system* axis — the one the defect actually lived on — had been
moved to a different issue entirely. The steward was holding what #758 meant the
last time it read it.

The worker did not answer the question. It **corrected the question**, then
answered the corrected one: wrong comparison target, here is the real sibling,
and the relationship is partial overlap rather than either fold-in or
independence.

The steward's conclusion — *don't fold this into #758* — was **right, and partly
wrongly grounded.** That combination is the dangerous one: a correct verdict
generates no friction, so the stale premise underneath it survives to be reused.

This is the file:line failure in a different costume. A line number drifts
because the file moves; **an issue number drifts because its scope is rewritten
underneath a stable identifier.** The number is *designed* never to change — that
is what makes it feel like a fixed address — and nothing in a reference to
"#758" reveals which version of #758 the writer had in mind.

The compounding risk is delegation. A tightly-scoped question is normally good
practice; it is what stops an investigation from ending in vagueness. But
**scoping a question around a stale reference hands the delegate a wrong frame
with your authority on it** — and the tighter the scope, the fewer degrees of
freedom the delegate has to escape it. Only a worker willing to reject the
question caught this.

**How to apply:**

- **Re-read an issue before you build a decision on it.** Especially one you are
  citing from memory to scope someone else's work. Issues get rescoped, split,
  narrowed, and superseded while the number stays put.
- **When you scope a delegate's question around a reference, say it is
  checkable.** "Compare against #758 — and if #758 turns out not to be the right
  comparison, say so and tell me what is." A tight scope should constrain the
  *answer*, never forbid correcting the *question*.
- **Ask them to open the reference and confirm its scope still matches — do not
  rely on them noticing.** The worker above caught the rescoping only because a
  *comparison* task forced it to open both issues; phrased as "fix X per #758" it
  would have gone straight to the code and tangled identically. Its own words:
  *"방법이 좋아서가 아니라 이슈를 직접 열어봤기 때문"* — not good method, just
  having opened it. **Delegate-side catching is contingent on the task shape, so
  it is not a guard you may lean on.** The burden stays with whoever hands over
  the reference.
- **Treat a delegate rejecting your framing as a higher-grade catch than a
  delegate correcting a fact.** A wrong fact produces a wrong answer; a wrong
  frame produces a confidently right-looking answer to a question nobody needed.
- **Right conclusion, wrong reason still needs correcting.** When the verdict
  survives but its grounds do not, fix the grounds out loud — the reasoning is
  what gets reused next time, and a correct outcome is exactly what stops anyone
  from auditing it.

- **"Does this already exist?" is a separate gate from "is this true?"** Search
  the tracker before authorising any new issue, comment, or document. Strength of
  evidence has no bearing on novelty.
- **Treat an urge to waive review as a reason to keep it.** When you find yourself
  saying "this one is clear enough to skip the check", that is the moment the
  check is load-bearing — you are removing a guard on the strength of the same
  feeling that would make you miss what it guards against.
- **A finding that feels like a discovery deserves the duplicate check most.**
  Extensions get folded in naturally; discoveries get filed on enthusiasm.
- **When you endorse someone's brief, you adopt every claim in it** — including
  the ones you did not examine and the ones the target artifact has already
  retracted.

- **Open the artifact before correcting it.** A correction needs the defect
  verified in the target, not in the message describing the target. Two greps —
  does the bad value appear, does the good one — cost seconds.
- **Never approve a correction you have not independently confirmed.** Endorsing a
  fix is asserting the flaw exists.
- **When evidence matches your expectation, name the other explanation it also
  fits.** "Fixed" and "never broken" leave identical traces; only one of them is
  worth publishing about.
- **Put "verify the citations I gave you and report any drift" in the delegation
  prompt body**, not as an afterthought. Unasked, a delegate assumes your
  references are ground truth and builds on them.
- **Re-open a line before citing it in anything durable** — an issue, a handoff, a
  message upward. Cheap at the moment of writing, expensive after someone acts on
  it. See [[butler-asserting-comments-stop-verification]].
- **Never strip an unrequested caveat a delegate adds.** They were looking at the
  file and you were not. The caveat usually exists because they found something
  that contradicts the brief — which is exactly the information you delegated for.
- **Endorsing someone else's phrasing is asserting it.** "Send that verbatim"
  transfers your credibility onto a sentence you did not check.
- **Cite what does not drift when you can.** A symbol name, a function, or a
  distinctive string survives refactors; a bare line number does not. Give both —
  the number for speed, the symbol so the reader can recover when it has moved.
- **Treat a delegate correcting you as the system working.** Four catches in a day
  means the loop is functioning; zero catches would have meant it was not running.

**SPT:** the habit is *when you hand someone a file:line, ask them to check it —
and when they hand back a caveat you did not ask for, keep it.*
