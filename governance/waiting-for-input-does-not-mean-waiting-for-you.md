---
name: butler-waiting-for-input-does-not-mean-waiting-for-you
description: "'Claude is waiting for your input' fires identically for a worker that is genuinely idle and one that is blocked on its OWN background subagent. Treating the label as idleness invites a re-dispatch that collides with in-flight work; the tell is the background-agent row at the bottom of the session screen. Read before re-sending — and never re-send on elapsed time alone.'"
metadata:
  node_type: memory
  type: feedback
---

**The rule.** The fleet notification *"Worker X needs attention: Claude is waiting for your input"* — and the `WAITING` state in `session_status` — do **not** distinguish these two situations:

1. The worker finished, has nothing to do, and is genuinely waiting on the steward.
2. The worker is **mid-task, blocked on a background subagent it dispatched itself**, and needs nothing from anyone.

They render identically. Case 2 is common precisely *because* the fleet instructs every worker to delegate reads, searches, and investigations to its own subagents ([[butler-subagent-first]]) — so **the better a worker follows standing orders, the more often it will look idle.**

**Why this matters more than a wasted glance.** The natural inference from "idle 90 seconds after I dispatched it, and no report" is *my message did not land* — which leads directly to re-sending. Re-sending onto a worker whose subagent is running duplicates the work, and the second dispatch can land mid-flight and contradict the first. **The label invites exactly the wrong action.**

**Why (2026-08-13, steward).** Three times in roughly thirty minutes. `472-image-edit` showed "waiting for your input" three minutes after a dispatch; the steward read it as a message that had not landed and was about to re-send — the screen showed a `general-purpose` agent 1m13s into a read-only status check. `dealmatch` did the same twice, the second time 60 seconds after being told to re-run coverage evidence: it had dispatched the re-run to a subagent and drafted the PR-body fix while waiting, deliberately holding the edit so both could be posted linked. In all three the worker was doing exactly what it had been told to do, and the notification described it as needing attention.

**The tell is mechanical and cheap — but it has more than one form, so look for the class, not one string.** The session's terminal screen shows what it is blocked on at the bottom. Two distinct shapes seen the same night:

*Background subagent* — an agent row plus a `✻ Waiting for 1 background agent to finish` line:
```
  ● main
  ◯ general-purpose  Re-run coverage+revert-verify raw evidence for PR #1149     1m 33s · ↓ 60.7k tokens
```

*Background shell* — **no agent row at all**, only a counter in the spinner and status lines:
```
✻ Cooked for 7m 40s · 1 shell still running
⏵⏵ auto mode on · 1 shell · ← 2 agents
```

⚠️ **The second form is the trap for anyone applying this rule literally.** A worker running a long
command (a full test suite, a coverage sweep, a build) shows *no* agent row — so checking only for the
agent row finds nothing and reproduces the exact wrong conclusion this principle exists to prevent. **Ask
"is it blocked on anything of its own?" and scan for any of: an agent row, `N shell still running`, a live
spinner with an elapsed timer, or a `· N shell ·` counter in the status line.** Any one of them settles it.

**How to apply.**
1. **Never re-send on elapsed time plus silence.** "Idle N minutes after dispatch with no report" is not evidence the message was lost. It is equally consistent with the worker delegating, which is what you asked it to do.
2. **`read_session_output` before any re-send**, and look specifically for the background-agent row and the `Waiting for N background agent` line — not just the last message. This is the same check [[butler-relay-safe-worker-decisions]] requires before free-form text, so in practice it is one habit, not two.
3. **A worker blocked on its own subagent needs nothing. Send nothing.** Anything you send is at best noise and at worst collides with work in flight.
4. **Distinguish this from genuine wedging.** A worker sitting on an interactive prompt with no background agent *does* need you. The background-agent row is what separates them; absence of the row plus a visible menu is the wedge case.
5. **Do not "fix" this by telling workers to delegate less.** The delegation is correct and required. The defect is in the label's resolution, not the worker's behaviour.

**The general shape.** *A status label reports the scheduler's view, not the worker's situation.* "Waiting for input" is true in both cases — the session's main thread genuinely is parked at a prompt — but the operationally decisive fact (is anyone else working on its behalf?) is invisible at that layer. This is [[butler-a-label-is-a-claim-not-the-thing-it-names]] applied to fleet telemetry, and it is the reason [[butler-quiet-is-not-done-audit-parked-workers]] cannot be run from the notification stream alone.

Related: [[butler-session-liveness-by-buffer]] (ground truth is the buffer, not the registry — same disease at the liveness layer), [[butler-after-send-check-recipient-state]], [[butler-verify-delivery]], [[butler-no-overinterpret]].

**SPT:** *before you re-send, look for the agent row — the quiet worker is probably obeying you.*
