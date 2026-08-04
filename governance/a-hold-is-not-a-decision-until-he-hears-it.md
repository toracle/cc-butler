---
name: butler-a-hold-is-not-a-decision-until-he-hears-it
description: "Surface every hold to 정수님 rather than merely holding it — he lifted two in one day and was entitled to; and when he works directly in sessions, an empty inbox means no worker reported, not that nothing happened"
metadata:
  node_type: memory
  type: feedback
---

Two halves of one situation: **the human acts outside your channel.** So your channel is neither the decision path nor the observation path, and treating it as either produces a specific, repeatable error.

## 1. Surface the hold; do not merely hold it

A steward-level hold is an economy-and-quality measure. 정수님 is weighing shipping velocity against it, and that trade is his to make — but he cannot make it if the hold never reaches him.

**Why:** 2026-08-04, he lifted two holds in one afternoon. The #1514 screenshot (held because it was the most expensive item on an exhausted cap) and dealmatch #1118 (held because round 4 turned an ambiguous empty result into `constructor_found: False` — a *confident wrong answer* about a constructor that exists). Both overrides were well-formed: the worker explained the hold and its reasoning first, then flagged it AGAIN at the point of no return, so he decided with the defect in front of him.

But #1118's hold had never been put in front of him by the steward. The worker did that. That is the only reason his decision was informed, and it was luck rather than design.

**The lesson is not "hold less."** The holds were correct. It is that a hold you keep to yourself is a decision you took on his behalf without telling him.

**How to apply:** when you decide to hold something the human might want shipped, route it up the same turn — briefly, with the concrete cost of shipping and the concrete cost of waiting. If he overrides, do not re-litigate; record what became live and re-prioritise accordingly. Note the inversion that follows: a known defect **shipped** is more urgent than the same defect **blocking a merge**, not less — same content, higher priority. Move it out of a review comment on a now-closed PR (one of the least discoverable places a live defect can sit) into a filed issue marked live-on-staging.

## 2. An empty inbox means no worker REPORTED — not that nothing happened

**Why:** the steward believed dealmatch was stood down for the day. It had been pinging "waiting for input", indistinguishable from idle-liveness noise, and `pending_events` was empty on every drain. A merge to devel and a staging promotion had in fact happened. It was discovered only by reading the session's screen.

A worker taking instruction directly from 정수님 generates **no event for the steward at all**. So the steward is structurally blind to any work it did not dispatch. This is the same seam as cc-butler#42 — the return path does not follow the dispatcher — extended: for human-initiated work the return path does not exist.

**How to apply:** when 정수님 is working directly inside sessions, **screens are the ground truth, not queues.** Sweep them rather than trusting a quiet inbox. Say "no worker reported" instead of "nothing happened," and expect to learn of human-initiated work late or not at all. Related: `pending-events-is-a-destructive-read`, `absence-of-evidence-needs-a-control-and-an-evidence-class`, `session-liveness-by-buffer`.
