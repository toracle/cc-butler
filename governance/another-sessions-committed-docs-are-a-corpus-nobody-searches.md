---
name: butler-another-sessions-committed-docs-are-a-corpus-nobody-searches
description: "Fleet sessions commit operational findings into repo docs, but no session searches another's — so the same incident gets investigated twice in parallel. Before investigating an incident, grep docs/ and sibling worktrees for its date, PR number, and error string. The knowledge is written down; it is just not retrieved."
metadata:
  node_type: memory
  type: feedback
---

Fleet sessions write genuinely good operational documentation and commit it to the
repo. No session reads another session's. So two sessions investigate the same
incident in parallel, days apart, neither knowing the other's work exists.

The failure is **not** documentation discipline — the doc existed, was thorough,
was committed, and was correct. The failure is that nothing retrieves it.

**Why:** 2026-08-07, ~22:40. The steward was doing something unrelated — the fleet
check kept flagging `monocle-security` as long-idle, and the stated risk is a stuck
dialog rather than genuine idle, so the steward read its screen to check. It was
genuinely idle. But the screen happened to show two filenames in its restored
context: `docs/operations/2026-08-05-github-actions-lambda-migration-policy-gap.md`
and a `pr1562-body.md` scratchpad.

**PR #1562 was the exact PR the scheduler track had spent that evening
investigating**, as the fix for the 08-05 staging deploy failure. A different
session had already written a 500-line operations doc about that failure, two days
earlier, committed to the repo the scheduler session had checked out.

Reading it produced three things the scheduler track did not have:

1. A **live risk it did not know about**: `scheduler-stack.ts` pins `Code.ImageUri`
   to a moving tag literal, not a digest, so CloudFormation cannot detect image
   changes — meaning the only thing that ever updates those Lambdas is the deploy
   job that had been `AccessDenied` since they were created. If still true, every
   e2e run 정수님 was doing was against code that was not the repo's code
   ([[the-running-daemon-may-not-be-the-code-on-disk]]). It turned out to be
   already fixed — but that was **checked**, not assumed, and the checking took two
   commands.
2. **Empirical confirmation** of a finding the scheduler had reached by code
   reading only: the migration stage emits exactly four log lines, none per-tenant.
   A single tenant failing produces a byte-identical log. That upgraded an
   inference to an observation, which is the difference between a filed issue that
   argues and one that shows.
3. A **cheaper path to the open question**: the deploy log contains the migration
   ECS task ARN, whose CloudWatch logs may hold the per-tenant results — possibly
   answering the open question without the staging RDS access that had already
   been escalated to the human as a blocker.

None of this required new investigation. It required *reading something already
written*. And it surfaced by accident, from a stuck-dialog check.

**The uncomfortable part is the counterfactual.** Nothing in the workflow would
have surfaced it. The scheduler session was competent, thorough, and investigating
the correct artifact — it simply had no reason to believe another session had been
there first, and no habit that would have told it.

Note this is the third retrieval failure recorded on a single day, alongside
[[search-for-the-existing-decision-first]] (the human's own closure) and
[[novelty-is-a-claim-about-the-issue-set-not-about-the-code]] (the issue tracker).
Three different corpora, one shape: **the answer already existed and the cost of
looking was one command.** When a class of error recurs three times in a day in
three disguises, the common factor is not the corpus — it is that investigation
feels like work and retrieval feels like admin.

**How to apply:**

1. **Before investigating an incident, grep for it first.** Search `docs/`,
   `docs/operations/`, and any `.claude/worktrees/` siblings for the **date**, the
   **PR/issue number**, and a distinctive fragment of the **error string**. One
   command, run before the first hypothesis, not after the fourth.
2. Put this in the dispatch. A worker sent to investigate an incident should be
   told to run that search as step zero — it will not occur to it, because from
   inside a session there is no visible evidence other sessions exist.
3. **The steward is the only one positioned to do this**, and that is the actual
   duty here: workers see one repo checkout; the steward sees the whole fleet and
   which sessions touched which incident. When dispatching, say plainly *"session X
   worked on this two days ago, read its docs first."*
4. **Docs written by a parked session are the most valuable and the least likely to
   be read** — the session that could have told you is idle, compacted, or closed.
   Treat a long-idle session's committed artifacts as an asset to harvest, not
   dormant state to leave alone.
5. When a doc's status header contradicts the repo (this one said "not merged, not
   deployed" while the code was in both `devel` and `staging`), **trust the repo and
   correct the doc**. A stale header does not invalidate the doc's findings — it
   just means nobody revisited it, which is this same principle one level down.
6. Report cross-session finds upward explicitly. Otherwise the fleet's only record
   is that one session got lucky.

**SPT:** *before you investigate, spend one grep asking "has another session
already been here?" — the fleet writes more than it reads.*
