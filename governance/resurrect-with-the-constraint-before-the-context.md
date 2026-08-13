---
name: butler-resurrect-with-the-constraint-before-the-context
description: "When relaunching a fleet after a crash/shutdown, state the CURRENT operating constraint in the relaunch dispatch itself and forbid resuming interrupted background work — a resurrected worker reconstructs the world as it was when it died, including expensive jobs whose justification has since expired."
metadata:
  node_type: memory
  type: feedback
---

A resurrected worker faithfully restores the world **as of the moment it died** — including in-flight background work (workflows, tasks, subagent fan-outs) whose justification has since expired. Resurrection instructions must therefore carry two things *before* the worker starts reconstructing:

1. **The current constraint, stated as fact with its evidence** — budget posture, holds, gates — not left to be re-derived from on-disk docs written before the event.
2. **An explicit prohibition on resuming interrupted background work.** "Reconstruct your state" reads to a competent worker as "restart what was running." Tell it instead: record the resume handle to disk and report it; do not resume it.

**Why:** 2026-08-12, post-shutdown relaunch of 14 workers. `monocle-472-image-edit` came back, correctly detected its interrupted background code-review Workflow, and — reasoning well from what it had — resumed it from cache to avoid wasted work. That was 5 agents and 407.1k tokens, the largest single spend in the fleet, at a moment when every worker was under a hold-until-reset at 90% of the weekly limit. The limit ticked 90% → 91% while the sweep was running. The worker was not disobedient: the hold was established *after* it died and was never in its relaunch dispatch, so from inside its context resuming was the frugal choice. The steward caught it only by reading screens one by one — `list_claude_sessions` showed nothing wrong, and the worker's own registry entry looked healthy.

Nothing was lost when it was stopped, because the fix is cheap: the runId replays completed agents free from cache. That asymmetry is the point — recording a resume handle costs nothing, re-running the work costs 407k.

**How to apply:**
- In the relaunch dispatch, before any "reconstruct your state" instruction: state the constraint, its evidence, and its expiry ("90% of weekly limit, live sighting on a worker screen, resets 23:00 KST").
- Add verbatim: *"Do not resume interrupted background work. If you find a stopped workflow or task, write its runId and scriptPath into your handoff and report it — do not restart it."*
- After a mass relaunch, sweep for the failure by screen, not by registry: a resumed background job shows as a live task line and a token counter, and appears nowhere in `list_claude_sessions` or `session_status`.
- Generalize past budget: the same shape applies to any constraint set while a worker was dead — a new gate, a freeze, a revoked approval. A pre-shutdown go-ahead is **suspended, not revoked**; say so explicitly, so the worker neither acts on it now nor discards it and asks again later.

Related: [[butler-worker-context-hygiene]], [[butler-subagent-first]] (whose "delegate by default" habit is exactly what must be suspended under a budget hold), [[butler-verify-delivery]].
