---
name: live-aws-verification-uncloseable-in-worker-sandbox
description: "Worker sandboxes structurally have NO AWS credentials, so any verification that requires a live AWS call — `cdk diff` against deployed state, a CloudWatch app-log spot-check, a prod/staging DB query — CANNOT be completed inside the worker. The worker can only produce INDIRECT evidence (ECS 'deployment succeeded' signal, code-structure/alembic-head checks, deploy-script logs). Never let indirect evidence be rounded up to 'verified': when a deploy/change is cleared on it, NAME the residual gap explicitly and route its closure to a cred-host/CI or to 정수님, or have 정수님 explicitly accept the gap."
metadata:
  node_type: memory
  type: feedback
---

**The recurring root (monocle fleet, 2026-08).** Worker sandboxes do not carry AWS credentials. So the
class of verification that needs a *live* AWS call is structurally impossible from inside the worker — the
worker can run everything up to the AWS boundary and no further. It has recurred across ≥3 distinct
verification types in one week, same root each time:
- **`cdk diff` against deployed state** (envelop #923, jarvice #1468) — needed to catch phantom DESTROYs of
  a stale branch; worker can `cdk synth` but not `cdk diff`. See [[cdk-synth-is-not-a-deploy-diff]].
- **CloudWatch app-log spot-check** (jarvice-978 #1420 staging deploy) — 정수님's explicit "flag-OFF tenants
  must stay log-clean" requirement could NOT be directly confirmed; only *indirect* evidence existed (ECS
  stabilization success + code-structure + local alembic-head match), not a live log query.
- **live prod/staging DB query** (envelop STAGING-VERIFICATION-RUNBOOK Step 3) — the specific tenant/connector
  couldn't be pinned in code, so the worker substituted read-only SQL for a *jarvice engineer* to run.

**Why it's a trap.** The deploy/change usually *works*, and the deploy tooling emits a confident success
signal ("✅ ECS deployment completed successfully"). It is easy to treat that as end-to-end verification.
But the tooling's success signal is not the same as *the specific property you were asked to verify* — e.g.
"deploy stabilized" ≠ "flag-OFF tenants emit no logs." The gap is silent: nothing errors, so an
indirect-only clearance reads as fully verified when it isn't.

**How to apply (steward/butler).**
1. **Distinguish the deploy-succeeded signal from the property under test.** When a worker clears a
   deploy/change, ask: was the *specific requirement* (log-clean, no phantom DESTROY, correct tenant state)
   verified by a live AWS call, or only inferred from the deploy tooling + code structure?
2. **If it's indirect-only, NAME the residual gap explicitly** in the handoff and the escalation — never let
   "indirect evidence" round up to "verified." A good worker (jarvice-978 did this) discloses the gap
   honestly; steward's job is to make sure it reaches 정수님 as a *named* open item, not buried.
3. **Route the gap's closure to where creds exist:** a cred-host / CI job that can run the live diff or log
   query, OR 정수님 doing a manual check, OR 정수님 *explicitly accepting* the gap. "No creds in-sandbox" is
   never a reason to silently accept the indirect evidence as sufficient — it's a reason to route the
   closure elsewhere or surface the residual risk for a human accept.
4. **This is a [[premortem]] trigger for the irreversible slice** — for the prod one-way door (main+tag), an
   un-closed live-verification gap is a hard reason to hold; for a reversible staging deploy it's a named
   caveat 정수님 can weigh, not necessarily a blocker.

**SPT:** the habit is *worker sandboxes can't make live AWS calls, so any AWS-live verification is
indirect-only from inside — NAME the residual gap and route its closure to a cred-host/CI/정수님; never
round indirect evidence up to "verified."*
