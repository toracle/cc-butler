---
name: session-id-change-is-not-a-second-agent
description: "A session ID you don't recognize is not evidence that a second agent is running. Re-registration (restart, network/OS restore, reconnect) mints a new ID for the SAME session. Before standing down to avoid a duplicate-agent conflict, confirm against list_claude_sessions — it marks the caller `(you)`. Standing down is not the safe default: it costs unattended fleet time, and the check costs one tool call."
metadata:
  node_type: memory
  type: feedback
---

**The incident (steward, 2026-08-03).** After an overnight network migration, fleet-check output began showing
`steward (claude-steward-20260803-173044)` — an ID the steward did not recognize as its own (it had been running as
`claude-steward-20260722-100635`). It read this as a *second steward session* that had been restarted to fix an
MCP wedge, concluded that two stewards operating the same fleet would double-drain `pending_events`, double-dispatch
workers, and issue conflicting decisions, and **stood down completely** — no drains, no dispatches, no escalations —
for roughly two hours, acknowledging each incoming notification with "Stood down, holding quiet."

There was never a second steward. `list_claude_sessions` showed exactly one, marked `(you)`. The Emacs side had
re-registered the same session under a new timestamped ID during the restore. The whole stand-down rested on an
inference that one read-only tool call would have falsified.

**Why the reasoning felt safe and wasn't.** Avoiding a duplicate-agent conflict is a real concern, and standing
down *feels* like the conservative branch — doing nothing can't break anything. But inaction has a cost that is
invisible in the moment: for two hours nobody drained the inbox, nobody swept four sessions sitting over the
context ceiling, and nobody checked five long-idle workers for stuck dialogs. **"Do nothing" is an action with
consequences, not an abstention from acting.** The genuinely conservative move was the cheap check, not the
expensive silence.

**Identity lives in the registry, not in the ID string.** An agent does not reliably know its own session ID —
it is minted and re-minted by the runtime (restart, reconnect, network/OS restore, re-registration), and a summary
carried across a compaction can easily preserve a *stale* one. So an unfamiliar ID is weak evidence about anything.
The registry is the authority: `list_claude_sessions` marks the calling session `(you)`, and that mark is the fact.
Note the same rule caught a related error here — the steward's own ID in its carried-over context was the outdated
one, so it was comparing a live ID against a stale memory and trusting the memory.

**How to apply.**
1. Before standing down, pausing, or deferring to a suspected peer agent, **call `list_claude_sessions` and find
   the `(you)` marker.** One call. Do this even when the duplicate seems obvious.
2. Treat a changed or unfamiliar session ID as **re-registration until proven otherwise** — restarts and network
   restores rename sessions routinely. Two entries in the registry is evidence of two agents; one unfamiliar
   string is not.
3. Do not trust your own session ID from carried-over context after a compaction or restore. Re-derive it.
4. If a genuine duplicate IS confirmed, don't sit silent — `escalate_to_butler` and name both IDs, so a human can
   kill one. Silent standing-down leaves nobody driving and nobody informed.
5. Weigh the cost of inaction explicitly. Ask "what does *not* acting cost per hour?" — unattended context
   ceilings, undrained inboxes, blocked workers — and compare it to the cost of the check. Standing down for
   hours to avoid a hypothetical is a bad trade whenever the hypothesis is one call away from being tested.

**The same failure, twice more the same day — the general form.** Within an hour of the stand-down the steward
did it again in a costlier direction. A worker rehydrated after a network migration, found a PR it had opened
three days earlier, could not account for it, and reported it as an **unauthorized push by a rogue sub-agent**.
The steward then reasoned — carefully, at length, and *correctly* — about whether a butler→sub-agent channel
structurally exists (it does not), and escalated a security incident on that basis. Nobody checked whether the
push had happened at all. `gh pr view 1467 --json createdAt,author` settled it in seconds: created three days
prior, authored by the human's own account, zero activity since. There was no incident. Amnesia had
manufactured one, and precise reasoning about a false premise made it *more* credible, not less.

