# Audio transcription — reference bundle (for the elisp port)

`audio_axis.py` in this directory is the audio-handling code from
`bridge.py` (macbook-m1-max), copied verbatim. It is not runnable
standalone and is not meant to be — it exists because `git grep` on this
canonical repo found no reference implementation of this logic anywhere
else, and rebuilding it from a description would risk quietly diverging
from the version that's already been verified live. Port the elisp
implementation from this file's logic, then delete this directory.

## Why HOME has to be injected (`MONOCLE_ENV`)

This isn't a Python-specific quirk — it applies to any process this
bridge launches under launchd, elisp included, if the launch path is ever
a launchd job rather than an interactive Emacs session.

launchd's environment for a background service carries **no `$HOME`** and
a minimal `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`) — it does not inherit
your login shell's environment at all. `monocle` reads `$HOME` to locate
`~/.monocle/credentials.json`. Under launchd with no `$HOME`, it fails
with `Not logged in.` and exit code 1 — **despite a valid, working token
existing on disk** — because it's looking in the wrong place (or nowhere),
not because auth is actually broken. This was a real incident on
macbook-m1-max (the third instance of the same "launchd silently gives a
process a different environment than the terminal" defect class in one
night — the other two were `emacsclient` and `monocle` needing absolute
paths for the same PATH-not-inherited reason).

The fix is the `env=MONOCLE_ENV` argument to `Popen` — not
`os.environ["HOME"] = ...` — so the override is scoped to that one
subprocess call and never leaks into the rest of the bridge's own
environment. If x600's elisp equivalent shells out to `monocle` (directly
or via `emacsclient`), the launching process needs the equivalent of this:
whatever environment dict it uses for that subprocess call must have
`HOME` set explicitly, not assumed inherited.

## Where "preserve the original on failure" actually branches

정수님's spec: keep the original audio file regardless of whether
transcription succeeds, so it's still usable as a raw ASR sample even on
failure. In the code this isn't one check — it's three separate places
that all have to independently choose to keep going rather than bail:

1. **`download_media` throws, or returns `None`** (bad `mxc://` url) —
   nothing has been written to disk yet, so there's no original to lose;
   the branch here is just "tell the user download failed" rather than
   silently dropping the event.
2. **`audio_path.write_bytes(data)` happens before `monocle` is ever
   invoked.** This ordering is the actual mechanism behind "preserved
   regardless of transcription outcome" — the file is already durably on
   disk by the time anything related to transcription runs, so nothing
   `monocle` does (crash, non-zero exit, hang) can take the original away.
3. **`monocle` fails to start, or exits non-zero, or exits 0 with empty
   output** — three different failure shapes, and all three still
   reference `첨부: {audio_path}` in the message they deliver. The file
   was already safe per (2); these branches only decide what *text*
   accompanies it.

Verified live, both polarities, 2026-09-06 21:14: a real audio clip → `monocle`
exits 0 → transcribed text delivered with the file path; a missing/bad
file → `monocle` exits 1 → explicit failure message delivered, same file
path, same guarantee.

## What's deliberately left out of `audio_axis.py`

- `log()`, `inject_into_session()`, `attribution()` — generic bridge
  primitives, not audio-specific. elisp already has its own equivalents
  (`matrix-bridge-attribution` etc.) — call those, don't port these.
- `preflight_check()`'s monocle-credentials check — a bridge-wide startup
  self-check, not part of the per-message audio path. The HOME-injection
  paragraph above is the one part of it that matters here.
- No secrets: `HOMESERVER` (a LAN URL, already treated as non-secret
  config elsewhere in this migration's docs) and the fact that the access
  token is loaded from a file at runtime are both referenced by name only
  — no token value, no credentials file content, appears anywhere in
  `audio_axis.py` or this README.

## Scope note

This bundle only contains the audio axis. It does not touch
`matrix-bridge.el` and is not meant to overlap with x600's open
`post-to-lounge.sh` PR (#179) — those are a different file and a
different code path (send-side room-key routing, not receive-side audio
transcription).
