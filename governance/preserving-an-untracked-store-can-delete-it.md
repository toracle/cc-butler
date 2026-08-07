---
name: butler-preserving-an-untracked-store-can-delete-it
description: "Committing untracked files onto a branch makes them tracked — and checking out any branch without that commit then deletes them from the working tree the tools actually read"
metadata:
  node_type: memory
  type: feedback
---

Preserving and restoring are **two operations**. Committing untracked files onto a branch makes them *tracked*, and a tracked file only exists in the working tree on branches whose history contains that commit. So the moment anyone checks out a branch that predates the preservation commit, the files vanish from disk — including from the live directory that tools read and regenerate from. Untracked files survive every checkout precisely *because* git ignores them; committing removes that accidental immunity.

**Why:** 2026-08-05. Twelve uncommitted files were found in the `governance/` store (11 untracked, 1 tracked-modified). The steward had them committed to a new branch off `origin/main`, pushed, and `ls-remote`-verified — correct preservation. The worker then returned to the branch it started on (`fix/governance-index-bidirectional-check`, PR #50's branch), which is ordinarily exemplary hygiene. That checkout **deleted all eleven from the working tree**, because they were now tracked and that branch has no such commit. Its report — *"working tree is clean there now"* — was literally true and was precisely the symptom: clean because the files were gone. The store dropped from 90 principles to 80, and `record_principle` kept reporting success, because it verifies its own write and not what a later checkout does.

The instruction contained the flaw: preservation was designed, restoration was never ordered. Both the steward who designed it and the butler who approved it read "commit the untracked files" without asking what committing does to a *live* directory the tools read.

**How to apply:**
- Before committing a live store or config directory, ask: **which branches will this working tree be on afterwards?** If any of them lack the commit, the directory empties when someone switches.
- Pair every preservation with an explicit restore step, and verify the files are on disk *after* returning to wherever work continues.
- To restore, use the form that moves **files**, not **history**: `git checkout <branch> -- <path>` followed by `git restore --staged <path>`. `merge` and `cherry-pick` both carry a commit and will contaminate an unrelated PR's diff — which is the same contamination that branching off the mainline was meant to avoid.
- Verify by **naming** the files (`test -f` each), not by counting them. The right count with the wrong files passes a count check.
- The durable fix is not "land it on the mainline" alone: branches forked *before* that commit still empty the directory. That only works combined with rebasing every branch used in the checkout — an unenforced discipline, the class of fix that breaks quietly. Making the store checkout-independent (a worktree pinned to the mainline) is what closes it structurally. See [[butler-structurally-impossible-beats-checked-and-absent]].
- Related: [[butler-a-tools-success-check-covers-only-its-own-layer]], [[butler-squash-merging-a-base-strands-the-stacked-pr]] — the same family, where a git operation silently changes what exists where.
