---
name: butler-absence-criteria-pass-a-handled-failure
description: "Criteria written as \"this error must not appear\" only catch unhandled failures — a failure the code caught and recorded passes all of them, so success needs a positive signal, not a set of clean absences."
metadata:
  node_type: memory
  type: feedback
---

A verification checklist built from *absences* — "no `UndefinedTable`", "no `run
failed`", "no `skipping`" — has a blind spot that is invisible while writing it:

**It only detects failures that escaped. A failure the code caught, handled, and
recorded as data passes every absence check.**

The error never reaches the log line you are grepping for, because the program
did its job and turned the crash into a field. Your criteria come back clean and
the thing under test still failed.

**So a success verdict needs at least one *positive* signal** — a line that can
only exist if the thing worked. Absences bound the failure modes you enumerated;
they never add up to success.

**Why:** On 2026-08-09 a worker verified jarvice #1611's fix in staging with six
criteria fixed **before** observing anything: two required-present, four
required-absent. All six passed. **The schedule still failed** — the turn died on
an unrelated `AttributeError`, which `schedule_runner` caught internally and
wrote as `outcome=failed`. A handled failure, invisible to all four absence
checks.

The worker reported this against itself rather than presenting six green checks
as a pass:

> *"기준 4는 미처리 예외를 잡도록 설계했는데, 이 실패는 내부에서 잡아
> `outcome=failed`로 기록했습니다. 처리된 실패는 제 6개 기준을 전부 통과합니다."*

Two things made this recoverable, and both were decisions made in advance:

1. **The criteria were nailed down before the observation.** Fixing them
   afterward to fit what was seen was structurally unavailable — the pass/fail
   line could not drift toward the result.
2. **Two criteria were required-*present*.** The worker had reasoned that if
   nothing ran at all, every absence would be **vacuously true**. That instinct
   is the same one this note generalizes: it caught the empty case, and the
   handled-failure case is its sibling.

The positive signal is what carried the real finding. `run=019fe420-…` proved a
`schedule_run` row was found, and that table exists **only** in the tenant
schema — so the query had resolved into the right schema. Not "no error
appeared" but "a thing appeared that requires correctness to exist."

**The same blind spot has a second face: handled failures are also what error
tracking loses first.** Hours later, the same incident's exception *was* found in
Sentry — but not by the path anyone designed. The worker's `sentry_sdk` hook only
catches exceptions that **escape**, and this one was caught internally at
`schedule_runner.py:841`, so the hook never fired. It was captured only because
`main.py`'s init happens to leave `LoggingIntegration` enabled, turning
`log.exception` into an event.

That is the *exact behaviour* a separate issue (#1615) had catalogued as a
**trap** — one log line double-firing into an alert. The trap was the only
observation channel this path had. So "fixing" it consistently across the worker
would silently delete visibility into every handled failure there, leaving a
system with no DB access, denied Lambda logs, and now a silent tracker.

Both statements must be written down together — *it is a trap* **and** *it is
currently load-bearing*. Recording only one sends the next person confidently the
wrong way, and the dependency has to be filed on **both** issues, since whoever
opens only the remediation issue cannot see what it blinds.

**The remedy has its own blind spot: a positive signal can be a handled failure
too.** Later the same day, the replacement observation ran. The criteria now
included a required-present terminal signal — **`outcome=succeeded`** — and it
appeared. It was reported upward as proof the path completed.

Then the human pasted the actual chat screen. What the user saw was:

> **"응답을 받지 못했습니다. 다시 시도해 주세요."**

An error placeholder. No document, no answer, nothing delivered. **The same run
the backend recorded as `succeeded`.**

Note the symmetry, because it is the whole lesson. In the morning, `outcome=failed`
was the handled-failure record that four absence checks could not see. In the
afternoon, **`outcome=succeeded` was a handled failure wearing the success
field** — and it was the very positive signal adopted to fix the morning's gap.
Same field, opposite direction, same root cause: *the field records what the
executor did with the exception, not what the user received.*

So "name one line that cannot exist unless it worked" is necessary and **not
sufficient**. The line must be one that failure cannot **produce**, not merely one
that failure does not usually produce. A status field written by the component
under test fails that bar — it is the component grading itself.

What made this catchable at all was that a **second, independent surface** existed
(the user-visible chat) and someone looked at it. Every signal in the log came
from one process's own self-report; no amount of care inside that log would have
revealed the divergence.

**How to apply:**

- **Name one line that cannot exist unless it worked.** If every criterion is an
  absence, you have not written a success test. Ask: what does the *success path*
  emit that failure cannot fake?
- **Prefer a signal the component cannot author.** A status field it writes about
  itself is self-assessment. An artifact that only real work produces — a row in a
  schema that only exists when routing resolved, a file on disk, output on a
  surface the component does not control — cannot be faked by a caught exception.
- **Check one surface the system does not own.** The strongest observation of the
  day came from a screenshot of what the user actually saw. When every channel is
  the system reporting on itself, agreement between them is not corroboration.
- **When a success metric and the user's experience disagree, that gap is a defect
  in its own right** — file it separately and immediately. It silently corrupts
  every future observation drawn from those logs, including ones about unrelated
  work.
- **Guard a closed issue against over-citation.** #1611 was correctly closed on
  evidence independent of output quality (tenant on the `acting-as` line,
  `UndefinedTable` at zero, a real-Postgres routing test passing in CI). A comment
  was added recording that `outcome=succeeded` coexisted with a user-visible
  error — otherwise someone later cites the close as proof scheduled turns work
  end-to-end, which this very run disproves.
- **Ask where handled failures go.** Any `try/except` that records an outcome
  converts a crash into a field. Grep the outcome field, not just the traceback.
- **Include required-present criteria to kill vacuous truth.** "Nothing ran" and
  "everything ran cleanly" satisfy an all-absence checklist identically.
- **Fix criteria before observing, and keep them fixed.** The value shows up
  precisely when they *fail you* — a criterion you can still edit is a criterion
  that will quietly widen to admit the result you got.
- **Passing a scoped check is not passing the goal.** Six criteria scoped to
  #1611 passing meant #1611 was fixed — it never meant the schedule succeeded.
  State which question each criterion answers. See
  [[butler-name-the-command-a-check-that-resembles-the-gate-is-not-the-gate]].
- **Before removing a noisy behaviour, ask what is currently reading it.** Noise
  and signal often share a channel. Decide what replaces the observation *first*,
  then silence it — reversed, you discover the loss only after it is gone.
- **File a cross-issue dependency on both issues, not the one you are in.**
  "Turning this off here blinds that over there" is invisible from the
  remediation side unless you write it there too.
- **When a trap turns out to be load-bearing, record both facts.** Half the
  finding sends the next reader confidently in the wrong direction.
- **A defect newly *reachable* is not a defect newly *introduced*.** When fixing
  a blocker exposes code that never ran before, prove it structurally (this path
  died earlier, so this line never executed) rather than by diff alone — diffs
  get argued, unreachability does not.

**SPT:** the habit is *before calling absences a pass, ask what a caught-and-
logged failure would look like in this checklist — and name the one line that
only success can produce, and that the component cannot write about itself.*
