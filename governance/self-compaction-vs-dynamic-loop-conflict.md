---
name: self-compaction-vs-dynamic-loop-conflict
description: "If a session self-schedules its own wake-ups (a dynamic /loop via ScheduleWakeup with a prompt), it can NEVER self-compact: the loop re-arms a pending wakeup before every turn ends, so the session never reaches the genuinely-idle WAITING state compact_session requires. session_status shows `running` + `blocked: session is busy — not at a safe waiting point` forever, at ANY delay length. The fix is ScheduleWakeup({stop:true}) — not a longer delay. Diagnose with session_status the moment a queued compaction doesn't fire; don't re-queue it a tenth time."
metadata:
  node_type: memory
  type: feedback
---

**The incident (steward, 2026-08-03).** Steward queued `compact_session(steward)` ~10 times over nearly an
hour while its context climbed 300k → 349k. Each call returned the normal, reassuring "Compaction QUEUED —
will start on its own the moment that turn ends and the session is safely idle." It never started.
`session_status` was the tool that broke the loop of guessing: it showed steward stuck at `running` /
`OVER THRESHOLD` / `blocked: session is busy — not at a safe waiting point`, continuously.

**Root cause.** The session was running an autonomous `/loop` in **dynamic pacing** mode — `ScheduleWakeup`
with a `prompt`, re-armed at the end of every turn so the loop continues. That is precisely the thing that
starves compaction: a session with a pending wakeup is never "sitting idle," it is always "about to be
re-invoked." The compaction driver waits for a genuinely-idle `WAITING` state that, by construction, can
never arrive.

**The trap: it looks like a timing problem, so you fight it with timing.** The natural reaction is "the gap
between ticks is too short — give it more room," and the delay gets walked up 120s → 150s → 300s → 1500s.
None of it works, because the blocker is not gap *length* but that a wakeup is *pending at all*. A 25-minute
gap fails exactly as hard as a 2-minute one. Every extra attempt also burns context on the very session that
is over threshold — the diagnosis gets more urgent while the tool for it gets no closer.

**The fix.** `ScheduleWakeup({stop: true})` to end the dynamic loop, then queue the compaction. It fires.
Confirmed: steward woke at 0k on the next turn.

**Why stopping the loop is safe (and usually correct anyway) for butler/steward.** These sessions are
**fleet-event-driven by design** — worker reports, `pending_events`, and the fleet-monitor hook bring them
back. A self-timer is redundant with that native wake path, and here it was actively fighting it. Compare
[[butler-context-ceiling-and-compaction]]: the whole point of the externalize → verify → clear → re-hydrate
discipline is that the session can actually *reach* the clear step.

**How to apply.**
1. **A queued compaction that hasn't fired is a diagnosis, not a retry.** If `compact_session` on yourself
   doesn't take effect within a turn or two, call `session_status` — do not re-queue it repeatedly. The
   "QUEUED" reply is not evidence anything will happen; it says nothing about whether the idle state is
   reachable.
2. **`blocked: session is busy — not at a safe waiting point` on a session that isn't obviously mid-edit
   means something is holding it non-idle.** A self-scheduled wakeup is the first thing to check.
3. **Don't tune the delay to fix it.** Longer intervals do not help. Stop the loop.
4. **Prefer the native wake path for butler/steward.** Don't re-arm a dynamic loop on a session that is
   already woken by fleet events; you gain nothing and forfeit the ability to self-compact. If a periodic
   heartbeat really is wanted, it must be reconciled with compaction, not layered on top of it.
5. Externalize to the handoff doc **before** the compaction, not after — under this failure mode you may sit
   at an over-threshold context for a long time, and the handoff is what survives if the session is restarted
   out from under you instead (see [[butler-channel-wedge-fallback-visibility]] for the restart path).

**SPT:** the habit is *when your own queued compaction silently never fires, reach for `session_status` and
look for something keeping you non-idle — a self-scheduled wakeup — and stop it, rather than re-queueing or
lengthening the delay.*
