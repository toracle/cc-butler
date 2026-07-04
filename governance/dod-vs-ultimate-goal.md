---
name: butler-dod-vs-ultimate-goal
description: "Judge a \"stopped/parked/done\" session against its ULTIMATE goal, not the proximate task — distinguish intermediate achievement from final, and surface the remaining delta"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 24305c3a-429a-4449-800d-2bf67f660d4b
---

The user flagged a core butler responsibility: when a session **stops or reports "done,"** the
butler must judge whether the **ultimate goal (real Definition of Done)** is actually met, or
whether it stopped at an **intermediate milestone** dressed as done. The proximate task is not
the goal.

Example the user gave: jarvice-assets-cdn — "put assets on the CDN" is NOT the DoD. The
ultimate purpose is **"jarvice does not load heavy assets" (a light/fast app).** So the butler
must ask: is that achieved, or is "uploaded to CDN" just a step? (Answer there: the heavy bytes
— pyodide/onnx — WERE offloaded = core met; the remaining `_app` chunk offload is an incremental
bandwidth/edge gain, the tail, not the core.)

**Why:** Sessions naturally report the proximate step they finished. If the butler accepts that
as "done," work false-completes and the real objective silently stalls — especially since the
real DoD is usually behind a gate (merge / deploy / actually-usable-by-the-user) the session
can't cross alone.

**How to apply (butler discipline):**
- For every parked/"done" session, name its **ultimate goal** and the **delta** between where it
  stopped and that goal. "On CDN" / "code complete" / "staging deployed" / "PR ready" are
  usually intermediate — the real done is typically *merged + in prod + actually usable*.
- Classify: **final** (core goal met) vs **intermediate** (stopped short) vs **core-met+tail**
  (main objective achieved, only incremental remainder left).
- Surface the delta in the dashboard so nothing reads as complete when it isn't. Don't let
  "stopped" be mistaken for "done."
- Ties to [[operating-principles-doc]] §2 (define observable success/failure signals up front —
  the ultimate signal, not the step) and the DoD-in-the-brief lever. Judge from observed facts,
  not the session's own success-narrative ([[butler-evaluation-independence]]).

Recurring pattern (2026-07-03 scan): most parked sessions were intermediate — envelope-enc
(T5 backfill + billing-key + T4-prod remain), server-side (flag not flipped), custom-mcp
(backend skeleton only, not usable), jarvice#1130 (proposed fix unsound), safetysnap (model
invalid + general-user access unbuilt), dealmatch (not merged). Only cli-rust had its core done.
