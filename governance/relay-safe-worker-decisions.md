---
name: butler-relay-safe-worker-decisions
description: "AskUserQuestion assumes a human is at the terminal typing directly; it does not compose with fleet orchestration, where the steward drives workers via send_to_session (text + one Enter at the end). Workers under fleet orchestration should prefer report_to_butler/escalate_to_butler over AskUserQuestion for human-decision requests."
metadata:
  node_type: memory
  type: feedback
---

**The hazard.** `AskUserQuestion` is designed around a human sitting at the
terminal, reading a menu and pressing a key to pick an option. It does not
compose with fleet orchestration, where the steward reaches a worker through
`send_to_session` — text typed in, then **one** Enter pressed at the end to
submit. If a worker opens a multi-question `AskUserQuestion` wizard right as
the steward's dispatch lands (free-form prose, not a menu pick), that single
Enter does not submit the steward's text — it lands on the wizard's
**highlighted default** and silently consumes it. The steward's message is
swallowed with no error on either side; the steward believes it dispatched
instructions, the worker believes it received an answer to its question, and
neither is true. This is exactly the failure class [[butler-relay-fidelity-provenance]]
and the wider relay-safety concern already warn about — but `AskUserQuestion`
is the recurring, concrete *trigger surface* for it, not a rare edge case.

**The fix — workers under fleet orchestration use text-based decision
requests, not interactive ones.** A worker is "under fleet orchestration"
when it was spawned/dispatched by the steward (or, in single mode, the
butler) rather than being driven directly by a human at the keyboard. Such a
worker should prefer:
- `report_to_butler` with a clear `needs` — when it has a status to share and
  something specific it needs from the human, or
- `escalate_to_butler` — when it needs a decision and nothing else is
  blocking it.

over `AskUserQuestion`. Both are **pull-based**: they queue for the steward
(`pending_events`) or butler (`pending_decisions`) to drain on their own turn,
so there is no live wizard sitting open waiting for a precisely-timed
keystroke that a `send_to_session` dispatch could collide with. A human
working directly in a worker's terminal is unaffected — this preference is
specifically for workers a steward/butler drives.

**How to apply.** [as steward, and as butler in single mode] Every dispatch
or check-in to a worker states this preference explicitly — the same
standing, repeated-at-every-touchpoint pattern as [[butler-subagent-first]]'s
delegation duty and [[butler-worker-context-hygiene]]'s context-hygiene duty.
A worker's own `CLAUDE.md` carrying this guidance once is not enough on its
own — see the "guidance alone does not change behavior" caveat in
`subagent-first`; it must be a live, repeated instruction, not a document a
worker reads once and forgets under load.

**Before texting a worker, check first.** Before a `send_to_session` dispatch
carrying free-form text (not a reply to a question the steward itself asked),
`read_session_output` the worker's current screen. A visible interactive
prompt or menu is a strong signal an `AskUserQuestion` wizard (or similar) is
open — treat the pending Enter as live and dangerous, not routine.

**Known gap.** This principle was written down (2026-07-06) after the
`AskUserQuestion`/relay-safety failure recurred, steward included — a rule
stated once and expected to be remembered is exactly what erodes under load
([[butler-subagent-first]]'s caveat applies here too). The durable fix is
that dispatch/check-in restates it every time, not that it is written once.
