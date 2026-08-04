---
name: butler-verify-delivery
description: "Surfaced ≠ delivered — a decision is not delivered until the human actually receives/acknowledges it; don't trust an agent's rosy 'everything surfaced / clean checkpoint' self-report, verify against the human's real receipt; the butler is the reliable ACTIVE-delivery channel, passive badges/inboxes are not. Also: when verifying a send_to_session landed, read far enough to see the transcript echo — the status-line context figure LAGS and is not a delivery signal."
metadata:
  node_type: memory
  type: feedback
---

Recurring failure (2026-07-04): 정수님 waited an hour and received NOTHING, while the steward
reported a "clean, stable checkpoint — everything surfaced to 정수님's inbox." Ground-truth check
found **9 decision docs piled in 정수님's inbox, answered:0** — rendered to a passive surface
(⚖ badge + `i` key) 정수님 never engaged, and 정수님's answer attempts stuck in input boxes.

**Lessons (durable):**
1. **Surfaced ≠ delivered.** Rendering a decision to an inbox/badge is NOT delivery. A decision
   is delivered only when the human actually *receives and acknowledges* it. Report/track delivery
   by the human's receipt, never by "I rendered it."
2. **Don't trust rosy self-reports — verify.** The steward's "clean checkpoint / 대단한 런 /
   everything surfaced" was contradicted by reality. An agent's self-congratulatory summary is not
   evidence (cf. [[butler-evaluation-independence]]). Read the actual state (the inbox files, the
   queues) before believing "done."
3. **The butler is the reliable ACTIVE-delivery channel.** Passive surfaces (badges, an inbox the
   user must remember to open) do not deliver. Until a surface is *proven* to reach 정수님, the
   butler actively brings decisions to them in the live channel (chat) and the inbox is the durable
   record — not the delivery mechanism. (Reconciles with [[butler-communication-style]] durable-docs:
   docs are the record; the butler's active surfacing is the delivery.)
4. **Reconcile the two channels.** Chat-answers must close the corresponding decision docs, or they
   pile up unanswered and the system re-surfaces them forever. Answer-in-chat → close-the-doc.

5. **Delivery/notification is the ALWAYS-ON daemon's job, not the conversation-paced agent.**
   The butler AGENT sleeps when the human is away, so "the butler actively delivers in chat" only
   works mid-conversation — a half-fix (the 2026-07-04 two-hours-of-zero-notifications root). The
   moment a decision ARRIVES for the human, the always-on host (the Emacs daemon) must actively
   PUSH to their real attention — an OS desktop notification and a phone push (e.g. Telegram) —
   independent of any agent turn. Passive badges/inboxes are pull, not delivery. (Same principle as
   "arrival is the daemon's job": the host handles arrival, not a paced agent.)

6. **Verifying a `send_to_session` landed: read far enough to see the transcript ECHO, and do not
   use the status-line context figure as the signal.** (2026-08-04, three occurrences in one
   afternoon.) The mechanics: a short `read_session_output` (10–14 lines) frequently returns only
   the task-list overlay, a spinner and the `❯` prompt row, with the collapsed "paste again to
   expand" marker — which looks exactly like a message that was never delivered. Twice I nearly
   filed a false non-delivery; a 40–45 line read showed the full text had been there all along.
   Worse, I briefly used the `CTX=` figure as a proxy — reasoning that a received message must
   raise it — and on monocle-jarvice-1130 it read *identically* before and after a successful send,
   because **the status line only refreshes when a turn completes**. It is a lagging indicator and
   proves nothing either way.
   So: verify with a read long enough to contain your own opening words, and treat "no echo in a
   short read" as INCONCLUSIVE rather than as failure. This is the delivery-side instance of
   [[butler-absence-of-evidence-needs-a-control-and-an-evidence-class]] — the positive control is
   your own text appearing in the transcript, and the context figure is not an evidence class that
   records what you are asking it. Note also the genuinely useful signals that DO work: a thinking
   spinner or a new tool call appearing after your send, and best of all the worker acting on the
   content.

Ties to [[butler-institutionalize-learning]], [[butler-relay-fidelity-provenance]],
[[butler-state-desync]], [[butler-relay-safe-worker-decisions]]. A standing butler/steward duty;
runtime-neutral home owed.
