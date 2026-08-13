---
name: butler-a-stale-checkout-is-invisible-to-grep
description: "A local ref is a cached claim about the world, not the world — fetch before you measure or deploy. Three incidents in one night: a stale checkout regressed a prod authorization flag, an audit mis-attributed itself to a plugin version 8h out of date, and neither announced itself"
metadata:
  node_type: memory
  type: feedback
---

A checkout that is behind `origin` looks **exactly** like a current one. `grep`, `git log`, `git show`, a build, a `cdk synth` — every one of them reads your local refs and answers confidently, and nothing in the output says "as of whenever you last fetched." So the defect is invisible to inspection: you can read the file, quote the line, and be precisely wrong.

**A local ref is a cached claim about the world. Fetch before you measure, and fetch before you act.**

## Three instances in one night (2026-08-12/13), each corrupting something different

**1. It regressed a production authorization control.** 정수님 ran `cdk deploy JarviceSchedulerStackPrd -c env=prd`. The target stack never deployed (an IAM approval prompt with no TTY), but `cdk` deploys out-of-date *dependency* stacks first and had already finished six — replacing `JarviceAppStackPrd`'s chat-proxy task definition. Result: `MODEL_ACCESS_PER_USER_ENABLED=false` live on 100% of prod traffic, disabling per-user and per-department model-block enforcement.

The cause was entirely the checkout: **detached HEAD at `cdab0d68`, 11 commits / ~19.5h behind `origin/main`**, with `git merge-base --is-ancestor bae9e2ae HEAD` → **false**. That missing commit (PR #1724) had deliberately deleted the old `prd ? 'false' : 'true'` conditional. The stale tree still contained it, so `cdk synth` faithfully regenerated `false` and shipped it. **A commit that was already merged, already deployed once, and already correct got silently undone by a working copy nobody had fetched.**

Note the shape: nothing malfunctioned. Every tool did exactly what it was asked, against the wrong inputs.

**2. It mis-attributed a measurement's provenance.** The `monocle-skills` #69 trigger-eval audit ran its full 104-case round against local `cbbb96f` / **plugin 1.6.3**. `main` had moved to `c42a6c5` / **v1.7.0** — landing **~8 hours before the audit ran**. The workspace had never fetched.

The round itself survived (the corpus was identical at both revisions; every case recorded `plugin_version 1.6.3`), but the *trigger landscape* had changed underneath it: the plugin description — the retrieval-driving text — was rewritten, and a new skill now competes for every prompt. So the next round runs against a different roster, and comparing across them needs explicit care.

**The worker knew this only because its push collided with the moved `main`.** Had it not collided, the run would have recorded "1.6.3" with nobody noticing that `main` had said 1.7.0 for eight hours. **Provenance would have been quietly wrong, and the record would have looked complete.**

**3. The same shape without a checkout.** The night's third instance was a *banner* reading (91% weekly budget consumed) taken as world state and never corroborated against `/usage`, which read 0%. See [[butler-a-banner-reading-is-not-a-measurement]] — different instrument, identical failure: **a local reading treated as the state of the world, with no corroboration step.**

## How to apply

- **Before any deploy, `synth`, or plan-generating command: fetch, and verify the specific commit you depend on is an ancestor of `HEAD`.** Not "the branch looks right" — name the commit and check it: `git merge-base --is-ancestor <sha> HEAD`. The prod incident above is exactly what that one command prevents.
- **Before a measurement whose provenance will be recorded: fetch, and record the upstream SHA alongside the local one.** A run that logs only its local revision cannot be distinguished later from a run that was current. If they differ, say so in the results rather than letting the reader assume.
- **A restore or re-run from the same unfetched tree reproduces the defect.** After the incident above, the fix carried a mandatory precondition — fetch first, verify `bae9e2ae` is present — because deploying again from that checkout would have written `false` a second time and looked like the fix failing.
- **`cdk deploy <Stack>` is not scoped to that stack.** It deploys out-of-date dependencies too. Use `--exclusively` when you mean one stack; its absence is why a scheduler-scoped command rewrote the chat-proxy task definition.
- **Detached HEAD is a silent aggravator** — it pins you to a moment with no branch to signal drift, and `git status` reports nothing alarming.
- Generalize: this is [[butler-a-true-observation-licenses-only-its-own-scope]] item 16 (ask the remote, not your cache) in its most expensive costume, and a sibling of [[butler-the-running-daemon-may-not-be-the-code-on-disk]] (what is *running* vs. what is on disk) — here it is what is **on disk** vs. what is **on the remote**. All three are the same question: *whose copy of reality am I reading, and when was it true?*

Related: [[butler-git-claims-need-origin-verification]], [[butler-a-banner-reading-is-not-a-measurement]], [[butler-resurrect-with-the-constraint-before-the-context]].
