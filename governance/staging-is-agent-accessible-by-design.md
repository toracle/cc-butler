---
name: butler-staging-is-agent-accessible-by-design
description: "정수님's standing position: agents should be able to reach staging; a staging DB password is not the gate because the DB sits in a private VPC — network access via the AWS profile is"
metadata:
  node_type: memory
  type: feedback
---

**정수님, 2026-08-05:** *"스테이징은 저는 에이전트가 액세스 가능하면 좋을 것 같습니다. 어차피 AWS 프로파일 퍼미션이 없으면 패스워드를 안다고 해도 이게 프라이빗 VPC에 있기 때문에 접근을 할 수가 없어요."*

Two things follow, and they are separate.

**1. A staging DB credential is not the gate; network reach is.** The staging RDS instances sit in a private VPC, reachable only through an SSM tunnel, which requires the AWS profile. A leaked staging password with no AWS permission grants nothing. So treat a staging credential appearing in a transcript as **hygiene, not an incident** — worth noting once, not worth an alarm or a mandatory rotation. Say what the actual second factor is before recommending remediation.

The caveat worth keeping in one sentence: on the fleet host, the transcript and the AWS profile live on the **same machine**, so the two factors are co-located there. That is a modest, real point — not a reason to escalate.

**2. Agents reaching staging is desired, not tolerated.** Do not design around worker sandboxes lacking AWS access as if it were a fixed constraint to be routed around. Where a worker needs staging to verify its own work, the goal is to give it that reach — this is the same instinct as [[butler-if-the-human-is-your-only-oracle-build-the-harness-first]]. Compare [[butler-live-aws-verification-uncloseable-in-worker-sandbox]], which describes the *current* limitation; this note records that the limitation is not the intent.

**Why:** On 2026-08-05 a worker could not verify a deploy because worker sandboxes have no AWS credentials, and repeatedly had to hand commands to 정수님 to run. When one such command printed a staging DB credential in plaintext into a session transcript, the butler flagged it and proposed rotation. 정수님's reply reframed it: the credential alone is inert without VPC reach, and the better direction is for agents to have staging access rather than for humans to be the fleet's only hands.

**How to apply:**

- Keep the **production** boundary exactly as strict as it is — see [[butler-prod-data-access-requires-explicit-approval]] and [[butler-workers-must-not-reach-aws-profiles]] for non-`-stg` profiles. This note narrows to **staging** and nothing else.
- Before calling a leaked credential an incident, **name the other factor that must also be held** and say whether it is. "Password on disk" is a fact; "therefore exposed" is a conclusion requiring the network story.
- **Two different mechanisms block agents today, and only one is IAM.** The local sandbox classifier blocks credential-adjacent reads (`~/.aws/config`, `secretsmanager get-secret-value`) regardless of what IAM allows. Granting IAM permissions alone will not change what a worker can do. Any work toward agent staging access must address both layers, or it will look granted and behave blocked.
- Least-privilege still applies within staging: prefer the narrow `-stg` role and widen only on evidence, not on a first failure. See [[butler-a-tools-success-check-covers-only-its-own-layer]] for why "it was blocked, so we widened" is the wrong reflex.
