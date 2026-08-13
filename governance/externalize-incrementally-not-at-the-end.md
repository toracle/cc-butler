---
name: butler-externalize-incrementally-not-at-the-end
description: "'A record that exists only inside a running agent dies with it. Long work must write its findings out as it goes, not at the end — because the ceiling that kills the run also destroys the evidence of what was already established. Seen in four distinct mechanisms in one night: context ceiling, OUTPUT ceiling, credential expiry, and sheer context size.'"
metadata:
  node_type: memory
  type: feedback
---

**The rule.** Any long-running piece of work — a verification sweep, a multi-step smoke test, an audit — must **write each result out the moment it is established**, not accumulate findings and report at the end. The failure this prevents is not "the run failed"; it is **"the run failed and we cannot even say what it had already proven."**

**Why (2026-08-13, steward).** Four different mechanisms produced the identical loss in a single night:

1. **Output ceiling.** `dealmatch` ran a staging smoke test for **38 minutes** and died on `Claude's response exceeded the 64000 output token maximum`. No intermediate record existed. **The entire 38 minutes became "unknown"** — not "partially verified", *unknown*. We could not say which tools had been exercised.
2. **The same ceiling again, after the fix.** Per-step logging to a file was imposed. The next run died the same way at 24 minutes — **but steps 1 and 2 survived in the file**, so "what is verified" remained a precise statement.
3. **Credential expiry.** The staging MCP token then expired mid-run. Again the file held; the verified steps were still reportable.
4. **Context ceiling / sheer size.** Worker handoffs before compaction are the same discipline under a different name, and a session at 600k+ running a long browser verification is one ceiling away from losing a result it is holding in memory.

The decisive comparison is 1 versus 2: **same task, same failure, similar duration — completely different salvage value.** The only difference was whether findings were written down as they were produced.

**How to apply.**
1. **Write the verdict, then continue.** One line per step is enough: what was checked, pass/fail, the evidence pointer. Do it *before* analysing, before summarising, before the next step.
2. **When a subagent returns a result, record it before reasoning about it.** The reasoning is what consumes budget and risks the ceiling; the result is what you cannot regenerate.
3. **Budget-blind failures are the ones that matter.** You will not see a ceiling coming — an output ceiling in particular can fire on a payload that looks trivially small, for reasons you may not be able to explain. Do not rely on estimating headroom.
4. **Treat "what has been established so far" as the deliverable**, distinct from the final report. If the run dies, that partial record *is* the output.
5. **This is not only about crashes.** Handoffs before compaction, credential expiry, and a session being killed all destroy in-agent state the same way. The question is never "will it crash" but **"if this stopped right now, what could I still say with evidence?"**

**The general shape.** *Durability is a property of where a fact lives, not of how certain the agent is about it.* An agent's confidence in a finding does not survive the agent. See [[butler-worker-context-hygiene]] (the same discipline for context specifically), [[butler-verify-delivery]] (confirm the fact rather than inferring it from a clean exit), and [[butler-subagent-first]] (delegation moves the payload out of the fragile place — the same lever applied to an output ceiling rather than a context one).

**SPT:** *write it down when you learn it, not when you finish — the ceiling takes the reasoning and the evidence together.*
