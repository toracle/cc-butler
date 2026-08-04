---
name: butler-a-pr-body-freezes-constraints-at-authoring-time
description: "A PR/issue body records the constraints as of the moment it was written and never updates when the human later lifts them — so a merged PR whose body says 'do not merge' reads as a process violation to every later reader"
metadata:
  node_type: memory
  type: feedback
---

A PR or issue body is a snapshot of its authoring moment, including the dispatch constraints in force then. Those constraints get lifted in conversation; the body does not update. So the artifact ends up asserting a rule that was later revoked, and every future reader — human or agent — sees a contradiction and reasonably suspects the process was violated.

**Why:**

2026-08-04. jarvice#1511 (the Craft credential-strategy fix) carried in its body: "branch/commit/push/PR-open only — do NOT merge, approve or deploy." It was then merged to devel and promoted to staging. A different worker, investigating the track for 정수님, spotted the mismatch and flagged it honestly while noting it could not judge another track's affairs — good instinct, exactly the right response.

Nothing was violated. That constraint was the authoring-time instruction to the worker, and 정수님 lifted it explicitly hours later: "그 크래프트 1511번 PR 머지 하고 스테이징으로 보냅시다. 테스트 해 볼 수 있도록요." The merge was authorized by the person whose constraint it was.

But the body still reads as a standing prohibition, and it will keep doing so. The cost is not hypothetical: it consumed a worker's attention, generated an escalation, and would have left 정수님 wondering whether his fleet merged against instructions.

**How to apply:**

- When a human lifts a constraint that a PR/issue body records, **post a comment saying so, with their words and the time**. One comment, at the moment of acting. The body cannot be trusted to age well; the timeline can.
- Read a PR body as "the constraints as of `createdAt`," not as current policy. Before treating it as a live prohibition, check the comments and the decision record for a later lift — `search-for-the-existing-decision-first`.
- When you flag an apparent process violation in someone else's track, do it the way this worker did: state the mismatch, say you cannot judge the other track, do not act on it. That is the correct handling of an out-of-scope contradiction.
- Same family as `the-tracker-keeps-claiming-work-that-already-shipped` and `release-scope-comes-from-the-diff-not-the-titles`: a written record is a fact about when it was written. Ask what it was true of, not just what it says.
