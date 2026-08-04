---
name: butler-workers-must-not-reach-aws-profiles
description: "정수님's ruling 2026-08-04: workers should be unable to READ or USE AWS profiles, as far as achievable — enforce at the launch environment, not by telling each worker to abstain; route genuinely-needed AWS work to a cred-host instead"
metadata:
  node_type: memory
  type: feedback
---

**정수님's decision, 2026-08-04, verbatim:** "wokrer는 가급적 AWS profile을 읽거나 사용할 수 없게 합시다."
("Let's make it so workers cannot, as far as possible, read or use AWS profiles.")

So the standing posture is: **a worker session should not be able to reach AWS credentials at all** — not read the profile list, not authenticate, not call. `가급적` acknowledges perfect isolation may not be reachable; it does not soften the intent.

**Why this exists:**

The protection we believed we had was imaginary. The note `live-aws-verification-uncloseable-in-worker-sandbox` asserted workers "structurally have NO AWS credentials." False: `~/.aws/config` defines **production** profiles (`monocle-jarvice`, `monocle-stark`, `warmblood-cross-account-admin`) and the `aws` CLI is on PATH. Workers run as the same user, in the same home. What we called structural was mere convention — it held only while every agent chose not to use what was sitting there.

That false premise was load-bearing in a real assessment: on 2026-08-03 the harness flagged a subagent for `ssm:StartSession` into the **production** bastion, and reasoning from "workers can't reach AWS" makes such a flag read as noise.

**How to apply:**

- **Enforce at the launch environment, not in prompts.** `subagent-scope-is-not-self-enforcing` — a prompt is not a sandbox, and an instruction every worker must remember is the read-guard anti-pattern (`fix-at-the-write-site-not-the-read-guard`). The correct site is wherever sessions are launched: redirect `AWS_CONFIG_FILE` / `AWS_SHARED_CREDENTIALS_FILE` away from the real ones, plus a permission deny-rule on `aws` invocations.
- **Be honest about the strength.** Env redirection under the same UID is a strong speed bump, not a jail — a determined agent can unset a variable. Combined with a classifier deny-rule it is meaningfully enforced. Never describe it as structural isolation; that is the exact mistake this note corrects.
- **Do not leave legitimate AWS work stranded — route it.** Some tracks genuinely need live AWS: prd-bastion policy confirmation (`monocle-stark` admin, `iam:SimulatePrincipalPolicy`) and the 16-scheduler CDK deploy (`monocle-jarvice-stg`, hand-run since no workflow runs cdk). Those go to a cred-host, to CI, or to 정수님 — never by re-opening worker access. When a worker's verification needs AWS, it must NAME the residual gap and escalate it, not reach for a profile.
- Distinguish `simulate-principal-policy` (asks whether an action *would* be allowed; performs nothing, reads nothing) from a live call. Both are now out of scope for workers, but they are not the same severity, and harness flags lump them together.
- `prod-data-access-requires-explicit-approval` still stands on top of this. Read-only is not a justification.
