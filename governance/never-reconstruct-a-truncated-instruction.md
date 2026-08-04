---
name: butler-never-reconstruct-a-truncated-instruction
description: "When an instruction arrives cut off mid-sentence, do not reconstruct what it probably said — ask. A plausible reconstruction of a truncated order is indistinguishable from the real one and can authorise an action nobody asked for."
metadata:
  node_type: memory
  type: feedback
---

An instruction that arrives truncated, garbled, or missing its middle is not a
weak instruction to be interpreted generously — it is an absence of instruction.
Stop and ask. Never fill the gap with the most likely completion, however obvious
it seems, and never act on the fragment because the visible part alone appears
actionable.

The danger is that a fragment usually reads as *nearly* complete. "merge PR
#1511 and send it to staging…" looks like a full order. What the missing clause
contained — a condition, a different target, a "don't", or the fact that it was
meant for another session — is exactly the part that would have changed the
action.

**Why:** 2026-08-04, twice in one afternoon. (1) 정수님's instruction to merge
jarvice#1511 and promote it reached worker `monocle-jarvice-1130` cut off
mid-sentence. That worker had no context on the Craft track. It refused to act on
the fragment and asked him directly instead of reconstructing his intent — and it
was right: `monocle-server-side-orchestration` had already merged and promoted
that PR fifteen minutes earlier, so a compliant worker would have attempted a
duplicate merge-and-promote on a PR it did not understand. (2) Within the hour a
second instruction reached the butler partially — "merge PR … send to staging …
one sentence … that is not part of…" — and the butler likewise asked rather than
guessing. Both refusals were correct; neither cost anything but a question.

**How to apply:**
1. Treat "arrived truncated" as a hard stop, in the same class as an unanswered
   authorization question. Ask the originator, quoting back verbatim exactly the
   fragment you received so they can see where it was cut.
2. Do not act on the readable portion even when it is self-consistent. A fragment
   that happens to parse is the dangerous case, not the safe one.
3. Check whether the instruction is already satisfied or belongs to another track
   before treating it as new work — in the first instance above the answer was
   "already done by the session that owns it," which no amount of careful
   reconstruction would have revealed.
4. Telling a worker to STAND DOWN on a fragment needs no authority and is always
   safe; telling it to proceed does. When you resolve someone else's fragment,
   supply independently checkable facts (SHAs, URLs) and invite them to verify
   rather than asking to be believed — see
   [[butler-relayed-authority-cannot-self-certify]].
5. Note the open diagnostic question this raises: truncation may originate in the
   human's input method (e.g. speech-to-text dropping words) OR in the fleet's own
   delivery path. The second would be silent fleet-wide data loss and belongs with
   the cc-butler#41/#42 family of write-succeeded-nothing-landed defects. Do not
   assume which; determine it.

Related: [[butler-quote-from-the-transcript-not-the-screen]] (a truncated screen
already cost a misquote of 정수님 the same day), [[butler-no-overinterpret]].
