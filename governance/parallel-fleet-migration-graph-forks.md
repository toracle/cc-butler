---
name: parallel-fleet-migration-graph-forks
description: "Running many workers in parallel on ONE repo systematically forks the Alembic (or any linear-DAG) migration graph — two branches each add a migration off the same parent, producing 2 heads and breaking `upgrade head`. This is a STRUCTURAL consequence of fleet parallelism, not a worker mistake. Standing habit: every worker adding a migration checks heads against the CURRENT integration branch right before opening/merging the PR, verifies via the real API (ScriptDirectory.get_heads()), and resolves with a standard merge revision — never by rewriting or reparenting."
metadata:
  node_type: memory
  type: feedback
---

**The pattern, observed 4+ times in ~2 weeks on `jarvice` alone** (the 2026-07-15 incident;
`merge_7268_a7c9`; `schedule_tables` + `craft_env`; `welcome_delete` + `schedule`; the #1420
access-policy migration vs. a concurrent devel merge). Each time: two branches independently add a
migration whose `down_revision` is the same parent, both land, the tenant branch now has **2 heads**, and
`alembic upgrade head` breaks.

**Why it is structural, not carelessness.** A migration chain is a linear DAG with a single head, and its
`down_revision` is fixed at *authoring* time. A fleet of workers each branch from the same integration
branch and each author correctly against the head *they* saw. The fork is created by **merge order**,
which no individual worker can observe from inside its own branch. So the more parallel workers on one
repo, the more certain this becomes — it is a cost of the fleet model itself, and blaming the worker who
merged second is both wrong and useless.

Corollary: this generalizes past Alembic to **anything with a single-head linear DAG** — ordered seed
files, changelog chains, any "latest wins" pointer file.

**How to apply.**
1. **Check heads late, not early.** The head that matters is the one on the *integration branch at merge
   time*, not the one at authoring time. So the check belongs immediately before opening/merging the PR —
   re-checking after a rebase, not once when the migration was written.
2. **Verify with the real API, not by reading files.** `ScriptDirectory.get_heads()` (or the project's
   equivalent) is authoritative; eyeballing `down_revision` across files misses exactly the cross-branch
   case that causes this. Workers have caught real forks this way that judgment alone missed.
3. **Resolve with a standard merge revision.** That is the in-repo precedent and it is the correct fix.
   **Do NOT reparent or rewrite an already-merged migration's `down_revision`** — that rewrites history
   others have already applied ([[backward-compatible-changes]]).
4. **Confirm the two branches touch disjoint objects first.** A merge revision reconciles the *graph*; it
   does not make a genuine ordering dependency safe. If both branches alter the same table/column, the
   conflict is semantic and needs a real decision, not a merge node.
5. **Steward/butler: expect it and say so in the dispatch.** When dispatching migration work while other
   workers are active on the same repo, tell the worker up front that a fork is likely and that
   head-verification before merge is part of Definition of Done — cheaper than rediscovering it each round.

**What good looks like (workers have done this correctly every time).** Detect via the real API →
confirm disjoint objects → add a merge revision → re-verify a single head → note it in the report. The
recurrence is not a discipline failure; the gap is that each worker rediscovers the need independently.
That rediscovery is what this note removes.

**SPT:** the habit is *re-verify heads against the integration branch immediately before merge, with the
real API* — not a migration linter, and never a history rewrite.
