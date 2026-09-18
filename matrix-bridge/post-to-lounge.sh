#!/usr/bin/env bash
# Send a text message into the Warmblood Lounge room as this fleet's butler.
# Usage: post-to-lounge.sh "$(cat message.md)" ["$thread-root-event-id"]
#
# Machine identity (homeserver, token, room-id file, human mxid) comes from
# matrix-bridge/config.sh next to this script (MATRIX_BRIDGE_CONFIG=<path>
# to point elsewhere), or plain env vars, which always win.  See config.sh.
#
# Room selection has TWO accepted calling shapes, kept side by side rather
# than picking one, because 2026-09-06 the x600 and m1 fleets each already
# had live callers on their own shape and a silent reinterpretation of an
# existing argument position is exactly how a message lands in the wrong
# room with no error (the orphan-thread incident earlier that night):
#   x600-style (2 args):  ROOM_ID=<id-or-name> post-to-lounge.sh body thread-root
#   m1-style   (4 args):  post-to-lounge.sh body thread-root <reserved> room
# The 3rd positional arg in m1-style is m1's own and not interpreted here --
# only its presence (4 args total) selects the branch.  Exactly 3 args, or
# both a 4th arg AND ROOM_ID set, is refused as ambiguous: a guess here would
# be a silent misroute, so it errors instead.  `room` may be a literal room
# id ('!...') or a symbolic name resolved against
# "$MATRIX_BRIDGE_CONDUIT_DIR/<name>-room-id.txt" (e.g. "lounge", "butlers").
#
# Pass the body via "$(cat FILE)" -- NOT as an inline double-quoted string.
# Inside double quotes the shell runs backticks and expands $..., so a body
# containing `some-name` is executed as a command and REPLACED BY NOTHING.
# Observed 2026-09-05: a session name vanished mid-sentence and the message
# went out mangled; the send still returned 200.  No check here can catch it --
# by the time "$1" arrives the damage already happened in the caller.  Reading
# it back from a file is what makes the body inert.
# With no second arg, behaves byte-for-byte as before (plain top-level message).
#
# MENTION_JEONGSOO=1 adds a real Matrix mention of 정수님 (an m.mentions entry
# plus a matrix.to pill in formatted_body).  He asked for this on 2026-09-06:
# "저한테 메세지 주실 때는 matrix상에서 멘션해주세요."  Without it a message
# addressed to him is just another line in a busy room and may raise no
# notification at all -- so questions can sit unanswered while looking asked.
# It is OPT-IN on purpose: most traffic here is fleet-to-fleet, and mentioning
# him on those would train him to ignore the ping that matters.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${MATRIX_BRIDGE_CONFIG:-$SCRIPT_DIR/config.sh}"
if [ -f "$CONFIG_FILE" ]; then
  # shellcheck source=config.sh
  . "$CONFIG_FILE"
fi

JEONGSOO_MXID="${MATRIX_BRIDGE_HUMAN_MXID:?MATRIX_BRIDGE_HUMAN_MXID not set (config.sh missing or incomplete)}"
CONDUIT_DIR="${MATRIX_BRIDGE_CONDUIT_DIR:?MATRIX_BRIDGE_CONDUIT_DIR not set (config.sh missing or incomplete)}"
HOMESERVER="${MATRIX_BRIDGE_HOMESERVER:?MATRIX_BRIDGE_HOMESERVER not set (config.sh missing or incomplete)}"
TOKEN="$(cat "${MATRIX_BRIDGE_SELF_TOKEN_FILE:?MATRIX_BRIDGE_SELF_TOKEN_FILE not set (config.sh missing or incomplete)}")"

TEXT="${1:?usage: post-to-lounge.sh \"text\" [thread-root-event-id]}"
THREAD_ROOT="${2:-}"

