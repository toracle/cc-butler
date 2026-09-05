#!/usr/bin/env python3
"""Self-check for the cursor/delivery logic in bridge.py (§5: cursor
advance must be tied to delivery success, not to the fetch call).

stdlib only, no pytest. Run: `python3 test_bridge.py`. Sets the required
env vars to dummy values before import, since module-level `env(...,
required=True)` calls would otherwise abort at import time.
"""
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

os.environ.setdefault("BRIDGE_HOMESERVER", "http://example.invalid:8008")
os.environ.setdefault("BRIDGE_TOKEN", "test-token")
os.environ.setdefault("BRIDGE_ROOM_ID", "!room:example.invalid")
os.environ.setdefault("BRIDGE_SELF_USER_ID", "@butler-test:example.invalid")
os.environ.setdefault("BRIDGE_HUMAN_USER_ID", "@human:example.invalid")

import bridge  # noqa: E402  (env vars above must be set first)


def make_event(event_id, body, sender="@human:example.invalid"):
    return {
        "event_id": event_id,
        "type": "m.room.message",
        "sender": sender,
        "content": {"msgtype": "m.text", "body": body},
    }


class PollOnceMessagesTest(unittest.TestCase):
    def setUp(self):
        self._tmpdir = tempfile.TemporaryDirectory()
        self._orig_state_file = bridge.STATE_FILE
        bridge.STATE_FILE = Path(self._tmpdir.name) / "state.json"
        self._orig_log_file = bridge.LOG_FILE
        bridge.LOG_FILE = Path(self._tmpdir.name) / "bridge.log"

    def tearDown(self):
        bridge.STATE_FILE = self._orig_state_file
        bridge.LOG_FILE = self._orig_log_file
        self._tmpdir.cleanup()

    def test_all_deliveries_succeed_advances_to_newest(self):
        chunk = [make_event("e3", "c"), make_event("e2", "b"), make_event("e1", "a")]
        with mock.patch.object(bridge, "fetch_recent_events", return_value=chunk), \
             mock.patch.object(bridge, "inject_into_session", return_value=True):
            committed = bridge.poll_once_messages(last_seen=None)
        self.assertEqual(committed, "e3")
        self.assertEqual(bridge.load_last_seen(), "e3")

    def test_failed_delivery_does_not_advance_past_it(self):
        # newest-first chunk; e1 is the oldest (already seen), e2 and e3 new.
        chunk = [make_event("e3", "c"), make_event("e2", "b"), make_event("e1", "a")]

        def inject_side_effect(text):
            return "b" not in text  # e2's body "b" fails to deliver

        with mock.patch.object(bridge, "fetch_recent_events", return_value=chunk), \
             mock.patch.object(bridge, "inject_into_session", side_effect=inject_side_effect):
            committed = bridge.poll_once_messages(last_seen="e1")

        # e2 failed -> cursor must stay at e1, e3 must NOT be skipped over
        # even though it comes after e2 in the batch (§3-①'s exact defect).
        self.assertEqual(committed, "e1")
        self.assertEqual(bridge.load_last_seen(), None)  # never written -- unchanged

    def test_retry_after_failure_delivers_the_previously_failed_event(self):
        chunk = [make_event("e3", "c"), make_event("e2", "b"), make_event("e1", "a")]
        # First poll: e2 fails, e3 never attempted, cursor stays at e1.
        with mock.patch.object(bridge, "fetch_recent_events", return_value=chunk), \
             mock.patch.object(bridge, "inject_into_session", return_value=False):
            committed = bridge.poll_once_messages(last_seen="e1")
        self.assertEqual(committed, "e1")

        # Second poll (retry): now everything succeeds.
        delivered = []
        with mock.patch.object(bridge, "fetch_recent_events", return_value=chunk), \
             mock.patch.object(bridge, "inject_into_session",
                                side_effect=lambda text: delivered.append(text) or True):
            committed = bridge.poll_once_messages(last_seen=committed)
        self.assertEqual(committed, "e3")
        self.assertEqual(len(delivered), 2)  # e2 and e3, in that order
        self.assertIn("b", delivered[0])
        self.assertIn("c", delivered[1])


class DeliverEventTest(unittest.TestCase):
    def test_own_message_is_skipped_without_injecting(self):
        ev = make_event("e1", "echo", sender=bridge.SELF_USER_ID)
        with mock.patch.object(bridge, "inject_into_session") as m:
            self.assertTrue(bridge.deliver_event(ev))
            m.assert_not_called()

    def test_non_text_message_is_skipped(self):
        ev = make_event("e1", "ignored")
        ev["content"] = {"msgtype": "m.image"}
        with mock.patch.object(bridge, "inject_into_session") as m:
            self.assertTrue(bridge.deliver_event(ev))
            m.assert_not_called()


if __name__ == "__main__":
    unittest.main()
