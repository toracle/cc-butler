---
name: butler-verify-delivery
description: "Surfaced ≠ delivered — a decision is not delivered until the human actually receives/acknowledges it; don't trust an agent's rosy 'everything surfaced / clean checkpoint' self-report, verify against the human's real receipt; the butler is the reliable ACTIVE-delivery channel, passive badges/inboxes are not"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 24305c3a-429a-4449-800d-2bf67f660d4b
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

Ties to [[butler-institutionalize-learning]], [[butler-relay-fidelity-provenance]],
[[butler-state-desync]]. A standing butler/steward duty; runtime-neutral home owed.
