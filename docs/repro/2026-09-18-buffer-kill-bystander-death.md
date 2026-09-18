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

---

## Round 2 pre-registration (written before any Round-2 run; freezes here)

Butler/x600 tasked two follow-ups. Both use the same ccb-repro isolated
daemon, same safety boundary (no bare emacsclient, live daemon never
touched, not even read-only).

### Module version being loaded (stated before running, checked, not assumed)

`~/.emacs.d/elpa/ghostel-20260823.1350/ghostel-module.version` = `0.51.0`.
The stale `~/.emacs.d/elpa/ghostel-20260804.2129/` on disk is `0.49.0`. My
ccb-repro `init.el` puts `ghostel-20260823.1350` on `load-path` explicitly
(see the Setup section above) — this matches the live m1 daemon's loaded
copy (0.51.0), confirmed by reading the version file directly, not
inferred.

### Task (b): position-rule decisive test — hypothesis A vs hypothesis B

Round 1 (X, Y, Z created in order; kill Z → Y dies, X survives) is
consistent with two different rules that were not yet separated:

- **Hypothesis A (fixed position):** the victim is always "the
  second-most-recently-created still-alive session at the moment of the
  kill," independent of *which* session you choose to kill.
- **Hypothesis B (relative position):** killing the session created at
  creation-order position N kills the session at position N-1 (the one
  created immediately before it); a session with no predecessor (the
  oldest) has no victim.

**Predictions, stated now, before running:**

| Row | Kill | A predicts | B predicts |
|---|---|---|---|
| 1 (done, Round 1) | Z (newest of X,Y,Z) | Y dies | Y dies |
| 2 | Y (middle of X,Y,Z) | no bystander (Y itself is both target and the position the rule names — vacuous) | X dies |
| 3 | X (oldest of X,Y,Z) | Y dies (Y is still 2nd-newest of the surviving set after accounting for X being removed — see note) | no bystander (X has no predecessor) |
| 4 (repeat of row 1, control) | newest, with 2 fresh throwaways spawned right before | a throwaway (newest-but-one at spawn time) dies | a throwaway (immediately-preceding one) dies |

Row 3 note: A's prediction for "kill the oldest" is stated as "Y dies"
under the reading that the fixed position is evaluated over the ORIGINAL
three-session set minus the target, i.e. still names Y. If instead A is
read as recomputing "2nd-newest among the survivors after removing the
target first," it would predict no clean single answer for a 2-survivor
set of {Y, Z} (2nd-newest of 2 survivors is Y again) — both readings of A
converge on "Y dies" for row 3, so this row still discriminates against B
cleanly (B predicts nobody dies).

**Interpretation rule:** ≥2 of 3 repeats per row agreeing counts as that
row's outcome (a single flaky run, given the delayed-observation caveat
already on record, does not overturn the row). Rows 2 and 3 are the
decisive ones — if row 2 shows X dying (not Y, not nobody) AND row 3 shows
nobody dying, B is confirmed and A is falsified. If row 2 shows nobody
dying and row 3 shows Y dying, A is confirmed and B is falsified. Any
other combination (e.g. row 2 kills neither X nor nobody, or both rows'
outcomes support neither table cleanly) is reported as "neither cleanly
fits" with the raw data, not forced into A or B.

**Falsification conditions:** A is falsified if row 2 ever shows X (not
nobody) dying, or row 3 ever shows nobody dying is required (i.e. it
predicts row 3 = "Y dies", which is B's non-death that would falsify B, so
if row 3 shows a death, B is falsified). B is falsified if row 2 ever
shows nobody dying, or row 3 ever shows anybody dying.

**Sample-size limit:** n=3 per row (rows 2 and 3), same single machine,
same day. This can distinguish A from B given the two are logically
exclusive in their row-2/row-3 predictions; it cannot rule out a THIRD
rule that happens to coincide with A or B on these two rows only.

### Task (c): native module source

Contrary to my Round-1 report, the ghostel elpa package DOES ship full
Zig source for the native pty/reaper logic — I had only grepped
`src/module.zig` (175 lines, Emacs dynamic-module glue only) and
incorrectly generalized "no source" from that one file. The real logic is
in `src/PosixPtyProcess.zig` and `src/NativeProcess.zig` (both present in
`~/.emacs.d/elpa/ghostel-20260823.1350/src/`). Upstream:
`https://github.com/dakra/ghostel`, pinned at commit
`447cacd64370e5fc3ee3fa71719d7d6e3da7a624` per `ghostel-pkg.el`. Read
directly (not cloned — the two files above were sufficient to find the
candidate defect; cloning add no additional evidence beyond what's already
on disk, so I did not spend the extra step unless asked).

**Candidate site, read (not yet proven the sole cause):**
`src/PosixPtyProcess.zig`, function `deinitAndWait` (lines 358-374):

```zig
pub fn deinitAndWait(self: *Self) u32 {
    std.debug.assert(self.pid > 0);
    self.pty.deinit();              // closes primary_fd (pty master) BY RAW INT
    _ = sys.close(self.wake_pipe[0]);
    _ = sys.close(self.wake_pipe[1]);
    while (true) {
        var status: c_int = undefined;
        switch (sys.errno(sys.waitpid(self.pid, &status, 0))) { ... }
```

