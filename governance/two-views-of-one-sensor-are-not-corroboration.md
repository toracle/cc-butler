---
name: two-views-of-one-sensor-are-not-corroboration
description: "Before treating two agreeing instruments as confirmation, ask whether they READ THE SAME SENSOR. session_status and a session's on-screen statusline are one source quoted twice, not two witnesses — their agreement carries no more weight than either alone. Corollary: a screen's activity/task title is a stale label, not a liveness signal; it says what was once started, never what is running now."
metadata:
  node_type: memory
  type: feedback
---

Two instrument errors in one evening (2026-08-04, planned-shutdown dehydrate sweep), both
by the steward, both of the same shape: **a derived or stale view was mistaken for an
independent check.**

**Instance 1 — agreement that wasn't.** The steward reported `monocle-16-scheduler` as
"0k on BOTH instruments, so this is **not** a repeat of the morning's disagreement" —
explicitly claiming to have applied the read-both-instruments rule. The session was at
**114k**. Both readings came from the *same* underlying statusline report, so their
agreement was never corroboration: it was one stale source quoted twice. The rule
"read both and prefer the one that could have updated since the event" had been
learned that same morning, and was defeated by applying it to two views of one sensor.

**Instance 2 — a label read as live state.** The steward raised an alarm that
`monocle-security` had "worktree agents in flight" writing seam tests, on the strength
of its screen's activity title. The worker verified from source that it had **never
called the Agent tool in that session at all**; the nine `.claude/worktrees/agent-*`
checkouts were stale copies of already-merged work (eight completely clean), and the
title came from a backlog task marked `in_progress` *before that window even started*.
Nothing was in flight and nothing was at risk.

**Contrast — what real corroboration looked like the same evening.** Four sessions
closing mid-sweep was established by three signals that fail independently:
`list_claude_sessions`, `session_status`, and `send_to_session` **actually erroring**
with "No session named …". The third is an attempted *operation*, not a reading — which
is what made the set trustworthy.

**Lessons (durable):**

1. **Ask "do these share a source?" before counting instruments.** Two readings agree
   trivially when one is a rendering of the other. Provenance, not count, is what makes
   agreement evidence. `session_status` and the on-screen `CTX=` figure are the same
   sensor; so are any tool and the UI that displays its output.
2. **Prefer an ATTEMPTED OPERATION over a reading.** A failed `send_to_session`, a
   `git show` that returns `fatal:`, a push that errors — these are cheap and they fail
   for real reasons. Readings can be stale in unison; an operation cannot succeed against
   a state that isn't there.
3. **An activity title / task label is not a liveness signal.** It records what was once
   started, in some window, possibly not this one. To learn whether work is *running*,
   look for the work: the agent list, a process, an open file handle — or ask the session
   to check and report from source.
4. **Beware the freshly-learned rule.** Both errors happened while the steward was
   consciously invoking the correct discipline. A rule applied to the wrong object is
   more dangerous than no rule, because the invocation itself supplies false confidence.
   Cf. [[your-own-assumption-returns-as-corroboration]] — same failure, new costume.
5. **When a worker contradicts your instrument reading, its from-source check wins.**
   Both corrections tonight came from the worker checking its own repo and tool history.
   Ask for that rather than escalating an alarm built on a screen read.
   Cf. [[verify-delivery]] (the `CTX=` figure lags and is not a delivery signal),
   [[session-liveness-by-buffer]], [[structurally-impossible-beats-checked-and-absent]].
