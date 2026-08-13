---
name: butler-a-label-is-a-claim-not-the-thing-it-names
description: "'Five times in one day: a profile name read as an environment, a log group's emptiness as a task's absence, a model display as history, failed=0 as a launch, NULL as never-started — every label is a value some other system wrote, at some other time, to answer some other question, and substituting it for the thing is invisible precisely because the label really is about the thing'"
metadata:
  node_type: memory
  type: feedback
---

A name, a counter, a status column, a UI string — each is a **value some system
wrote, at some past moment, to answer some question of its own**. When you read it
as an answer to *your* question, you have silently substituted a proxy for the
thing. The substitution is hard to see because the label genuinely *is* about the
thing. It is not a random error; it is a plausible one.

The label is also **cheaper to read than the thing**, which is exactly why it gets
substituted under time pressure.

**Why:** 2026-08-08. This happened **five times in one day**, across unrelated
domains, in one investigation:

1. **`<AWS_PROFILE>` (no `-stg` suffix) → "production environment."** False. Same
   AWS account as staging; the suffix marks a *permission tier*, and that profile is
   the account **administrator** role. Two escalations were built on it, one reaching
   정수님. One `~/.aws/config` read would have settled it.
   ([[butler-a-profile-name-is-a-permission-tier-not-an-environment]])
2. **`/ecs/jarvice-stg` searched, zero runner markers → "the task never started."**
   False. The runner writes to `/ecs/jarvice-scheduler-worker-stg`, a different CDK
   stack's log group. The reported conclusion was not merely unsupported — it was
   the **exact inverse** of the truth.
3. **`MODEL=Sonnet-5` on a worker → "a failed Opus restore."** Unverified, and
   probably false: most of the fleet defaults to Sonnet. Asserted twice in durable
   artifacts before being caught.
4. **Launcher reports `failed=0` → "the ECS task launched."** False. `ecs.run_task()`'s
   return value is never assigned; `failed` counts SQS records that raised a Python
   exception. It says nothing whatsoever about ECS.
5. **`last_heartbeat_at IS NULL` → "the runner never started."** False. The CAS write
   that sets it sits *after* a full application import, so NULL means "never reached
   its first heartbeat" — which includes **"started and died early,"** the case that
   actually occurred. Had this been checked before the log group, it would have
   produced a confident, wrong answer.

**The sixth one was caught, and the contrast is the lesson.** A worker was told
*"'connected' does not tell you what you can do — open the tool list."* It did.
`/mcp` said **"Authentication successful. Connected to dealmatch-stg-stable"** while
**zero** of that server's tools were in the session. The label was true and useless.
The only difference from the other five was being told to look at the thing.

**The common shape:** in every case the label was produced *by a different system,
at a different time, for a different purpose* than the question asked of it. A
profile name encodes a permission tier for humans reading config. A log group name
encodes a CDK construct's identity. A counter counts what its author chose to count.
A NULL column records the absence of one specific write — not the absence of the
event you care about.

**How to apply:**

1. **Before using a name, count, flag, or status as evidence, ask three things:
   who wrote this value, when, and to answer what question?** If that question is
   not yours, you are holding a proxy. This is answerable in seconds and it is the
   whole discipline.
2. **State what would make label and reality diverge, then check that specifically.**
   "The runner might log elsewhere." "The counter might not observe the API response."
   Naming the divergence turns a vague doubt into a one-command check.
3. **Zero and NULL are the most dangerous labels.** Absence of a *record* is not
   absence of the *event*. Always ask which write produces that record and whether it
   could have been skipped — see
   [[butler-absence-of-evidence-needs-a-control-and-an-evidence-class]].
4. **Read the code that increments an aggregate before quoting it.** `failed=0`,
   `total=1`, `skipped=91` are all assertions by whoever wrote the increment.
5. **Prefer the artifact over the label when both are available** — the tool list
   over "connected", the log stream over the log group name, the config file over the
   profile name. Usually cheaper than the escalation it prevents. See
   [[butler-check-the-artifact-before-the-instrument]].
6. **Order your checks so a wrong reading cannot land first.** Case 5 was harmless
   only because the log-group check ran first. When two observations bear on the same
   question, run the one whose failure mode you understand.
7. **The tell is the sentence "obviously it's X — it's called X."** That is the
   substitution happening out loud.
8. **This is not the name's fault.** Every one of these labels was correct for its
   own purpose. The error is importing a value across purposes without re-deriving
   that it still answers the new question — the same move as
   [[a-true-observation-licenses-only-its-own-scope]], applied to identifiers.