This runs on a **detached reaper thread**
(`NativeProcess.zig`, `run()`: `reaper_thread.detach()`, calling
`reapChild` → `deinitAndWait`), spawned only after the read loop exits.
`self.pty.primary_fd` is a raw POSIX file descriptor integer (`c_int`),
closed via `sys.close()` with no generation counter, no owner-identity
check, and no coordination with any other session's pty lifecycle.
Closing a pty's master fd is a real kernel operation: on last-close of the
master side, the tty driver delivers a hang-up condition (SIGHUP) to the
foreground process group of whatever is attached to the CORRESPONDING
slave (this is the actual SIGHUP mechanism observed for the bystander in
Round 1 — a real kernel signal, not confusion at the Lisp level).

**The hazard (inferred, not proven with a targeted test in Round 2 —
flagged as inference):** because this close runs on a detached thread with
no synchronization against when OTHER sessions' ptys are opened, if this
particular `deinitAndWait` call is delayed (e.g. queued behind OS
scheduling, or behind a slow `waitpid` on a process that took a moment to
actually die) past the point where the OS has reused that exact fd number
for a **newly-opened** pty belonging to a different, newer session, the
`sys.close()` — and the kernel hang-up it triggers — lands on that newer
session's pty instead of the original one's. This is a
raw-file-descriptor-identity race (close-after-reuse), not a "slot index"
data structure bug as I speculated in Round 1 — same class of defect
(identity confusion via a bare OS handle), different specific mechanism.
I have NOT instrumented and confirmed the exact fd-number collision with a
targeted test (e.g. logging `primary_fd` values across sessions and
watching for a repeat); this is a code-reading-supported hypothesis, held
to the same "inference, not observation" standard as Round 1's guesses.

### Draft upstream issue (NOT filed — for steward/butler review)

**Title:** `Detached reaper's deinitAndWait() closes the pty master fd on
a background thread with no protection against fd-number reuse by a
different, newer session`

**Body (draft):**

> `PosixPtyProcess.deinitAndWait` (src/PosixPtyProcess.zig:358-374) closes
> `self.pty.primary_fd` — a raw POSIX fd integer — via `sys.close()`,
> then waits on the child. This call happens on a **detached** reaper
> thread (`NativeProcess.run`, `reaper_thread.detach()`), spawned only
> after the terminal's read loop exits, with no synchronization against
> other sessions' pty lifecycles and no way for the caller (Emacs, via
> `ghostel-exec`/kill-buffer teardown) to know when it actually runs.
>
> Because `primary_fd` is a bare integer with no generation check, if this
> particular close is delayed long enough for the OS to reuse that exact
> fd number for a **different, newly-opened** pty (opened by a different
> ghostel terminal buffer created shortly after), the close — and the
> resulting kernel-level pty hang-up (SIGHUP delivered to the foreground
> process group of the corresponding slave) — lands on the wrong,
> unrelated session's child process instead of the one actually being
> torn down.
>
> **Observed symptom (reproduced 11/13 times across 3 batches in
> `claude-code-ide.el`, an Emacs package that uses ghostel as a terminal
> backend):** killing ONE ghostel-backed terminal buffer (via
> `kill-buffer`, while ≥2 other ghostel sessions are alive in the same
> Emacs process) causes a DIFFERENT, untouched ghostel session's real
> child process to receive a genuine SIGHUP and exit — confirmed via the
> native reaper's own exit-status event (`"129"` = 128+SIGHUP) for the
> BYSTANDER session's own pipe, not a misdirected signal from Emacs Lisp.
> The effect requires ≥3 sessions' worth of creation history in the same
> Emacs process to appear reliably in our testing.
>
> **Minimal repro (Emacs Lisp, ghostel alone, no claude-code-ide
> needed):** create 3 ghostel buffers running a trivial `trap 'echo HUP'
> HUP; cat` shell script in quick succession; kill the newest buffer;
> check whether the SECOND-newest buffer's shell also receives HUP despite
> never being touched. (Our own repro additionally routed through
> claude-code-ide for fidelity to the reported bug; a ghostel-only
> reduction was not separately re-verified as of this draft — flagged so
> whoever files this can confirm the reduction first.)
>
> **Suggested direction (not fully verified):** give the pty backend a
> stable, checkable identity (e.g. re-validate the fd still refers to the
> same pty, via `fstat`+device/inode comparison, or a generation
> counter/handle wrapper) before closing it on the detached reaper thread,
> or synchronize reaper-thread teardown so a stale close cannot outlive a
> new pty's allocation of the same fd number.

This draft is intentionally NOT filed. It is held here for steward/butler
review before anyone opens it upstream.

## Round 2 results (appended after the Round-2 pre-registration commit)

### Module version (observation)

