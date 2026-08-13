---
name: butler-subagent-first
description: "'Delegation to sub-agents is the DEFAULT working mode, not the exception — every substantial read/search/investigation/analysis/self-contained execution is delegated by default; the main/manager session working directly is what now needs a reason. Context re-reading is the #1 cost lever, so keep the manager a thin coordination layer. HARD EXCEPTION: when reading the artifact IS the verification, delegating it destroys the independence being verified — read it yourself.'"
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
- it is a tight loop where the delegation round-trip overhead dominates the work;
- **reading the artifact IS the verification** — see below. This one is not a
  cost trade-off but a correctness constraint, and it overrides the default.

## The hard exception: when the read *is* the verification, delegating destroys it

**Delegating a read replaces the artifact with a summary of the artifact.** Normally
that is exactly the point — the manager only needed the conclusion. But when the
entire purpose of the task is *"do not trust the summary, go look at the original,"*
delegating reconstructs the very structure the task exists to defeat, one layer
further in and now invisible. The verifier ends up certifying a sub-agent's
description of the evidence while believing it examined the evidence.

**Why (2026-08-13, monocle-security, dealmatch#1149).** Across three rounds the
steward had escalated to demanding raw artifacts, because two rounds of prose
claims had each been contradicted by measurement. The author finally posted the
raw output (23.6k chars: coverage tables, tracebacks, restore diffs). The steward's
dispatch — as always — carried the standing line *"delegate reads to sub-agents,
keep your main thread thin."* **The reviewer declined, and gave the reason:**
delegating would mean judging *"a summary of the artifact,"* collapsing the
independence built over two rounds. It sized the artifact first, judged 23.6k
tractable in the main window, read it directly, and used sub-agents only for
side-comparisons.

That read is what found the finding. The reviewer confirmed via
`git log --diff-filter=A` that `admin_deal_tools.py` was **created by this PR**,
so all 154 statements are changed lines — which promoted 9 unexecuted lines from
a footnote into a condition-1 shortfall. A distilled summary would almost
certainly have reported "6 defensive branches all covered" and stopped.

**The steward's standing instruction was wrong for this task, and the worker was
right to override it.** Record it that way round: the boilerplate is a default for
cost, not a rule about correctness, and it ships in *every* dispatch — so it will
keep arriving attached to tasks it damages.

**How to apply.**
- **Ask what the task's premise is.** If it is "the summary may be wrong, check the
  source" — an independent review, an audit, a verification of someone's claim,
  a relay-fidelity check — **read it yourself.** Delegation here is not thrift, it
  is the defect.
- **Size it before deciding.** "Too big for my window" is a real constraint; if the
  artifact genuinely cannot be read directly, say so explicitly and record that the
  verification is *mediated*, rather than quietly delegating and claiming it is not.
- **Sub-agents remain right for the side work** in the same task — cross-checks,
  counting, hunting a symbol elsewhere. It is the *primary* read that must not move.
- **Dispatchers: do not let boilerplate override judgment.** When dispatching a
  verification task, either drop the delegate-by-default line or mark it explicitly
  as not applying to the primary artifact.

**Critical caveat — guidance ALONE does not change behavior.** A real worker's
`CLAUDE.md` already carried near-identical advice ("act as orchestrator;
utilize subagents to save context") and it was *not* followed. Willpower and a
written reminder are not a control system. So this rule is written down here as
the source of truth AND it must be **backed by a feedback device that makes
context usage visible** (the missing piece — see the open thread in
`butler-session-state.org`). Institutionalizing the rule ([[butler-institutionalize-learning]])
means writing it *and* building the structure that enforces it; a doc by itself
is known to fail here.

Related: [[butler-evaluation-independence]], [[butler-a-delegated-sweeps-confident-prose-is-not-verified-fact]],
[[butler-merging-agent-results-must-keep-per-claim-provenance]], [[butler-a-true-observation-licenses-only-its-own-scope]].

**SPT:** start with the flipped default + rough guide + the visibility device;
do not build an elaborate delegation classifier. The judgment carries most of it —
**except where the read is the verification, and then you read it yourself.**
