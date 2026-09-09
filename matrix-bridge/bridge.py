#!/usr/bin/env python3
"""Matrix Warmblood Lounge -> cc-butler bridge (receive side).

Long-polls /sync as @butler-x600, and on each new text message from
anyone else in the lounge room (정수님 or another fleet's butler),
injects it into the "butler" Claude Code session's terminal via
emacsclient, attributed as "[matrix · <sender>]". The room is a shared
cross-fleet channel, so all senders are relayed -- deciding whether a
given message is worth acting on is left to the receiving session.

stdlib only -- no pip install needed. See ~/.../warmble-jumble/.../
"Matrix 릴레이 핸드오프" doc for the design this implements (candidate B).
"""
import json
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

SERVICE_DIR = Path(__file__).parent
CONDUIT_DIR = Path("/home/toracle/services/conduit")
HOMESERVER = "http://localhost:8008"
TOKEN_FILE = CONDUIT_DIR / "butler-x600.token"
ROOM_ID_FILE = CONDUIT_DIR / "lounge-room-id.txt"
STATE_FILE = SERVICE_DIR / "state.json"
LOG_FILE = SERVICE_DIR / "bridge.log"
TARGET_SESSION = "butler"
SELF_USER_ID = "@butler-x600:warmblood-lounge"
HUMAN_USER_ID = "@jeongsoo:warmblood-lounge"
SYNC_TIMEOUT_MS = 30000

TOKEN = TOKEN_FILE.read_text().strip()
ROOM_ID = ROOM_ID_FILE.read_text().strip()
# room id -> human-readable name, filled lazily by room_label().
ROOM_LABELS = {}


def log(msg):
    line = f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}"
    print(line, flush=True)
    with LOG_FILE.open("a") as f:
        f.write(line + "\n")


def load_since():
    if STATE_FILE.exists():
        return json.loads(STATE_FILE.read_text()).get("since")
    return None


def save_since(token):
    STATE_FILE.write_text(json.dumps({"since": token}))


def matrix_get(path, params=None):
    url = f"{HOMESERVER}{path}"
    if params:
        url += "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {TOKEN}"})
    with urllib.request.urlopen(req, timeout=(SYNC_TIMEOUT_MS / 1000) + 10) as resp:
        return json.loads(resp.read())


