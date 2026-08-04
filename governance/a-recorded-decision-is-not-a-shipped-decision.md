---
name: butler-a-recorded-decision-is-not-a-shipped-decision
description: "When you find a decision in an issue or design doc, read the code that was supposed to implement it and compare — decisions get half-built, and the half that quietly goes missing is usually the part that would have told a human something."
metadata:
  node_type: memory
  type: feedback
---

Finding a recorded decision feels like finding the answer. It is not. It tells you
what someone INTENDED. Before relying on it — and especially before concluding
"this is handled, look elsewhere" — read the code that was supposed to implement
it and compare clause by clause. Decisions get partially built, the issue is
closed on the strength of the decision rather than the delivery, and nothing ever
reconciles the two.

**Why:** 2026-08-04, the Craft custom-MCP investigation. agent-sandbox#169 had
decided, in June, that a credential-resolve failure (including a missing
`callbackUrl`) must be a *noisy* fail — explicitly promising it would be
**surfaced to the user as a visible error event**, never silently skipped. The
code even carried the policy in a doc comment: "Failure policy is NOISY-FAIL, not
silent degrade (#169 decision)", with no TODO and no hedging.

Only the developer half was built. `reportMcpAuthErrors` calls `console.error`
and Sentry and **never touches `EventBus`**, the SSE channel that reaches the
client. So the failure was loud to developers and *completely silent to users* —
for two months. And the decision's own reasoning depended on the missing half:
jarvice had offered to add a guard guaranteeing `callbackUrl`, and agent-sandbox
**declined it** on the grounds that failing loudly would expose the problem
early. That declination is only sound if the loud failure reaches someone who can
act on it.

The cost was not abstract. We spent an afternoon diagnosing a symptom — a server
simply absent, with no error anywhere the user could see — that **the system had
been designed to explain to us.**

**How to apply:**
1. When a decision record answers your question, immediately locate its
   implementation and check each promised clause against the code. Treat "decided"
   and "delivered" as separate facts, and say which one you verified.
2. Suspect the **user-visible** clause first. Logging and metrics get built because
   the implementer needs them; the part that informs an end user is the easiest to
   defer and the least likely to be missed by anyone on the team.
3. When a decision REASSIGNS or DECLINES responsibility ("we don't need a guard
   there, because we fail loudly here"), the declination inherits a dependency on
   the promised behaviour. If that behaviour was never built, the allocation is
   void and must be revisited rather than honoured.
4. A doc comment citing a decision is evidence of intent, not of completion — it
   is written when the code is written, and it does not update when a clause is
   dropped. Same failure shape as
   [[butler-a-pr-body-freezes-constraints-at-authoring-time]].
5. Do not overclaim the gap. "This function does not emit to the client" is not
   "no user-visible surface exists" — search for other paths before asserting
   silence, per
   [[butler-absence-of-evidence-needs-a-control-and-an-evidence-class]]. An
   overclaimed observability defect is a bad way to be wrong.
6. File the gap as its OWN issue cross-referenced from the decision, not as a
   comment inside it — see
   [[butler-for-a-two-repo-bug-search-the-other-repo-s-tests-first]] on how much
   gets lost in closed issues and merged PRs.
