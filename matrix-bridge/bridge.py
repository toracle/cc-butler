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
import re
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

MEDIA_DIR = SERVICE_DIR / "media"
MEDIA_DIR.mkdir(exist_ok=True)
# Absolute paths: this service runs under `systemctl --user`, whose PATH
# (measured 2026-09-10: /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:
# /sbin:/bin) does not include ~/.local/bin, so a bare "monocle"/"ffprobe"
# raises FileNotFoundError even though both work fine from a terminal.
MONOCLE = "/home/toracle/.local/bin/monocle"
FFPROBE = "/usr/bin/ffprobe"
# In-flight {"proc", "audio_path", "prefix"} dicts, drained once per main-loop
# tick by poll_pending_transcriptions(). Not persisted -- a transcription
# in flight at restart time is lost (the audio file on disk survives).
PENDING_TRANSCRIPTIONS = []

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


# Off by default -- every importer (test, REPL, a future wrapper) gets the
# safe, non-delivering behavior with nothing to remember. Flipped to True by
# exactly one explicit call, enable_live_delivery(), made from exactly one
# place: main(), right before it starts the real event loop.
#
# Deliberately NOT `__name__ == "__main__"`. That was this guard's first
# version, and a reviewer caught why it's wrong: it INFERS liveness from how
# the interpreter happened to invoke this file, so it silently flips to
# False the moment anything changes that shape -- `python -m bridge`, a
# supervisor that imports this module and calls main() directly, anything
# that wraps it. A silently disabled delivery path is exactly the failure
# mode this whole task exists to fix (41 voice messages, 5 days, nobody
# noticed because nothing said so) -- so this listens for an explicit
# decision instead of inferring one from execution shape, and the state is
# always logged (see the module-level log call near the bottom of this
# file, and enable_live_delivery() itself) so it can never be silently
# wrong either way.
#
# Incident, 2026-09-10, that led to this guard existing at all: a test that
# forgot to stub inject_into_session() actually shelled out to emacsclient
# and injected a fabricated message into the live "butler" session. The
# guard lives inside inject_into_session() itself (the one place that calls
# emacsclient), not at each call site, so no caller can forget it.
LIVE = False


def enable_live_delivery():
    """Call exactly once, only from main(), immediately before it starts
    the real event loop. This is the one explicit statement "this process
    is genuinely running as the live service" -- everything else (import,
    test, REPL) leaves LIVE False."""
    global LIVE
    LIVE = True
    log("delivery: LIVE")


def inject_into_session(text):
    if not LIVE:
        log(f"SUPPRESSED inject (not LIVE, {len(text)} chars)")
        return
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


def sanitize_filename(name):
    """Reduce NAME (sender-controlled `body` text) to a safe filename
    component -- replaces everything outside alnum/dot/dash/underscore, so
    "../../etc/passwd" collapses to a plain filename with no directory
    component."""
    safe = re.sub(r"[^A-Za-z0-9._-]", "_", name or "")
    return safe[:100]


def media_path(event_id, body):
    """Where a downloaded attachment for EVENT_ID/BODY is written. The
    event id is server-assigned (not sender-controlled) and already unique."""
    return MEDIA_DIR / f"{event_id}-{sanitize_filename(body)}"


def download_media(mxc_url, timeout=30):
    """Fetch an attachment's bytes via the authenticated media endpoint
    (MSC3916) -- this homeserver (Tuwunel) supports it; no legacy
    /_matrix/media/v3/download fallback needed."""
    m = re.match(r"mxc://([^/]+)/(.+)", mxc_url or "")
    if not m:
        return None
    server, media_id = m.group(1), m.group(2)
    url = f"{HOMESERVER}/_matrix/client/v1/media/download/{server}/{media_id}"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {TOKEN}"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


def is_decodable(path):
    """True if ffprobe finds an actual audio stream in PATH.

    This is what tells a broken/empty recording (real case, 09-10 10:52:
    valid OggS/Opus headers, 493,446 bytes, but 99.8% null bytes -- ffmpeg
    cannot decode it) apart from a monocle/API failure on a genuine
    recording. Only the former needs a resend -- asking 정수님 to repeat
    himself for the latter would be wrong."""
    result = subprocess.run(
        [FFPROBE, "-v", "error", "-select_streams", "a",
         "-show_entries", "stream=codec_type", "-of", "csv=p=0", str(path)],
        capture_output=True, text=True, timeout=15,
    )
    return result.returncode == 0 and "audio" in result.stdout


