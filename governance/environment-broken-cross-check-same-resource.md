---
name: environment-broken-cross-check-same-resource
description: "When a worker concludes 'the environment is broken' (CI runner offline, service down, network dead), cross-check a sibling session using the SAME resource before accepting it. But the cross-check has two halves and both are load-bearing: (1) is a sibling working right now? (2) is that sibling ACTUALLY on the same resource? Skipping (2) flips the error to the opposite conclusion — 'it works next door, so it's not broken' — which is just as wrong. Also: a repo-scoped API count of 0 (e.g. /repos/.../actions/runners) is not evidence of absence; org-scoped resources don't appear there."
metadata:
  node_type: memory
  type: feedback
---

**The incident (dealmatch CI, 2026-08-03).** A worker concluded "the office self-hosted CI runner is offline
(0 registered runners)", parked PR #1109, and set a monitor to wait for the runner to return. Meanwhile
jarvice's CI ran fine all night — a merge, a checks pass, and a successful staging deploy. Two sessions held
contradictory beliefs about shared infrastructure and neither compared notes.

**Both halves of the cross-check matter, and skipping the second flips the error.**
The obvious lesson is *cross-check a sibling*. But when we actually ran it here, the naive version would have
produced the OPPOSITE wrong answer. jarvice's successful run reported
`runner_group_name: "GitHub Actions"`, `labels: ["ubuntu-latest"]` — **GitHub-hosted runners. jarvice never
touches the self-hosted runner at all.** So "jarvice's CI is green" says exactly nothing about the office
runner's health. Had we stopped at half the check, we'd have told the worker "the runner is fine, your
diagnosis is wrong" — confidently, and wrongly.

So the check is: **(1) is a sibling green right now, and (2) is that sibling actually on the same resource?**
Prove (2) from the run's own metadata (which runner, which group, which labels — not from what you assume the
repo does). Only a sibling that provably shares the resource is evidence about that resource.

**⚠️ Same-day sequel: the steward got (2) wrong by checking ONE run.** Hours after writing the above, the
steward inspected a single jarvice run — the *deploy* run — saw `ubuntu-latest` / GitHub-hosted, and
generalized it to the whole repo: "jarvice never touches the self-hosted runner." That was **false**.
A repo's workflows do not share a runner policy: jarvice's deploy ran GitHub-hosted while its **PR check
jobs** (`Frontend Unit Tests`, `Format & Build Frontend`) ran on `warmblood-x600-desktop-runner-3`,
`labels: ["self-hosted","Linux"]` — the very resource in question. The owner's original premise ("the repos
share a runner") had been correct, and the steward had told the butler it was false, who relayed it upward.
**Resource identity must be established for the SAME KIND OF JOB that is failing, not for the repo.** One
green run proves something only about that run's resource. Check the failing job class against the sibling's
equivalent job class.

The correction also resurrected a hypothesis that had been discarded too fast. The steward had suspected
office-wide DNS trouble, tested `getent hosts` on its own machine, got 3/3, and dropped it. But the failing
DNS was on the *runner desktops*, not the steward's host — and once the jarvice log was read
(`lookup auth.docker.io: i/o timeout`, `lookup registry-1.docker.io: i/o timeout`) it matched dealmatch's
DNS timeouts on a different runner, plus the steward's own intermittent `github.com` failures. Three
"separate" incidents were one infrastructure event. **A negative test result scopes a hypothesis; it does not
kill it.** The honest conclusion was "my host resolves fine," never "the network is fine."

**Corollary: a repo-scoped count of 0 is not evidence of absence.** `gh api /repos/{o}/{r}/actions/runners`
counts only runners registered *directly to that repo*; org-level runners never appear, so it returns
`total_count: 0` during perfectly healthy operation. In this incident BOTH the broken repo and the working
repo reported 0 — the number discriminated nothing. (And `/orgs/{org}/actions/runners` needs `admin:org`; a
403 there means *unknown*, not *none*. Don't round unknown down to zero — that is how the original wrong
conclusion got its confidence.)

**Look for a designed escape hatch before waiting on a repair.** The real cause here was a label, and the
workflow already had the switch built in:
`runs-on: ${{ fromJSON(vars.CI_RUNS_ON || '["self-hosted","Linux"]') }}` — one job requesting self-hosted
while every sibling job used `ubuntu-latest`, with `CI_RUNS_ON` unset so the default applied. A parameterized
`runs-on`, a feature flag, a fallback endpoint: when infrastructure "breaks," check whether someone already
anticipated it. Waiting for a repair that a config variable would bypass can burn days.

**But don't flip the switch unilaterally.** Moving a job off a self-hosted runner can silently break or leak:
the job may depend on that runner's network position (VPC-internal resources) or its instance-role credentials
(e.g. private CodeArtifact installs). Determine the dependency first, then route the change as a decision —
it alters repo-wide CI behavior. See [[prod-data-access-requires-explicit-approval]] for the same shape.

**How to apply.**
1. A worker reporting "environment is broken" is a **hypothesis**, not a finding. Before parking work on it,
   run both halves of the cross-check above.
2. Verify resource identity from run metadata, not assumption. `gh api .../runs/{id}/jobs` gives
   `runner_name` / `runner_group_name` / `labels`.
3. Treat a scope-limited API count of 0 as *uninformative* until you have confirmed the scope matches where
   the resource actually lives.
4. Ask "is there already a switch for this?" before scheduling a wait.
5. Steward owns this: you see the whole fleet, so you are the only one positioned to notice that two sessions
   believe incompatible things about shared infrastructure. Reconcile it rather than letting each session
   reason alone ([[evaluation-independence]] is about not copying conclusions — this is about not missing
   contradictions).

**SPT:** the habit is *when someone says the environment is broken, find a sibling that provably uses the same
resource — and if you can't prove sameness, you have no evidence either way.*
