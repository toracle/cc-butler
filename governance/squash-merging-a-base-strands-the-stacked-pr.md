---
name: butler-squash-merging-a-base-strands-the-stacked-pr
description: "Squash-merging the base of a stacked PR leaves its commits non-ancestors of the target, so a naive rebase replays them and can silently revert or duplicate what just landed"
metadata:
  node_type: memory
  type: feedback
---

When PR B is stacked on PR A's branch and **A is squash-merged**, A's content enters the target as one new commit — A's original commits never become ancestors of the target. Git still regards them as unmerged work sitting under B. Nothing errors; B just quietly becomes wrong in three ways at once:

1. **Merging B now targets A's dead branch**, not the integration branch — zero effect where you wanted it.
2. **Retargeting B** to the integration branch makes its diff appear to re-contain all of A's changes.
3. **`git rebase <integration>`** tries to replay A's already-landed commits, conflicts, and — resolved carelessly — **reverts or duplicates what A just merged.**

The third is the dangerous one: the revert is silent, and **CI can be green on it**, because the tests that would notice are usually the ones A brought with it, which the bad resolution may also have removed.

**Why:** On 2026-08-05 a five-PR merge sequence ran cleanly (jarvice #1546 → #1548 → #1547 → …), each step rebased with CI re-run. A sixth PR, #1551, was based on #1546's branch `wire/978-mysql-dispatch` rather than `devel`. When #1546 squash-merged, that branch went **diverged: ahead 2, behind 6**. Nobody had flagged it — the whole sequence had been checked for *text conflicts between siblings*, and this hazard is not a conflict at all. It was found only because the steward re-verified the three merges against `origin` with `gh` instead of trusting the worker's reports, and noticed the base branch had vanished beneath the stacked PR.

**How to apply:**

- Before merging any PR, ask **whether anything is stacked on its branch**. The merge that strands a child is invisible from the parent's side.
- Rejoin a stranded stacked PR with **`git rebase --onto <integration> <old-base> <branch>`**, which drops the already-squashed commits, not `git rebase <integration>`, which replays them.
- **Verify by diff, not by exit code.** After the rebase, `git diff <integration>...HEAD` must contain **none** of the parent's changes. If any appear, stop — the resolution went wrong. A rebase that "succeeded" is not evidence.
- A green CI does not clear this. See [[butler-a-test-that-cannot-fail-is-not-evidence]].
- One upside worth knowing: retargeting a stacked PR to the default integration branch usually **makes its Checks tab work again** — an empty Checks tab is a common symptom of a feature-branch base, not of an untested PR. See [[butler-same-shape-as-the-last-one-is-a-hypothesis]] before assuming any *other* empty Checks tab has this cause.

See also [[butler-git-claims-need-origin-verification]], [[butler-close-topic-audit-uses-local-refs]].
