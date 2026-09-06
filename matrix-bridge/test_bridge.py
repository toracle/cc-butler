#!/usr/bin/env python3
"""Self-check for the bridge's envelope/描述 formatting. Run: python3 test_bridge.py"""
from bridge import describe, envelope

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

print("ok")
