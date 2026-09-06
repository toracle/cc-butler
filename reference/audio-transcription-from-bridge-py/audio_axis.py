# Extracted verbatim from bridge.py (macbook-m1-max, service dir
# /Users/jeongsoopark/services/matrix-bridge/bridge.py), unmodified except
# for the line-number comments marking provenance. Not runnable standalone
# -- see README.md in this directory for what's deliberately left out and
# why, and for the failure-recovery test evidence (rc=0/rc=1, 2026-09-06
# 21:14).
#
# Do NOT clean up, restructure, or "elisp-ify" this file. It exists so the
# elisp port has ground truth to work from instead of being rebuilt from
# a description. Port from THIS, then delete this reference bundle once
# the port lands and is verified.

# --- bridge.py:71-90 (constants this axis depends on) -----------------

MEDIA_DIR = SERVICE_DIR / "media"  # bridge.py:71
MEDIA_DIR.mkdir(exist_ok=True)  # bridge.py:108

MONOCLE = "/Users/jeongsoopark/.local/bin/monocle"  # bridge.py:78
# launchd does not inherit the interactive shell's PATH, so this must be
# an absolute path -- a bare "monocle" raises FileNotFoundError under the
# service even though it works fine from a terminal.

MONOCLE_ENV = {**os.environ, "HOME": "/Users/jeongsoopark", }  # bridge.py:90
# launchd's environment for this service carries no $HOME at all. `monocle`
# reads $HOME to find ~/.monocle/credentials.json and otherwise fails with
# "Not logged in." and exit code 1 -- despite a valid, working token
# existing on disk. This dict is passed as `env=` to Popen below, NOT set
# via os.environ, so it only affects this one subprocess.

PENDING_TRANSCRIPTIONS = []  # bridge.py:118
# In-memory queue of {"proc", "audio_path", "sender", "footer",
# "human_reminder"} dicts for transcriptions still running. Not persisted
# across a restart -- a transcription in flight at restart time is lost
# (the audio file on disk survives; the pending-delivery record does not).
# This is an accepted gap, not yet solved on the Python side either.


# --- bridge.py:240-254 (filename/path helpers) -------------------------

def sanitize_filename(name):
    """Reduce NAME (attacker/sender-controlled `body` text) to a safe
    filename component -- can't just strip "/" and call it done: this
    replaces everything outside alnum/dot/dash/underscore, so
    "../../etc/passwd" collapses to a plain filename with no directory
    component."""
    safe = re.sub(r"[^A-Za-z0-9._-]", "_", name or "")
    return safe[:100]


def media_path(event_id, body):
    """Where a downloaded attachment for EVENT_ID/BODY is written. The
    event id is server-assigned (not sender-controlled) and already unique,
    so no other collision handling is needed on top of it."""
    return MEDIA_DIR / f"{event_id}-{sanitize_filename(body)}"


# --- bridge.py:257-269 (1. media download) ------------------------------

def download_media(mxc_url, timeout=30):
    """Fetch an attachment's bytes via the authenticated media endpoint
    (MSC3916). This homeserver (Tuwunel 1.9.0) confirmed support for it via
    /_matrix/client/versions (msc3916.stable: true, measured 2026-09-06) --
    no legacy /_matrix/media/v3/download fallback needed here.

    HOMESERVER and TOKEN are bridge-wide constants defined elsewhere in
    bridge.py (HOMESERVER = LAN URL of the x600 homeserver; TOKEN = this
    account's access token, loaded at startup from a credentials file on
    disk -- never hardcoded in source). Both are free variables here,
    exactly as in the original."""
    m = re.match(r"mxc://([^/]+)/(.+)", mxc_url or "")
    if not m:
        return None
    server, media_id = m.group(1), m.group(2)
    url = f"{HOMESERVER}/_matrix/client/v1/media/download/{server}/{media_id}"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {TOKEN}"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


# --- bridge.py:272-333 (2. monocle call site) ---------------------------

