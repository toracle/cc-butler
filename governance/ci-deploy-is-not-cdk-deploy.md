---
name: ci-deploy-is-not-cdk-deploy
description: "In a repo where app code and infrastructure deploy via DIFFERENT paths, merging + a green CI deploy does NOT apply infra-definition changes (env vars, IAM, task defs, EventBridge, Lambda config) — those need a separate, often human-run `cdk deploy`. So 'I merged the CDK source change' ≠ 'it is live', in BOTH directions: a safety fix you merged may not be applied, and a dangerous value you 'removed' may still be live. Verify what the pipeline ACTUALLY deploys before inferring live-infra state. And when live-infra control is blocked (no creds / manual step), prefer making the system safe-without-knowing (a code-level guard that ships via the app pipeline) over struggling to confirm the unknown."
metadata:
  node_type: memory
  type: feedback
---

**The incident (stark #919/#923, 2026-08-02).** A CMK auto-reconcile kill-switch env var
(`CMK_TIER_RECONCILE_ENABLED`) was believed controlled by merging CDK source edits. It was not:
the repo's CI deploy pipeline (`.github/workflows/_deploy.yml` → `monocle_stark.cli.deploy`) only
builds/pushes the app image, updates Lambda *images* (`update_function_code`, NOT
`update_function_configuration`), and `force-new-deployment`s ECS with the *existing* task def. It
NEVER runs `cdk deploy`. Infra definitions (env vars, IAM, task defs, EventBridge rules, Lambda
config) change only when a human runs `cdk deploy stg` manually. So the merged "flag off" fix was in
the branch source but NOT applied live — and, symmetrically, the "flag on" value was likely never
applied live either (a pre-deploy `cdk diff` showed it as *added*, i.e. absent live). "Merge" told us
nothing about "live."

**Why it's a trap.** The deploy tooling emits a confident success signal ("✅ deployment completed")
and CI is green — so it reads as end-to-end done. But "app deploy succeeded" ≠ "the infra change I
merged is live." The gap is silent: nothing errors, so a merged-but-unapplied safety change looks
handled when it isn't. This is the deploy-mechanism sibling of [[cdk-synth-is-not-a-deploy-diff]]
(synth-clean ≠ deploy-safe) and [[live-aws-verification-uncloseable-in-worker-sandbox]] (no in-sandbox
creds to observe live state).

**How to apply (steward/butler + workers).**
1. **Before treating any infra-definition change as live, learn how THIS repo deploys.** Grep the
   workflows for `cdk deploy`. If CI doesn't run it, the change only reaches live via a separate manual
   step — say so explicitly; "merged" is not "applied." Read `deploy.py`-equivalents: does it touch
   `update_function_configuration` / register a new task def, or only images?
2. **Verify what actually deployed, not that a merge happened.** For a real infra change, confirm the
   live resource — or NAME the residual gap (per [[live-aws-verification-uncloseable-in-worker-sandbox]])
   and route its closure to a cred-host / CI / human. Do not round "CI green" up to "infra live."
3. **Prefer safe-without-knowing over confirm-the-unknown.** When you can't observe or change live infra
   (blocked creds, manual-only step), ask: can I make the system safe *regardless of* the live value? In
   #923 the fix was a hardcoded code-level guard at the top of every automatic entry point — which ships
   through the *normal app pipeline* (the entry points' code lived in the app image, incl. an
   image-based Lambda updated by `update_function_code`). That closed the risk with no `cdk deploy` and
   no broad AWS profile, and made the un-observable live flag value moot. Trying to *read* the live value
   had hit the credential wall; making the code self-refuse did not.
4. **Absence-of-trace is not proof.** Forensics from git/GitHub metadata (no manual deploy recorded after
   the flag entered source) is the complete *available* answer and often decisive — but keep the caveat
   attached: this team's own history (a manual deploy undocumented for 6 days until a bug surfaced it)
   shows metadata can miss reality. State likelihood, not certainty, until a live read confirms.

**Related flag lesson (record with [[feature-flag-gate-every-door]]).** Enumerate exhaustively what a
flag *arms* at introduction time, not just what UI it gates. One flag here armed BOTH manual use AND
the automatic cron + save/delete signals — so "we blocked execution" diverged from what the flag
actually did. "Enables the feature" ≠ "arms automatic execution."

**SPT:** the habit is *find out how the repo actually deploys before believing a merge is live; verify
the deployed resource or name the gap; and when live control is blocked, make it safe-without-knowing
via the app pipeline rather than chasing an unobservable value.*
