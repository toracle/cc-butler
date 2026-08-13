---
name: butler-the-human-acts-outside-your-channels-so-re-check-before-re-asking
description: "'A pending-decision list goes stale not only when your messages fail to arrive, but when the human resolves an item himself — and on a shared machine an artifact's author field cannot tell you he did it, because agents run under his credentials; the discriminator lives in session scrollback, which compaction destroys, so verify before you compact and before you re-ask'"
metadata:
  node_type: memory
  type: feedback
---

A queued decision can be resolved without either role observing it. 정수님 works
directly — in worker sessions, on GitHub, in his own terminal — and none of those
surfaces report back into `pending_decisions`, the dashboard, or the butler's
screen. So an item can be **done in the world and still open in our list**, and
nothing in the list will look wrong.

This is a different failure from [[putting-it-in-a-queue-is-not-delivering-it]].
That one is about *our* messages not arriving. This one is about *the world
changing outside every channel we watch* — our record is internally consistent,
freshly written, and false.

**Why:** 2026-08-08, ~03:35. The steward finished handing butler the scheduler
census, and closed with a list of what could wait until tomorrow — including
*"관측성 이슈 파일링 go-ahead는 내일도 됩니다."* It had sat on the dashboard as open
decision #4 for a day: a drafted GitHub issue awaiting 정수님's go-ahead.

A worker mentioned in passing that it had "registered the structural defect as
issue #1606." The steward checked rather than reading past it:

```
gh issue view 1606 --repo warmblood-kr/jarvice
→ OPEN, author: toracle (Jeongsoo, Park), created 2026-08-07T18:02:12Z
```

**정수님 had filed it himself, ~28 minutes earlier.** The item had been dead for
half an hour while our list still asked him to authorize it. Had butler presented
that list, it would have requested permission for a thing he had already done with
his own hands, which reads as not having noticed his work.

Two details make it worth recording. First, **the steward's own correction message
carried the stale item** — the paragraph was written *after* the resolving event,
because the list was the source, not the world. Freshly composed is not fresh.
Second, **the tell was one clause in a worker's status report**, not a
notification; a passing mention is often the only trace an out-of-band action
leaves, and reading past it is the default.

**The author field proves nothing, and the proof is perishable.** The steward
wrote "정수님 filed it himself" into this very principle on the strength of
`author: toracle` alone — then caught that this machine's `gh` runs under 정수님's
credentials, so *(a) he typed it* and *(b) an agent ran it and inherited his
identity* leave an **identical** trace on GitHub. On a shared-credential machine,
authorship, committer, and actor fields are all non-discriminating.

What actually settles it lives in the session scrollback: the worker found the
command under a **`<bash-input>` tag — the harness marker for a `!`-prefixed
command the human typed** — with a first attempt failing on truncated arguments
and a retry succeeding, and no matching Bash tool call of its own. That is
falsifiable and specific, and it confirmed (a).

Note the ordering trap. The worker was at 287k and had just said *"압축하셔도
됩니다."* **Compaction would have summarized away the only evidence that could
answer the question** — so the steward asked first and compacted second. If the
answer had been (b), the consequence would have been heavier than a wrong
principle: it would mean an external mutating action ran without the human's
direct execution, which is exactly the boundary
[[issue-creation-is-steward-discretion-the-rest-of-external-exposure-is-not]]
draws.

Note also what butler did right on receipt: it ran its own `gh` call before
accepting the steward's correction, rather than propagating a claim it had not
checked — the receiver-side half of
[[a-channel-that-carries-authority-must-be-verifiable-by-the-receiver]].

**How to apply:**

1. **Check the artifact before presenting any item as pending, not before adding
   it.** Issues, PRs, files, tables — the state lives there, not in our list. A
   pending item is a claim about the present tense; a `gh issue view` or a file
   read costs seconds, and the whole list is worth sweeping before a briefing.
2. **Treat "the human works outside our channels" as the normal case.** He is not
   an input queue. He types in worker sessions, files issues, runs commands. Every
   decision list should be read as *"these were open when written"* — and re-read
   against reality before it goes in front of him.
3. **When a worker mentions a completed external action in passing, verify it and
   reconcile the list immediately.** "I registered it as #1606", "that's already
   merged", "he ran it yesterday" — these clauses are load-bearing. Verify who did
   it and when; *who* is the part that changes what you say next.
4. **Never infer human execution from an author/committer/actor field.** Agents on
   this machine inherit 정수님's credentials, so those fields cannot separate him
   from us. The discriminator is the harness marker in scrollback (`<bash-input>`
   for his `!` commands) versus an agent's own tool-call record — check that, or
   answer "모르겠음".
5. **Ask before you compact.** Scrollback is the only home for execution
   provenance, and compaction converts it to summary. Whenever a question's answer
   lives in a session's history, get the answer *first* — even when the session is
   near its context ceiling and asking costs tokens you would rather save.
6. **Rank re-asking above being late.** A late item costs the human waiting. A
   re-asked item tells him his own completed work was not seen, and it puts every
   other line in the same briefing in doubt. When unsure whether an item is still
   live, check it or drop it — never present it hedged.
7. **A correction is not automatically current.** The steward's own supersession
   carried the stale line, because it was composed from the list rather than from
   the world. When correcting one item, re-validate the others travelling in the
   same message. See [[a-true-observation-licenses-only-its-own-scope]] — fixing
   one thing is what makes the rest feel checked.
8. **Hold your own durable artifacts to the bar you impose on others.** This
   principle asserted a fact about who did what; the assertion outlives the
   session, gets cited later as settled, and nobody re-derives it. Verify claims
   you write into the store *because* they are durable, not despite it.
