---
name: butler-your-dispatches-trigger-automation-that-consumes-the-humans-resources
description: "'An orchestrator's own actions (merge, push, dispatch) wake automation it does not run — CI, runners, builds — and that automation competes with the human for the same finite resource; enumerate what you TRIGGER, not just what you RUN, before attributing load or scheduling work'"
metadata:
  node_type: memory
  type: feedback
---

When you ask "what is consuming this resource?", the honest candidate set is not
"the actors I can see working." It includes **the automation your own actions
wake up** — CI runs your merge triggered, builds your push started, containers a
worker spawned. You do not run them, they do not appear in your session list, and
they are still yours.

The characteristic failure is a feedback loop the orchestrator cannot see from
inside: **you take an action, the action wakes automation, the automation degrades
the human's ability to talk to you.**

**Why:** 2026-08-08, ~02:00-02:40. 정수님's SSH kept stalling 10-30 seconds at a
time. Butler diagnosed a buffer-bloat pattern correctly — gateway RTT went from
0.227ms idle to 226ms average under a 98Mbit inbound burst, 0% packet loss, pure
queueing — and then attributed the burst to *"the 15-session Claude fleet doing
package downloads, docker pulls, git clones."*

The steward refuted it from ownership data: exactly one session was active, the
rest parked, several at zero context. Butler re-measured and confirmed RX was flat
at 0Mbit, named its own error (`a-true-observation-licenses-only-its-own-scope` —
it had observed the burst and the latency, never the *source*), withdrew its CAKE
proposal until the source was known, and set a netwatch: 10-second sampling,
snapshotting connections and processes on any threshold breach.

At 02:34 it caught one. Two inbound bursts of 93-98Mbit, gateway RTT 349ms then
230ms. The source was **three self-hosted GitHub Actions runners on this same
machine**, executing jarvice CI in docker.

Then the part that matters. That CI was running *because butler had merged
PR #1582 forty minutes earlier, at the steward's escalation and 정수님's approval.*
**Our own merge stalled the human's connection to us.** Both roles had spent the
whole investigation reasoning about a two-element candidate set — the fleet, or
정수님 himself — and the answer was a third thing: our own automation, which
neither of us was "using" and both of us had triggered.

Note that the steward's mitigation, adopted an hour earlier, was aimed at the
wrong lever: serialize docker pulls and large clones *inside worker sessions*.
That was a real lever but a minor one. The dominant fleet-attributable load was
CI, and the control for CI is **when you merge and push** — which is entirely the
steward's to schedule, and was not being scheduled at all.

The underlying physical constraint is separate and unfixed: the wired NIC is an
RTL8125 (2.5GbE-class) negotiated at **100Mbit**, 1/25 of its capability. At
gigabit none of this would be perceptible. Cable and switch-port remain 정수님's
to check — a reminder that a correctly-identified proximate cause can still sit on
top of a root cause you cannot reach.

A coda on what the steward then got wrong, because it sharpens the lever. The
steward proposed cutting the three self-hosted runners to one, reasoning that
three concurrent jobs would *multiply* the 98Mbit. Butler refuted it: the link
ceilings at 100Mbit, so concurrency cannot multiply anything — and netwatch's
snapshot showed **one runner already saturating it alone**. Reducing runner count
would not lower the peak, only stretch the same bytes across more separate stalls.
Butler declined to put it to 정수님 at all, on the grounds that an option with
tradeoffs and no upside spends decision budget for nothing — correct.

The consequence is the operative one: **when a single job already saturates, an
orchestrator's scheduling levers cannot reduce the depth of a stall, only its
frequency.** How long each stall lasts is set by job duration, which you do not
control. So batching is not a nicety — pushing several PRs so CI wakes *once*
is strictly better than the same merges spread out, and it is the only lever
that actually moves.

**How to apply:**

1. **Enumerate what you trigger, not just what you run.** Before attributing
   resource consumption to any actor, list the automation your side sets in
   motion: CI on push/merge, scheduled jobs, self-hosted runners, image builds,
   test containers. These are invisible to session listings and to
   `list_claude_sessions` — the tools that make the fleet feel like the whole
   world.
2. **Schedule merges and pushes away from the human's interactive work.** They are
   not free operations; they are the loudest thing an orchestrator does to shared
   infrastructure. Batch them, and when the human is live on a constrained link,
   say so and offer to defer — as butler did: *"2·3번을 실행하시면 CI가 다시 돌아
   네트워크가 또 느려질 수 있습니다."* Telling the human the cost is part of the
   request.
3. **When you are about to blame the other role's domain, ask its owner first.**
   The steward owns the fleet and could falsify "the fleet is doing it" in one
   call; butler could not. Cross-domain attribution is cheap to check and
   expensive to get wrong — it sends the fix to the wrong place and, if presented
   to the human, licenses a remedy aimed at nothing. See
   [[a-true-observation-licenses-only-its-own-scope]].
4. **Do not act on an unsourced cause, even a well-measured one.** Butler had
   excellent measurements and still held the CAKE change — correctly, since the
   proposed remedy would have throttled 정수님's only access path to fix load that
   turned out not to need throttling at all. Measure the *source*, then act.
   See [[premortem]]-style reasoning on asymmetric failure cost: the mitigation's
   downside was losing the human's sole channel.
5. **Watch for the loop specifically.** Ask: *could the thing I just did be causing
   the symptom I am now investigating?* An orchestrator's actions are the most
   likely uninstrumented input to its own environment, and the loop is invisible
   from inside because the action already succeeded and moved into the past.
