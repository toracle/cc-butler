---
name: butler-relay-safe-worker-decisions
description: "AskUserQuestion assumes a human at the terminal; it does not compose with fleet orchestration, where the steward drives workers via send_to_session (text + one Enter at the end). Workers under fleet orchestration should prefer report_to_steward/escalate_to_butler. Covers the MIXED state (human joins a fleet-driven session) and the PROSE-vs-BARE-DIGIT split: prose is discarded and Enter hits the highlighted default. A bare digit aims correctly at usage-limit choosers but NOT at AskUserQuestion menus, where it was falsified 2026-08-12 — it silently selected the default instead. There is no relay path for choosing a non-default AskUserQuestion option; the human must use their own keyboard."
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

**PROSE vs BARE DIGIT — do not treat all sends as unaimable.** (Added
2026-08-04, correcting an over-broad claim the steward made twice the same day.)
These are two different cases and conflating them costs a real capability:
- **PROSE into an open menu is unaimable and destructive.** The text is
  discarded and the Enter lands on whatever is highlighted. You are not choosing
  an option, you are pressing Enter and taking whatever the cursor happens to sit
  on. Never do this.
- **A BARE DIGIT ("2") aims correctly at SOME menus, and NOT at
  `AskUserQuestion` menus.** Verified working by the butler on the **usage-limit
  choosers**, confirmed by reading the screen back — but that verification
  licenses only its own widget class, and it does not extend.

  **FALSIFIED FOR `AskUserQuestion` ON 2026-08-12.** The steward read
  `monocle-16-scheduler`'s open `AskUserQuestion` menu, confirmed it was on
  screen, and sent a bare `3` to pick option 3. The transcript recorded
  **option 1** — the highlighted default. The digit was typed as text and the
  Enter took the cursor's option, exactly as PROSE does. Same conditions this
  note says a digit works under: menu verified open immediately before sending.

  So the operative rule is: **you cannot select a NON-DEFAULT option in an
  `AskUserQuestion` menu by any means available to you.** Sending the digit does
  not fail loudly — it silently selects the default, which is a *plausible*
  answer, so the transcript will show a human-looking choice that nobody made.
  That is worse than prose, whose damage is at least visible as a swallowed
  message. If a non-default option must be chosen, the human uses their own
  keyboard in the Emacs buffer; there is no relay path. Consequence here was
  small (option 1 added a CDK file edit, overridden a minute later), but the
  same mistake on a destructive menu would not be.

So a steward/butler CAN faithfully relay a human's own menu answer when the human
replied in prose to the wrong surface — which happens often, because a human
answers the person who asked, not the widget. On 2026-08-04 정수님 answered the
butler directly ("일요일 삼은 UI가 없는 백앤드 변경 이군요. 네 오케이 그러면은 뭐
스크린샷 필요 없습니다") while `monocle-jarvice-978` held an open menu whose
option 2 was the literal match for "no screenshot needed". Pressing `2` was
**relaying his answer, not deciding for him.**

The distinction that governs it: relaying a human's OWN stated answer into a menu
is faithful transcription; picking an option the human never expressed is
deciding on their behalf. Do the first freely, and only when the mapping is
literal and unambiguous. Never the second — see
[[butler-relayed-authority-cannot-self-certify]] on why inventing the human's
position is the thing to avoid, and prefer surfacing the wedge
([[butler-channel-wedge-fallback-visibility]]) when no answer exists to relay.

**BUT A DIGIT ONLY AIMS AT A MENU THAT IS STILL OPEN — RE-CHECK IMMEDIATELY
BEFORE SENDING.** The same 2026-08-04 relay demonstrated the failure: by the time
the butler's `2` arrived, 정수님 had already answered `monocle-jarvice-978`
directly (picking option 1), so the menu was gone and the digit landed as a
**context-free token in the worker's input**. Harmless only because the worker
refused to interpret it — it reported "got a bare `2` from the butler with no
context I can connect to anything, not acting on it since I can't tell what it
refers to."

That is the right behaviour and it is worth naming as a general rule: **an
unanchored digit is dangerous precisely because it is so easily resolvable into a
plausible action** — "option 2 of something." A worker that helpfully guesses
which menu it belonged to would act on an instruction nobody gave. Same shape as
[[butler-never-reconstruct-a-truncated-instruction]]: treat an ambiguous input as
ambiguous, do not resolve it into the most likely meaning.

So: `read_session_output` immediately before relaying a digit and confirm the menu
is still on screen; a human answering the worker directly can close it between
your read and your send. And if you sent one that may have missed, say so to the
worker rather than leaving a stray token for it to puzzle over.

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

Costs of the mixed state, to be recognised:
1. **While a dialog is open, do not send PROSE and do not `compact_session`** —
   compaction interrupts whatever the session does next. A bare digit relaying
   the human's own answer is the exception (above).
2. **If the human walks away mid-dialog, the session is wedged** — unreachable
   by prose and waiting on a keystroke nobody will press. Recognise it by an
   unanswered menu persisting across several checks; surface it rather than
   absorbing it silently.
3. A worker should open a dialog only for a question the human will plausibly
   answer *in the same sitting*.
4. When a human takes over a session, their instructions SUPERSEDE the steward's
   standing holds for that track — do not countermand them; log the supersession.

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
