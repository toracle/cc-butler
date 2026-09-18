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

*(Results appended below this line only, after this file's initial commit.)*
