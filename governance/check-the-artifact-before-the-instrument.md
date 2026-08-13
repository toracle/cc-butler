---
name: butler-check-the-artifact-before-the-instrument
description: "''모니터해봅시다' names a goal, not a toolset — the system's own output is usually visible for free in the surface the human is already looking at, while telemetry is exactly where permission walls and classifiers live; reaching for instruments first converts a free yes/no into a permissions negotiation, and the pull is strongest right after the human lists the tools he happens to think of'"
metadata:
  node_type: memory
  type: feedback
---

There are two places to learn whether something worked: the **artifact** it was
supposed to produce, and the **instrument** that watched it produce it. The
artifact is usually free — it sits in the surface the human already has open. The
instrument is usually gated: logs need IAM, dashboards need auth, APM needs a
connected tool, and every one of those is a place a classifier or a permission
wall can stop you.

So the ordering is not a style preference. **Reaching for the instrument first
converts a free yes/no into a permissions negotiation** — and the negotiation is
about access you may turn out not to have needed at all.

**Why:** 2026-08-08, midday. 정수님 created a one-off schedule set to fire one
minute out, precisely to test whether the scheduler symptom was still live. Two
minutes later he said:

> "스케쥴이 시작한지 2분 경과했습니다. 상태를 모니터해봅시다. sentry도 보고,
> cloudwatch도 보고, 등등."

The worker went straight down all three instrument paths and hit a wall on each:
CloudWatch returned `AccessDenied` on `logs:FilterLogEvents`, the Sentry CLI call
was stopped by the session's auto-mode classifier, and the DB census was the third
proposal. It then presented 정수님 a three-way menu — **including a request to open
`logs:FilterLogEvents` on the `-stg` role.**

**Nobody had looked at the chat thread.** That was the actual test: does a result
message appear? No IAM, no classifier, no profile — the same screen he had just
used to create the schedule. One glance splits the entire tree: *arrived* and the
symptom is resolved, making all three instruments unnecessary; *absent* and you
hold a fresh live reproduction, which is both better evidence and a clear
justification for opening the log permission.

Two details make this worth keeping.

**First, the worker had itself set the correct bar** an hour earlier — *"로그만 보고
됐다고 판단하지 않는 게 안전합니다"* — and dropped it the moment the human's phrasing
pointed at tools. A standard you authored does not survive on its own; it competes
with the last sentence you read.

**Second, 정수님's phrasing was a gesture, not a specification.** *"sentry도 보고,
cloudwatch도 보고, **등등**"* — the *등등* is the tell. He named the instruments that
came to mind and waved at the rest. His goal was *find out whether it worked*.
Reading a tool list out of it and executing that list literally is how a free
answer became three blocked calls and a permission request.

Note what was **not** wrong: the worker refused to escalate to the admin role when
`-stg` was denied, and stopped rather than routing around the classifier — both
correct, and both patterns that had already failed twice that day. The defect was
never the boundary. It was the **order**.

This is also the same-shaped error as the night that preceded it: hours spent on
the mechanism of a symptom nobody had confirmed was still occurring. Skipping the
cheap confirmation is not a one-off slip; it is the default pull.

**How to apply:**

1. **Before opening any instrument, ask: what did this system produce, and can I
   just look at it?** The output artifact — the message, the row, the file, the
   rendered page — is the primary observation. Telemetry is secondary evidence
   about how the primary came to be.
2. **Rank candidate observations by cost before running any of them.** Free and
   decisive beats gated and decisive, always. If the free one splits the tree, the
   gated ones are not "also worth doing" — they are unnecessary until it does not.
3. **Never request a permission expansion to answer a question a free observation
   might already answer.** You may be buying access to learn something you already
   could have known, and each request spends the human's security attention.
4. **Read "let's monitor it" / "check the status" as a goal, not a toolset.** When
   the human lists tools, he is offering the ones he thought of. Enumerated
   examples followed by *등등* / "etc." are explicitly an incomplete gesture. Answer
   the goal.
5. **When the human's phrasing conflicts with a bar you set earlier, say so rather
   than silently switching.** "You mentioned Sentry and CloudWatch — before those,
   can you just tell me whether the message arrived?" costs one line and is not a
   contradiction of him.
6. **Do not hand up a menu of blocked paths.** Three options that all require
   something you lack is not a decision for the human; it is an unfinished
   observation. Make the free one first, then decide yourself — see
   [[butler-reversibility-is-the-escalation-test]].
7. Related: [[butler-unblocking-restores-the-option-not-its-priority]] (the same
   hour, the same investigation — a lifted permission is not a reason to spend it),
   and [[butler-check-whether-it-is-measurable-before-escalating-it-as-a-decision]]
   (its sibling: that one asks *whether* to measure, this one asks *which
   measurement costs least*).