def elisp_string(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def inject_into_session(text):
    expr = (
        f'(cc-butler--send-input (cc-butler--dir-by-name "{TARGET_SESSION}") '
        f"{elisp_string(text)} t)"
    )
    result = subprocess.run(
        ["emacsclient", "--eval", expr], capture_output=True, text=True, timeout=15
    )
    if result.returncode == 0:
        log(f"OK inject ({len(text)} chars): {result.stdout.strip()[:200]}")
    else:
        log(f"FAIL inject rc={result.returncode} stderr={result.stderr.strip()[:500]}")


def attribution(sender):
    if sender == HUMAN_USER_ID:
        return "정수님"
    # Other fleets' butlers: "@butler-macbook-m1-max:..." -> "butler-macbook-m1-max"
    return sender.split(":", 1)[0].lstrip("@")


def envelope(event_id, content, room_label=None):
    """The courier's markings: where this came from, which message it is,
    and what it answers.

    Every marking is NAMED. An unlabelled id makes the reader guess what kind
    of id it is, and once a room id joins the line that guess gets worse --
    so `msg-id:` / `thread-id:` / `reply-to:` / `room:` say it outright.

    Always carries the event's own id -- that is what lets the session open a
    NEW thread on a plain message, not merely answer inside an existing one.
    """
    parts = []
    if room_label:
        parts.append(f"room:{room_label}")
    parts.append(f"msg-id:{event_id}")
    rel = content.get("m.relates_to")
    if isinstance(rel, dict):
        if rel.get("rel_type") == "m.thread" and rel.get("event_id"):
            parts.append(f"thread-id:{rel['event_id']}")
        reply = rel.get("m.in_reply_to")
        # A thread reply carries a synthetic in_reply_to for old clients;
        # only a genuine reply (no fallback flag) is worth announcing.
        if isinstance(reply, dict) and reply.get("event_id") and not rel.get(
            "is_falling_back"
        ):
            parts.append(f"reply-to:{reply['event_id']}")
    return " · " + " · ".join(parts)


def room_label(room_id):
    """Human-readable name of a room, resolved once per room and cached.

    A name beats a room id for someone reading the terminal.  Falls back to
    the room id so the marking is never simply missing.
    """
    if room_id in ROOM_LABELS:
        return ROOM_LABELS[room_id]
    try:
        enc = urllib.parse.quote(room_id, safe="")
        label = matrix_get(
            f"/_matrix/client/v3/rooms/{enc}/state/m.room.name"
        )["name"]
    except Exception as exc:  # unnamed room, or homeserver hiccup
        log(f"room name unresolved for {room_id} ({exc}); using room id")
        label = room_id
    ROOM_LABELS[room_id] = label
    return label


def describe(content):
    """The letter itself -- or a claim ticket when it is not text.

    Audio, images and files are NOT fetched here (that is a later step); the
    point is that they stop vanishing silently. mxc:// is retrievable via the
    media API with our own token when we decide to handle them.
    """
    msgtype = content.get("msgtype", "")
    body = content.get("body", "")
    if msgtype in ("m.text", "m.notice", "m.emote"):
        return body
    info = content.get("info") or {}
    bits = [msgtype, body, info.get("mimetype"), content.get("url")]
    return "[첨부 " + " · ".join(str(b) for b in bits if b) + "]"


def handle_room_events(events, room_id):
    for ev in events:
        if ev.get("type") != "m.room.message":
            continue
        sender = ev.get("sender")
        if sender == SELF_USER_ID:
            continue  # don't re-inject our own outgoing messages
        content = ev.get("content", {})
        if not content.get("msgtype"):
            continue  # redaction or state-ish payload, nothing to deliver
        body = describe(content)
        marks = envelope(ev.get("event_id", ""), content, room_label(room_id))
        text = f"[matrix · {attribution(sender)}{marks}] {body}"
        log(f"RECV from {sender}: {body[:200]!r}")
        inject_into_session(text)


def main():
    log("bridge starting")
    log(f"lounge label: {room_label(ROOM_ID)!r}")
    since = load_since()
    if since is None:
        # First run: establish a baseline without replaying room history.
        resp = matrix_get("/_matrix/client/v3/sync", {"timeout": "0"})
        since = resp["next_batch"]
        save_since(since)
        log(f"baseline established, since={since}")

    while True:
        try:
            resp = matrix_get(
                "/_matrix/client/v3/sync",
                {"since": since, "timeout": str(SYNC_TIMEOUT_MS)},
            )
        # Deliberately broad: a relay must outlive every transport failure.
        # URLError alone is not enough -- killing the homeserver mid-request
        # raises http.client.RemoteDisconnected, which is a ConnectionResetError
        # and NOT a URLError, so it escaped this net and crashed the bridge
        # (observed 2026-09-05 18:41 during the conduit -> tuwunel swap).
        except Exception as e:
            log(f"sync error: {e!r}, retrying in 5s")
            time.sleep(5)
            continue

        # Every joined room, not only the lounge.  2026-09-06 정수님 asked each
        # fleet butler to open its own room and joined ours -- and a bridge that
        # polls one room would have swallowed everything he wrote there in
        # silence, since /sync delivers those events and this loop discarded
        # them.  A room we are IN is a room we must read.
        for room_id, room in resp.get("rooms", {}).get("join", {}).items():
            events = room.get("timeline", {}).get("events", [])
            if events:
                handle_room_events(events, room_id)

        since = resp["next_batch"]
        save_since(since)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
