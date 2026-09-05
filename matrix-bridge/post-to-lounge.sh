#!/usr/bin/env bash
# Send a text message into the Warmblood Lounge room as @butler-macbook-m1-max.
# Usage: post-to-lounge.sh "text to send" [thread-root-event-id]
#
# With no second arg, behaves identically to the pre-threading version --
# every existing caller (the fleet's lounge relay) must keep working
# unchanged. Pass a thread-root event_id as $2 to reply into that thread
# instead of posting a top-level message.
set -euo pipefail

SERVICE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOMESERVER="http://192.168.100.90:8008"
TOKEN="$(cat "$SERVICE_DIR/butler-macbook-m1-max.token")"
ROOM_ID="$(cat "$SERVICE_DIR/lounge-room-id.txt")"

TEXT="${1:?usage: post-to-lounge.sh \"text\" [thread-root-event-id]}"
THREAD_ROOT="${2:-}"
TXN_ID="$(date +%s%N)"

curl -s -X PUT \
  "$HOMESERVER/_matrix/client/v3/rooms/$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$ROOM_ID")/send/m.room.message/$TXN_ID" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "$(python3 -c '
import json, sys
text, thread_root = sys.argv[1], sys.argv[2]
payload = {"msgtype": "m.text", "body": text}
if thread_root:
    payload["m.relates_to"] = {"rel_type": "m.thread", "event_id": thread_root}
print(json.dumps(payload))
' "$TEXT" "$THREAD_ROOT")"
echo