# Room selection: two calling shapes, see header comment for why both stay.
case "$#" in
  0|1|2) CALL_MODE=x600 ;;
  4)     CALL_MODE=m1 ;;
  *) echo "post-to-lounge: unrecognized call shape ($# args)." >&2
     echo "  expected 2 args (x600: body, thread-root; room via ROOM_ID env)" >&2
     echo "  or 4 args (m1: body, thread-root, <m1-reserved>, room)." >&2
     exit 2 ;;
esac
if [ "$CALL_MODE" = "m1" ] && [ -n "${ROOM_ID:-}" ]; then
  echo "post-to-lounge: ambiguous room selection -- got BOTH a 4th" >&2
  echo "  positional arg ('$4') AND ROOM_ID=$ROOM_ID in the environment." >&2
  echo "  Pick one: 4 positional args (m1-style) XOR ROOM_ID env var (x600-style)." >&2
  exit 2
fi
ROOM_RAW="${ROOM_ID:-}"
[ "$CALL_MODE" = "m1" ] && ROOM_RAW="$4"

# Reading became multi-room on 2026-09-06 (the bridge now polls every joined
# room, including each fleet's own), but sending stayed pinned to one room per
# call -- so a message arriving in a fleet room would be READ there and
# ANSWERED elsewhere, which is the same "right channel, wrong place" failure
# measured that day, one level up.
if [ -z "$ROOM_RAW" ]; then
  ROOM_ID="$(cat "${MATRIX_BRIDGE_ROOM_ID_FILE:?MATRIX_BRIDGE_ROOM_ID_FILE not set (config.sh missing or incomplete)}")"
elif [ "${ROOM_RAW#!}" != "$ROOM_RAW" ]; then
  ROOM_ID="$ROOM_RAW"
else
  ROOM_NAME_FILE="$CONDUIT_DIR/${ROOM_RAW}-room-id.txt"
  if [ ! -f "$ROOM_NAME_FILE" ]; then
    echo "post-to-lounge: unknown room '$ROOM_RAW' (no $ROOM_NAME_FILE)" >&2
    exit 2
  fi
  ROOM_ID="$(cat "$ROOM_NAME_FILE")"
fi
case "$ROOM_ID" in
  '!'*) : ;;
  *) echo "post-to-lounge: bad ROOM_ID: $ROOM_ID (a room id starts with !)" >&2
     exit 2 ;;
esac

# An argument that is PRESENT but EMPTY is a caller bug, not a request to post
# at top level -- and the two are indistinguishable downstream, so the message
# posts top-level and the send still returns 200.  This is not hypothetical:
# 2026-09-06 the m1 fleet lost a reply to 정수님 exactly this way by writing
# "$evt" in DOUBLE quotes, where the shell expanded the '$'-leading event id to
# nothing.  It then asked 정수님 to eyeball whether the reply had attached --
# spending his hand on a value we can read ourselves.  Refuse it here.
if [ "$#" -ge 2 ] && [ -z "$THREAD_ROOT" ]; then
  echo "post-to-lounge: thread root argument was given but is EMPTY" >&2
  echo "  event ids start with \$ -- quote them with SINGLE quotes." >&2
  echo "  inside double quotes the shell expands \"\$abc\" to nothing and the" >&2
  echo "  message would post at top level with no error." >&2
  exit 2
fi

# Matrix accepts ANY thread root without validating it: a malformed or simply
# wrong id is not refused, it silently starts an orphan thread and the send
# still returns 200.  A caller that writes '\$abc' (a backslash kept literal by
# single quotes) therefore fails invisibly.  Refuse it here, at the write site.
if [ -n "$THREAD_ROOT" ]; then
  case "$THREAD_ROOT" in
    '$'*) : ;;
    *) echo "post-to-lounge: bad thread root: $THREAD_ROOT" >&2
       echo "  an event id starts with \$ -- a leading backslash usually means" >&2
       echo "  it was written as '\\\$...' inside single quotes." >&2
       exit 2 ;;
  esac
