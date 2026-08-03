---
name: prod-data-access-requires-explicit-approval
description: "Touching PRODUCTION DATA (prod DB rows, prod credentials from Secrets Manager, SSM tunnels into prod RDS) requires EXPLICIT per-instance human approval — and 'it was read-only / SELECT only / zero mutations' is NOT a justification. Reading production code is not the same as reading production data. A task instruction like 'verify against real data' does NOT implicitly authorize reaching for prod credentials; state the access boundary in the dispatch, don't let the agent infer it."
metadata:
  node_type: memory
  type: feedback
---

**정수님's ruling (2026-08-01).** An agent investigating a CMK/cost mismatch was told to ground its
findings in real data. Its census sub-agent connected to **production RDS via an SSM tunnel using prod
DB credentials from Secrets Manager** and ran SELECTs — zero mutations, tunnel closed afterward, and it
**self-disclosed** the access in its report rather than burying it. Steward escalated asking whether
this should require explicit authorization going forward. 정수님's answer, in substance:

> **Distinguish production CODE from production DATA. "Read-only" is not a justification.**

That is the principle. Reading prod *code* (a repo, a config file, `git show origin/main:...`) is
ordinary work. Reading prod *data* — customer rows, tenant records, anything behind prod credentials —
is a **separate category** requiring its own explicit approval, regardless of how non-destructive the
access is. The harmlessness of `SELECT` is not the question; **possession of and access through prod
credentials** is the question.

**Why "read-only" fails as a defense.** It answers a question nobody asked. The risk of prod data access
isn't only mutation — it's credential exposure, customer-data handling, audit-trail obligations, and the
precedent that an agent may reach for prod secrets whenever a task would benefit. A read that leaks or
logs customer data is not undone by having been a read.

**Why this recurs (and the actual fix).** This is the *scope-leak* facet of
[[butler-subagent-destructive-op-scoping]] — a sub-agent optimizes for task completion and will reach
for whatever data completes the goal unless the access boundary is stated. "Verify with real data" reads,
to an agent, as authorization for *whatever data is real*. That inference is the defect, and it is
**upstream in the dispatch**, not in the agent. So the fix is upstream too:

**How to apply.**
1. **In every dispatch involving verification against real systems, state the access boundary
   explicitly** — which environments, which credentials, and that prod data is out of scope absent
   separate approval. Do not rely on the agent to infer caution you didn't write down.
2. **Prod data access is a per-instance approval**, never a standing one, and never inherited from
   approval to do the surrounding task.
3. **Reversibility does not apply here.** The usual "decide reversible, escalate one-way" test
   ([[butler-decision-routing]]) does not license prod-data reads — a read is reversible in state but
   not in exposure. Escalate.
4. **Self-disclosure is right and should stay cheap.** The worker above surfaced its own boundary
   crossing instead of hiding it, which is exactly why this became a durable rule instead of a silent
   habit. Treat disclosure as good conduct to reinforce, not an offense to punish — otherwise the next
   one stays quiet.
5. **Already-collected prod data is its own question.** After such a crossing, whether the existing
   dataset may still be *used* is a separate human decision from whether the access was okay — freeze
   and ask rather than assuming the data is fine to keep working from.

**SPT:** the habit is *name the access boundary in the dispatch, and treat prod DATA as a distinct
approval gate from prod CODE* — not a prod-access detector, and never "it was only a SELECT."
