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

Example the user gave: an assets-offload task — "put assets on the CDN" is NOT the DoD. The
ultimate purpose is **"the app does not load heavy assets" (a light/fast app).** So the butler
must ask: is that achieved, or is "uploaded to CDN" just a step? (Answer there: the heavy bytes
— the large runtime/model blobs — WERE offloaded = core met; the remaining app-chunk offload is
an incremental bandwidth/edge gain, the tail, not the core.)

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

Recurring pattern (2026-07-03 scan): most parked sessions were intermediate — one encryption
task (backfill + key-rotation + prod tier remain), a server-side one (flag not flipped), a
custom-integration one (backend skeleton only, not usable), another (proposed fix unsound),
another (model invalid + general-user access unbuilt), a further one (not merged). Only one
session had its core done.
