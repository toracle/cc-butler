---
name: butler-relay-safe-worker-decisions
description: "AskUserQuestion assumes a human is at the terminal typing directly; it does not compose with fleet orchestration, where the steward drives workers via send_to_session (text + one Enter at the end). Workers under fleet orchestration should prefer report_to_steward/escalate_to_butler over AskUserQuestion for human-decision requests. Also covers the MIXED state: when the human joins a fleet-driven session mid-flight, a dialog is correct for the worker but locks the steward out."
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
- `report_to_steward` with a clear `needs` — when it has a status to share and
  something specific it needs from the human, or
- `escalate_to_butler` — when it needs a decision and nothing else is
  blocking it.

over `AskUserQuestion`. Both are **pull-based**: they queue for the steward
(`pending_events`) or butler (`pending_decisions`) to drain on their own turn,
so there is no live wizard sitting open waiting for a precisely-timed
keystroke that a `send_to_session` dispatch could collide with. A human
working directly in a worker's terminal is unaffected — this preference is
specifically for workers a steward/butler drives.

**THE MIXED STATE — the human joins a fleet-driven session mid-flight.**
(Added 2026-08-04.) The two categories above are not always disjoint, and the
overlap has its own rules. 정수님 dropped directly into `monocle-jarvice-978`
— a worker the steward had been driving all day — asked it questions, and gave
it new work. The worker then opened an `AskUserQuestion` menu. **That was
CORRECT**: a human really was at the keyboard, and the blanket "always prefer
report_to_steward" that the steward had been restating in every dispatch would
have made the right behaviour wrong. State the preference as *conditional on
who is driving*, not as an absolute, or workers will route a live human's
question through a queue that human is not reading.

But the mixed state costs the steward something, and it must be recognised:
1. **While that dialog is open, the steward CANNOT reach the session at all.**
   Any `send_to_session` would land its one Enter on the highlighted option and
   answer on the human's behalf — potentially selecting a choice the human was
   still considering. The correct steward behaviour is total hands-off: no
   dispatches, and **no `compact_session` either**, since compaction interrupts
   whatever the session does next.
2. **If the human walks away mid-dialog, the session is wedged** — unreachable
   by the steward and waiting on a keystroke nobody will press. Recognise this
   by an unanswered menu persisting across several checks.
3. So a worker should open a dialog only for a question the human will plausibly
   answer *in the same sitting*. For anything the human may not return to, the
   pull-based channels are still correct even with a human present.
4. When a human takes over a session, their instructions SUPERSEDE the steward's
   standing holds for that track — do not countermand them. Log the supersession
   rather than re-imposing the hold.

**How to apply.** [as steward, and as butler in single mode] Every dispatch
or check-in to a worker states this preference explicitly — the same
standing, repeated-at-every-touchpoint pattern as [[butler-subagent-first]]'s
delegation duty and [[butler-worker-context-hygiene]]'s context-hygiene duty.
A worker's own `CLAUDE.md` carrying this guidance once is not enough on its
own — see the "guidance alone does not change behavior" caveat in
`subagent-first`; it must be a live, repeated instruction, not a document a
worker reads once and forgets under load. Phrase it conditionally, per the
mixed-state section above.

**Before texting a worker, check first.** Before a `send_to_session` dispatch
carrying free-form text (not a reply to a question the steward itself asked),
`read_session_output` the worker's current screen. A visible interactive
prompt or menu is a strong signal an `AskUserQuestion` wizard (or similar) is
open — treat the pending Enter as live and dangerous, not routine. Read
enough lines to see the menu AND whether a human's own typed rows appear above
it; see [[butler-verify-delivery]] lesson 6 on short reads being inconclusive.

**Known gap.** This principle was written down (2026-07-06) after the
`AskUserQuestion`/relay-safety failure recurred, steward included — a rule
stated once and expected to be remembered is exactly what erodes under load
([[butler-subagent-first]]'s caveat applies here too). The durable fix is
that dispatch/check-in restates it every time, not that it is written once.
