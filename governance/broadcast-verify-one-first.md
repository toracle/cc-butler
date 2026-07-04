---
name: butler-broadcast-verify-one-first
description: "Any fleet-global / broadcast operation (re-arm all, dismiss all, bulk inject) must be verified on ONE session first — confirm it actually does what's intended — before applying to the whole fleet"
metadata:
  node_type: memory
  type: feedback
---

Before running any **broadcast / fleet-global** operation — a bulk re-arm, a
dismiss-all, injecting a command into every worker — **verify it on ONE session
first**, observe that it actually does what you intend, and only then apply it to
the whole fleet.

**Why:** on 2026-07-04 a bulk re-arm typed `/mcp reconnect` into ~25 workers at
once. That command does **not** headlessly reconnect — it opens the interactive
`/mcp` panel and parks the session in nav mode. Applied to all at once, it parked
~15 workers before anyone saw the effect. A single-session dry run would have
shown the panel-parking immediately, at the cost of one worker, not the fleet.

**How to apply:** a bulk action gets a one-session canary. Type it into one
worker, confirm the observable result matches intent (not just "the command was
sent"), THEN fan out. The blast radius of an unverified fleet-wide action is the
whole fleet. Ties to [[butler-verify-delivery]] (sent ≠ delivered/effective) and
[[warmblood-talent-philosophy]] (완결 — verify the outcome, not the gesture).
