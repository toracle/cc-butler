---
name: butler-write-the-observation-protocol-before-the-change-lands
description: "'Decide what you will look at, and what each outcome would mean, BEFORE the change ships — a protocol written after the result bends 'what did we check' to fit 'what came out'; pre-commit a signal that must NOT appear, prefer a positive signal over an absence, and calibrate the detector against a known failure first or its silence proves nothing'"
metadata:
  node_type: memory
  type: feedback
---

Verification written *after* a change lands is not verification: the question
silently reshapes itself around the answer. **Write the protocol while the
outcome is still unknown** — what you will look at, what counts as success, and
what each possible result would mean.

Four things make such a protocol able to fail, and all four were missed on the
first draft of a real one:

1. a pre-committed signal that must **not** appear, derived from mechanism;
2. a **positive** signal, not merely an absence;
3. a **calibrated detector** — proven to fire on a known failure *before* you
   trust its silence;
4. room for the **unimagined** — a script only catches what you already thought of.

**Why:** 2026-08-08, jarvice scheduler. jarvice#1611 — the ECS remote worker
never received tenant context, so the path had **never once succeeded**. PR
#1613 sat CI-green awaiting deploy. The worker wrote the post-deploy protocol
*before* approval, stating why: *"written afterwards, 'what did we look at' gets
fitted to 'what came out'."* Its pre-registered falsifier:

> **At T+15min, `reclaimed 1 ... (lease 900s expired)` must NOT appear.**

Mechanism-derived and genuinely falsifiable: the lease branch requires
`last_heartbeat_at IS NULL`, i.e. death before `claim_first_heartbeat` — still
dying at `remote.py:412`. Three outcomes, three pre-assigned conclusions (no
lease reclaim → fixed; lease reclaim → not fixed; heartbeat-120s reclaim → #1611
fixed, different problem). Framing fixed up front: **first success, not
no-regression**, so a failure means *a cause remains*, not *the PR broke
something*. Success defined as **the result message arriving in chat**, with
"task started / no exception / tests green" explicitly excluded.

**Then it audited its own protocol and found three real defects** — this is the
part worth copying:

- **The checks had never been red.** Five of them were *"this error string will
  be absent."* If the pattern is wrong, **"no match" reads as "healthy."** A
  vacuously-passing check. Note the inconsistency it caught in itself: the
  #1611 reproduction test had guarded exactly this (the fixture asserts
  `public.schedule_run` is absent, else a mis-routed query silently succeeds and
  proves nothing) — the same author omitted the same guard from the protocol.
  **Fix: run the patterns against the known failure stream first; if they don't
  fire there, the detector is broken, and executing the protocol is forbidden
  until it does.**
- **Absence was the primary evidence.** Nothing logs which schema the worker
  resolved, so an absent error cannot distinguish "routing worked" from "died
  earlier somewhere else." **Fix: switch the primary signal to positive —
  `last_heartbeat_at IS NOT NULL`, direct proof the worker found and UPDATEd the
  row inside the tenant schema.**
- **All checking, zero testing.** A first-ever success is the one window where
  unknown defects surface, and a script only catches the imagined. **Fix: add
  exploratory charters** — chiefly that the fix's two new branches
  (`tenant_id is None`; legacy payload → `RemoteExecutorError`) have never run
  in staging, and **the 5–10 minutes after deploy is the only window to observe
  legacy in-flight messages**. The design had already flagged *"never having
  succeeded does not mean no in-flight messages exist"*; the observation plan
  had dropped it.

A staged-table diagnostic was also demoted: read top-to-bottom it invites
stopping at "the task launched, good enough" — the exact misreading #1608 exists
to document. It now opens only *after* failure.

**How to apply:**

1. **Write it before the change ships, and say so in the artifact.** Pre-deploy
   timestamping separates prediction from rationalization.
2. **Name a signal that must NOT appear**, derived from mechanism —
   [[butler-a-test-that-cannot-fail-is-not-evidence]].
3. **Calibrate the detector on a known positive before trusting its silence**,
   and gate execution on that. An uncalibrated absence-check reports "normal"
   no matter what happens.
4. **Prefer a positive signal to an absence.** Ask what would be *present* if it
   worked — [[butler-absence-of-evidence-needs-a-control-and-an-evidence-class]].
5. **Enumerate every outcome, including "fixed, but something else is wrong."**
   Two branches usually means you skipped the third.
6. **Budget for the unimagined.** Add charters for paths never exercised in the
   target environment, and note windows that close (in-flight legacy messages).
7. **Order diagnostics so they cannot be mistaken for the success criterion** —
   keep the ladder folded until something fails.
8. **List the instruments that can lie** and how — unchecked return values,
   swallowed exceptions, logs that omit the identifier you need
   ([[butler-fixing-one-instrument-flaw-does-not-validate-the-instrument]]).
9. **Name the access it requires and forbid privilege escalation to get it** —
   [[butler-workers-must-not-reach-aws-profiles]].
10. **Audit the protocol as its own artifact.** Three defects here survived a
    careful first draft and died to a deliberate second pass.
