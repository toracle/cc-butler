---
name: butler-subagent-first
description: "Delegation to sub-agents is the DEFAULT working mode, not the exception — every substantial read/search/investigation/analysis/self-contained execution is delegated by default; the main/manager session working directly is what now needs a reason. Context re-reading is the #1 cost lever, so keep the manager a thin coordination layer."
metadata:
  node_type: memory
  type: feedback
---

The default is flipped: **delegation to sub-agents is the normal mode, and the
main (manager) session doing the work directly is the exception that needs a
reason.** This applies to the butler, the steward, and every worker session
acting as a manager. The old habit — "I'll just read/search/investigate it
myself" — is now the thing to justify, not the thing to reach for.

**Why (the cost basis).** The cost analysis found **62.7% of spend is context
re-reading** (`cache_read`) — context is the #1 cost lever, above model mix
(→ `~/.ccsm/docs/cost-driver-analysis.org`). Every large read/log/search the
manager pulls into its own window is re-billed on every subsequent turn. A
sub-agent reads the raw material in *its* window and returns only the distilled
conclusion, which is all the manager ever needed. So keep the manager a **thin
coordination layer: raw material stays in sub-agent windows; only distilled
conclusions (decisions, findings) come back.** Ties to [[butler-dod-vs-ultimate-goal]]
(judge the outcome) and [[warmblood-talent-philosophy]] (완결 — return the
finished conclusion, not the firehose).

**What counts as a "delegation situation" is JUDGMENT plus a rough guide, not a
rigid line.** Rough triggers — delegate by default when the task is:
- more than *skimming* a file;
- session output, large tool output, or logs;
- a multi-file search;
- a multi-step investigation, analysis, or review;
- a self-contained execution task (only the result matters, not the working
  context).

**Direct-is-fine exceptions** (the manager may work directly when):
- the content itself is needed for the very next action — Read-for-Edit, or
  reading to scope the next move;
- it is small and fast;
- it is a tight loop where the delegation round-trip overhead dominates the work.

When in doubt between these, prefer delegating — the default is flipped for a
reason, and the exceptions are narrow.

**Critical caveat — guidance ALONE does not change behavior.** A real worker's
`CLAUDE.md` already carried near-identical advice ("act as orchestrator;
utilize subagents to save context") and it was *not* followed. Willpower and a
written reminder are not a control system. So this rule is written down here as
the source of truth AND it must be **backed by a feedback device that makes
context usage visible** (the missing piece — see the open thread in
`butler-session-state.org`). Institutionalizing the rule ([[butler-institutionalize-learning]])
means writing it *and* building the structure that enforces it; a doc by itself
is known to fail here.

**SPT:** start with the flipped default + rough guide + the visibility device;
do not build an elaborate delegation classifier. The judgment carries most of it.
