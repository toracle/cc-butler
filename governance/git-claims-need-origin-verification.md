---
name: butler-git-claims-need-origin-verification
description: "'N unpushed commits' / 'ahead of devel' / 'no upstream' are unreliable — verify against origin (fetch --prune, merge-base, ls-remote) before acting, and never force-push on such a count"
metadata:
  node_type: memory
  type: feedback
---

Any claim about git state that came from a *local* read — an audit's "N unpushed
commits", "14 ahead of devel", "no upstream", a `git log` count, a push command's
own stdout — is a hypothesis, not a fact. Verify against origin before acting on
it, and *always* before anything irreversible.

**Why:** on 2026-08-05 this exact pattern produced five separate false readings in
one day across different workers:

1. A fleet audit reported a branch "14 commits ahead of devel" — its upstream was
   merely misconfigured to point at `origin/devel` instead of itself; it was
   already fully pushed under its own name.
2. jarvice-978's workspace showed "8 unpushed commits" — after `git fetch --prune`
   and a per-branch `git log <branch> --not --remotes`, the real number was **0**.
   The four flagged branches were orphaned duplicates of already-squash-merged PRs
   (#1397, #1403), confirmed byte-identical.
3. server-side-orchestration found three jarvice branches rejected as
   non-fast-forward. Instead of assuming divergence or force-pushing, it ran
   `git merge-base --is-ancestor <origin-branch> origin/devel` on each: all three
   were already ancestors of devel — 정수님 had rebased/squashed them a week
   after the local snapshots were taken. Force-pushing would have created
   confusing duplicate branches of already-integrated work.
4. stark: one of three "unique" commits was already merged into devel under a
   different SHA (PR #1082).
5. A subagent read an old checked-out branch as if it were current devel and
   reported a regression that did not exist.

The unifying failure is **reading stale local state as current**. It has two
distinct moments — *branch-from* time (branch off freshly-fetched `origin/devel`,
not a long-lived local checkout) and *read* time (confirm the ref before trusting
a read of source, especially when delegating investigation to a subagent).

**How to apply:**
- `git fetch --prune` **first**, then compare fresh. Do not trust "N ahead of X"
  framing or stale `[gone]` tracking refs.
- Before concluding a branch holds unpreserved work, check
  `git merge-base --is-ancestor <branch> origin/<mainline>` — squash/rebase makes
  content-identical work look divergent by SHA.
- Confirm a push landed with `git ls-remote origin refs/heads/<branch>` and match
  the SHA. The push command's own output is not proof; neither is local `git log`.
- A non-fast-forward rejection is a **signal to investigate, never a reason to
  force-push**. Diff the actual content, not just commit messages.
- When a local branch is stale relative to origin, prefer pushing the work to a
  **new branch** (a new ref cannot conflict) over pulling/rebasing unknown
  upstream commits to make a mainline push succeed.
- When delegating code investigation to a subagent, either have it fetch and
  check out a known-good ref itself, or hand it the exact commit to treat as
  current.

See [[butler-verify-delivery]] — same shape: the send/write succeeding is not
evidence the thing arrived.
