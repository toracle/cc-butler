---
name: butler-verify-delivery-at-the-recipient-not-the-return-string
description: "A messaging tool's success confirmation is not evidence of delivery. Confirm the message at the RECIPIENT's inbox, not from the sender's return string — report_to_butler returned success while self-addressing to the steward."
metadata:
  node_type: memory
  type: feedback
---

**What happened (2026-08-04 18:55, steward, post-move rehydration).** The
steward called `report_to_butler` with its full pre-relaunch report. The tool
returned **"Reported to the steward as steward
(claude-steward-20260804-184656)"** — a *success* string. The report then
appeared in the **steward's own** `pending_events`. The butler never received
it. Had the steward trusted the return value, it would have sat waiting on a
GO that the butler had no idea was pending, while ten workers ran unattended.

Detected only because the steward read the confirmation string carefully and
then drained its *own* inbox to check. Re-routed via `escalate_to_butler` plus
a durable file on disk
(`docs/steward-rehydration-report-2026-08-04-1855.md`).

**The principle.** A tool that reports "sent" is reporting that *it ran*, not
that the message ARRIVED SOMEWHERE USEFUL. Those are different claims, and the
gap between them is silent on both ends — the sender believes it reported, the
recipient never knew there was anything to receive. So:

1. **Read the confirmation string, don't just check for absence of error.** The
   recipient name is in it. `report_to_butler` naming the *steward* as
   recipient is the whole bug, visible in the success message.
2. **Verify at the recipient's inbox where you can** — and when you cannot
   read the recipient (see below), fall back to a channel whose delivery you
   can independently confirm, plus a file on disk.
3. **Prefer the pull-based channels** (`escalate_to_butler` →
   `pending_decisions`; `report_to_steward` → `pending_events`). They are
   drained by the recipient, so arrival is observable rather than asserted.

**Compounding failure the same evening:** `read_session_output` on the butler
**timed out twice at 120s**, so the steward could not read the butler's screen
at all. That removed the fallback verification AND — per
[[relay-safe-worker-decisions]] — forbade sending free-form text, since an
unreadable screen means the next Enter must be assumed live. **Two of the three
steward→butler channels were broken simultaneously.** When that happens, the
answer is not to pick the least-bad blind send; it is `escalate_to_butler`
**plus a file on disk**, and to tell the recipient in the escalation which
channels are down so their reply does not go into the same void.

**Why this is its own principle and not just a bug report.** The instrument
was *lying in the success direction*, which is the direction nobody checks.
This is the same family as the sweep's other instrument lessons (a statusline
is not independent of `session_status`; an activity title is not a liveness
signal) and of [[steward-verify-delivery-not-just-send]] — but that note is
about a *worker screen* after `send_to_session`. This one fires on a **tool's
own return value**, which feels far more authoritative and is therefore
trusted more cheaply. Extends [[steward-verify-delivery-not-just-send]] from
screens to tools.

Also a `cc-butler` issue in its own right: a silently self-addressing
`report_to_butler` breaks the one escalation path the steward's own
instructions name first.