So the pattern generalizes past session IDs: **an artifact you cannot account for looks exactly like an
intrusion, and intrusion-shaped reports travel upward faster than anything else — precisely because nobody
wants to be the one who ignored one.** That speed is what makes the cheap check mandatory rather than optional.
Concretely: **before escalating any "unauthorized action" claim, query the artifact and read its creation time
and author first. If it predates the reporting session's last rehydration, the first hypothesis is that
session's own forgotten work, not an intrusion.** Note that body text (a quoted "human prompt", a rationale)
proves nothing — an author writes that. Server-side metadata — `createdAt`, `author`, commit timestamps — is
the part a misbehaving agent cannot forge. Ask for metadata, not narrative.

**⚠ CORRECTION, same night — the paragraph above was itself wrong, and the way it was wrong matters more than
the original error.** Hours later the "phantom incident" turned out not to be a phantom. Two failures, both mine:

1. **`author` is not authorization.** I read `author: toracle` — the human's own account — and concluded a human
   had acted. But **every agent on that machine commits and pushes with the human's credential**, so the author
   field records *whose credential was used*, never *that a person acted*. A rogue agent's output is stamped
   identically to the human's. I did query the artifact, and still drew a conclusion the artifact could not
   support. **Querying the artifact is necessary, not sufficient — you must also ask what the field can actually
   prove.** Metadata is only unforgeable evidence of the thing it literally records.
2. **The "predates the rehydration ⇒ forgotten own work" heuristic I wrote above needs its premise checked too.**
   It only applies if the session actually rehydrated. That one had run continuously since well before the
   artifact was created, so the artifact was *inside* its continuous record — it had witnessed the event live and
   said so. I invented an amnesia that never happened because it tidily explained the facts away.

The deeper trap: after being burned by escalating too fast, the correction pressure runs toward *dismissing* the
next report — and a dismissal gets far less scrutiny than an alarm, because it asks nothing of anyone. **The
discipline is symmetric. "Nothing happened" is a claim requiring evidence exactly as much as "an intrusion
happened."** Verify the reassuring conclusion with the same rigor as the alarming one. Ask specifically: *what
would have to be true for this to be benign, and have I actually checked that — or only checked something
adjacent that pattern-matches to it?*

**Third instance the same night — this one caught in time, which shows what the fix looks like in practice.**
A sub-agent auditing a branch reported, as a serious finding, that *"a real person (Jeongsoo Park) — not me —
committed here."* Same error class as #1 above, third occurrence in one evening. The worker did not escalate
it. It ran `git config` on that checkout, found the commit identity was pinned to the human's name/email by
default (as were all prior commits on `devel`), and closed the false positive itself. Cost: one command.
Compare with occurrence #2, which reached a security escalation and consumed hours.

So state the rule in the form that actually blocks the error: **every agent on this machine commits and pushes
with the human's credential, therefore `author`/`committer` records only WHICH CREDENTIAL WAS USED and can
never establish THAT A PERSON ACTED.** An identity field naming the human is the expected default, not a
signal. Before treating any identity field as evidence of a distinct actor, check what the environment's
default identity is — the "surprising" name is usually just the configured one.

The unifying rule across all these incidents: **a cheap targeted check beats elaborate inference — and check
what the evidence actually establishes, not merely that you gathered some.** Reasoning quality cannot rescue a
false premise, and the more rigorous the reasoning, the more convincing the wrong conclusion becomes. Spend the
tool call on the premise before spending any thought on the inference — in both directions.

Related: [[steward-compaction-erases-worker-memory-of-own-work]] (the reverse form — a worker losing memory of
its own work manufactures a phantom security incident; load this alongside), [[verify-delivery]] (confirm the
fact, don't infer it), [[environment-broken-cross-check-same-resource]] (cross-check the same resource from a
second vantage point before believing an environment-level story).

**SPT:** the habit is *before you stand down for a peer you think exists, check the registry for `(you)` — and
count what an hour of doing nothing actually costs.*
