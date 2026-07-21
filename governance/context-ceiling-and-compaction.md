---
name: butler-context-ceiling-and-compaction
description: "Standing operational rule (정수님, 2026-07-21): keep every session's context under a 400k ceiling (500k only as a rare, actively-shrinking tolerance); the steward owns compaction for the whole fleet AND its own context; the model-switch/compact/restore procedure must run as three separate submissions with each step verified; and a read context/status figure is a claim, not an observation — re-read it at the moment of use rather than trusting an earlier read."
metadata:
  node_type: memory
  type: feedback
---

Source: 정수님, 2026-07-21, relayed via the butler in
`docs/steward-standing-criteria.md` §5. That file's own verbatim-Korean block
(at its bottom) covers §1–4 only — there is no separate Korean capture of
this specific rule in the source doc, so the English below is the full
relayed text, not a paraphrase standing in for a lost original. If a fuller
verbatim capture of this rule ever surfaces, it wins over this text.

## Thresholds

Keep a session's context **under 400k** — that is the working ceiling. **500k
is acceptable only when genuinely necessary**, and even then compact as soon
as it is reasonably possible. It is a tolerance for a real case, not a
second budget.

## Ownership

**The steward owns compaction for the whole fleet** — deciding when a worker
compacts and driving it — **and manages its own context size too.** The
steward is not exempt from this rule; it is usually one of the largest
sessions running.

## The compaction procedure (order matters)

1. Switch the session's model to **sonnet** first.
2. Accept the prompt-cache warning if one appears. Abandoning the cache is an
   **unavoidable** cost of this procedure — accept it and proceed, don't stop.
3. Run the compaction.
4. **Restore the session to its original model** — opus or sonnet, whichever
   it was before. Never leave a session silently downgraded.

**Mechanism caveat.** `send_to_session` delivers a multi-line body as a paste
and presses Enter only **once**, at the end. Three slash commands sent as one
multi-line body land as a single prompt and execute nothing. The four-step
sequence above needs **three separate submissions** — elisp is the reliable
way to drive this, not one bundled multi-line send.

**Verify, don't assume, at every step.** Confirm the model actually switched
before compacting, and confirm it was actually restored afterward. A session
silently left on the wrong model is a real, ongoing cost, not a cosmetic
slip — the concrete case that motivated this: `monocle-server-side-orchestration`
was directly confirmed (from its own session listing, not taken on report)
to be running Sonnet-5, when it had been Opus-4.8 earlier the same day. An
unnoticed downgrade like that costs money indefinitely, because nothing
about it announces itself — someone has to specifically look.

Compaction stays subject to [[butler-worker-context-hygiene]]'s own
discipline — act only at a safe (WAITING) point, never mid-flight. A session
whose context IS the evidence for a pending decision is exactly the
"genuinely necessary" 500k case, not a compaction target.

## A read context/status figure is a claim, not an observation

A context-size (or any status) number obtained at one time and then acted on
later is a claim about the past, not a current fact, because the thing it
describes can change in between — most concretely here, the session may
have compacted since. Treat any such figure as needing a **fresh re-read at
the moment it is actually used** for a decision, not whenever it was first
obtained.

**Why this earns its own line, not just a pointer to state-desync:** the
concrete incident that produced this rule was misdiagnosed the wrong way at
first. The butler reported five context figures; two were badly off from
what was expected. The first read of that mismatch was "the relay is
unreliable" — i.e. don't trust what the butler reports. That diagnosis was
**wrong**. The butler's numbers were real, direct reads; they had simply
**aged an hour**, and in that hour the sessions in question had compacted
(desktop-app 499k → 299k, security 359k → 98k). The correct lesson is not
"distrust reports from others" — that would teach people to doubt each other
for no reason, which corrodes coordination instead of fixing anything. The
correct lesson is **"a genuine observation decays — re-check it right before
acting on it,"** regardless of who read it, how it was relayed, or how
confident the original read was.

This is a close relative of [[butler-state-desync]] — same family of
failure (state going stale between being read and being acted on), a
different instance of it: there it's an instruction going stale between
issuance and relay; here it's a status figure aging between read and use.
