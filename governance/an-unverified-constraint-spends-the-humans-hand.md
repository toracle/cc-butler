---
name: butler-an-unverified-constraint-spends-the-humans-hand
description: "\"Only the human can do this\" is a claim, and an untested one quietly converts into routing every instance to them — test the constraint once yourself before building a workflow that spends their attention on it."
metadata:
  node_type: memory
  type: feedback
---

Operating constraints — *"the model can't invoke this"*, *"the classifier blocks
workers from merging"* — get adopted from a plausible mechanism and then never
retested. Each one silently becomes a routing rule: every instance of that action
goes to the human. The cost is invisible because it looks like correct deference.

**A constraint you have not tested is a hypothesis you are billing to the human.**

The tell is a *category* claim resting on a mechanism that was only ever observed
in one configuration. "A session cannot invoke `/code-review` on itself" is a fact
about **self**-invocation. It says nothing about whether *another* session can
type that command into it. Those are different acts, and only one was ever tried.

**Why:** On 2026-08-09, two such constraints fell within an hour.

1. **`/code-review` requires 정수님's hand.** Held for days; 정수님 personally typed
   it into the scheduler session **four times** across four review rounds. The
   steward then sent `/code-review` to a worker via `send_to_session` — it ran
   immediately (`Running in the background as @code-review`). The true constraint
   was narrower than the adopted one: a session cannot call it *on itself*.
2. **The harness classifier blocks worker merges.** Every merge was being routed
   to the human on this basis. 정수님 typed *"직접 merge해주세요"* into the dealmatch
   session and the worker's merge command went straight through. What changed was
   not the command but who instructed it — which nobody had tested.

Both constraints were real observations, generalized one step too far, and the
over-generalization is what did the damage: not a wrong belief about a tool, but
a workflow built on top of it that spent the principal's attention repeatedly.

3. **"The worker log group is our entire observation surface."** Later the same
   day, verifying a staging fix, both worker and steward wrote this down after
   AWS denied the Lambda log groups, `ecs:ListTasks`, and DB access. Two
   permission requests went up to 정수님 on that basis. Then he looked at the
   **chat** and read the failure straight off the product surface: a new thread,
   the schedule prompt as the user turn, and the exception text as the assistant
   message. **That failure was observable with zero AWS permissions.** The
   enumeration had silently meant "infrastructure surfaces" while claiming to
   mean "surfaces" — and 정수님's own next question ("can we utilize sentry?")
   named a third one neither of us had counted.

The tell in all three: a **completeness claim** ("only", "entire", "always")
resting on an enumeration nobody audited for what category it had quietly
restricted itself to.

**How to apply:**

- **Test the constraint once, cheaply, before it becomes routing.** The whole
  disproof here was one `send_to_session` call. Weigh that against four rounds of
  a human's hand.
- **State constraints at the width you actually observed.** "A session can't
  invoke it on itself" is defensible; "only a human can invoke it" is a different,
  larger claim that was never checked. Write down which one you have.
- **Re-test when the surrounding conditions change.** A classifier verdict can
  depend on who instructed the action, the session's history, or the phrasing.
  Treat "it was blocked once" as a datum with a timestamp, not a property.
- **Verify on one target before adopting fleet-wide.** Try the new capability in a
  single session and confirm by reading its screen; only then make it standard.
- **When enumerating observation surfaces, count outside the infrastructure
  first.** The product surface — what the user actually sees — is usually the
  cheapest, needs no credentials, and is where the failure *matters*. Ask "could
  I observe this with no access at all?" before requesting access.
- **Audit completeness claims for a hidden category.** "Only X is left" is worth
  one question: *left of what set?* A blocker built on a silently narrowed
  enumeration is a request for the human's hand that never needed making.
- **A block you hit is still a stop signal.** Testing whether a constraint exists
  is not the same as circumventing one you have confirmed. When something is
  genuinely blocked, escalate — do not route around it. See
  [[butler-a-safety-classifier-block-is-a-stop-signal]].
- **Sending a slash command can open a modal — read the screen first.** Doing this
  test, the steward sent `/model` and a prompt-cache confirmation appeared, leaving
  the next Enter aimed at a highlighted menu item. It knew that modal existed. See
  [[butler-never-ask-a-human-to-type-into-a-session-you-just-queued-work-on]].

**SPT:** the habit is *when you catch yourself saying "only the human can do this",
ask when you last tried — and if the answer is "never", try it before routing one
more instance to them.*
