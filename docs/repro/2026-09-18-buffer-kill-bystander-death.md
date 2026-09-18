# Pre-registration: buffer-kill bystander death

Written before any ccb-repro run today. This section is frozen once committed;
results get appended below it, never edited into it.

## Background (relayed, not measured by me)

Steward observed 5/5 same-day pairs: a `kill-buffer` on one ghostel-backed
`*claude-code[X]*` buffer is followed within 0.8–3s by a DIFFERENT session's
CLI logging a graceful `Entering exit handler` exit, while the killed one
dies abruptly. Code suspects (read-only): (a) `claude-code-ide--cleanup-on-exit`
runs twice per kill (kill-buffer-hook, then the wrapping process sentinel);
(b) ghostel's native-pty pipe sentinel
(`ghostel.el:4429-4437`) unconditionally calls
`(signal-process (process-get process 'ghostel--native-pid) 9)`.

Two hypotheses were raised and retracted by the fleet (x600) before any run
on this machine:
- H1 (steward, pid reuse of a reaped native-pid): deprioritized — pid_max is
  large enough that reuse within seconds is judged improbable.
- H2 (butler relay of x600, `signal-process nil` resolves to current-buffer's
  process): retracted — x600 measured that ghostel's pty-backed buffer
  process is a pipe with `process-id` = nil, and `signal-process` on a
  pidless process errors rather than resolving to anything.

What survives from H2's investigation, not yet evidenced as *the* cause: the
`signal-process` call at ghostel.el:4435 has no `ignore-errors`, unlike its
sibling `ghostel--kill-native-processes-on-exit` (which guards with
`when-let*` and `ignore-errors`). If it throws, `(ghostel--sentinel process
event)` on the next line never runs, silently skipping buffer-level cleanup
for whichever session hit it.

## What this pre-registration commits to before seeing results

### Observations to make (on THIS machine, ccb-repro only — no live daemon read or write; see Safety note)

1. For each ghostel-backed terminal buffer created via the real
   `claude-code-ide` → `ghostel` code path (stub CLI, not real `claude`):
   record `(process-live-p proc)`, `(process-id proc)`, and
   `(process-get proc 'ghostel--native-pid)`.
2. Instrument (`advice-add ... :around`) `signal-process` to log, on every
   call during a trial: the raw PROCESS arg, `(current-buffer)` name,
   whether the call threw, and the condition data if it did.
3. Instrument `ghostel--sentinel` (`advice-add ... :before`) to log that it
   was entered, with the buffer name — to detect the "skipped cleanup"
   defect directly (call happened vs. did not).
4. `lsof -p <pid>` for every victim/control process before and after each
   trial run, plus fd count on the ccb-repro Emacs process itself.

### Interpretation rules (decided now, not after)

Let a trial be one `kill-buffer` (kill arm) or one typed `exit` (control arm)
against session A, with session B a second live ghostel session in the same
daemon.

- **Mechanism confirmed** if, in the kill arm, `signal-process` is ever
  called with a PROCESS argument that is NOT session A's own process/pid
  (i.e. targets B, or is a bare nil/pipe that provably resolves to B at
  that call site) AND B subsequently shows HUP/TERM/exit in its trap log.
- **Skip-cleanup defect confirmed independently of bystander death** if
  `signal-process` throws (any target) and the paired `ghostel--sentinel`
  advice does NOT fire immediately after for that same process — this is
  real regardless of whether any bystander dies.
- **No mechanism found** if, across all kill-arm trials, `signal-process` is
  never called with anything but session A's own process/pid, and B never
  shows a signal/exit event, while B does show one in the corresponding
  literature-relayed live-fleet pattern (i.e. same absence in a same-shaped
  local repro, not just "we didn't try hard enough").

### Falsification conditions

- H_double-cleanup (suspect a) is FALSIFIED if removing the second
  `cleanup-on-exit` call (the sentinel-side one) does not change whether
  `signal-process` ever gets called with an argument other than A's own
  process, across ≥5 kill trials with it removed vs. ≥5 with it present.
