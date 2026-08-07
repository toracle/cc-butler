---
name: butler-a-merge-conflict-is-a-textual-event-not-a-semantic-one
description: "'There is a conflict' does not mean 'the two sides differ' — identical content arriving by different routes (squash promotion vs. direct merge) conflicts too, so read the diff before concluding a resolution loses anything"
metadata:
  node_type: memory
  type: feedback
---

A merge conflict is a statement about **text arriving by two paths**, not about the two sides holding different content. Git raises a conflict whenever the same region was touched on both branches since the merge base — including when both touches produced **byte-identical** results. So "resolving by taking one side" is dangerous *sometimes*, and the question of whether it drops anything is a separate, semantic question you must answer by reading the diff. Do not infer the second from the first, in either direction.

**Why:** On 2026-08-07 the butler was assembling the devel→staging promotion (jarvice #1581) in a scratch clone and ran `git checkout origin/devel -- infra/cdk/stacks/scheduler-stack.ts && git add -A`. The steward stopped it, warning that overwriting with devel's version would silently discard whatever staging held in that file — a real hazard, and the file was the very one the night's fix touched.

The butler then did the verification the warning demanded, and the warning did not survive it. Staging *had* touched the file since the merge base (via the squash promotions #1573/#1578), but that content was **textually identical** to what devel had merged first (#1572/#1575); git flagged the region because two paths reached it, not because they disagreed. The full staging↔devel diff on the file reduced to exactly the intended edits. A whole-file checkout of devel was provably equivalent to auto-merge plus the devel-side hunk. Nothing staging-only existed to lose.

The steward was the one over-reading its evidence this time — the same shape as [[butler-a-true-observation-licenses-only-its-own-scope]], which the fleet had already tripped over four times that day. "Conflict" was a true observation; "therefore staging holds unique content" was outside its scope.

Two things are worth keeping about how this went well. The warning was still **correct to raise** — it named a possibility and demanded measurement, and measurement closed it; that is the loop working, not a false alarm to be embarrassed by. And the verification surfaced something better than its own answer: devel's `const launcherSubnetSelection` feeds **both** the Lambda's `vpcSubnets` and the new worker env var, so the two can no longer drift apart — the night's bug prevented structurally rather than patched.

**How to apply:**

- On any conflict, before resolving by taking a side, run `git diff <ours> <theirs> -- <path>`. **Empty or reducible-to-the-intended-change means taking a side loses nothing.** Non-empty means you must understand each hunk before choosing.
- Expect spurious-looking conflicts wherever a repo mixes **squash promotion with direct merges** — the same change reaches two branches as two unrelated commits, and every later merge re-conflicts on it. The conflict is an artifact of the workflow, not evidence of divergence. See [[butler-squash-merging-a-base-strands-the-stacked-pr]].
- Resolve with a **path-scoped** `git add <path>`, never `git add -A`, even in a fresh clone where `-A` is harmless. Habits have to be built while they are cheap so they hold when they are not. See [[butler-a-tools-success-check-covers-only-its-own-layer]].
- Conversely, do not let this principle talk you out of checking. The asymmetry is real: **a wrongly-dropped change produces no error and passes every check.** It surfaces days later as "devel has it, staging doesn't." Silence is the failure mode, so pay the cost of the diff every time.
- When you raise a hazard and the evidence dissolves it, say so plainly and record what the check established. A warning retired by measurement is a completed loop; treating it as a loss makes the next person hesitate to raise one.
