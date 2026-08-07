---
name: butler-a-hold-is-not-a-decision-until-he-hears-it
description: "Surface every hold to 정수님 rather than merely holding it — and when you tell a worker to WAIT for his answer, escalating is now load-bearing: an unrouted hold parks that worker indefinitely on an answer that will never come"
metadata:
  node_type: memory
  type: feedback
---

Two halves of one situation: **the human acts outside your channel.** So your channel is neither the decision path nor the observation path, and treating it as either produces a specific, repeatable error. A third half was added later: when you *instruct a worker to wait* on that decision, forgetting to route it stops being a missed opportunity and becomes an indefinite park.

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

## 3. "Wait for his answer" makes the escalation load-bearing

Telling a worker to **stand by** for a human decision converts your escalation from a courtesy into the only thing that can ever restart it. Skip it and the worker does not fail loudly — it waits, correctly and indefinitely, for an answer nobody asked for.

**Why:** 2026-08-07, `monocle-model-router` honestly flagged two gaps in chat-proxy #350 that needed live execution against deployed endpoints. The steward answered: "those are 정수님's call — do not proceed without authorization, stand by." The instruction was right. **The steward then never escalated them.** They stayed a steward-side note; the dashboard's open-decisions list never carried them. The session stood waiting **two days** for an answer that was never requested — and it was found only because an audit finally read the parked sessions' screens, after the recurring fleet-check warning had been dismissed for two days as "the known parked set." The principle being violated was already in this store, written by the same steward.

Note the failure is *silent by construction*: a correctly-waiting worker is indistinguishable from an idle one. Nothing alarms. The queue looks quiet because the work is blocked, and the block is invisible from the outside — see [[butler-externalizing-is-not-delivering]] and [[butler-verify-delivery-at-the-recipient-not-the-return-string]].

**How to apply:**

- When you tell a worker to wait on a human decision, **escalate in the same turn, before anything else.** Not after the current thread, not "when I next update the dashboard." The instruction to wait and the request for the answer are one action split in two, and the second half is the one that gets dropped.
- Then **verify it landed** in the durable surface (the dashboard's open decisions, the decision queue) — not in your own notes. If you cannot point at where the human will see it, you have not escalated.
- Periodically reconcile the other way: for each parked worker, name the decision it is waiting on and confirm that decision is actually pending with the human. A worker waiting on nothing is the signature of this bug.
- **Receiver side — do not take "it was relayed" on faith.** After this incident, `monocle-model-router` wrote into its own handoff a note telling its future self to check rather than assume the steward had escalated. That is the correct response to an unreliable relay and it costs almost nothing. A worker parked on a human decision may ask, once, whether the escalation actually went up; that question is not insubordination, it is the only cheap check available to it. Compare [[butler-a-channel-that-carries-authority-must-be-verifiable-by-the-receiver]]: the receiver cannot verify authenticity, but it *can* verify that a request exists.
- Treat a repeatedly-ignored automated warning as an unchecked assumption of your own. The fleet check flagged these idle sessions every turn for two days; dismissing it each time was itself the untested claim that hid this.
