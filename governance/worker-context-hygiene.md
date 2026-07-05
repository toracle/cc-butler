---
name: butler-worker-context-hygiene
description: "The butler and steward keep each worker session's context window from growing unbounded — at a safe point (WAITING) the session externalizes what it needs, is verified sufficient, is cleared, then re-hydrates thin from its handoff doc. Order matters because clearing destroys context."
metadata:
  node_type: memory
  type: feedback
---

A worker session left to run indefinitely accumulates a huge context window,
and (per [[butler-subagent-first]]) context re-reading is the dominant cost. So
context hygiene is not the session's problem alone — the **butler and steward
actively monitor each worker's context-window usage and do not let a session run
unbounded.** At a safe point they drive the session through a proactive
**externalize → clear (or compact) → re-hydrate** cycle, the same discipline the
butler applies to itself.

**Safe point.** Only act when the session is at a genuinely safe boundary —
**WAITING**, between tasks, not mid-edit. Clearing mid-work loses live state.

**Safe sequence (the order matters — clear destroys context, so externalize and
verify BEFORE clearing):**
1. The session **externalizes** its live design, decisions, open threads, and
   resume-point to a handoff doc at `~/.ccsm/docs/handoff-<session>.md`.
2. **Verify the doc suffices** — that a fresh read of it is enough to continue
   the work — before touching the session.
3. **Clear** the session (or **compact** instead, only when genuine continuity
   with the running history is needed).
4. The freshly-cleared session **reads its handoff doc** and re-hydrates thin —
   rebuilding a lean, deliberate working context instead of carrying the old
   half-million-token history.

**Externalize continuously, not only at the end.** The handoff doc is not
something written once, in the moment before a clear. Externalize *as you work* —
when you finish a small task or settle a decision, capture it into a durable doc
then. That way the externalized record is always current, a clear is always cheap
and safe because nothing live is lost, and re-hydration is never a scramble.
Treat making documents as part of the work, not a closing ritual.

**When to pick a session (candidate heuristic — start simple):** a long-running
session whose *current* work is **discontinuous** from its long history is a
clear candidate — the accumulated history is no longer serving the present task,
so it is pure carried cost. **Prefer clear over compact as the default.** The
whole point of the cycle is that *we* keep the means to externalize while the
context is still alive, so the session resumes from a handoff doc we authored and
can read — not from compact's opaque, automatic summary that we neither control
nor can inspect. Reserve compact for the narrow case where the running thread
genuinely must continue and no externalized doc could carry it.

**Ownership.** The **steward** watches the worker firehose and drives worker
context hygiene ([[butler-steward-routing]]); the **butler** applies the same
cycle to its own session. This is a standing duty, not a one-off cleanup — the
value is the *discipline*, not any single clear.

This principle is stated at the level of principle and safe sequence only. The
tool-level and shell-level mechanism for detecting usage and driving the cycle
lives in operational notes, not here in governance.
