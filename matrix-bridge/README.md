# matrix-bridge/bridge.py

Supervised by `cc-butler-matrix-bridge.el` (repo root) via `make-process` +
a sentinel, not by launchd/systemd. See `docs/sdd-draft.md` in the
`cc-butler-topics/cc-butler-matrix-bridge` workspace for the design.

This script takes no config of its own — everything comes from the
environment, set by the Elisp supervisor from `defcustom`s and
`auth-source`:

| Variable | Required | Set from |
|---|---|---|
| `BRIDGE_HOMESERVER` | yes | `cc-butler-matrix-bridge-homeserver-url` |
| `BRIDGE_TOKEN` | yes | `auth-source` (`cc-butler-matrix-bridge-auth-source-token-host`) |
| `BRIDGE_ROOM_ID` | yes | `auth-source` (`cc-butler-matrix-bridge-auth-source-room-host`) |
| `BRIDGE_SELF_USER_ID` | yes | `cc-butler-matrix-bridge-self-user-id` |
| `BRIDGE_HUMAN_USER_ID` | yes | `cc-butler-matrix-bridge-human-user-id` |
| `BRIDGE_TARGET_SESSION` | no (default `butler`) | `cc-butler-matrix-bridge-target-session` |
| `BRIDGE_EMACSCLIENT` | no (default `emacsclient`) | resolved via `executable-find` |
| `BRIDGE_POLL_STRATEGY` | no (default `messages`) | `cc-butler-matrix-bridge-poll-strategy` |
| `BRIDGE_POLL_INTERVAL_S` | no (default `3`) | — |
| `BRIDGE_MESSAGES_LIMIT` | no (default `20`) | — |
| `BRIDGE_SYNC_TIMEOUT_MS` | no (default `30000`) | — |

Manual standalone testing (no Emacs):

```sh
BRIDGE_HOMESERVER=http://localhost:8008 \
BRIDGE_TOKEN=... BRIDGE_ROOM_ID=... \
BRIDGE_SELF_USER_ID=@butler-test:warmblood-lounge \
BRIDGE_HUMAN_USER_ID=@jeongsoo:warmblood-lounge \
python3 bridge.py
```

Self-check: `python3 test_bridge.py -v` (stdlib `unittest`, no network).

## Why /messages vs /sync is a real fork, not tech debt

`BRIDGE_POLL_STRATEGY=sync` does not surface the lounge room for m1's
(account, room) combination even after a confirmed successful `/join`
(2026-09-04 measured — not a guess; see `docs/sdd-draft.md` §2.2 and §6).
`BRIDGE_POLL_STRATEGY=messages` works for that same account+room every
time. Do not "clean this up" into one strategy — that silently kills
whichever machine needs the other one.

## state.json schema is per-strategy, on purpose

`messages` writes `{"last_seen_event_id": ...}`; `sync` writes
`{"since": ...}`. These are NOT unified during migration, so a rollback to
the old launchd/systemd-supervised bridge can still read the file this
process wrote (`docs/sdd-draft.md` §10).