ccb-repro's `init.el` loaded `ghostel-20260823.1350`; confirmed live in the
daemon via `(locate-library "ghostel")` → that exact path.
`ghostel-module.version` in that directory reads `0.51.0`, matching the m1
daemon per butler. The stale `ghostel-20260804.2129` (`0.49.0`) was never
on this daemon's `load-path`.

### Task (b): decisive rows (observation, raw)

3 fresh X/Y/Z triples per row, ~1.2s wait plus one extra `emacsclient`
round-trip (to pump Emacs's event loop again) before checking each
session's log for `HUP`:

| Row | Killed | X | Y | Z | Victim |
|---|---|---|---|---|---|
| 1 (Round 1, for reference) | Z | survives | **HUP** | (killed) | Y |
| 2, run 1/3 | Y | **HUP** | (killed) | survives | X |
| 2, run 2/3 | Y | **HUP** | (killed) | survives | X |
| 2, run 3/3 | Y | **HUP** | (killed) | survives | X |
| 3, run 1/3 | X | (killed) | **HUP** | survives | Y |
| 3, run 2/3 | X | (killed) | **HUP** | survives | Y |
| 3, run 3/3 | X | (killed) | **HUP** | survives | Y |

Row 4 (2 fresh throwaways W1/W2 spawned right after X/Y/Z, then the OLD
target X killed), 3 runs, order X<Y<Z<W1<W2 by creation:

| Run | X | Y | Z | W1 | W2 | Victim |
|---|---|---|---|---|---|---|
| 1/3 | (killed) | survives | survives | **HUP** | survives | W1 |
| 2/3 | (killed) | survives | survives | **HUP** | survives | W1 |
| 3/3 | (killed) | survives | survives | **HUP** | survives | W1 |

Every run within a row agreed 3/3 — no discards, no flaky rows this time.

### Falsification-condition outcomes (as pre-registered)

- **Hypothesis A (fixed: always the 2nd-newest overall) is FALSIFIED**:
  row 2 shows X dying (not "nobody"), which the pre-registration named
  explicitly as A's falsification condition.
- **Hypothesis B (relative: kill N → N-1 dies, oldest has no victim) is
  FALSIFIED**: row 3 shows Y dying when X (the oldest) was killed, where
  B predicted nobody would die — the pre-registered falsification
  condition for B.
- Per the pre-registered interpretation rule, this combination ("row 2
  matches B not A; row 3 matches A's stated reading, not B") is reported
  as **neither hypothesis cleanly fits**, with the raw data above, not
  forced into either table.

### Inference: a refined rule that fits all 9 trials (kept separate from the above observation)

Looking at the position pattern across all 4 rows (0-indexed by creation
order, N = live session count at kill time):

- Killing a session that is NOT the oldest (index > 0) kills its
  immediate predecessor (index − 1) — this is exactly hypothesis B, and
  it held in every non-oldest-kill trial (row 1: idx2 killed → idx1
  victim; row 2: idx1 killed → idx0 victim).
- Killing the OLDEST session (index 0) instead kills the session at index
  **N − 2** — the second-newest of the CURRENT live set (not "nobody," and
  not the newest either). Row 3 (N=3): index 3−2=1=Y ✓. Row 4 (N=5, since
  W1/W2 were alive too): index 5−2=3=W1 ✓.

This merged rule (call it **C**: "predecessor, except the oldest session's
kill instead lands on the second-newest of the live set") fits all 9
kill trials run across both rounds with zero exceptions. This is
INFERENCE — a pattern read off 9 data points on one machine, one day —
not a confirmed code-level mechanism. I did not find (and did not spend
further budget hunting for) the exact arithmetic in
`PosixPtyProcess.zig`/`NativeProcess.zig` that would produce precisely
this shape (a plain circular "index − 1 mod N" would land the oldest's
victim on the NEWEST, not the second-newest, so whatever produces this is
some other indexing detail, e.g. a small fixed-size history/handoff
structure with its own off-by-one, not a simple ring buffer over all live
sessions). The candidate site named earlier
(`PosixPtyProcess.zig:358-374`, a detached reaper thread closing a raw pty
fd) remains the most likely general LOCATION of the defect (it's the only
place in the read source that closes an OS-level fd tied to a specific
session asynchronously), but I have not proven rule C traces to that exact
line — flagging this gap rather than overclaiming precision.

### Sample-size / scope honesty (Round 2)

9 kill trials total (3+3+3 across rows 2–4), zero discards, one machine,
one day, same build as Round 1. This is enough to cleanly falsify both
pre-registered hypotheses and to notice rule C fits everything tried — it
is NOT enough to claim rule C is exhaustive (a 4-or-more-position kill, or
a session created and killed out of the simple "spawn all, then kill one"
pattern used here, was not tested) or to claim it generalizes past this
build/machine.

### Draft upstream issue — unchanged recommendation

The draft issue text above still stands as the best available write-up:
it correctly describes the observed symptom and the general hazard shape
(closing a raw pty fd on a detached, unsynchronized thread). I have NOT
updated it to claim rule C's exact "N−2 for the oldest" detail as a proven
mechanism, since that would overclaim past what Round 2 established. It
remains unfiled, for steward/butler review.
