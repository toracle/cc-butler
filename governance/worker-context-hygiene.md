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

**But appending is not maintaining — the doc's *entry point* goes stale on its
own.** Continuous externalization makes the handoff **grow**, and growth pushes
today's state to the bottom while the top keeps whatever "read this first" block
was written weeks ago. A fresh session reads top-down and stops when it finds
something that looks authoritative. So the doc can be complete, current, and
verified at every append, and still rehydrate a session into a stale world.

This is worse than an absent entry point, because a heading like *"CURRENT STATE
— this supersedes anything older that conflicts"* actively **discourages** reading
further. The reader is doing exactly the right thing and is misled by it. And the
failure is invisible from the writing side: whoever appends today has the real
state in context and never re-reads the top.

**Observed twice on 2026-08-08, both times by luck rather than by process.** A
worker noticed, in the minutes before its own compaction, that its `HANDOFF.md`
still opened with a two-days-old *"read from here after compaction"* block while
that day's entire investigation sat at the bottom — the safety net for the
compaction was the document, and the document pointed at the wrong day. Checking
the steward's own `steward-handoff.md` on that finding showed the same defect in a
worse form: four days stale, 422KB, top block self-declared as CURRENT STATE, and
it is item #1 on the steward's documented startup path. Compaction happened to
carry the real state forward; a `/clear` would have landed squarely on it.

**So make the entry point part of the cycle, not part of the content:**
1. **Before** any clear/compact, re-read the doc's *top*, not just append to its
   bottom. The question is not "is today's work written down" but "where does a
   session with no memory actually land, and is that where I want it."
2. Keep **one** block that claims currency, and **date it**. When it stops being
   current, demote it explicitly — mark it superseded and say so in the heading
   itself. Prepend the new block; do not rewrite or delete the history, which is
   both irreversible and where the reasoning lives.
3. The current block should carry what a cold reader must not get wrong:
   what is **decided vs. pending**, what is **in flight** (so nothing is
   re-dispatched), the **standing prohibitions**, and **where the detail lives**.
   That is a different job from the append log below it.
4. A doc that another role is told to read on startup is **shared state**. Its
   staleness is not a private cost — see [[butler-externalizing-is-not-delivering]]
   for the same lesson at the delivery boundary, and
   [[butler-a-decision-you-cite-may-have-been-narrowed-later]] for the same
   shape in the governance store: an accurate quotation of a superseded block.

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
