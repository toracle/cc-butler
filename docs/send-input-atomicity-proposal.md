# Making type+submit interruption-safe in `cc-butler--send-input`

Status: **proposal, no code written.** For a boss decision before anything is built.
Context: surfaced by PR #17 (2026-07-23). #17 repairs the damage in the compaction
driver only; this is the root the whole race class grows from.

## The defect

`cc-butler-orchestrator.el:257-263`:

```elisp
(with-current-buffer buf
  (claude-code-ide--terminal-send-string body)     ; 1. type
  (when submit
    (sleep-for cc-butler-submit-delay)             ; 2. YIELD  ← the hole
    (claude-code-ide--terminal-send-return)))      ; 3. submit
```

The usual framing — "a notification starts the turn and the Return misses" —
understates it. The precise mechanism is narrower and worse:

**`sleep-for` runs timers.** (Measured in this project on 2026-07-22 while
designing the compaction driver, and the reason that driver has no `sleep-for`
in its waiting path.) Elisp is single-threaded, so two statements with no yield
between them are atomic with respect to every other cc-butler timer. Step 2 is
the only yield point in the sequence — and it is *inside* the sequence.

So during those 100ms any other timer may run and call `cc-butler--send-input`
on the same session: mail delivery, the compaction monitor's steward notify, a
dispatch, the compaction driver itself. Writer A has typed but not submitted;
writer B types and submits; A's Return then lands on whatever state B produced.

Consequences seen tonight: a command left unsubmitted (session stranded on the
cheap model), and stale text prepended to the next dispatch — a failure in one
session becoming a corrupted instruction to an unrelated one later.

**This is not compaction-specific.** Every caller shares it: `send_to_session`,
mail delivery, dispatches, the monitor. Compaction is simply where it was caught,
because that path checks its own work afterwards.

## Scope: this covers one of two distinct races

Everything above is a *writer-vs-writer* race: two cc-butler timers, both
starting from an empty box, interleaving inside a single send. There is a
second, different race this proposal does not touch — *writer-vs-human*: a
person is mid-draft in the input box when a relay/notification write lands
on top of it. That is what happened three times this evening, including
정수님's sentence truncated mid-word (`and, when I tried to launch mobile
app, it`). Approach A makes cc-butler's own type-then-submit atomic with
respect to other cc-butler timers, but it has nothing to say once a human
has already put text in the box: at that point the collision is
character-level, not turn-level, and — as Approach C's own weakness note
below already states — text already merged with another writer's cannot be
told apart from ours after the fact. Today that second race is only
suppressed by discipline (batch non-urgent reports, check the screen
before sending), which lowers its odds without removing it. If A ships, it
closes the machine-vs-machine half only; it should not be read or reported
as "input gets destroyed" being solved. The specific, currently-active
source of this writer-vs-human race is `cc-butler--forward-to-ops`
(`cc-butler-orchestrator.el:975-989`), which calls this same
`cc-butler--send-input` unconditionally with `cc-butler-forward` defaulting
to `'submit` — see `cc-butler-steward-inbox-design.md` for that forwarder's
own diagnosis and proposed fix.

## Approaches

### A. Delete the yield — send the Return in the same write

Append the submit byte to the same `claude-code-ide--terminal-send-string` call
(or issue it immediately with no `sleep-for` between). No yield point, therefore
no interleaving: atomic by construction rather than by coordination.

- **Blast radius:** small and uniform — one function, no API change, no caller
  changes, no new failure modes to reason about.
- **Risk, and it is the whole question:** the delay is deliberate. The docstring
  says *"A short settle delay precedes the Return so it is not dropped before the
  input is processed."* Someone hit a dropped Return and added it. Whether that
  was a genuine TUI requirement or a workaround for something since fixed is
  **unknown and must be measured, not assumed** — and it may differ for the
  bracketed-paste path (which already has a terminator the TUI must consume)
  versus the single-line path.
- **If the delay turns out to be required:** it can move *before* the typing
  rather than between typing and Return. A yield before we have written anything
  is harmless; a yield mid-sequence is the bug.

### B. Per-session send lock

A `dir -> in-progress` table. A send that finds the lock held queues itself and
drains from a timer instead of writing.

- **Blast radius:** large. Sends stop being synchronous, so every caller's error
  handling and return value changes meaning; `with-timeout` interacts with the
  queue; a crash between acquire and release wedges a session until something
  clears it.
- **Merit:** it is the only option that also fixes *concurrent* writers who never
  interleave inside one call — two dispatches racing at the same instant.
- Reasonable as a later layer, poor as the first move.

### C. Verify-and-repair inside the primitive

Generalise #17: after submitting, read the box back; if our text is still sitting
there, re-submit (bounded).

- **Blast radius:** small, and strictly additive — nothing that works today
  changes behaviour.
- **Cost:** every send grows a terminal read, which forces a redraw. On the
  monitor's fleet-wide sweeps that is not free.
- **Weakness:** it repairs rather than prevents, and it cannot repair the worst
  case — text already merged with another writer's is not distinguishable as ours.

### D. One serialized write queue for the whole fleet

All terminal writes become entries drained by a single timer.

- Architecturally the honest answer, and it subsumes A/B/C.
- Largest change by far; turns every send asynchronous. Not tonight's size.

## Recommendation

**A, gated on measuring the delay** — with C as a cheap safety net if wanted.

A is the only option that removes the hole rather than coordinating around it,
and it is a smaller diff than either alternative. The single unknown is whether
`cc-butler-submit-delay` is load-bearing; that is one experiment, not a design
argument. If it is required, moving it before the typing keeps the atomicity and
costs nothing.

B and D should wait until there is evidence that same-instant concurrent writers
are a real problem, as distinct from the mid-sequence yield we know is one.

## Test strategy

The property to pin is *"no yield between typing and submitting"* — testable
without a live terminal, since the yield is what lets another timer run:

1. **Interleaving regression.** Stub the terminal primitives; have the
   send-string stub call `cc-butler--send-input` again for the same session
   (standing in for a timer firing mid-sequence). Assert the writes come out as
   two complete, ordered sequences and never interleaved. This test fails against
   today's code and passes after A.
2. **No-yield structural test.** Assert `cc-butler--send-input` performs no
   `sleep-for`/`sit-for`/`accept-process-output` between the string and the
   Return — stub all three to signal. Cheap, and it stops the delay being
   reintroduced later by someone who does not know why it left.
3. **Delay experiment (manual, before writing any code).** On a throwaway session
   only: submit N times with the delay at 0 and confirm nothing is dropped, on
   both the single-line and bracketed-paste paths. This is the measurement the
   whole recommendation rests on and it should not be skipped.
4. **Bracketed-paste integrity.** Multi-line body still arrives as one paste with
   embedded newlines literal and exactly one submit — the existing behaviour A
   must not disturb.
5. Byte-compile the changed module (PR #17: a stub certified a call signature
   that did not exist; the compiler caught it and the suite did not).

## Explicitly not proposed

Changing what callers pass, changing the return contract, or touching
`claude-code-ide`. The fix should stay inside `cc-butler--send-input`.
