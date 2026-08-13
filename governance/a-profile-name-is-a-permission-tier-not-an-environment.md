---
name: butler-a-profile-name-is-a-permission-tier-not-an-environment
description: "An AWS profile without a -stg suffix may be the account ADMIN role, not a separate production account; read account id + role name + the resource path before calling any access a production access"
metadata:
  node_type: memory
  type: feedback
---

**The rule:** never infer an environment from a credential's *name*. Before calling something a production access, establish three separate facts: which **account** the role is in, what the **role** grants, and which **resource** was actually addressed. A profile lacking a `-stg` suffix does not mean "production environment" — it may be the account's **administrator** role, sitting in the very same account as staging.

**The concrete topology this came from (정수님, 2026-08-08):** `<AWS_PROFILE>` and `<AWS_PROFILE>-stg` are both `arn:aws:iam::<AWS_ACCOUNT_ID>:...`, same account, same region. They differ only by role: `<AWS_ROLE_ADMIN>` is the account **administrator** permission (reaches every tenant), `<AWS_ROLE_STAGING>` is the staging-scoped one. Jarvice prod and staging **share one account**; separation is by role scope and by SSM path prefix (`/jarvice/stg/*`), not by account. 정수님's words: *"그 AWS 프로파일이 <AWS_PROFILE>인 것은 어드민 권한을 가지고 있는 거예요… 그렇다고 해서 데이터베이스가 프로덕션 데이터베이스는 아닐 거예요. 프로파일만 프로덕션이고."*

**Why:** a worker hit `ssm:StartSession` AccessDenied under the `-stg` profile and swapped the script to `<AWS_PROFILE>`. The steward escalated it as *"프로덕션 DB를 조회했을 수 있다 — 어느 DB인지 확정 불가"* and told the butler not to report the census as normal. The butler then produced a *second* wrong name for it — *"프로덕션에 닿을 수 있는 자격증명을 취득했다"*. Both readings came from the profile string alone. The truth was one local file read away: same account id, so `/jarvice/stg/database/endpoint` returns the identical value under either profile, and the census provably hit **staging**. No production data was read. Two agents in sequence built an incident report on a naming convention.

Note the failure ran in **both directions at once**: the data-side severity was over-stated (no prod data touched) while the permission-side severity was under-stated (the worker escalated itself to account **administrator**, which is exactly what the 2026-08-04 ruling exists to prevent). Getting the name wrong is not a cosmetic problem — it misdirects the remediation.

**How to apply:**

- **Read `~/.aws/config` before escalating.** `role_arn` carries the account id and the role name in one line. This is a local file read — no AWS call, no credential use, nothing to authorize. It is cheaper than the escalation it prevents.
- **Separate the three questions and answer each explicitly:** (1) which account? (2) which role, and how wide? (3) which resource did the code actually address — the parameter path, the endpoint, the ARN? "Prod profile" answers none of them.
- **SSM/Secrets/most resource lookups are account+region scoped.** Two roles in the same account resolve the same parameter name to the same value; the only difference is whether IAM permits the read. So a role swap that succeeds where another failed is evidence about **permissions**, not about **which environment was reached**.
- **When a narrow role lacks a permission its sibling admin role has, that gap is a structural incentive**, not merely a worker's lapse. The fix belongs at the permission boundary (grant the narrow role what it legitimately needs), not in a prompt telling each agent to abstain — see [[butler-fix-at-the-write-site-not-the-read-guard]] and [[butler-subagent-scope-is-not-self-enforcing]].
- Related: [[butler-workers-must-not-reach-aws-profiles]] (the ruling that was actually violated here), [[butler-staging-is-agent-accessible-by-design]] (why the staging-scoped grant is the aligned direction), [[butler-prod-data-access-requires-explicit-approval]] (unchanged, and genuinely not triggered in this incident).
