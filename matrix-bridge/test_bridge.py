#!/usr/bin/env python3
"""Self-check for the bridge's envelope/描述 formatting. Run: python3 test_bridge.py"""
import subprocess
import bridge
from bridge import (
    describe, envelope, is_decodable, start_audio_transcription,
    finish_transcription, enable_live_delivery,
)

# --- delivery safety: the delivery function itself must refuse to actually
# send outside the live process (incident, 2026-09-10: a test called
# start_audio_transcription() before its failure branch's inject_into_session()
# was stubbed, and it really shelled out to emacsclient, injecting a
# fabricated message into the live "butler" cc-butler session). The guard
# belongs INSIDE the one function that shells out to emacsclient, not at
# each call site -- a per-site stub is a thing the next test author can
# forget; a guard the delivery function applies to itself cannot be.
#
# Judgment must be an explicit decision (enable_live_delivery(), called only
# from main()), never inferred from execution shape (`__name__ ==
# "__main__"` was this guard's first version -- a reviewer caught that it
# silently flips if anything ever wraps/imports this file differently). So
# this asserts BOTH halves: the default (import alone) stays off, AND the
# one explicit path that's supposed to turn it on actually does.
assert bridge.LIVE is False, "importing bridge.py must never count as the live process"
enable_live_delivery()
assert bridge.LIVE is True, "enable_live_delivery() must actually turn delivery on"
bridge.LIVE = False  # back to safe for the rest of this file


class _RecordedProc:
    returncode = 0
    stdout = ""
    stderr = ""


_emacsclient_calls = []


def _recording_run(*args, **kwargs):
    _emacsclient_calls.append(args[0] if args else kwargs.get("args"))
    return _RecordedProc()


_real_subprocess_run = subprocess.run
subprocess.run = _recording_run
bridge.inject_into_session("must never actually send -- LIVE is False here")
subprocess.run = _real_subprocess_run
assert not any(cmd and cmd[0] == "emacsclient" for cmd in _emacsclient_calls), (
    f"inject_into_session shelled out to emacsclient despite LIVE=False: {_emacsclient_calls}"
)

# --- envelope: what the courier stamps on the outside ---------------------
plain = envelope("$abc", {"msgtype": "m.text", "body": "hi"})
assert plain == " · msg-id:$abc", plain

# room label, when the bridge knows it, is named explicitly
with_room = envelope("$abc", {"msgtype": "m.text", "body": "hi"}, "Warmblood Lounge")
assert with_room == " · room:Warmblood Lounge · msg-id:$abc", with_room

threaded = envelope(
    "$def",
    {
        "msgtype": "m.text",
        "m.relates_to": {"rel_type": "m.thread", "event_id": "$root"},
    },
)
assert threaded == " · msg-id:$def · thread-id:$root", threaded

# A thread reply's synthetic in_reply_to must NOT show up as a real reply.
fallback = envelope(
    "$ghi",
    {
        "msgtype": "m.text",
        "m.relates_to": {
            "rel_type": "m.thread",
            "event_id": "$root",
            "is_falling_back": True,
            "m.in_reply_to": {"event_id": "$prev"},
        },
    },
)
assert fallback == " · msg-id:$ghi · thread-id:$root", fallback

# A genuine reply (no thread) must show up.
replied = envelope(
    "$jkl", {"msgtype": "m.text", "m.relates_to": {"m.in_reply_to": {"event_id": "$tgt"}}}
)
assert replied == " · msg-id:$jkl · reply-to:$tgt", replied

# --- describe: text passes through, attachments leave a claim ticket ------
assert describe({"msgtype": "m.text", "body": "hello"}) == "hello"
assert describe({"msgtype": "m.notice", "body": "note"}) == "note"

img = describe(
    {
        "msgtype": "m.image",
        "body": "shot.png",
        "url": "mxc://x/1",
        "info": {"mimetype": "image/png"},
    }
)
assert img == "[첨부 m.image · shot.png · image/png · mxc://x/1]", img

# Missing info must not crash -- the ticket just carries less.
bare = describe({"msgtype": "m.audio", "body": "voice.ogg"})
assert bare == "[첨부 m.audio · voice.ogg]", bare

