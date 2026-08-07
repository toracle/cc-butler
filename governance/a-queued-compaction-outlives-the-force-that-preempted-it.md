---
name: butler-a-queued-compaction-outlives-the-force-that-preempted-it
description: "Forcing a compaction does NOT cancel a compaction already queued on that session — the queued one fires later and compacts a second time, summarizing away the re-hydration message sent in between. Read an unexplained context drop on a recently-forced session as this, not as an anomaly, and keep re-hydration facts in butler_log so a repeat costs nothing."
metadata:
  node_type: memory
  type: feedback
---

`compact_session(force=true)` preempts the wait, but it does **not** consume or
cancel a compaction already queued on that same session. Both triggers stay
live against one target. The forced one runs immediately; the queued one fires
whenever its idle window finally closes — possibly much later — and compacts
the session a **second** time.

The casualty is the re-hydration message sent in between. That message is
precisely the content least able to survive summarization: dense externalized
facts (PR numbers, branch names, commit SHAs, and caveats whose wording is
load-bearing), which a summarizer compresses into gist exactly where the detail
was the point.

**Why:** 2026-08-05, `monocle-jarvice-1130`. It had a queued compaction that had
starved. I forced one (349k → 0k) and re-hydrated it with its three PRs
(#1547/#1548/#1549), the absent-vs-malformed `toolIds` distinction, and the
paired residual-risk sentences. About an hour later `session_status` showed it
`blocked: compaction already in flight` — the old queued request, still pending —
and it fired, taking the session 124k → 0k and summarizing that re-hydration
away. Two compactions, one intended.

Note the misreading this invites: a session you *just* re-hydrated showing 0k
looks like a fresh problem, or like the re-hydration failed to land. It is
neither. It is the earlier queue arriving.

**How to apply:**

1. Before forcing, check `session_status` for a pending/in-flight compaction on
   that session. If one exists, expect a second compaction and plan to
   re-hydrate twice rather than treating the second as a fault.
2. Treat an unexplained context drop on a recently-forced session as **this
   mechanism first**, not as an anomaly to investigate. Re-hydrate and move on.
3. The real mitigation is upstream: **write the re-hydration facts to
   `butler_log`, not only into the message sent to the worker.** The log
   survives arbitrarily many compactions on both sides — the worker's and the
   steward's own. In this incident re-hydrating a second time cost nothing,
   because the facts were already in the log and did not have to be
   reconstructed from a summarized transcript. This is
   [[butler-externalizing-is-not-delivering]] running in the useful direction:
   externalizing did not *deliver* anything, but it made delivery cheaply
   repeatable, which is what you want when delivery can be undone by a
   background process you did not schedule.
4. Corollary to [[butler-context-ceiling-and-compaction]]'s "a read figure is a
   claim": a 0k reading is ambiguous in a second way beyond staleness. It may be
   the momentary trough *mid*-compaction rather than the settled size —
   `monocle-envelop-encryption` read 0k and settled at 122k once its summary and
   restored file refs loaded back, while genuinely parked sessions sit at a true
   0k. Both look identical in the table; re-read before concluding.
