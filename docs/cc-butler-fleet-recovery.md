# Manual fleet recovery — what to do when the automated path can't be trusted

## What it is

`M-x cc-butler-restore-sessions` (`R` in the session list) is the automated
recovery path: it reads `cc-butler-sessions.eld` and relaunches every
recorded session that isn't currently running, with `claude --continue`. It
has failed twice in ways worth knowing about (2026-07-13, 2026-07-21) — this
note is the manual fallback procedure plus the two defects that caused it,
so the next person hit by either doesn't have to rediscover them mid-incident.

## When you need this

- **The roster is missing sessions.** `cc-butler--save-roster` used to
  overwrite `cc-butler-sessions.eld` with a bare snapshot of whichever
  sessions happened to be live at the moment a debounced save fired — and
  since an OS shutdown kills sessions one at a time, not atomically, any
  save during that window could clobber the record of the rest. **Fixed**
  2026-07-21 (roster save now merges instead of overwriting; see
  `cc-butler-persist.el`'s `cc-butler--roster-records`) — but if you're
  reading this because `cc-butler-restore-sessions` still came back with
  fewer sessions than expected, that fix may not yet be loaded into the
  running Emacs (a reload was deliberately deferred mid-fleet; see the
  commit history around 2026-07-21 for why), or you may be looking at a
  roster that was already clobbered before the fix landed.
- **A "recovered" session isn't actually doing anything.** `--continue`
  resume can land a session at Claude Code's own startup chooser instead of
  actually resuming:
  ```
  This session is 13h 25m old and 460.1k tokens
  1. Resume from summary (recommended)
  2. Resume full session as-is
  3. Don't ask me again
  ```
  `list_claude_sessions` reports such a session as `running` — it can't
  currently tell "processing" apart from "parked at its own prompt". On
  2026-07-21 this produced a false "16/16 recovered, zero failures" report
  while 7 of the 16 sessions sat idle at exactly this gate. **Not yet
  fixed** — tracked as
  [issue #4](https://github.com/toracle/cc-butler/issues/4), filed but
  deliberately not implemented (it touches the same status-detection
  machinery the fleet depends on to know what it's doing; landing a change
  there mid-incident is how you turn one bug into two).
- **The dashboard.org fallback below can itself be destroyed by using it.**
  During the 2026-07-21 recovery, calling `butler_dashboard` while only 2 of
  16 sessions were live overwrote the dashboard's session table down to
  those 2 rows — the tool's own response was `Dashboard updated (2 live
  sessions)`. See the caveat in step 1 below and
  [issue #5](https://github.com/toracle/cc-butler/issues/5) — filed, not
  implemented.

## The manual procedure

1. **Find the real roster.** If the butler was still running and dutifully
   calling `butler_dashboard` before the crash, its `dashboard.org` (under
   the butler home, e.g. `~/.emacs.d/cc-butler/butler/docs/dashboard.org`)
   has a session table as of its last regeneration. Use that directory list
   as the source of truth if `cc-butler-sessions.eld` looks short.

   **Caveat, don't skip this:** `dashboard.org`'s table is generated the
   same way the roster used to be saved — it lists whatever
   `cc-butler--sessions` (the LIVE set) returned at the moment of the last
   `butler_dashboard` call (see `cc-butler-docs--session-rows` in
   `cc-butler-docs.el`). It is not a durable roster either. It survived the
   past incidents as a usable snapshot only because nothing regenerated it
   *after* the crash started — if the butler had called `butler_dashboard`
   again mid-teardown, its table would shrink the same way the roster file
   used to. Treat it as "the last known-good snapshot, by luck of timing,"
   not as a guaranteed record — and do not call `butler_dashboard` yourself
   while consulting it for this purpose: refreshing it is what destroys it
   ([issue #5](https://github.com/toracle/cc-butler/issues/5)).

2. **Relaunch each session** in its directory, resuming its last
   conversation: `claude --continue` (or whatever `cc-butler-resume-args`
   is set to) from that working directory. `cc-butler-restore-sessions`
   does exactly this per roster record if you'd rather fix the roster file
   by hand first and let it do the relaunching.

3. **Check each relaunched session, don't trust the summary count.** After
   relaunching, actually look — or grep the screen capture — for the
   startup-chooser text above. A session sitting at that prompt needs `1`
   (or whatever option resumes from summary) sent to it before it's really
   back. Do not conclude "N/N recovered" from `list_claude_sessions` alone
   until this is fixed (issue #4).

## The throughline

Both defects above are the same failure at different layers: **the
mechanism running is not the same claim as the thing being true.**
`cc-butler-restore-sessions` returning without error, buffers existing for
every relaunched directory, and `list_claude_sessions` reporting `running`
are all "the mechanism ran" signals — none of them verify "the session is
actually resuming a conversation" or "the roster reflects the real fleet".
Worth remembering the next time a recovery or status path in cc-butler looks
clean: ask what it actually verified, not just whether it errored.

## Status

Roster-clobber defect fixed in code (2026-07-21); not yet reloaded into any
already-running fleet Emacs (a live reload was assessed as low-risk but
deliberately held for a human decision, since it touches the fleet's own
recovery data). Liveness/resume-gate defect filed as issue #4, and the
dashboard.org self-destruction defect filed as issue #5 — both not scoped or
implemented; all three cc-butler behavior changes are deliberately being
held for a day when the fleet isn't live and mid-incident. This document
should be revisited (or deleted) once all land and a restart has actually
exercised the fixed path end-to-end.
