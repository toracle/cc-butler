---
name: butler-model-is-fable-by-designation
description: "정수님's standing designation 2026-08-08: the butler session runs on Fable-5, NOT Opus; if found on Opus that is drift ('demotion' cases exist) — restore to Fable; compaction restore preserves pre-compact state so it conserves drift rather than fixing it — the designation is enforced by fleet-check comparison, not by the compact machinery"
metadata:
  node_type: memory
  type: feedback
---

**The rule:** the butler session's designated model is **Fable-5**. Finding the butler on Opus is *drift to be corrected*, not a state to preserve. Anyone maintaining fleet model state must treat **Fable** as the butler's reference model.

**정수님, 2026-08-08, verbatim:** "버틀러는 페이블로 돌게 합시다. 혹시 오퍼스로 돌아갔다면은 페이블로 되돌려주세요. 간혹 이게 강등되는 경우가 있더라구요."

**Why:** On 2026-08-08 evening the steward observed the butler's status line reading `MODEL=Fable-5`, inferred a stuck compaction machine (same shape as a worker caught on Sonnet that morning), and urged restoring Opus. The butler checked its own transcript first: 정수님 had typed `/model fable` himself, hours earlier — `an-anomaly-may-be-the-humans-own-hand` in action, and the butler correctly refused to revert. When surfaced, 정수님 confirmed Fable is the *designation*, not a temporary state, and added that spontaneous "demotions" (강등) do happen — so the direction to watch for is Fable→elsewhere drift, and the correction is back to **Fable**.

**How the compact machinery actually behaves (steward verified in code, `cc-butler-compact.el:919-936`, same day):** there is **no hardcoded Opus restore**. The restore step captures the model the session was actually on just before compaction (screen → transcript → last-known) and restores exactly that, per session. Consequence that matters here: **restore preserves drift rather than fixing it** — if the butler had already drifted to Opus before a compact, the compact faithfully restores Opus. So the designation cannot be enforced by the compact machinery; it is enforced by **comparison of designation vs observed model in fleet checks**. The code has no per-session-designation concept, and we chose (2026-08-08) not to add one — operational discipline over unneeded code. A code-level guard (per-session designation registry consulted by restore) is a possible future design, not a current bug.

**How to apply:**

- **Steward fleet checks:** butler on any non-Fable model → restore to Fable via `send_to_session` typing `/model fable` into the butler session — the butler cannot run `/model` on itself (CLI built-in, not a skill). Judge by observation (status line / command sequence), not by label.
- **Do not treat a post-compact Opus as proof the machinery broke** — it may be conserved pre-compact drift. Check when the drift began before blaming the restore step.
- This is session-specific: it names the **butler** session only. Worker model choices are decided per-dispatch as before.
- Related: [[butler-context-ceiling-and-compaction]] (the switch/compact/restore procedure), [[butler-the-human-acts-outside-your-channels-so-re-check-before-re-asking]] (why the transcript was checked before "correcting" the model), [[butler-a-remediation-can-migrate-traffic-into-the-blind-spot]] (a mechanism that faithfully restores state also faithfully restores the wrong state).
