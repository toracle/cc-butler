---
name: butler-steward-post-restart-fleet-recovery
description: "After an OS/Emacs restart, sweep the whole fleet before trusting anything: SOME sessions freeze at the resume-gate chooser while the registry reports 'running' (tell = no model in the listing; unstick with '1'). Also: the batch restore aborts wholesale on cc-butler#8, CTX=0 after a resume/compaction is a display artifact and NOT a lost context, and a resume-gate keystroke can be left unsubmitted in a worker's input row."
metadata:
  node_type: memory
  type: feedback
---

**Post-restart reconciliation is a STANDING STEWARD DUTY, not an anomaly response.** On any morning where session IDs carry a new date, assume part of the fleet is not what the registry says it is, and sweep before trusting anything.

## 1. Sessions frozen at the resume-gate chooser

An OS/Emacs restart brings worker PROCESSES back, so `list_claude_sessions` reports them `running` — but they have not auto-resumed. They sit at:

```
  ❯ 1. Resume from summary (recommended)
    2. Resume full session as-is
    3. Don't ask me again
```

Nothing advances until someone selects. A session parked here looks identical in the registry to a healthy one.

**Fast triage tell:** a stuck session shows **NO model field** in `list_claude_sessions`; a resumed one shows Sonnet-5 / Opus-4.8 / Fable-5. **Not proof** — confirm by reading the screen for the chooser text.

**The fix:** `send_to_session` the stuck session `"1"` — "Resume from summary", the correct choice (full-resume burns usage limits). This is a legitimate, intended menu selection, NOT the relay-safety hazard in [[butler-worker-relay-prompt-safety]] — that hazard is *prose* being swallowed as a selection; here you deliberately mean to pick option 1. Verify by re-reading: chooser gone, idle prompt with a model present.

**How many? Don't predict — check all.** Observed 7/16, 8/16, then **1 of 12** (2026-08-04). Earlier versions of this note said "expect roughly half," which would have under-motivated the sweep on the day it was 1, and the one stuck session was real. Read this as **"some — verify every session by screen,"** never as a ratio.

## 2. The batch restore aborts wholesale (cc-butler#8)

`cc-butler-restore-sessions` runs a 5-second `cc-butler--wait-for-session-ready` check after each launch. On a slow starter that check **signals an error, and the error propagates out of the restore loop and kills the whole batch.** On 2026-08-04 it launched 2 of 12 and died on a worker that was in fact perfectly healthy — merely slower than 5s to paint its input row.

So: **after any restore, count the fleet.** Do not assume the batch completed. `*Messages*` is the ground truth — look for `Claude Code started in <name>` lines and a trailing `N recorded session(s) not running`. Re-running is safe and idempotent (it skips live ones), but may abort again on the next slow starter, so it can take several passes.

If you hand-roll a relaunch script to work around this, put the `cc-butler--live-dir-p` guard **inside** the timer lambda, not in the scheduling loop — launches fire on a stagger of tens of seconds, and a guard evaluated at schedule time lets a second eval within that window double-launch every pending session. `cc-butler--resume-in` has no internal guard.

## 3. CTX=0 after a resume or compaction is a DISPLAY ARTIFACT

A freshly-resumed or freshly-compacted session shows `CTX=0 0%`, which is indistinguishable at a glance from **a session that came up fresh and lost its context** — the worst outcome a restore can produce, and the one that would tempt you to relaunch it and destroy the real state.

**It is not that.** The counter is simply not charged until the session's first turn. Confirm by screen: a genuinely resumed session carries a resume banner — `Skills restored (...)`, plus references to its own prior files, HANDOFF.md, and earlier task outputs. Check for that banner before concluding anything from CTX=0.

## 4. A resume-gate keystroke can be left UNSUBMITTED in the input row

Seen 2026-08-04: a healthy, working worker had a bare `"2"` sitting in its input box — verified real input, not ghost text — evidently typed at the resume gate and never submitted. The session was otherwise fine.

This is a live hazard: `send_to_session` types and presses Enter once, so the next dispatch lands as `2<your text>`. **During the sweep, check every worker's input row, not just whether it is awake,** and clear stray characters before dispatching.

## 5. What survives, and what you must repair

- Resumed sessions come back from a SUMMARY, so their picture is STALE — a worker may believe a PR is still open that has since merged. Correct the delta before dispatching ([[butler-state-desync]]).
- A compaction erases a worker's memory of its own parked state. If a worker is parked in front of a **one-way door** (a go-live flip, real money, a prod deploy), re-anchor the hold explicitly after any resume/compaction and tell it that your message wins over its summary ([[steward-compaction-erases-worker-memory-of-own-work]]).
- Anything a dead session held only in its own context is gone; only what was externalized survives ([[steward-externalize-is-survival-insurance]]).

**Be sparing with concurrency during the sweep.** Reading screens directly is fine; do NOT fan out many concurrent background agents against the single Emacs process — that contention is a documented stall risk. Sequential or small-batch reads by the steward itself are the safe way to reconcile.

**Why:** Three restarts (2026-07-21, 07-22, 08-04) each produced a different failure shape — 7/16 stuck, 8/16 stuck, then 1/12 stuck but a batch restore that silently stopped at 2 of 12. Every time, what caught the real state was reading screens and `*Messages*` rather than trusting `list_claude_sessions`. On 08-04 three separate things would each have been misread from the registry alone: the aborted batch, a CTX=0 that looked like a wiped context, and a stray keystroke that would have corrupted the next dispatch.

**How to apply:** After any restart — count the fleet against the roster; read `*Messages*` for the launch trace and the "N not running" tail; re-run the restore until the count is whole; then verify EVERY session by screen (awake? chooser? stray input row? resume banner if CTX=0?), unstick with `"1"`, and re-anchor any one-way-door hold before letting a compacted worker act.