# --- audio transcription axis ---------------------------------------------
# inject_into_session() shells out to a REAL emacsclient, targeting the
# live "butler" cc-butler session -- stub it BEFORE any call that can reach
# it, full stop. (Incident, 2026-09-10: an earlier version of this test
# called start_audio_transcription() before this stub was in place, and its
# failure branch actually injected a fabricated "please resend" message
# into the live butler session's terminal, attributed to 정수님. No real
# harm intended or done to bridge.log -- but a test must never be able to
# touch production infrastructure, so this stub goes first, before
# anything else in this section.)
_captured = []
bridge.inject_into_session = lambda text: _captured.append(text)

# is_decodable: real ffprobe, real files -- this is what tells "the input
# itself is broken" (needs a resend) apart from "monocle/API failed" (does
# not). No mocking here; it's a fast, local, offline check.
import tempfile

_tmpdir = tempfile.mkdtemp()
_valid_ogg = f"{_tmpdir}/valid.ogg"
subprocess.run(
    ["ffmpeg", "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
     "-c:a", "libopus", _valid_ogg, "-loglevel", "error"],
    check=True,
)
assert is_decodable(_valid_ogg) is True

_broken_ogg = f"{_tmpdir}/broken.ogg"
with open(_broken_ogg, "wb") as f:
    f.write(b"OggS" + bytes(200) + bytes(500000))  # real-case shape: looks
    # like an Ogg file (magic bytes present) but ffprobe cannot decode it --
    # matches the 09-10 10:52 field case (headers present, 99.8% null bytes).
assert is_decodable(_broken_ogg) is False

# start_audio_transcription: a genuine attachment must actually reach
# monocle -- not silently no-op, which is the bug this axis exists to fix
# (41 voice messages, 09-06 through 09-10, delivered with zero content).
# bridge.MONOCLE is pointed at a stub script (not subprocess.Popen itself --
# that would also break is_decodable()'s own subprocess.run call, since
# both share the same subprocess module) so this test runs a real Popen
# through real plumbing, just fast and offline. The real `monocle audio
# transcribe` behavior against these same two files was measured by hand
# first (see PR body): valid -> rc=0, "text":""; broken -> rejected by
# is_decodable() before monocle is ever invoked.
_fake_monocle = f"{_tmpdir}/fake_monocle.sh"
with open(_fake_monocle, "w") as f:
    f.write('#!/bin/sh\necho \'{"text": "stub"}\'\n')
import os
os.chmod(_fake_monocle, 0o755)
bridge.MONOCLE = _fake_monocle

bridge.download_media = lambda url, timeout=30: open(_valid_ogg, "rb").read()
bridge.PENDING_TRANSCRIPTIONS.clear()
start_audio_transcription(
    {"event_id": "$t1"}, "@jeongsoo:warmblood-lounge",
    {"msgtype": "m.audio", "body": "voice.ogg", "url": "mxc://x/1"}, "!room:x",
)
assert len(bridge.PENDING_TRANSCRIPTIONS) == 1, "a genuine audio message must queue a transcription"
_t1_proc = bridge.PENDING_TRANSCRIPTIONS[0]["proc"]
_t1_proc.wait(timeout=5)
assert _t1_proc.returncode == 0, "the stub monocle must have actually run"

# Negative control, the opposite direction: a broken recording must never
# reach monocle at all -- is_decodable() rejects it first.
bridge.download_media = lambda url, timeout=30: open(_broken_ogg, "rb").read()
bridge.PENDING_TRANSCRIPTIONS.clear()
start_audio_transcription(
    {"event_id": "$t2"}, "@jeongsoo:warmblood-lounge",
    {"msgtype": "m.audio", "body": "voice.ogg", "url": "mxc://x/2"}, "!room:x",
)
assert len(bridge.PENDING_TRANSCRIPTIONS) == 0, "a broken recording should never reach monocle"

# finish_transcription: the three "monocle ran" outcomes must each produce
# a visibly different message. Success is not just "no failure line" --
# steward 09-10: this exact gap went unnoticed for 5 days because manual
# transcription made silent non-operation look identical to success.
_captured.clear()

finish_transcription({"audio_path": _valid_ogg, "prefix": "[matrix · x]"}, 0, '{"text": "hello"}', "")
assert "텍스트 변환) hello" in _captured[-1], _captured[-1]

finish_transcription({"audio_path": _valid_ogg, "prefix": "[matrix · x]"}, 0, '{"text": ""}', "")
assert "변환 결과 비어있음" in _captured[-1], _captured[-1]

finish_transcription({"audio_path": _valid_ogg, "prefix": "[matrix · x]"}, 1, "", "some api error")
assert "텍스트 변환 실패: rc=1" in _captured[-1], _captured[-1]

print("ok")
