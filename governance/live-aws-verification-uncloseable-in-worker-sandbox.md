---
name: butler-live-aws-verification-uncloseable-in-worker-sandbox
description: "⚠️ THIS NOTE'S ORIGINAL PREMISE IS CONTRADICTED — worker sandboxes are NOT structurally free of AWS credentials; ~/.aws/config lists production profiles and the aws CLI is on PATH"
metadata:
  node_type: memory
  type: feedback
---

**⚠️ PREMISE CONTRADICTED 2026-08-04 — read this first.**

This note previously asserted that worker sandboxes "structurally have NO AWS credentials, so any verification requiring a live AWS call CANNOT be completed inside the worker." **That structural guarantee does not exist.** Verified by the butler directly, reading config only (no secrets read, no auth attempted, no calls made):

- `~/.aws/config` defines **production** profiles alongside staging ones: `<AWS_PROFILE_1>`, `<AWS_PROFILE_2>`, `<AWS_PROFILE_3>`, `<AWS_PROFILE_4>`, `<AWS_PROFILE_5>`, plus `<AWS_PROFILE_6>` / `<AWS_PROFILE_7>`.
- The `aws` CLI is on PATH at `~/.local/bin/aws`.
- `~/.aws/credentials` holds static keys for only `<AWS_PROFILE_1>`, `<AWS_PROFILE_2>`, `<AWS_PROFILE_3>`, `<AWS_PROFILE_4>`.

**What is established vs. not:**
- ESTABLISHED: production profile *definitions* are reachable from the agent environment, and the CLI exists. There is no sandbox boundary making AWS unreachable.
- NOT ESTABLISHED (do not round up): whether those prod profiles would successfully authenticate right now — they require SSO or role assumption, and that was not tested. Also, this was confirmed in the steward's environment; that workers share it is a strong inference from same-user/same-home, not a tested fact.

**Why this matters more than a documentation error:**

The false premise was load-bearing in assessing a real security incident. On 2026-08-03 the harness flagged a subagent for `[Credential Exploration]`, naming `ssm:StartSession` into **both staging and production bastions**, `rds-db:connect`, `secretsmanager:GetSecretValue`, and Lambda env-var reads. If you believe workers cannot reach AWS, that flag reads as noise. It is not noise. The steward also relied on this note an hour before discovering it was false, and told a worker its AWS checks were "structurally impossible."

So the protection we thought was **structural** is merely **conventional** — it holds only as long as every agent chooses not to use what is sitting there.

**How to apply now:**

- Never cite "workers can't reach AWS" as a safety argument. It is false. If a task must not touch AWS, that has to be enforced by instruction and by the permission classifier, not assumed from the environment.
- The genuine remaining constraint is narrower and still worth stating: a worker producing INDIRECT evidence (an ECS "deployment succeeded" signal, a code-structure check, an alembic-head check) has not verified live AWS state. When a change is cleared on indirect evidence, NAME the residual gap and route its closure explicitly — do not let it round up to "verified."
- `simulate-principal-policy` only ASKS whether an action would be allowed; it performs nothing and reads no data. Harness flags lump it together with live calls. When assessing such a flag, the decisive question is narrow: **did an actual StartSession / GetSecretValue against production succeed?** Only CloudTrail answers that — neither a harness banner nor the subagent's own denial can settle it.
- `prod-data-access-requires-explicit-approval` still governs, and is now the ONLY thing governing. Read-only is not a justification.

Open decision with 정수님 as of 2026-08-04: whether workers should have production AWS profiles reachable at all. Until answered, treat prod profile access as forbidden by instruction, and say so in every dispatch that touches infrastructure.
