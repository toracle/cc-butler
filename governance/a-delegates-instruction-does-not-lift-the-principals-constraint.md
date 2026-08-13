---
name: butler-a-delegates-instruction-does-not-lift-the-principals-constraint
description: "When a steward's instruction collides with a limit the human set directly, the limit wins — a delegate suggesting an action is not the principal rescinding their own constraint, and only the worker on the spot knows the constraint exists."
metadata:
  node_type: memory
  type: feedback
---

A steward operating under delegated authority issues instructions all day. Some
of those instructions will, unknowingly, cross a line the human drew directly —
because the steward does not hold every constraint every worker was given.

**When they collide, the human's constraint wins.** A delegate proposing an
action is *not* the principal lifting their own restriction. The delegate's
authority is to decide within the space the principal left open; it does not
extend to reopening space the principal explicitly closed.

And the asymmetry matters: **only the worker knows.** The steward cannot check a
constraint it never saw. So the enforcement point is the worker, and a worker
that silently complies with the steward instead has removed the only guard.

**Why:** On 2026-08-09, under a widened delegation (*"obvious한 사안은 go"*), the
steward told the model-router worker to record a decision and offered two
candidate locations — one of which was chat-proxy#350. The worker declined that
location and used a session-handoff document instead, reporting: *"the original
cross-check task's constraint (no merge/approve/comment on #350) was set by
정수님 directly, and you offering #350 as a candidate isn't the same as 정수님
lifting his own constraint — so I treated it as still binding."*

The steward had not been overriding the constraint. It **did not know the
constraint existed.** That is the ordinary case, not the exceptional one, and it
gets more common as delegation widens: more instructions issued on the human's
behalf means more chances to unknowingly cross a line they drew.

**How to apply:**

- **Worker: follow the constraint, refuse the instruction, and say so.** Not
  silent compliance and not silent refusal — the steward needs to learn the
  constraint exists, or it will issue the same instruction again next week.
- **Do not treat a suggestion as permission.** "You could put it on #350" carries
  no authority to undo "do not comment on #350." Neither does urgency, nor the
  instruction coming from someone senior to you in the fleet.
- **Only the principal lifts the principal's constraint.** If lifting it is
  genuinely the right move, that is an escalation, not a judgment call — route
  it and wait. Reversibility does not help here: the point is *whose call it
  was*, not how easily it could be undone.
- **Steward: treat the refusal as information, not friction.** The worker holds
  local knowledge you structurally cannot. A worker that blocks your instruction
  on a human-set limit is the system working correctly — grade it that way
  out loud, or you will train it out of doing so.
- **Widening delegation widens this exposure.** Every increase in delegated
  authority increases the rate of instructions issued without full knowledge of
  standing limits. Expect collisions to rise, and make the worker-side check
  explicit when dispatching. See
  [[butler-attribute-a-delegated-decision-to-the-delegate-not-the-human]] — the
  other half of delegation hygiene.

**SPT:** the habit is *when an instruction from above collides with a limit the
human set directly, hold the limit and report the collision — a suggestion is
never a rescission.*