fi
# A thread root that is simply ABSENT is the failure this script could not see.
# 2026-09-06, measured against the room itself: 18 of 정수님's 69 messages that
# day got no reply in their own thread -- and the largest cluster was not work
# left undone but work DONE and reported in the WRONG thread (he asked for a
# room, the room was created and announced, and the thread he asked in stayed
# empty).  He had already said "쓰레드 댓글로 달아주세요" twice that same day, so
# remembering demonstrably does not work; only a mechanism does.
#
# Replying is the overwhelmingly common case, so it is the default and opening
# a new subject is what must be said out loud.  NEW_TOPIC=1 is that saying.
if [ "$#" -lt 2 ] && [ "${NEW_TOPIC:-}" != "1" ]; then
  echo "post-to-lounge: no thread root given." >&2
  echo "  Default to replying INSIDE the thread the message arrived in --" >&2
  echo "  the notification carries thread-id:/reply-to: for exactly this." >&2
  echo "  Answering elsewhere leaves the asker's own thread looking ignored," >&2
  echo "  even when the work is done and posted." >&2
  echo "  Genuinely opening a new subject?  NEW_TOPIC=1 post-to-lounge.sh ..." >&2
  exit 2
fi

# A thread root is only meaningful in the room that HOLDS it.  Matrix does not
# check this: give it a root from another room and it starts an orphan thread,
# returns 200, and the reply is simply somewhere the asker is not looking.
# 2026-09-06 this happened -- a reply meant for the new "butlers" room went to
# the lounge because ROOM_ID was left off while the root belonged to butlers.
#
# ⚠ Do NOT verify with /rooms/{room}/event/{id}: this homeserver serves that
# event whatever room you name in the path, so it answers "yes" for both rooms
# and cannot tell them apart.  /context/ DOES 404 on the wrong room (measured
# the same day, both directions), which is what makes it usable as a check.
if [ -n "$THREAD_ROOT" ]; then
  ROOT_HTTP="$(curl -s -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer $TOKEN" \
    "$HOMESERVER/_matrix/client/v3/rooms/$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$ROOM_ID")/context/$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$THREAD_ROOT")?limit=0")"
  if [ "$ROOT_HTTP" != "200" ]; then
    echo "post-to-lounge: thread root is NOT in this room (HTTP $ROOT_HTTP)." >&2
    echo "  root: $THREAD_ROOT" >&2
    echo "  room: $ROOM_ID" >&2
    echo "  Matrix would accept this and start an ORPHAN thread -- the reply" >&2
    echo "  lands where the asker never looks, and the send still returns 200." >&2
    echo "  Did you forget ROOM_ID=<the room the message came from>?" >&2
    exit 2
  fi
fi

# 정수님, 2026-09-06: "메인 피드는 간결하게 유지하고 싶습니다. 상세한 내용은 각
# 쓰레드 안에서 관리되고 논의되도록."  A top-level post is the feed; a thread
# reply is the discussion.  So length is refused HERE and nowhere else -- the
# same words are perfectly fine one level down.
#
# Counted in characters, not bytes: this text is Korean, and a byte limit would
# cut it at roughly a third of the intended length.
TOPLEVEL_MAX="${TOPLEVEL_MAX:-900}"
if [ -z "$THREAD_ROOT" ]; then
  TEXT_LEN="$(printf '%s' "$TEXT" | python3 -c "import sys;print(len(sys.stdin.read()))")"
  if [ "$TEXT_LEN" -gt "$TOPLEVEL_MAX" ]; then
    echo "post-to-lounge: top-level post is $TEXT_LEN chars (limit $TOPLEVEL_MAX)." >&2
    echo "  The main feed stays a summary; detail belongs in the thread under it." >&2
    echo "  Post the SUMMARY at top level, read back its event id, then send the" >&2
    echo "  detail as a reply with that id as the thread root." >&2
    echo "  (A deliberate exception: TOPLEVEL_MAX=<n> post-to-lounge.sh ...)" >&2
    exit 2
  fi
