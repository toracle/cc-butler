---
name: butler-a-banner-reading-is-not-a-measurement
description: "A budget/quota figure read off a UI banner is a secondary artifact — corroborate it against the authoritative command (/usage) before letting it constrain how the whole fleet works, because a wrong constraint is invisible and self-reinforcing"
metadata:
  node_type: memory
  type: feedback
---

A remaining-budget/quota figure read off a **UI banner** is a secondary artifact, not a measurement. Before letting such a number impose a fleet-wide constraint — a hold, a spend freeze, a "don't delegate to subagents" posture — **corroborate it against the authoritative source** (`/usage` in a worker session, which reports session and weekly windows with explicit reset times).

**Why:** 2026-08-12. A banner sighting on a worker screen was recorded as directly-witnessed fact: "weekly limit 91% consumed, resets 23:00 KST." It was propagated into `steward-handoff.md`, `dashboard.org`, an open decision to 정수님 (hold vs. release vs. downgrade three Opus workers to Sonnet), and into individual workers' own committed handoff docs — `monocle-skills` spent a push authorization on commit `cbbb96f` specifically to correct an earlier "19:00" reading to "~23:00 per the live banner." On 2026-08-13 ~22:1x, after a second shutdown, `/usage` run on two independent freshly-resumed sessions both reported **0% weekly used, resets Aug 19**, with a +50% promo banner active. The gap was ~91 percentage points.

The cost was not a wasted query. For roughly a day the entire fleet worked in a degraded mode it never chose: workers suppressed subagent delegation and did main-thread-only reads to conserve a budget that was not scarce. `monocle-security` reported zero subagent dispatches across a full working day and correctly characterized it as *a consequence of the reading, not a judgment it made*. Real work (`dealmatch` #1146, the `chat-proxy#366` review) sat parked. And the error was self-reinforcing: each role that inherited the figure treated it as established fact and wrote it forward, so the correction had to travel back through a handoff doc, a dashboard, an escalation, and a worker's own git history.

**How to apply:**
- Treat a banner/statusline number as a *prompt to verify*, never as the verification. `/usage` is one cheap call in any live session; run it on **two** sessions, since a single reading is what caused this.
- When a constraint is derived from a reading, record the *evidence and its provenance* alongside it ("banner sighting on worker screen, unconfirmed") — not just the conclusion. A figure written without its provenance is indistinguishable from a measurement to the next reader.
- Before propagating a constraint into durable state (handoff, dashboard, escalation, a worker's committed docs), ask what it costs if wrong. A hold that suppresses delegation fleet-wide is expensive and **invisible** — nothing fails, work just quietly gets slower and dumber, so there is no error signal to catch it.
- When such a figure is corrected, **annotate in place and keep all readings**, so the record shows the value proved unreliable more than once. That pattern is the durable lesson; any single corrected number is not.
- Generalize past budget: same shape for any environment-reported scalar that gates fleet behavior — rate limits, disk/quota warnings, "X commits behind", context-percentage displays. See [[butler-a-threshold-is-not-a-cliff-check-the-denominator]] for the neighboring failure (reading a policy value as a hard limit).

Related: [[butler-resurrect-with-the-constraint-before-the-context]] (constraints stated to resurrected workers must carry their evidence *and* their expiry), [[butler-subagent-first]] (the habit this bad reading suppressed), [[butler-verify-delivery]].
