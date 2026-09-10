#!/usr/bin/env python3
"""Which threads in the lounge are waiting on US?

ALWAYS run --all at least once: it shows the answered threads too, and that is
your positive control. A bare "nothing waiting" from a tool you have not seen
say anything else is not evidence -- it is an unexercised instrument.

bridge.log records only RECV (inbound). Judging "we never answered X" from it
is structurally impossible -- our own replies leave no trace there. This asks
the ROOM, which has both directions.

  ./unanswered.py                 # default room, last 300 events
  ./unanswered.py --room '!x:y'   # another room
  ./unanswered.py --all           # show answered threads too

A thread is "waiting on us" when its most recent message is from a human.

--asked is the MIRROR question, and it is a different one: not "did we answer
them" but "did THEY already answer us". Run it before asking a human anything.
2026-09-07 both fleets re-asked a question answered 3h40m earlier; each had
checked its own status file, which truthfully did not contain the answer.
A curated record is a CACHE of the room, and compaction ages it silently --
so the record is the one source structurally unable to answer this. Ask the
room. It reads the whole thread via the relations API, not a recent-events
window, because the answer you are missing is usually older than the window.

  ./unanswered.py --asked '$evt'  # every human message in that thread
"""
import argparse, datetime, json, os, sys, urllib.parse, urllib.request

HS = os.environ.get("MATRIX_HS", "http://localhost:8008")
TOKEN_FILE = os.path.expanduser("~/services/conduit/butler-x600.token")
DEFAULT_ROOM = os.environ.get("ROOM_ID", "!2quro5f9Gj0yniC8H6:warmblood-lounge")
# Senders that are fleet agents; anything else is treated as a human.
BOT_PREFIXES = ("@butler-", "@steward-", "@worker-", "@monocle-", "@xray")


def api(path, token):
    req = urllib.request.Request(HS + path, headers={"Authorization": "Bearer " + token})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.load(r)


def is_bot(sender):
    return sender.startswith(BOT_PREFIXES)


def thread_humans(room, root_id, token):
    """Every human message in one thread, oldest first. Resolves a reply id to
    its root, and includes the root itself -- the relations endpoint omits it."""
    ev = api(f"/_matrix/client/v3/rooms/{room}/event/{urllib.parse.quote(root_id, safe='')}", token)
    rel = (ev.get("content") or {}).get("m.relates_to") or {}
    if rel.get("rel_type") == "m.thread":          # given a reply, not the root
        root_id = rel["event_id"]
        ev = api(f"/_matrix/client/v3/rooms/{room}/event/{urllib.parse.quote(root_id, safe='')}", token)

    events, frm = [ev], None
    while True:
        q = "limit=100" + (f"&from={urllib.parse.quote(frm, safe='')}" if frm else "")
        d = api(f"/_matrix/client/v1/rooms/{room}/relations/"
                f"{urllib.parse.quote(root_id, safe='')}/m.thread?{q}", token)
        events += d.get("chunk", [])
        frm = d.get("next_batch")
        if not frm:
            break
    return root_id, sorted((e for e in events if not is_bot(e.get("sender", ""))),
                           key=lambda e: e["origin_server_ts"])


