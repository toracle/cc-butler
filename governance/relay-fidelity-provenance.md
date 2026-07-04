---
name: butler-relay-fidelity-provenance
description: "Relays lose fidelity by summarizing the user's words at each hop (butler→steward→worker); carry the user's VERBATIM voice as a referenceable artifact (appendix + resolvable link), not just a digest, so a worker can read the original approval directly"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 24305c3a-429a-4449-800d-2bf67f660d4b
---

The user watched worker sessions and noticed their own words arrive **abbreviated / under-
contextualized** — not distorted, but summarized at each relay hop (butler digests → steward
re-digests → worker gets a summary of a summary). The original context thins out by the time it
reaches the worker.

**The fix (the user's design — document-based cross-reference / hypermedia):** a downward
dispatch carries the *digest* (what to do) PLUS a **resolvable reference** to the artifacts the
user actually saw and approved — the decision document and the user's **verbatim signed
response** (their "real voice") — attached as an **appendix / link**. The worker acts on the
digest and can **follow the reference to read the user's original words directly** when it needs
the full context (progressive disclosure: digest to act, original to verify). Documents
cross-reference each other (hypertext): decision ↔ user's answer ↔ worker dispatch ↔ resulting
work — a linked provenance web.

**Why:** eliminates lossy compression of the master's intent; gives verifiable provenance (a
worker can trace exactly what the user approved, in what words) — strengthens faithful-relay
beyond the `[butler → steward · relaying the human]` tag by making the original *resolvable*, not
just claimed.

**SPT — build on existing primitives, not a new system.** We already have: maildir timestamped
files (audit trail), decision docs with IDs, correlation-ids. Add only: (1) preserve the user's
answer VERBATIM as a durable artifact (not relayed-then-re-summarized), (2) worker dispatch
carries a reference (id/path) + appendix to it, (3) workers can resolve/view that reference.

Ties to [[butler-institutionalize-learning]] (durable, runtime-neutral home — the reference layer
lives in cc-butler/maildir, not Claude Code memory), [[butler-communication-style]] (RFC-form:
carry detail/original, don't compress to fragments), [[butler-state-desync]] (anchor in real
state). A steward duty on every worker dispatch that derives from a user decision.

**From = origin, not the last hop (envelope + bidirectional bus).** The inbox envelope's `From`
must name the ORIGINAL author, never the last relayer: a worker's own message → From=worker;
a 정수님 document → From=정수님. The relay-path travels ALONGSIDE in a separate `Via:` field
(e.g. `Via: steward`) — never clobbering `From`. The inbox is a **bidirectional bus**: decisions
flow DOWN (to 정수님) and worker deliverables flow UP (to 정수님's inbox as first-class items,
From=worker) through the same envelope + document-graph. On a DOWN dispatch that enriches a
정수님-authored decision ("do this, by when"), 정수님's original text travels with it as
`Re`/appendix (the verbatim reference) so the worker can resolve the exact words. Envelope fields:
From (origin) · Via (path) · To · When · Kind · Re — origin + relay-path + reference, both
directions. (See docs/cc-butler-provenance-sdd.md §8.)