def start_audio_transcription(ev, sender, content, footer, human_reminder):
    """Download a voice message and hand it to `monocle audio transcribe`
    in the background (see PENDING_TRANSCRIPTIONS above for why non-
    blocking). The download itself stays a plain synchronous call like
    every other HTTP call in this script -- it's a small, fast, same-LAN
    GET, not the ~120s-worst-case step that needed to move off the main
    thread.

    정수님's instruction (2026-09-06, relayed): audio is almost always a
    voice message, so deliver the *transcribed text*, not just a file path
    -- but keep the original audio file regardless of whether transcription
    succeeds, so it's still usable as an ASR sample even on failure."""
    body = content.get("body") or "voice"
    url = content.get("url", "")
    audio_path = media_path(ev.get("event_id", ""), body)

    # --- (4. failure-preserves-original) branch 1: download itself fails ---
    try:
        data = download_media(url)
    except Exception as e:
        log(f"audio download failed: {e!r}")
        inject_into_session(
            f"[matrix · {attribution(sender)}] (음성 메시지 다운로드 실패: {e!r})\n"
            f"{footer}{human_reminder}"
        )
        return
    if data is None:
        log(f"audio: could not parse mxc url {url!r}")
        inject_into_session(
            f"[matrix · {attribution(sender)}] (음성 메시지 도착 — url 형식 이상: {url!r})\n"
            f"{footer}{human_reminder}"
        )
        return

    # Original bytes hit disk BEFORE monocle is ever invoked -- this is the
    # crux of "preserve the original regardless of what happens next": the
    # write below cannot fail because of anything monocle does, since it
    # hasn't run yet.
    audio_path.write_bytes(data)
    log(f"audio saved: {audio_path} ({len(data)} bytes)")

    # --- (2. monocle call site) --------------------------------------
    # Working directory: inherited (not overridden) -- monocle is invoked
    # with an absolute path to both the binary and the audio file, so cwd
    # doesn't matter for this call. Timeout: none set here (Popen, not
    # run()) -- the ~120s worst case is why this is async in the first
    # place; poll_pending_transcriptions() below is what notices completion.
    try:
        proc = subprocess.Popen(
            [MONOCLE, "audio", "transcribe", str(audio_path)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=MONOCLE_ENV,
        )
    # --- (4. failure-preserves-original) branch 2: monocle won't even start ---
    except Exception as e:
        log(f"audio: failed to start monocle: {e!r}")
        inject_into_session(
            f"[matrix · {attribution(sender)}] (음성 메시지, 텍스트 변환 시작 실패: {e!r})\n"
            f"첨부: {audio_path}\n{footer}{human_reminder}"
        )
        return

    PENDING_TRANSCRIPTIONS.append(
        {
            "proc": proc,
            "audio_path": audio_path,
            "sender": sender,
            "footer": footer,
            "human_reminder": human_reminder,
        }
    )
    log(f"audio: transcription started pid={proc.pid} for {audio_path}")


# --- bridge.py:367-380 (async completion check, called once per poll tick) --

def poll_pending_transcriptions():
    """Called once per main-loop tick. Popen.poll() is instantaneous (no
    blocking), so this never delays the room poll."""
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


# --- bridge.py:336-365 (3. injection point + 4. failure-preserves-original) -

def finish_transcription(item, returncode, stdout, stderr):
    """This is where the transcribed text actually reaches the session
    (inject_into_session calls below) -- the injection point steward asked
    to have called out explicitly. Note ALL THREE branches (success-with-
    text, success-but-empty, nonzero-returncode) reference `첨부:
    {audio_path}` -- the original file path is never dropped from the
    delivered message regardless of how transcription went. rc=0 and rc=1
    both verified live, 2026-09-06 21:14 (real clip / missing file)."""
    audio_path = item["audio_path"]
    sender = item["sender"]
    footer = item["footer"]
    human_reminder = item["human_reminder"]

    if returncode == 0:
        try:
            transcribed = (json.loads(stdout).get("text") or "").strip()
        except Exception:
            transcribed = ""
        if transcribed:
            text = (
                f"[matrix · {attribution(sender)}] (음성 메시지 텍스트 변환) {transcribed}\n"
                f"첨부: {audio_path}\n{footer}{human_reminder}"
            )
        else:
            text = (
                f"[matrix · {attribution(sender)}] (음성 메시지, 변환 결과 비어있음)\n"
                f"첨부: {audio_path}\n{footer}{human_reminder}"
            )
    else:
        # --- (4. failure-preserves-original) branch 3: monocle ran, non-zero exit ---
        text = (
            f"[matrix · {attribution(sender)}] (음성 메시지, 텍스트 변환 실패: "
            f"rc={returncode} {stderr.strip()[:300]!r})\n"
            f"첨부: {audio_path}\n{footer}{human_reminder}"
        )
    log(f"audio: transcription finished rc={returncode} for {audio_path}")
    inject_into_session(text)


# --- what this file does NOT include, on purpose ------------------------
# log(msg), inject_into_session(text), attribution(sender): generic bridge
# primitives, not audio-specific. elisp already has direct equivalents
# (matrix-bridge-attribution; its own logging/injection path) -- do not
# port these three, just call your existing ones from the ported functions
# above.
#
# preflight_check()'s monocle-credentials check (bridge.py:383-412) is NOT
# included here either -- it's a bridge-wide startup self-check, not part
# of the per-message audio axis. See README.md for the one paragraph of
# it that matters for this port (why HOME has to be injected at all).
