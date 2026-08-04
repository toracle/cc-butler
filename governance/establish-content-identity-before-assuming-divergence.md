---
name: butler-establish-content-identity-before-assuming-divergence
description: "A branch that looks diverged may not be: origin's commit is often YOUR commit under a rewritten SHA (squash-merge, rebase). Diff the trees before reconciling — then move the minimum, verify at the remote, and protect uncommitted state explicitly."
metadata:
  node_type: memory
  type: feedback
---

**What happened (2026-08-04, `monocle-server-side-orchestration`, post-shutdown restore).** The
steward found two commits that would not push: `monocle` `b47eee5`/`687aafb` on
`devx/local-testing-gotchas`, with origin **1 commit ahead**. It deliberately did
not rebase them itself and handed them to their author.

The worker did not accept the divergence at face value. It checked whether
origin's `6d5385b` was actually *different work*:

```
$ git diff 687aafb 6d5385b
                      # empty — identical tree
```

`6d5385b` **was** its own `687aafb`, squash-merged by GitHub under a rewritten
SHA. So only `b47eee5` was genuinely new. It moved exactly that one commit with
`git rebase --onto`, confirmed the pre/post tree diff was empty, and verified the
new tip by `git ls-remote` rather than trusting push output.

**The reflex this replaces.** "Origin is ahead, mine won't push" reads as *divergence*, and
the reflexes are all destructive in proportion: rebase everything, merge, force-push, or
escalate a conflict that isn't one. Rebasing both commits would have duplicated
already-merged work. Force-pushing would have destroyed the squash-merge. Both
"succeed".

## The discipline

1. **Diff the trees before believing the SHAs.** A rewritten SHA is not new work.
   Squash-merge, rebase-merge, cherry-pick and a shared clone's rebase all produce
   *the same content under a different identity* — the [[verify-delivery-at-the-recipient-not-the-return-string]]
   problem in git's own namespace. `git diff <mine> <theirs>` empty ⇒ nothing to reconcile.
2. **Move the minimum.** Rebase only the commits that are genuinely new
   (`--onto`), not the whole branch, and confirm the tree is unchanged afterwards —
   the old content is a free regression oracle.
3. **Verify at the remote, not at the push.** `git ls-remote` / `merge-base
   --is-ancestor`. "Everything up-to-date" and a clean `log <upstream>..HEAD` are
   both satisfiable while your recorded SHA is reachable from nothing (cc-butler#41
   instance 5, the same evening).
4. **Protect uncommitted state explicitly.** Stash before, confirm restored after.
   In this case three untracked local-dev files (`bootstrap.sh`,
   `docker-compose.yml`, `docker/stark/stark.local.json`) were the only
   *irreversible* thing in the operation — everything else was recoverable from
   origin.
5. **On a shared clone with many writers, cherry-pick onto current `origin/main`;
   do not rebase a badly-behind branch.** The same worker's vault clone was **364
   commits behind**. It fetched the commit by path out of the stale clone into the
   real one and cherry-picked.
6. **An append-only field's conflict is usually not a conflict.** Two dated log
   entries appended to the same frontmatter field are *independent records*, not
   competing edits. Concatenate chronologically. Picking a side silently deletes
   someone's record — and a conflict resolution that deletes data reports success.

## Why the steward hands these back rather than fixing them

A non-fast-forward needs a judgement about whether the *content* is still correct
after the divergence, and only the author has that. The steward's standing
git-ops autonomy covers pull/rebase/test-verify/push — it stops at
"is this still right?". Pushing by explicit SHA refspec with a per-repo
fast-forward check is the steward's job; deciding what a diverged branch *means*
is the author's.

Pairs with [[compare-content-not-hashes-when-a-sync-may-have-republished]] —
same insight, arrived at from the other direction.
