#!/usr/bin/env python3
"""Matrix Warmblood Lounge <-> cc-butler bridge (receive side).

Supervised by Emacs (`make-process` + a sentinel) rather than launchd/
systemd -- see `cc-butler-matrix-bridge.el` alongside this file, and
`docs/sdd-draft.md` in the cc-butler-topics/cc-butler-matrix-bridge
workspace for the design this implements. All machine-specific config that
used to be a hardcoded Python constant is now read from the environment,
set by the Elisp supervisor from `defcustom`s and `auth-source` -- see
README.md next to this file for the full BRIDGE_* variable list.

Ported (not rewritten) from two independently-evolved machine bridges: m1
(macbook-m1-max, polls /messages) and x600 (polls /sync). Both fetch
strategies are kept, selected by BRIDGE_POLL_STRATEGY, because /sync is
broken for m1's (account, room) combination -- Conduit does not surface
this room in /sync for that pairing even after a confirmed successful
/join (2026-09-04 measured, not a guess), while /messages works for the
same account+room every time. Do not "clean this up" into one strategy --
that silently kills the m1 channel. See docs/sdd-draft.md §2.2.

state.json schema is intentionally NOT unified across strategies during
migration -- it keeps each machine's pre-existing key
(`last_seen_event_id` for /messages, `since` for /sync) so a rollback to
the old launchd/systemd-supervised bridge can still read the file this
process wrote. See docs/sdd-draft.md §10 (rollback requires an unchanged
state.json schema).
"""
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

SERVICE_DIR = Path(__file__).parent


def env(name, default=None, required=False):
    val = os.environ.get(name, default)
    if required and val is None:
        raise SystemExit(f"cc-butler-matrix-bridge: missing required env var {name}")
    return val


HOMESERVER = env("BRIDGE_HOMESERVER", required=True)
TOKEN = env("BRIDGE_TOKEN", required=True)
ROOM_ID = env("BRIDGE_ROOM_ID", required=True)
SELF_USER_ID = env("BRIDGE_SELF_USER_ID", required=True)
HUMAN_USER_ID = env("BRIDGE_HUMAN_USER_ID", required=True)
TARGET_SESSION = env("BRIDGE_TARGET_SESSION", "butler")
EMACSCLIENT = env("BRIDGE_EMACSCLIENT", "emacsclient")
POLL_STRATEGY = env("BRIDGE_POLL_STRATEGY", "messages")  # "messages" | "sync"
POLL_INTERVAL_S = float(env("BRIDGE_POLL_INTERVAL_S", "3"))
MESSAGES_LIMIT = int(env("BRIDGE_MESSAGES_LIMIT", "20"))
SYNC_TIMEOUT_MS = int(env("BRIDGE_SYNC_TIMEOUT_MS", "30000"))

STATE_FILE = SERVICE_DIR / "state.json"
LOG_FILE = SERVICE_DIR / "bridge.log"
ROOM_ID_ENC = urllib.parse.quote(ROOM_ID, safe="")


def log(msg):
    line = f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}"
    print(line, flush=True)
    with LOG_FILE.open("a") as f:
        f.write(line + "\n")


def matrix_get(path, params=None, timeout=15):
    url = f"{HOMESERVER}{path}"
    if params:
        url += "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {TOKEN}"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read())