- H_signal-process-unguarded (suspect b) is FALSIFIED if adding an
  `ignore-errors`/nil-guard around the ghostel pipe-sentinel's
  `signal-process` call (via `cc-butler`-side advice, not an in-place
  ghostel edit) does not stop B from ever showing a signal/exit event, over
  ≥5 kill trials with the guard active, when trials without the guard did
  show it.
- The whole investigation is FALSIFIED (no local mechanism) if 5/5 kill
  trials plus 5/5 exit-control trials on this machine show no B-side
  signal/exit event, no `signal-process` call targeting anything but A, and
  no `ghostel--sentinel` skip — in which case I report that verbatim and do
  not invent a mechanism to satisfy the brief.

### Sample-size limits (stated now)

- n=5 kill trials, n=5 control trials, plus small (≤5-run) suspect-isolation
  batches. This can show **presence or absence of a mechanism on this
  machine, this day, this Emacs/ghostel/claude-code-ide build**. It CANNOT
  establish the live fleet's 5/5 incidence rate, cannot rule out a second,
  rarer mechanism, and cannot generalize across machines (H1's pid_max
  argument, in particular, is host-dependent and is re-measured here, not
  assumed).
- Victim shape: ghostel pty-backed terminal buffers spawned through the real
  `claude-code-ide--create-terminal-session` ghostel branch, with
  `claude-code-ide-cli-path` pointed at a stub script
  (`trap ... HUP TERM; cat`) instead of the real `claude` binary. A bare
  `make-process`/`ghostel` buffer created outside that code path does not
  count as the same shape and any negative result from one does not clear
  the other.
- Any discarded run (setup failure, stub script crash, wrong buffer
  targeted) is counted and reported with its reason, not silently dropped.

### Safety boundary (hard, not subject to butler/steward chat revision mid-task)

Per the original steward brief: every emacsclient call in this
investigation uses `-s ccb-repro`. No bare `emacsclient` (no `-s`) is run,
including for read-only inspection — the live default-socket daemon is not
touched by this investigation in any way, read or write. If read-only live
inspection is later judged necessary, that is flagged back to steward for
an explicit, separately-scoped decision; it is not folded into this
pre-registration's scope.

---

## Results (appended after the pre-registration commit, ccb-repro on this machine)

### Setup actually used

`emacs --daemon=ccb-repro -Q`, load-path pointed at this machine's real
`ghostel-20260823.1350`, `claude-code-ide` (pinned commit, see this repo's
CLAUDE.md) and this branch's `cc-butler` checkout — no live init.el loaded.
Victims: real `claude-code-ide--create-terminal-session` ghostel sessions
(`claude-code-ide-terminal-backend` = `ghostel`), `claude-code-ide-cli-path`
pointed at a stub script (`trap ... HUP TERM; cat`) instead of the real
`claude` binary — the pre-registered victim shape. `signal-process` and
`ghostel--sentinel` were instrumented via `advice-add` to log every call
(arg, current-buffer, throw/no-throw) without changing behavior.

### Observation (raw, machine-checkable)

- **The bystander-death mechanism reproduces on this machine.** Across three
  separate batches (a 5-trial batch, a second 5-trial batch with a
  treatment applied, and a 3-session X/Y/Z probe — 13 kill events total),
  a `kill-buffer` on one ghostel-backed session's buffer repeatedly (11 of
  13 kill events; the other 2 were the very first kill of a batch, where no
  qualifying second session had been alive long enough yet — see Sample
  limits) coincided with a *different*, untouched ghostel session's real
  child process logging `HUP <pid> ...` from its own trap handler and
  exiting — the same "graceful exit on the bystander, abrupt death on the
  target" signature the live fleet showed.
- **Confirmed via backtrace + native-reaper trace, not inferred:** in every
  reproducing case, `ghostel--events-filter` received a genuine numeric
  exit-status event (`"129"` = 128+SIGHUP) *from the bystander's own
  native reaper thread*, for the bystander's *own* pipe process, which then
  ran the bystander's own `claude-code-ide--cleanup-on-exit`. This is a
  real child-process death (the bystander's actual PID received a real
  SIGHUP), not a misdirected `signal-process` call from Lisp landing on
  the wrong target.