def room_humans(room, days, token):
    """Every human message in the room within `days`, oldest first, each tagged
    with the thread it lives in. This is the DEFAULT shape of the question:
    at the moment you are about to ask, you do not know which thread already
    holds the answer -- so a mode that demands a thread id hands the hard half
    back to you. Paginates to the cutoff; never a fixed recent-events window."""
    cutoff = (datetime.datetime.now() - datetime.timedelta(days=days)).timestamp() * 1000
    out, frm = [], None
    while True:
        q = "dir=b&limit=100" + (f"&from={urllib.parse.quote(frm, safe='')}" if frm else "")
        d = api(f"/_matrix/client/v3/rooms/{room}/messages?{q}", token)
        chunk = d.get("chunk", [])
        for e in chunk:
            if e.get("type") != "m.room.message" or is_bot(e.get("sender", "")):
                continue
            if e["origin_server_ts"] >= cutoff:
                out.append(e)
        frm = d.get("end")
        if not chunk or not frm or chunk[-1].get("origin_server_ts", 0) < cutoff:
            break
    return sorted(out, key=lambda e: e["origin_server_ts"])


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--asked", nargs="?", const="", metavar="EVENT_ID",
                   help="did they already answer? bare = whole room (use --days); "
                        "with an event/thread id = just that thread")
    p.add_argument("--days", type=float, default=1.0,
                   help="how far back --asked scans in room-wide mode (default 1)")
    p.add_argument("--room", default=DEFAULT_ROOM)
    p.add_argument("--limit", type=int, default=300)
    p.add_argument("--all", action="store_true")
    a = p.parse_args()

    token = open(TOKEN_FILE).read().strip()
    room = urllib.parse.quote(a.room, safe="")

    if a.asked == "":                      # bare --asked: whole room, no thread id needed
        humans = room_humans(room, a.days, token)
        print(f"human messages in {a.room}, last {a.days} day(s): {len(humans)}")
        if not humans:
            print("NONE -- they have not spoken in this room in that window. "
                  "Widen --days before treating this as 'never asked'.")
            return
        for e in humans:
            when = datetime.datetime.fromtimestamp(e["origin_server_ts"] / 1000).strftime("%m-%d %H:%M:%S")
            rel = (e["content"].get("m.relates_to") or {})
            root = rel.get("event_id") if rel.get("rel_type") == "m.thread" else e["event_id"]
            body = " / ".join((e["content"].get("body") or "").split("\n"))
            # the thread root is the point: it tells you WHERE the answer lives,
            # which is the half you did not have when you were about to re-ask.
            print(f"{when}  {e['sender']}\n  {body[:300]}\n  thread: {root}")
        return

    if a.asked:
        root, humans = thread_humans(room, a.asked, token)
        print(f"thread {root}")
        if not humans:
            # Distinguish "they said nothing here" from a broken read: the whole
            # point is that a silent empty result is what fooled us last time.
            print("NO human message in this thread -- they have not spoken here. "
                  "Not proof they were never asked elsewhere.")
            return
        for e in humans:
            when = datetime.datetime.fromtimestamp(e["origin_server_ts"] / 1000).strftime("%m-%d %H:%M:%S")
            body = " / ".join((e["content"].get("body") or "").split("\n"))
            print(f"{when}  {e['sender']}\n  {body[:400]}\n  event: {e['event_id']}")
        return

    data = api(f"/_matrix/client/v3/rooms/{room}/messages?dir=b&limit={a.limit}", token)

    # thread root -> newest event in it (chunk is newest-first, so first wins)
    threads, roots = {}, {}
    for e in data.get("chunk", []):
        if e.get("type") != "m.room.message":
            continue
        c = e.get("content", {})
        rel = c.get("m.relates_to") or {}
        root = rel.get("event_id") if rel.get("rel_type") == "m.thread" else e["event_id"]
        threads.setdefault(root, e)
        if e["event_id"] == root:
            roots[root] = (c.get("body") or "").split("\n")[0][:55]

    rows = []
    for root, last in threads.items():
        waiting = not is_bot(last.get("sender", ""))
        if waiting or a.all:
            rows.append((last["origin_server_ts"], waiting, root, last["sender"],
                         roots.get(root, "(root outside window)")))
    rows.sort()

    # A silent "nothing waiting" is the exact failure this tool exists to stop.
    # Zero threads means we read the wrong room (or an empty one), not that we
    # are caught up -- say which, never let the two look alike.
    if not threads:
        print(f"NO THREADS AT ALL in {a.room} -- wrong room, or empty. "
              f"This is NOT 'nothing waiting'.", file=sys.stderr)
        sys.exit(3)
    if not rows:
        print(f"nothing waiting on us ({len(threads)} threads seen, all ours) "
              f"in the last {a.limit} events")
        return
    for ts, waiting, root, sender, title in rows:
        when = datetime.datetime.fromtimestamp(ts / 1000).strftime("%m-%d %H:%M")
        mark = "WAITING" if waiting else "  ours "
        print(f"{mark}  {when}  {title}")
        print(f"           last: {sender}")
        print(f"           root: {root}")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # a broken check must be loud, never a silent zero
        print("unanswered.py FAILED: %r" % e, file=sys.stderr)
        sys.exit(2)