def elisp_string(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def inject_into_session(text):
    """Deliver TEXT into the target cc-butler session.

    Returns True/False -- rc==0 from `emacsclient` is NOT treated as proof
    of delivery elsewhere in this pipeline (see docs/sdd-draft.md §5: a
    landed submit-Return can vanish into an open prompt/menu and still
    return rc=0), but this function's boolean IS what the poll loop below
    uses to decide whether the cursor may advance past this event -- so
    for now rc==0 is our best available signal. `cc-butler--send-input`
    already reports genuine success once it returns a real result instead
    of a bare `t`/error (§5(c), gated on that change landing); this
    function's return value is the seam that swap plugs into without
    touching the poll loop below.
    """
    expr = (
        f'(cc-butler--send-input (cc-butler--dir-by-name "{TARGET_SESSION}") '
        f"{elisp_string(text)} t)"
    )
    result = subprocess.run(
        [EMACSCLIENT, "--eval", expr], capture_output=True, text=True, timeout=15
    )
    if result.returncode == 0:
        log(f"OK inject ({len(text)} chars): {result.stdout.strip()[:200]}")
        return True
    log(f"FAIL inject rc={result.returncode} stderr={result.stderr.strip()[:500]}")
    return False


def attribution(sender):
    if sender == HUMAN_USER_ID:
        return "정수님"
    # Other fleets' butlers: "@butler-x600:..." -> "butler-x600"
    return sender.split(":", 1)[0].lstrip("@")


def deliver_event(ev):
    """Return True iff it is safe to advance the cursor past EV -- either
    nothing needed to be sent, or it was sent successfully. Return False
    only when delivery was attempted and failed; the caller must not
    advance the cursor past this event in that case (§5: cursor advance
    tied to delivery success, not to rc==0 of the /messages or /sync call
    that merely fetched the event)."""
    if ev.get("type") != "m.room.message":
        return True
    sender = ev.get("sender")
    if sender == SELF_USER_ID:
        return True  # don't re-inject our own outgoing messages
    content = ev.get("content", {})
    if content.get("msgtype") != "m.text":
        return True
    body = content.get("body", "")
    text = f"[matrix · {attribution(sender)}] {body}"
    log(f"RECV from {sender}: {body[:200]!r}")
    return inject_into_session(text)


# ---- /messages strategy (m1) ------------------------------------------


def load_last_seen():
    if STATE_FILE.exists():
        return json.loads(STATE_FILE.read_text()).get("last_seen_event_id")
    return None


def save_last_seen(event_id):
    STATE_FILE.write_text(json.dumps({"last_seen_event_id": event_id}))


def fetch_recent_events():
    resp = matrix_get(
        f"/_matrix/client/v3/rooms/{ROOM_ID_ENC}/messages",
        {"dir": "b", "limit": str(MESSAGES_LIMIT)},
    )
    return resp.get("chunk", [])


def poll_once_messages(last_seen):
    chunk = fetch_recent_events()  # newest-first

    new_events = []
    for ev in chunk:
        if ev.get("event_id") == last_seen:
            break
        new_events.append(ev)
    new_events.reverse()  # oldest-first

    committed = last_seen
    for ev in new_events:
        if deliver_event(ev):
            committed = ev["event_id"]
        else:
            # ⛔ stop here -- do not advance past a failed delivery.
            # This event (and anything after it) is retried next poll.
            break
    else:
        if chunk:
            committed = chunk[0]["event_id"]

    if committed != last_seen:
        save_last_seen(committed)
    return committed


def run_messages():
    last_seen = load_last_seen()
    if last_seen is None:
        # First run (no saved cursor): establish a baseline without
        # replaying room history. This is keyed on cursor ABSENCE, not on
        # "process just started" -- see docs/sdd-draft.md §4. Because the
        # cursor is saved every loop iteration below, a normal Emacs
        # restart re-enters this function with last_seen already set and
        # skips straight to the while loop.
        chunk = fetch_recent_events()
        if chunk:
            save_last_seen(chunk[0]["event_id"])
            log(f"baseline established, last_seen={chunk[0]['event_id']}")
        last_seen = load_last_seen()

    while True:
        try:
            last_seen = poll_once_messages(last_seen)
        except (urllib.error.URLError, TimeoutError) as e:
            log(f"poll error: {e!r}, retrying in {POLL_INTERVAL_S}s")
        time.sleep(POLL_INTERVAL_S)


# ---- /sync strategy (x600) ---------------------------------------------


def load_since():
    if STATE_FILE.exists():
        return json.loads(STATE_FILE.read_text()).get("since")
    return None


def save_since(token):
    STATE_FILE.write_text(json.dumps({"since": token}))


def poll_once_sync(since):
    resp = matrix_get(
        "/_matrix/client/v3/sync",
        {"since": since, "timeout": str(SYNC_TIMEOUT_MS)},
        timeout=(SYNC_TIMEOUT_MS / 1000) + 10,
    )
    room = resp.get("rooms", {}).get("join", {}).get(ROOM_ID)
    events = room.get("timeline", {}).get("events", []) if room else []

    all_ok = True
    for ev in events:
        if not deliver_event(ev):
            all_ok = False
            # ⛔ do not advance `since` past a failed batch. The whole
            # batch -- including events in it that already succeeded --
            # is retried on the next call, because /sync's opaque
            # `next_batch` token has no per-event granularity to commit
            # partway through a batch (unlike /messages' event IDs).
            # Trading "possible duplicate delivery of an already-sent
            # event" for "never silently drop one" is the same principle
            # as the /messages strategy above, applied at the coarser
            # grain /sync forces on us.
            # ponytail: no in-memory de-dup window across the retried
            # batch. Add one (bounded event_id set) if duplicates turn
            # out to matter more than an occasional repeated relay line.
            break

    new_since = resp["next_batch"]
    if all_ok:
        save_since(new_since)
        return new_since
    return since


def run_sync():
    since = load_since()
    if since is None:
        resp = matrix_get("/_matrix/client/v3/sync", {"timeout": "0"})
        since = resp["next_batch"]
        save_since(since)
        log(f"baseline established, since={since}")

    while True:
        try:
            since = poll_once_sync(since)
        except (urllib.error.URLError, TimeoutError) as e:
            log(f"sync error: {e!r}, retrying in 5s")
            time.sleep(5)


def main():
    log(f"bridge starting (strategy={POLL_STRATEGY})")
    if POLL_STRATEGY == "messages":
        run_messages()
    elif POLL_STRATEGY == "sync":
        run_sync()
    else:
        raise SystemExit(
            f"cc-butler-matrix-bridge: unknown BRIDGE_POLL_STRATEGY {POLL_STRATEGY!r}"
        )


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
