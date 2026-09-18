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
  while 7 of the 16 sessions sat idle at exactly this gate. **Detection
  fixed in code** (2026-09-03; see `cc-butler--resume-gate-showing-p` and
  `cc-butler--session-state` in `cc-butler-session.el`) — both
  `list_claude_sessions` and the dashboard now report a gated session as
  `STUCK-AT-RESUME-GATE`/`GATE` instead of `running`. Not yet merged/live
  as of this writing; same caveat as the roster fix above applies. **Still
  not automated**: cc-butler does not send an answer to this gate for you
  — see step 3 below, and note the fix deliberately does NOT auto-answer
  it either (a wrong auto-send here is worse than a session sitting idle;
  [issue #4](https://github.com/toracle/cc-butler/issues/4) leaves that
  decision open).
- **The dashboard.org fallback below can itself be destroyed by using it.**
  During the 2026-07-21 recovery, calling `butler_dashboard` while only 2 of
  16 sessions were live overwrote the dashboard's session table down to
  those 2 rows — the tool's own response was `Dashboard updated (2 live
  sessions)`. **Fixed in code** (2026-09-03; see
  `cc-butler-docs--stale-session-rows` in `cc-butler-docs.el`, which appends
  an `OFFLINE` row per roster-recorded session that isn't currently live,
  instead of the table only ever showing the live set) — not yet
  merged/live as of this writing. See the caveat in step 1 below and
  [issue #5](https://github.com/toracle/cc-butler/issues/5).

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
   ([issue #5](https://github.com/toracle/cc-butler/issues/5), fixed in
   code 2026-09-03, not yet merged/live — see above).

2. **Relaunch each session** in its directory, resuming its last
   conversation: `claude --continue` (or whatever `cc-butler-resume-args`
   is set to) from that working directory. `cc-butler-restore-sessions`
   does exactly this per roster record if you'd rather fix the roster file
   by hand first and let it do the relaunching.

3. **Check each relaunched session, don't trust the summary count.** After
   relaunching, actually look — or grep the screen capture — for the
   startup-chooser text above. A session sitting at that prompt needs the
   option whose text reads **"Resume full session as-is"** sent to it
   before it's really back — send the option by matching its TEXT, never a
   fixed keystroke like "send 1" or "send 2": confirmed live 2026-09-03
   across a 5-session sample that the pre-highlighted default varies per
   session (4 defaulted to "Resume from summary", only 1 to "Resume full
   session as-is"), so a numbered/blind Return can land on the wrong
   option. Do not conclude "N/N recovered" from `list_claude_sessions`
   alone — even once the `STUCK-AT-RESUME-GATE` detection fix (issue #4)
   is live, cc-butler does not send an answer for you.

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
recovery data).

A related but distinct defect in the SAME failure class — `cc-butler-
restore-sessions`' relaunch loop aborting the whole batch the first time
any one session errored (e.g. exactly the resume-gate timeout below),
silently leaving every session after it in iteration order never even
attempted — caused today's (2026-09-03) crash-recovery to lose 20 of 25
sessions. Fixed and merged (PR #130, `a3e72ef`); regression test in PR
#131 (open, not merged).

Liveness/resume-gate detection (issue #4) and the dashboard self-
destruction defect (issue #5) both now have code fixes as of 2026-09-03
(see the bullets above) — PR-only, steward-authorized while the fleet
recovers from today's crash: **not merged, not reloaded into any live
Emacs.** Issue #4's harder question (should cc-butler auto-answer the
gate?) remains open and unimplemented on purpose. This document should be
revisited (or deleted) once all land, are actually merged AND reloaded,
and a restart has exercised the fixed path end-to-end.