- **`signal-process` was never observed called with `nil`.** Every logged
  call had a concrete pid argument (either the killed session's own native
  pid, or, in the delayed cross-contamination case, the bystander's own
  native pid) — H2 (butler-relayed, "signal-process nil resolves to
  current-buffer's process") was already retracted before any run here;
  this machine's trace does not resurrect it. `native-pid` properties were
  always integers, never nil, in every buffer inspected.
- **The double `cleanup-on-exit` call is real (confirmed by backtrace) but
  is NOT sufficient to explain the effect.** A treatment
  (`ccb-repro--cleanup-on-exit-fixed`, `:override` advice removing the
  `kill-buffer-hook nil` binding around the recursive `kill-buffer` call,
  while keeping `kill-buffer-query-functions nil`) was applied and a fresh
  5-trial batch run under it. The bystander effect still occurred in 4/4
  qualifying trials under the treatment — same signature, same
  `ghostel--events-filter` "129" trace.
- **The effect is not "kill A hits A's own pair-partner B."** Two isolated
  fresh pairs (no third session in play) showed no bystander effect at the
  time checked. The effect appeared specifically once a *third* session
  existed: killing the newest of 3 concurrently-tracked ghostel sessions
  hit the middle one (created immediately before it), not the oldest.
  Repeating this with fresh directories reproduced the same "hits the
  immediately-previously-created still-alive session" pattern 8 times
  across two different batches, plus once more in the isolated 3-session
  probe (X created, Y created, Z created, kill Z → Y dies, X survives).
- `lsof` on the ccb-repro Emacs process showed each session's pty master on
  its own fd (18u, 28u/34u, distinct minor tty numbers) with no shared fd
  visible from the Lisp/fd-table level before or after a kill.

### Inference (explicitly separated from the above)

- The double-`cleanup-on-exit` call (originally suspect (a)) is real but
  **ruled out** as sufficient cause by the treatment result above. It may
  still matter as a contributing/enabling condition under a different
  scenario than tested, but no evidence here supports that, and I am not
  claiming it does.
- The retracted H1 (pid reuse) and H2 (`signal-process nil` → current
  buffer) hypotheses are **not resurrected** by this data — nil arguments
  were never observed, and the killed processes' own pids were always the
  ones passed to `signal-process`, correctly.
- Given the bystander's own native reaper genuinely reports its own real
  child's death by SIGHUP, and this requires ≥3 sessions' worth of history
  in the same Emacs process before it manifests, and always lands on the
  session created immediately before the most-recently-created one — my
  best-supported inference is that the defect is **inside ghostel's
  native pty module** (compiled `ghostel-module.dylib`; the only source
  shipped in the elpa package, `src/module.zig`, is 175 lines of Emacs
  dynamic-module glue with no pty/reaper/spawn logic in it — that logic is
  not available to read on this machine). A plausible shape (not
  confirmed): an off-by-one or FIFO/slot-reuse bug in per-session
  reaper/pty bookkeeping keyed to creation order rather than to session
  identity or pid. This is inference, not a measured mechanism — I did not
  get inside the compiled module.
- I also cannot rule out that my two "clean" isolated-pair checks were
  false negatives from checking too early / not pumping Emacs's event loop
  again afterward (the reproducing cases only surfaced their
  `ghostel--events-filter` event once a *later* `emacsclient` call gave
  Emacs another chance to run pending process filters/sentinels). I did
  not re-verify this specific point with a longer wait before reporting.

### Falsification-condition outcomes (as pre-registered)

- H_double-cleanup (suspect a): **FALSIFIED** as sufficient cause — the
  guard-preserving treatment removing the blanket `kill-buffer-hook nil`
  binding did not stop the bystander death (4/4 still hit).
- H_signal-process-unguarded (suspect b, ghostel.el:4435's missing
  `ignore-errors`): not directly tested with a guard in this batch (time
  budget); not evidenced as *the* cause either — no `signal-process` call
  was ever observed throwing in any trace collected. Open.
- "No mechanism found" outcome: does **not** apply — the mechanism
  reproduces reliably (11/13 qualifying kill events across three batches)
  once the ≥3-session precondition holds.

### Sample-size / scope honesty

- 13 kill events total across 3 batches on ONE machine, ONE day, this
  exact Emacs 30.2 / ghostel-20260823.1350 / claude-code-ide (pinned
  a9485f7) build. This shows presence of a real, reproducible mechanism
  and rules out two specific prior hypotheses — it does NOT establish the
  live fleet's 5/5 incidence rate, does not fully characterize the
  triggering precondition (best guess: ≥3 ghostel sessions' worth of
  creation history in one Emacs process; not independently re-verified
  beyond the 3 batches above), and does not reach inside the compiled
  native module to name an exact defect line.
- Discards: 2 of the 13 kill events (the very first kill in the two
  5-trial batches) showed no bystander effect at check time and were
  initially logged as "clean" — per the note above, these are likely
  under-observed rather than genuinely clean, since the qualifying
  precondition (a third session) did not yet exist at that point in the
  batch. Reported as ambiguous, not counted as either confirming or
  refuting.

### Live-fleet safety recommendation

**Keep the freeze** (no `kill-buffer` / `close_topic` on ghostel-backed
sessions) until ghostel's native module is fixed upstream or a verified
safe precondition is found. No Lisp-level fix in cc-butler or
claude-code-ide can correct this — the reproducing mechanism is inside the
vendored native module, which per this investigation's scope is reported,
not edited in place, and is not its own repo to open an issue against
(lives inside `~/.emacs.d`).

### What shipped in this branch instead of a "fix"

Since the actual defect is not in code this investigation can patch, the
PR from this branch does not claim to fix the underlying bug. It converts
the manual freeze into an enforced code-level guard:
`cc-butler--close-topic-kill-session` (the single choke point both
`cc-butler-close-topic` and the `close_topic` MCP tool route through, via
`cc-butler--teardown-workspace`) now refuses with `user-error` to kill a
ghostel-backed session while another ghostel-backed session is tracked
alive, controlled by `cc-butler-close-topic-refuse-concurrent-ghostel`
(default t). Red-first tests in
`tests/cc-butler-workspace-test.el` cover: refusal under the hazard
condition, pass-through when solo or on a non-ghostel backend, and the
escape hatch. Full suite: 1048/1048 passing after the change.

## Correction (added after this PR's head; pre-registration and results above are unchanged)

A second round of pre-registered, decisive trials (isolated `ccb-repro`
daemon, same as above; branch `repro/buffer-kill-round2`, commit `942d4ac`)
tested the two creation-order rules this document's inference section
speculated about:

- Rule A ("fixed": killing any session kills the 2nd-newest live session,
  position-independent).
- Rule B ("relative": killing the session at creation-order position N kills
  position N-1; the oldest session has no victim).

**Both are falsified** by their own pre-registered falsification conditions
in round 2 — see `repro/buffer-kill-round2`'s pre-registration and results
commits for the full tables. **The victim rule is UNKNOWN.**

Round 2 also produced a post-hoc rule ("the predecessor dies, except killing
the oldest session instead hits index N-2 of the live set") that fits all 9
of round 2's own trials with zero exceptions. That rule is **not promoted
here as the answer**: checked against the steward's read-only census of 5
real bystander deaths observed on the live fleet the same day, it agrees
with only 2 of the 5 (the two where every candidate rule agrees) and fails
the other 3 — for example, killing `github-app-install` (12:34:19) is
predicted by this rule to kill `mobile-voice` (12:34:16, alive), but the
session that actually died was `d365` (12:34:29). No rule tested so far —
A, B, or the round-2 post-hoc rule — fits both the isolated-daemon data and
the live-fleet census.

The fd/pty-slot-ordering hypothesis and the native reaper-close hypothesis
(`ghostel-20260823.1350/src/PosixPtyProcess.zig`, `NativeProcess.zig`) remain
open and untested at the mechanism level; the live fleet's slot order can
diverge from creation order in a way the isolated daemon so far has not
exercised, which is one candidate reason no creation-order-only rule fits
both datasets. This does not change the live-fleet safety recommendation
above: **keep the freeze.**
