---
name: cdk-synth-is-not-a-deploy-diff
description: "`cdk synth` passing does NOT mean a stack is safe to deploy. A branch that is behind its integration branch and touches a SHARED stack (app-stack, shared infra) will, on a LIVE `cdk diff` against deployed state, show unrelated live resources (other teams' Lambdas/SQS/EventBridge) as DESTROY — because the branch is missing their definitions. synth only renders the branch's own template; it cannot see the delta vs what is actually deployed. So when steward/butler gate or approve ANY CDK deploy, require a live `cdk diff` against the real deployed state (staging AND prod), never synth-only."
metadata:
  node_type: memory
  type: feedback
---

**The near-miss (2026-08-01, envelop-encryption).** A worker prepping a staging deploy of PR #923
(`feat-stark-reconcile-routine`, CMK reconcile work) ran a **live** `cdk diff` before committing and
found its branch was **289 commits behind origin/devel**. Deploying it — staging OR prod — would have
shown **AutoTopupSweepLambda / AutoTopupReconcileLambda + their SQS/EventBridge as DESTROY**: unrelated
auto-topup infra (stark#963) that merged to devel *after* this branch forked and is **live in production
now**. `cdk synth` had passed cleanly. The worker held, committed nothing, and reported — a near-miss
caught only because it ran the LIVE diff, not synth alone.

**Why synth misses it.** `cdk synth` renders *this branch's* CloudFormation template in isolation. It
says nothing about the deployed stack. `cdk diff` compares the synthesized template against **what is
actually deployed**, so it surfaces "resource X exists in the account but not in my template ⇒ DESTROY."
A branch behind its base is missing the resource definitions others added since the fork, so those live
resources read as deletions. This is invisible from inside the branch and invisible to synth.

**It generalizes and it nearly recurred the same hour.** Steward had just told butler to "lean approve"
a *different* worker's CDK PR (jarvice #1468, 16-scheduler) on its **synth-level** analysis. Checking in
light of the above: #1468 was **4 commits behind devel and also touched `app-stack.ts`** — the same
staleness-touches-shared-stack pattern, smaller magnitude, and it too could not run a live diff (no AWS
creds in its sandbox). The synth-only "lean approve" was withdrawn and replaced with "require a live diff
first." Two workers, one hour, same trap.

**Structural kin of [[parallel-fleet-migration-graph-forks]].** Both are the same root: *a branch behind
the shared integration branch carries a hazard that is invisible from inside the branch* — there, a
second migration head; here, phantom DESTROYs of others' live resources. The more parallel workers share
a repo/infra, the more certain it is. Blaming the worker is wrong; the branch simply cannot see what
merged to the base after it forked.

**How to apply.**
1. **Gate every CDK deploy on a LIVE `cdk diff` against the real deployed state — staging AND prod —
   showing no unexpected DESTROY.** synth passing is necessary, not sufficient. Never clear a deploy on
   synth alone.
2. **Check branch staleness first.** `git rev-list --count origin/<branch>..origin/<base>` — if the
   branch is behind base AND its diff touches a shared stack (`app-stack`, shared infra, bin/cdk entry),
   treat a live diff as mandatory, not optional.
3. **No AWS creds in the worker's sandbox is itself a reason to withhold approval**, not to fall back to
   synth. The diff has to run somewhere with creds (an AWS-cred host / CI) before the deploy is cleared.
4. **Steward/butler: HARD-STOP the deploy until the clean live diff exists.** A synth-based "looks
   staging-only and reversible" is a hypothesis, not clearance. This is a [[premortem]] trigger — a risky,
   partly-irreversible move (resource destruction) where the failure is silent.
5. **Bring the branch current before deploying** (merge-in or rebase per repo convention), then re-diff.
   A current branch off the up-to-date base does not show the phantom DESTROYs.

**Amplifier — shared-account setups (jarvice, confirmed 2026-08-01).** jarvice's staging and prod live in
the **same AWS account** (`<AWS_ACCOUNT_ID>`); environments are separated by **stack name only** (`--context
env=stg|prd` → `...StackStg` vs `...StackPrd`), NOT by account isolation. So every "staging-only, prod
untouched" claim rests entirely on correct `--context`/stack-name targeting *within one account* — there
is no account boundary to catch a mistargeted stack. This makes the live-diff-before-deploy bar MORE
essential, not less: a targeting slip cannot be stopped by account permissions, only seen in the diff.

**SPT:** the habit is *require a live `cdk diff` against deployed state (both envs) before clearing any
CDK deploy, and check branch-behind-base staleness whenever the diff touches a shared stack* — never
"synth passed, ship it." In a shared-account setup, treat stack-name targeting as the only guardrail and
verify it in the diff.