def start_audio_transcription(ev, sender, content, room_id):
    """Download a voice message and hand it to `monocle audio transcribe`
    in the background (PENDING_TRANSCRIPTIONS is why this is non-blocking).

    Ported from macbook-m1-max's bridge.py:257-333 (verbatim reference:
    cc-butler commit ac09068, reference/audio-transcription-from-bridge-py)
    -- same three-branch failure-preserves-original structure (download
    fails / bad url / monocle won't start), same async poll-based
    completion. Two deliberate changes from that reference:
      (a) `monocle` needs only its absolute path here, not m1's MONOCLE_ENV
          HOME override -- measured 2026-09-10 that this systemd --user
          service already has a correct $HOME (unlike m1's launchd job);
          only PATH is restricted, and the absolute path alone covers it.
      (b) an is_decodable() gate runs before monocle is ever invoked, so a
          broken recording is classified (and reported: please resend)
          without spending an API call or misfiling it as a tool failure.
    """
    event_id = ev.get("event_id", "")
    body = content.get("body") or "voice"
    url = content.get("url", "")
    marks = envelope(event_id, content, room_label(room_id))
    prefix = f"[matrix · {attribution(sender)}{marks}]"
    audio_path = media_path(event_id, body)

    try:
        data = download_media(url)
    except Exception as e:
        log(f"audio download failed: {e!r}")
        inject_into_session(f"{prefix} (음성 메시지 다운로드 실패: {e!r})")
        return
    if data is None:
        log(f"audio: could not parse mxc url {url!r}")
        inject_into_session(f"{prefix} (음성 메시지 도착 — url 형식 이상: {url!r})")
        return

    # Original bytes hit disk BEFORE anything else runs -- this ordering is
    # the whole mechanism behind "preserved regardless of outcome".
    audio_path.write_bytes(data)
    log(f"audio saved: {audio_path} ({len(data)} bytes)")

    if not is_decodable(audio_path):
        log(f"audio: input broken, ffprobe cannot decode it -- {audio_path}")
        inject_into_session(
            f"{prefix} (음성 메시지가 빈 채로 도착했습니다 — 다시 보내 주셔야 합니다)\n"
            f"첨부: {audio_path}"
        )
        return

    try:
        proc = subprocess.Popen(
            [MONOCLE, "audio", "transcribe", str(audio_path)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
    except Exception as e:
        log(f"audio: failed to start monocle: {e!r}")
        inject_into_session(
            f"{prefix} (음성 메시지, 텍스트 변환 시작 실패: {e!r})\n첨부: {audio_path}"
        )
        return

    PENDING_TRANSCRIPTIONS.append({"proc": proc, "audio_path": audio_path, "prefix": prefix})
    log(f"audio: transcription started pid={proc.pid} for {audio_path}")


def poll_pending_transcriptions():
    """Called once per main-loop tick. Popen.poll() is instantaneous, so
    this never delays the room poll."""
    if not PENDING_TRANSCRIPTIONS:
        return
    still_pending = []
    for item in PENDING_TRANSCRIPTIONS:
        proc = item["proc"]
        if proc.poll() is None:
            still_pending.append(item)
            continue
        stdout, stderr = proc.communicate()
        finish_transcription(item, proc.returncode, stdout, stderr)
    PENDING_TRANSCRIPTIONS[:] = still_pending


def finish_transcription(item, returncode, stdout, stderr):
    """Deliver the transcription result. All three branches reference
    `첨부: {audio_path}` -- the original file is never dropped from the
    message regardless of how transcription went.

    Success is logged as its own distinct line (length only, never the
    transcribed text) -- not just the absence of a failure line. Steward
    09-10: this gap sat unnoticed for 5 days because the butler was manually
    transcribing, so the tool's own silent non-operation read as "handled".
    A machine that logs identically whether it ran or not can reproduce
    that exact blind spot in the opposite direction."""
    audio_path = item["audio_path"]
    prefix = item["prefix"]
    if returncode == 0:
        try:
            transcribed = (json.loads(stdout).get("text") or "").strip()
        except Exception:
            transcribed = ""
        if transcribed:
            log(f"audio: transcription OK ({len(transcribed)} chars) for {audio_path}")
            text = f"{prefix} (음성 메시지 텍스트 변환) {transcribed}\n첨부: {audio_path}"
        else:
            log(f"audio: transcription OK but empty text for {audio_path}")
            text = f"{prefix} (음성 메시지, 변환 결과 비어있음)\n첨부: {audio_path}"
    else:
        log(f"audio: transcription tool failure rc={returncode} for {audio_path}: {stderr.strip()[:300]!r}")
        text = (
            f"{prefix} (음성 메시지, 텍스트 변환 실패: rc={returncode} {stderr.strip()[:300]!r})\n"
            f"첨부: {audio_path}"
        )
    inject_into_session(text)


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
        event_id = ev.get("event_id", "")
        if content.get("msgtype") == "m.audio":
            log(f"RECV [{room_label(room_id)}] own={event_id} from {sender}: <audio {content.get('body', '')!r}>")
            start_audio_transcription(ev, sender, content, room_id)
            continue
        body = describe(content)
        marks = envelope(event_id, content, room_label(room_id))
        text = f"[matrix · {attribution(sender)}{marks}] {body}"
        # Log the FULL body, not a 200-char slice: this line is the only durable
        # record of an inbound message, and a compacted session reconstructs from
        # it.  Truncating here silently loses the tail of exactly the long, dense
        # messages worth reconstructing.  event_id makes the entry addressable.
        log(f"RECV [{room_label(room_id)}] own={event_id} from {sender}: {body!r}")
        inject_into_session(text)


def main():
    enable_live_delivery()
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

        # Runs every tick (at least every SYNC_TIMEOUT_MS, even with no new
        # events) -- a transcription in flight must not wait on the next
        # message to be noticed as done.
        poll_pending_transcriptions()

        since = resp["next_batch"]
        save_since(since)


# Runs on every import, always -- proves the delivery state out loud rather
# than leaving it to be inferred. At this point LIVE is still False even for
# the real service (main() hasn't run yet); main() logs "delivery: LIVE" a
# moment later when it actually starts. Anything that only ever imports
# this module (a test, a REPL) logs this line and nothing else.
log(f"delivery: {'LIVE' if LIVE else 'DISABLED(imported)'}")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
