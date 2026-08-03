---
name: feature-flag-gate-every-door
description: "When you gate a feature behind a flag, the flag must be enforced at EVERY entry point — every REST/admin endpoint, deeplink, dispatcher, background job — not just the obvious UI listing. The recurring bug is 'UI hidden but REST open': the frontend respects the flag, a secondary API doesn't, so a tenant with the flag OFF can still reach the feature. Detect it by ENUMERATING all doors and running a context-free 'disprove-it / try to reach it with the flag off' audit before merging — never assume the UI gate covers the API."
metadata:
  node_type: memory
  type: feedback
---

**The recurring pattern (3+ times in the monocle fleet, 2026-07/08).**
- `ENABLE_CUSTOM_MCP` — frontend read the flag; the chat-time dispatch path did not enforce it.
- `ENABLE_SCHEDULED_TASKS` / scheduler — 8 REST endpoints in `routers/schedules.py` were open with only
  `get_verified_user`, no flag check, after the core PR merged.
- `ENABLE_DB_MCP` (jarvice#978 #1420) — a pre-merge audit found **2** admin endpoints unguarded:
  `GET /mcp/custom-servers` (a flag-off tenant still saw db-type servers listed) and
  `POST /mcp/custom-servers/{id}/db-check-connection` (a flag-off tenant could still ATTEMPT a real DB
  connection). Both fixed by mirroring the 404/filter guard every *other* endpoint already had.

**Why it recurs.** The flag gets added where the feature was *designed* — the UI listing, the main create
flow — because that's where attention is. The secondary doors (admin list APIs, per-resource action
endpoints like check/test/delete, deeplink routes `/workspace/apps/{id}`, dispatchers, background jobs)
share code or exist off to the side, and each is a separate `if flag` that is easy to forget. "The UI
hides it" is not the same as "it cannot be reached" — the risk is the REST/admin surface that the UI
never linked but is still routable. This is the flag-specific face of [[new-variant-completeness]]: every
path that handles the feature must handle the flag, not just the first one you think of.

**The detection technique that actually works (jarvice-978, and it found real holes).**
1. **Enumerate EVERY door, file:line** — grep the whole repo for the feature's models/routes/handlers and
   list all of them: UI, every REST endpoint (GET *and* the action verbs — check/test/delete/connect),
   deeplink routes, chat/tool dispatch, schedulers, background jobs. A count you can point at ("15 doors").
2. **Run a context-free "disprove-it" sub-agent** — hand a fresh agent the flag and the instruction "with
   the flag OFF, try to reach this feature through any door; prove the gate leaks." Context-free + adversarial
   beats the author's own spot-check, which is blind to exactly the door they forgot.
3. **Gate each door identically** — mirror the existing endpoints' guard (same 404-not-403, "hidden not
   denied", so existence itself is concealed). Don't invent a new response shape per door.
4. **Bidirectional regression test per door** — off ⇒ hidden/404, on ⇒ works; and prove the test fails
   without the fix (stash the fix, watch it go red).

**How to apply (steward/butler).** Before clearing a flag-gated feature to merge, require the exhaustive
door-enumeration audit as part of Definition of Done — not a sample. If an audit round finds holes, that is
success (the audit worked), but confirm the enumeration was **complete** (all doors listed and each
checked), because "found 2" is only safe when it means "enumerated N, exactly 2 leaked," not "spot-checked
a few." 정수님's standing rule: **a hole found ⇒ stop the merge, report, human decides** — do not let the
author self-certify "fixed, therefore clean" and merge.

**SPT:** the habit is *enumerate every door and gate each, verified by a context-free flag-off audit* —
never "the UI hides it, ship it."
