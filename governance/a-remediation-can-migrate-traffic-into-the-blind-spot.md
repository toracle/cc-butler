---
name: butler-a-remediation-can-migrate-traffic-into-the-blind-spot
description: "'A cleanup that consolidates several bad paths into one canonical path can consolidate them into the UNINSTRUMENTED one — the metric falls to zero, the risk does not, and it reads as progress; before endorsing a consolidation, ask which of the merged paths carries observation and which way the traffic is moving'"
metadata:
  node_type: memory
  type: feedback
---

A remediation plan that says "stop doing X, do Y instead" is usually read as
strictly-better: fewer code paths, one canonical behaviour. But if X is
**logged** and Y is **silent**, completing that plan *destroys the only signal
you had* while leaving the underlying exposure intact. The dashboard improves.
The system does not.

**The tell:** a consolidation whose "before" side has a counter and whose
"after" side has none. After the migration the counter reads zero — not because
the behaviour stopped, but because it moved somewhere nobody counts.

**Why:** 2026-08-08, jarvice. Three distinct tenant-resolution fallbacks were in
play: **(A)** middleware plants a `default_tenant` sentinel, **(B)** the sentinel
resolves to `DATABASE_SCHEMA`, **(C)** no tenant contextvar is set at all, so no
`schema_translate_map` is attached and SQL goes out unqualified. (C) is the
branch that produced jarvice#1611 — the scheduler's remote worker dying on
`relation "schedule_run" does not exist`.

jarvice#1383 was already open to clean this up, and its **stage 0 decision was
already made and marked complete** (2026-07-23):

> "the non-strict middleware branch sets **no context at all** instead of the
> sentinel, and `get_session()`'s no-context branch becomes the canonical
> expression of dev single-tenant mode. `get_session()` is not modified."

Read as a summary, that is a tidy-up: stop planting a fake tenant. Read against
the actual risk map, **#1383 stage 1 merges (A)/(B) traffic into (C)** — the
exact branch that just caused an incident. And the asymmetry is the whole point:
(A) leaves a trace (`log.info` + a stark 404), which is why we *have* a number —
**931/day on staging**. (C) logs **nothing**: `db.py:218-219` is a bare `else`
with no log line. So the plan moves traffic **from the measurable path to the
unmeasurable one**, and its completion would make the fallback look solved
because the one metric we had goes quiet.

The steward had told the worker to read #1383's **body, not a summary of it**
(per [[butler-a-decision-you-cite-may-have-been-narrowed-later]] — search the
topic, read the source). That instruction is what surfaced this; the summary
said "scope doesn't overlap," and stopping there would have filed the new issue
as an unrelated sibling.

The worker then framed the new issue (jarvice#1614) not as a *successor* to
#1383 but as a **precondition of #1383's stage 1**, and — correctly — narrowed
its comment on #1383 from "reorder your plan" to "add one precondition." Same
shape as jarvice#1281's own Proposal item 2: *"migrate the legitimate callers
first, then turn on rejection — the reverse order is an outage."*

Note what this is **not**: it is not an argument against the cleanup. (A)'s
sentinel genuinely is the worse defect — it disguises unresolved as resolved.
The finding is only about **order**, and about not letting a falling counter be
mistaken for a falling risk.

**How to apply:**

1. **For any "consolidate these paths into one" plan, list the paths and mark
   which ones are instrumented.** If traffic flows from an observed path to an
   unobserved one, instrumenting the destination is a **precondition**, not a
   follow-up. Say "precondition," not "we should also" — the second gets dropped.
2. **Treat a metric going to zero right after a migration as unexplained until
   proven.** Ask where that traffic went and whether the new home counts it.
   "The number dropped" and "the behaviour stopped" are different claims; see
   [[butler-a-label-is-a-claim-not-the-thing-it-names]].
3. **Never infer a plan's scope from a summary of it.** This inversion was
   invisible in the summary and plain in the body — the stage-0 decision text
   named `get_session()` explicitly. Open the issue.
4. **Distinguish "no measurement" from "low frequency."** The phrasing that
   survived review here: *"not knowing the frequency is not evidence that (C) is
   rare; it is evidence that there is no instrumentation. (A)/(B) having 931 and
   (C) having nothing is a difference in observation, not in risk."* Absence of
   a number is not a small number — cf.
   [[butler-structurally-impossible-beats-checked-and-absent]].
5. **When you find an ordering hazard in an already-approved plan, propose the
   minimum amendment.** One added precondition is adoptable; "your sequencing is
   wrong" reopens a settled decision and stalls. Cite the repo's own precedent
   for the ordering rule if one exists — it did here (#1281).
