---
name: butler-compare-content-not-hashes-when-a-sync-may-have-republished
description: "When a push is rejected or a commit looks missing and an automated sync/mirror touches the same repo, compare CONTENT before concluding work was lost — a republished identical change carries a different SHA, and hash comparison reports it as missing."
metadata:
  node_type: memory
  type: feedback
---

Before concluding that a commit is missing, was lost, or still needs pushing, ask
whether anything OTHER than you writes to that repo — a periodic sync, a vault
mirror, a bot, another session. If so, **compare the content, not the hash.** An
automated process that republishes the same change produces a **different SHA for
identical content**, so a hash comparison reports your work as absent when it is
already live.

The cost of getting this wrong is not just a wasted check: you re-push or re-create
work that already exists, producing duplicate commits, a conflicting history, or a
"restored" file that silently reverts someone else's later edit.

**Why:** 2026-08-04. A worker's vault note-embed commit `800bbef` failed to push —
first a non-fast-forward rejection, then a DNS failure. It looked stuck local-only.
When it retried, it found the change was **already live on `origin/main`,
re-committed under a different SHA by a periodic vault sync.** It verified the
CONTENT was identical and fast-forwarded to match. Had it compared SHAs, an
identical change would have read as a lost one, and the natural response — force
it, cherry-pick it, re-commit it — would have duplicated work already published.

**How to apply:**
1. On a non-fast-forward rejection, ask *who else pushed* before assuming a
   conflict with your content. A sync process republishing your own change is a
   different situation from a real divergence and calls for a fast-forward, not a
   merge or a force.
2. Verify with a content comparison — `git show <ref>:<path>` against your local
   file, or a diff of the paths you touched. "My SHA is not on the remote" is not
   evidence your change is not on the remote.
3. Report the two facts separately, as always: **"committed X"** and **"pushed /
   not pushed"** are different claims — and now a third exists, **"content is live
   under another SHA"**, which is neither of the first two.
4. Never force-push to resolve this. If content is already live, fast-forward; the
   force would discard whatever the sync added alongside it.
5. Generalises to any mirrored or generated artifact: identity of *bytes* is the
   question, and identity of *revision ids* is a proxy that this class of process
   breaks. Related: [[butler-state-desync]] on what is true living somewhere you
   are not looking, and
   [[butler-absence-of-evidence-needs-a-control-and-an-evidence-class]] — a hash
   lookup is a query that cannot find a republished change, so its negative result
   is structurally uninformative.