fi

TXN_ID="$(date +%s%N)"

BODY_JSON="$(python3 -c '
import json, os, re, sys
text = sys.argv[1]
thread_root = sys.argv[2] if len(sys.argv) > 2 else ""
mxid = sys.argv[3] if len(sys.argv) > 3 else ""
mention = mxid and os.environ.get("MENTION_JEONGSOO") == "1"
if mention:
    # The plain-text body carries the localpart too: older clients raise their
    # notification from a body match, newer ones from m.mentions.  Both paths
    # are cheap, and having only one of them is how a "sent" ping goes unheard.
    text = "%s: %s" % (mxid.split(":")[0], text)
msg = {"msgtype": "m.text", "body": text}
try:
    # Element renders formatted_body; plain body stays as the fallback.
    import markdown
    html = markdown.markdown(text, extensions=["extra", "nl2br", "sane_lists"])
    html = re.sub(r"(?<![\">])(https?://[^\s<]+)", r"<a href=\"\1\">\1</a>", html)
    if mention:
        # NOTE: this whole python program lives inside bash single quotes, so a
        # single quote here would END it and the rest would run as shell.  That
        # is exactly what happened first try: `<a href=...` became a command.
        pill = "<a href=\"https://matrix.to/#/%s\">%s</a>" % (mxid, mxid.split(":")[0])
        html = html.replace(mxid.split(":")[0] + ":", pill + ":", 1)
    msg["format"] = "org.matrix.custom.html"
    msg["formatted_body"] = html
except Exception:
    pass  # no markdown module -> send plain, exactly as before
if mention:
    msg["m.mentions"] = {"user_ids": [mxid]}
if thread_root:
    msg["m.relates_to"] = {"rel_type": "m.thread", "event_id": thread_root}
print(json.dumps(msg))
' "$TEXT" "$THREAD_ROOT" "$JEONGSOO_MXID")"

# Every guard above can be tested by watching it REFUSE -- nothing is sent, so
# the check is free.  The PASS path had no such option: the only way to prove a
# guard lets a good message through was to actually send one.  2026-09-06 the m1
# fleet proved its 900-char cap by posting a real 899-char filler message into a
# shared room, minutes after 정수님 asked for the main feed to stay short -- and
# then could not redact it.  The test was correct; the only way to run it wasn't.
DRY_RUN="${DRY_RUN:-}"
if [ "$DRY_RUN" = "1" ]; then
  echo "post-to-lounge: DRY_RUN -- all guards passed, nothing sent." >&2
  echo "  room:   $ROOM_ID" >&2
  echo "  thread: ${THREAD_ROOT:-<top level>}" >&2
  printf '%s\n' "$BODY_JSON"
  exit 0
fi

curl -s -X PUT \
  "$HOMESERVER/_matrix/client/v3/rooms/$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$ROOM_ID")/send/m.room.message/$TXN_ID" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  --fail-with-body \
  -d "$BODY_JSON" || SEND_RC=$?
echo

# A plain `curl -s` exits 0 on HTTP 4xx/5xx, so every failed send used to look
# like a success to the caller (measured 2026-09-05: 401 -> rc=0, and `set -e`
# does not catch it).  --fail-with-body keeps the errcode text AND fails.
#
# The warning matters as much as the exit code.  This server persists the event
# and THEN reports failure: a bogus thread root returns HTTP 400
# M_INVALID_PARAM while the message lands in the room anyway (reproduced on
# both fleets, 2026-09-05).  Resending on that lie is what turns one orphan
# into two -- which is exactly how it happened.
if [ "${SEND_RC:-0}" != "0" ]; then
  echo "post-to-lounge: send REPORTED FAILURE (curl rc=$SEND_RC)." >&2
  echo "  ⚠ It may still have landed -- this server writes the event, then" >&2
  echo "    answers with an error.  READ THE ROOM before resending." >&2
  exit 3
fi
