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

---

# Round 3 pre-registration: fd-block reuse + reaper-close trace

Written before any Round 3 run. Frozen once committed; results appended
below it, never edited into it. Supersedes nothing above — Rounds 1 and 2
stand as reported. Isolated `ccb-repro` daemon only; the live daemon is
never touched, not even read-only, per the standing safety boundary.

## Why this round, and why this order

Round 2 falsified both creation-order hypotheses (A, B) and could not fit
a single rule to both the isolated data and the live-fleet census (see the
Correction on branch `repro/buffer-kill-bystander-death`, commit 6166757).
Two live inputs since then narrow the search:

- Relayed measurement (x600, re-verified read-only on the live daemon by
  butler `[확인]`): each ghostel session owns a fixed **fd block** — a
  dup'd pipe pair immediately followed by its ptmx fd (e.g. `16,17 → 18`;
  `27,28 → 29`). The dup comes from Emacs's `open_channel_for_module`
  (`process.c:8604` in Emacs 30 source, confirmed by butler
  `[확인]`), so one fd of the pair is the module's `event_writer`.
  `process.c:8599-8612` also shows `open_channel_for_module` returns
  `dup(open_fd[SUBPROCESS_STDOUT])` — the module's `event_writer` fd is
  its own distinct number, not the same fd Emacs closes on
  `delete-process`. That specific double-close path (Emacs and the module
  closing the *same* fd number) is therefore ruled out; a stale close
  needs a module-side second close on some fd.
- On the live daemon, slot order (fd-block position) is NOT the same as
  creation order (steward's read-only `lsof`/`ps` census, 17:1x:
  `ncloud`, created 16:07, holds `ttys006`, below `warmble-jumble` from
  12:19 on `ttys007`). A **fresh** isolated daemon allocates fds
  monotonically, so creation order and fd-block order coincide there —
  which is a plausible reason Round 1/2's isolated data fit *some*
  creation-order-shaped rule while the live census does not fit any of
  them.

Item (6) (fd-block reuse) therefore supersedes item (2) (plain fd/slot
ordering) by incorporating it as instrumentation, and is combined with
item (5) (native reaper-close trace) into one experiment: the block map is
what item (5)'s trace needs anyway, to resolve a close()'d fd to its
owning session. Item (1) (elisp-layer signal/delete-process/kill-process/
process-send-eof advice) runs only if this experiment is inconclusive —
Round 1 already cleared the elisp layer as *sufficient* cause via the
double-cleanup treatment; re-running a broader elisp trace is only worth
the time if the native trace fails to resolve the mechanism. Item (3) (see
below) is answered now, for free, without a daemon run.

## Item (3), answered now: does the stub harness reach cc-butler's session counter?

Checked by reading the code (`cc-butler-orchestrator.el:54`, `:1008`,
`cc-butler-session.el:304`, `:314`): cc-butler has **no separate
session-liveness counter** of its own. Every site that needs "how many
live sessions" reads `claude-code-ide--processes` directly (e.g.
`(hash-table-count claude-code-ide--processes)`,
`maphash ... claude-code-ide--processes`) — the same shared hash table
`ccb-repro`'s `spawn3.sh` populates via the real
`claude-code-ide--start-session`. There is also no hard-coded
cap-enforcement code in this repo at all; the "10 workers + butler +
steward, max 12" cap named in the docstring rider on
`cc-butler-close-topic-refuse-concurrent-ghostel` is an operational/human
policy, not a counter cc-butler evaluates itself. So: the stub harness
*does* populate the exact structure any cc-butler code would read, and
there is nothing separate to be out of sync with. Judged **unrelated** to
the bystander-death mechanism, as x600 flagged as likely — no further
action on this item.

## Observations to make

For every session, at every spawn and immediately before every kill, on
the ccb-repro Emacs process (call it `$DPID`):

1. Full fd-block map via `lsof -a -p $DPID -d0-1024` (or `lsof -p $DPID`
   filtered to fd numbers), parsed into per-session blocks: pipe-pair fds
   + immediately-following ptmx fd, matched to a session by spawn-order
   correlation (the block that newly appears right after a given
   `claude-code-ide--start-session` call belongs to that session).
2. The `event_writer` fd specifically: whichever of the pipe-pair is not
   the one already logged as the sentinel/filter fd Emacs itself uses for
   the pipe process (best available proxy on this machine, since the
   module does not expose the fd to Lisp directly) — logged at spawn, and
   again at close if the reaper-close trace resolves it.
3. A reaper-close trace: `dtruss`/`dtrace` attached to `$DPID`, filtering
   `close()` syscalls, logging the fd number and the thread. Each closed
   fd is resolved to an owning session by looking it up in the most
   recent block map taken *before* the kill that triggered it (not by
   `F_GETPATH` after the close, which is too late). If `dtrace`/`dtruss`
   cannot attach on this machine (SIP or entitlement failure), that is
   reported as a limitation, not silently substituted with something
   weaker without saying so; the fallback is lsof-only before/after
   diffing (shows which fd disappeared and roughly when, not which thread
   or call closed it).
4. Emacs version actually loaded in ccb-repro (`emacs-version`), checked
   against the live daemon's Emacs 30.2 (per steward). Any difference is
   stated, not silently assumed away.

## Procedure

### Fresh-daemon rows

Start a brand-new `ccb-repro` daemon (fds allocate monotonically from
session creation order). Spawn 3 sessions (X, Y, Z). For each of 3 rows,
n=3 reps each (fresh daemon restarted between reps to keep "fresh"
honest):

- Row F1: kill the newest (Z).
- Row F2: kill an old one, not newest, not before-newest (X, when ≥3 are
  alive; with only X/Y/Z, this is X).
- Row F3: kill the before-newest (Y).

Record the block map immediately before each kill, run the kill, record
victim + post-kill block map + reaper-close trace for that kill.

### Aging procedure (butler refinement, folded in before any row runs)

Between fresh-daemon rows and aged-daemon rows, age a **separate** fresh
daemon so that churn is not confounded with the fresh-daemon measurement
above:

1. Spawn several ghostel sessions, kill some of them (freeing their fd
   blocks), spawn new ones (some reusing freed blocks) — the churn step.
2. Between spawns, interleave **non-ghostel** fd consumers: several
   `make-process` subprocess spawns immediately deleted, a couple of
   `make-network-process` connections opened and closed, and a couple of
   plain pipe processes opened and closed — repeated until `lsof` on
   `$DPID` shows **non-contiguous** ghostel session blocks (gaps between
   them from the churn), not just reused-but-still-contiguous blocks from
   ghostel churn alone.
3. Record that `lsof` block map as the aging evidence, before any of the
   pre-registered kill rows run on this daemon.

Then run the **same three rows** (F1/F2/F3, renamed A1/A2/A3 for the aged
daemon) on this aged daemon, n=3 reps each, with the same before/after
block-map and reaper-close-trace instrumentation.

## Interpretation rules (decided now)

- A row's outcome is the victim that appears in ≥2 of its 3 reps. A row
  with no ≥2/3 agreement is reported as "no stable outcome," not forced
  into one.
- The **fresh-vs-aged comparison** is per matching row (F1 vs A1, F2 vs
  A2, F3 vs A3), comparing (a) which creation-order position dies and (b)
  whether the victim's fd block is the one adjacent to the killed
  session's freed block, when they differ.

## Falsification / decision conditions

- **H_fd-block-reuse (item 6)**: FALSIFIED (block reuse is not the
  variable) if all three rows' outcomes are identical between fresh and
  aged daemons, by both creation-order position and fd-adjacency. It is
  SUPPORTED (implicated as at least a contributing variable) if any row's
  outcome changes between fresh and aged in a way creation-order alone
  does not predict but fd-adjacency does.
- **H_reaper-cross-session-close (item 5)**: CONFIRMED as the mechanism if
  any captured reaper-thread `close()` resolves, via the pre-kill block
  map, to a fd inside a session's block OTHER than the one being killed.
  FALSIFIED as the mechanism (for the captured trace) if every reaper
  close in every captured kill resolves to the killed session's own
  block — in which case the next suspect is an Emacs-side
  `delete-process` on a dup'd module fd, and item (1)'s elisp-layer trace
  runs next.
- **INCONCLUSIVE**, reported as such and not forced into either verdict
  above, if `dtrace`/`dtruss` cannot attach to `$DPID` on this machine at
  all — in that case only the fd-block reuse comparison (not the
  reaper-close smoking-gun test) is evaluable.

## Sample-size limits (stated now)

n=3 reps per row, 3 rows, 2 daemon states (fresh, aged) = 18 kill events
targeted. One machine, one day, same Emacs/ghostel/claude-code-ide build
as Rounds 1-2 (build match checked and stated per observation (4) above).
This can show whether fd-block reuse changes the outcome ON THIS MACHINE
and whether the reaper closes a fd outside its own session's block IN THE
CAPTURED TRACES — it cannot prove the aged daemon reproduces the live
fleet's actual fd-fragmentation shape exactly, only that it is
non-contiguous by the same coarse measure the live census used. Discards
(setup failure, dtrace non-attach, ambiguous block-map read) are counted
and reported with reasons, not silently dropped.

---

## Round 3 results

### Setup actually used

Isolated `ccb-repro` (fresh) / `ccb-r3-aged` (aged) daemons, `emacs
--daemon=<sock> -Q --load init.el`, no live init.el. `emacs-version`
reported `GNU Emacs 30.2 ... of 2026-06-10` — matches the live daemon's
30.2 (per steward). `claude-code-ide-cli-path` was pointed at
`stub-claude.sh` explicitly in `init.el` this round (Round 1/2 apparently
set this ad hoc in a since-lost interactive session; without it, a fresh
daemon's default `claude-code-ide-cli-path` is `"claude"` and would have
launched the REAL CLI — caught before any kill ran, by noticing the stub
logs stayed empty on the first attempt; no real `claude` process was
launched by this round's harness). Victim detection used the same method
Round 1/2's saved logs show they used: polling `(buffer-list)` on the
daemon for a bystander's `*claude-code[label]*` buffer disappearing, not
the stub's own signal-trap log (see Methodological note below for why).

### dtrace/dtruss: cannot attach on this machine — CONFIRMED, as pre-registered

`csrutil status` → System Integrity Protection is **enabled**, and this
account has no passwordless `sudo`. `dtruss -p $$` (self-test, no target
daemon needed) fails immediately: `dtrace: failed to initialize dtrace:
DTrace requires additional privileges`. Per the pre-registration's own
fallback, this is **not** forced further — the reaper-close smoking-gun
test (item 5) is **INCONCLUSIVE**, and only the lsof before/after
block-map comparison (item 6) was run.

### Methodological note: the stub's own HUP-trap log is NOT a reliable check

Initial attempts checked the stub script's own `HUP`/`EXIT-TRAP` log lines
after a kill. Two problems, found and fixed before any pre-registered row
ran for real:

1. **Killing the daemon itself (`kill-emacs`) sends a real SIGHUP to every
   still-alive stub process at once** — confirmed directly: two idle
   sessions with no kill at all both logged `HUP ... EXIT-TRAP` the moment
   `emacsclient --eval '(kill-emacs)'` ran. Any check that reads the log
   *after* the daemon-stop step (even by a separate later shell command)
   will see every surviving session as a false "victim." All rows below
   read the logs strictly before calling `stop_daemon`, and the driver's
   `wait_and_report` timing was independently verified via a **15-second,
   no-kill idle control** (3 sessions, no kill, checked at t=+15s): zero
   spontaneous `HUP` lines. So an observed HUP is not spontaneous
   background noise on this build.
2. **The killed session's own process shows `killed_own_hup=0` in every
   single trial (18/18)** — it never logs `HUP` or `EXIT-TRAP` at all.
   This is consistent with, not contrary to, the background finding that
   ghostel's pipe-sentinel path (`ghostel.el:4435`) sends `signal-process
   ... 9` (SIGKILL, untrappable) directly to the killed session's own
   native pid — so the killed target's own stub never runs its trap
   handler. The bystander death, by contrast, IS observable via the trap
   log when it fires — it's specifically that its *timing* relative to a
   fixed-length wait was unreliable standalone, which is why buffer-list
   polling (matching Round 1/2's own saved logs) was used as the primary
   signal instead. Every trial that showed a `buffer-list` victim also
   showed that victim's own stub log gain a new `HUP` line, corroborating
   the two signals agree when both are checked.

### Fresh-daemon rows: raw observation

| Row | Killed (creation position) | n | Victim (all 3 reps) |
|---|---|---|---|
| F1 | Z (newest, 3rd) | 3 | Y (100%, 3/3) |
| F2 | X (oldest, 1st) | 3 | Y (100%, 3/3) |
| F3 | Y (before-newest, 2nd) | 3 | X (100%, 3/3) |

9/9 kill events, zero discards, `polls=1` on every trial (the bystander's
buffer was already gone by the very first 1-second poll after the kill —
tighter than Round 1's "0.8-3s" estimate, most likely because each poll's
`emacsclient --eval` round-trip is itself what gives Emacs's event loop
the chance to run the deferred sentinel, consistent with Round 1's
"under-observed... only surfaced once a later emacsclient call gave Emacs
another chance" note).

These three outcomes exactly match Round 2's own falsifying data (kill Y
→ X died; kill X → Y died) and Round 2's post-hoc "rule C" prediction for
all three positions (predecessor dies; oldest's kill hits the
second-newest instead) — 9/9 agreement, no exceptions, on a freshly
re-run, independently-driven harness.

### Aging procedure: raw observation

On a separate daemon (`ccb-r3-aged`), 5 throwaway ghostel sessions were
spawned (confirmed via block map: 5 distinct `pipe,pipe,ptmx` blocks,
fds 16-18 through 52-54), then throwaway #2 and #4 were killed and 5 more
rounds of non-ghostel churn (`make-process`, `make-network-process`,
`make-pipe-process`, each opened and immediately deleted) were run.
Result: **2 non-contiguous surviving blocks**, `16,17,18` and `52,53,54`,
with a measured **33-fd gap** between them (throwaway #3 also disappeared
on its own — not explicitly killed — most likely the same "quick
EOF/respawn" churn noted in Round 1/2 hitting an early-created session;
counted as an uncontrolled loss, not a discard, since it only strengthens
the non-contiguity already achieved). This satisfies the pre-registered
aging requirement (non-contiguous ghostel blocks, evidenced by the lsof
map before any A-row ran).

### Aged-daemon rows (A1/A2/A3): raw observation

| Row | Killed (creation position) | n | Victim (all 3 reps) |
|---|---|---|---|
| A1 | Z (newest) | 3 | Y (100%, 3/3) |
| A2 | X (oldest) | 3 | Y (100%, 3/3) |
| A3 | Y (before-newest) | 3 | X (100%, 3/3) |

9/9 kill events, zero discards. **Identical to the fresh-daemon rows in
every row**, both which position dies and (checked directly against the
recorded before/after block maps) in fd-adjacency: in every aged-daemon
rep, the test triad's own three blocks landed contiguously and in
creation order when they filled the gap left by the aged base (e.g. A1
rep 1's before-map was `16,17,18(throwaway-1) 25,26,27(X) 34,35,36(Y)
43,44,45(Z) 52,53,54(throwaway-5)` — X, Y, Z's own blocks are still
fd-adjacent in creation order relative to each other, even though the
*overall* daemon fd space around them is fragmented).

### Inference (explicitly separated from the above)

- **H_fd-block-reuse (item 6): FALSIFIED**, per the pre-registered
  condition ("all three rows' outcomes are identical between fresh and
  aged daemons, by both creation-order position and fd-adjacency") — the
  outcomes are identical, 9/9 aged = 9/9 fresh, row for row.
- **Important limitation on that falsification, stated plainly rather
  than overclaimed**: this round's aging fragmented the *overall* daemon
  fd space (proven: the 33-fd gap), but did **not** achieve a case where
  the specific X/Y/Z triad under test had fd-adjacency ordering different
  from their own creation order — they filled the gap sequentially, in
  the same relative order they were created in, so fd-adjacency and
  creation-order-adjacency never actually came apart *for the tested
  triad itself* in this round. The falsification is real for what was
  tested (fragmenting the surrounding fd space does not change the
  outcome), but a stronger test — deliberately reusing an EARLIER-freed
  slot for a LATER-created session, so a later session's block sits
  *before* an earlier session's block in fd order — was not achieved and
  remains open. Until that specific configuration is tested, "fd-block
  reuse is ruled out" should be read as "ruled out for ambient
  fragmentation, not yet tested for slot-order/creation-order inversion."
- **H_reaper-cross-session-close (item 5): INCONCLUSIVE**, exactly as the
  pre-registration's own fallback condition anticipated — `dtrace`/
  `dtruss` cannot attach on this machine (SIP enabled, no passwordless
  sudo), confirmed directly rather than assumed. The lsof-only before/
  after block-map fallback was run instead: it shows WHICH block
  disappears (always the victim session's own block, cleanly, in all 18
  trials) but — as the pre-registration itself noted this fallback
  cannot do — does not show which thread or native call closed it, so it
  cannot itself confirm or rule out a cross-session reaper close. Per the
  pre-registered falsification/next-step rule, since the reaper trace
  itself could not be captured at all (not "captured and clean"), item
  (1)'s elisp-layer advice trace is the next honest step, not yet run
  this round for time-budget reasons — flagged as pending, not silently
  dropped.
- Rule C (Round 2's post-hoc rule: predecessor dies, oldest's kill hits
  the second-newest) fit all 18 of this round's trials with zero
  exceptions, on both fresh and aged daemons. This is now 27/27 across
  Round 2 + Round 3 combined on isolated daemons. It is still **not**
  promoted as the general answer — the Correction on branch
  `repro/buffer-kill-bystander-death` (commit 6166757) already shows it
  fits only 2 of 5 real live-fleet deaths — and this round adds no new
  live-fleet data, so that gap is unchanged. What Round 3 narrows is
  specifically the fd-reuse explanation for *why* the isolated data and
  the live census disagree: ambient fd fragmentation alone does not
  explain it (H_fd-block-reuse falsified, with the stated limitation
  above); a live-daemon-realistic slot-order inversion, or the native
  reaper-close mechanism itself (still untested directly), remain the
  live candidates.

### Sample-size / scope honesty (Round 3)

18 kill events (9 fresh + 9 aged), zero discards (one uncontrolled
throwaway loss during aging, noted above, which helped rather than hurt
the aging goal). One machine, one day, same build as Rounds 1-2, Emacs
version cross-checked against the live daemon's 30.2. This shows the
mechanism is insensitive to ambient fd fragmentation on THIS machine and
that `dtrace` is unavailable for a direct native trace here — it does
NOT show the mechanism is insensitive to a genuine creation-order/fd-slot
inversion (not achieved), does not reach inside the native module, and
does not add to or subtract from the live-fleet census comparison.

---

# Round 4 pre-registration: elisp trace, native build, slot inversion, victim shape

Written before any Round 4 run. Frozen once committed; results appended
below it, never edited into it. One round, per steward's instruction —
items (1)-(4) below, then report. Isolated daemon only; the live daemon
(now running merged commit `238a08cb`, not yet reloaded into the live
runtime) is never touched, not even read-only.

## Item 1: elisp-layer advice trace

Advise (`:around` or `:before`, log-only, no behavior change)
`signal-process`, `delete-process`, `kill-process`, `process-send-eof`,
and every signal/close call site in `ghostel.el` that Rounds 1-3 already
identified (`ghostel--sentinel`, the pipe-sentinel's `signal-process`
call, `ghostel--kill-native-processes-on-exit`) to log: the target
process object, its pid (if any) and `process-get ... 'ghostel--native-pid`,
`current-buffer`, and the backtrace head (`backtrace-frames` truncated to
~10 frames), on every call during a kill trial. Run this on top of the
standard 3-session (X, Y, Z) fresh-daemon setup used in Rounds 1-3, one
kill of each creation-order position (kill Z, kill Y, kill X), n=3 each —
the same F1/F2/F3 shape as Round 3, so this round's elisp trace is
directly comparable to Round 3's lsof-only data on identical rows.

**Prediction**: every logged call's target resolves to the KILLED
session's own process/pid — none will resolve to the eventual bystander.
This is the same finding Rounds 1 and 3 already produced from a narrower
instrumentation (`signal-process`-only, and lsof-block-only,
respectively); this round's wider net (more call sites, full backtraces)
is the decisive check for whether that finding survives more scrutiny.

**Falsification**: if ANY signal/delete/kill/EOF call, on ANY of the 9
kill trials, is observed with a target that resolves to the eventual
bystander (not the killed session), this FALSIFIES "the wrong target is
never picked at the elisp layer" and reopens the elisp layer as a locus,
contradicting Rounds 1 and 3's inference. If, as predicted, no such call
is ever observed, elisp-layer targeting is CONFIRMED correct across a
wider instrumentation net, strengthening (not merely repeating) the
existing native-module inference.

## Item 2: native close() trace via a from-scratch instrumented build

`ghostel-20260823.1350`'s `build.zig.zon` requires **exactly Zig 0.16.0**
(enforced by a `comptime` check in `build.zig`); Homebrew's current `zig`
formula is stable at **0.16.0**, bottled, no-sudo, user-prefix
(`/opt/homebrew`) — this is judged to satisfy "installable user-local, no
sudo, no system change" and will be installed via `brew install zig` if
not already present, without touching anything outside the Homebrew
prefix. The source under `~/.emacs.d/elpa/ghostel-20260823.1350/src/`
will be COPIED (not built in place) to a scratchpad build directory; the
live elpa directory and the live-loaded `ghostel-module.dylib` are never
touched, written to, or rebuilt in place.

Planned instrumentation (added to the copy only): a log line in
`PosixPtyProcess.zig`'s `deinitAndWait` (around the `primary_fd` close at
the reported `:358-374` range) and in `NativeProcess.zig`'s reaper path
(`retireBackend`/`reapChild`/`finishEventChannel`), each printing the fd
number being closed, the owning session's identifying info available at
that point (native pid, or whatever handle the struct carries), and
`std.Thread.getCurrentId()`. Output goes to a stderr/file log distinguishable
from Emacs's own `*Messages*`.

If the build succeeds, the resulting `.dylib` is loaded ONLY by
overriding the isolated daemon's own `load-path` / package directory to
point at the scratchpad build output — never by editing
`~/.emacs.d/elpa/ghostel-20260823.1350` in place and never by changing the
live daemon's `load-path`. The same F1/F2/F3 kill rows (n=3 each) are run
against it.

If the build does NOT succeed (missing toolchain component, network
fetch of the vendored `ghostty` dependency fails, incompatible local
environment, or any other blocker within a reasonable time-box), this is
reported as "no native build achievable" with the specific blocker named
— per steward's instruction, this is not chased with workarounds beyond
one reasonably direct attempt, and item 2 is marked SKIPPED rather than
forced.

**Prediction (if the build succeeds and loads)**: at least one captured
`close()`/`deinitAndWait` call, across the 9 kill trials, targets an fd
that (per that trial's own recorded fd-block map) belongs to the
bystander session's block, not the killed session's own block — this
would be the direct "smoking gun" Round 3 could not capture without
`dtrace`. Secondary, weaker prediction if that specific smoking gun is
NOT observed: the timing/thread-id data may still show the reaper thread
for the KILLED session doing work that overlaps with the bystander's
death window, which would be suggestive but not conclusive on its own.

**Falsification**: the cross-session-close hypothesis (item 5, carried
over from Round 3) is FALSIFIED for this build if every captured
close()/deinitAndWait call across all 9 trials resolves only to the
killed session's own fd block — in which case the mechanism is NOT a
wrong-fd close by the module's own reaper, and the next candidate becomes
a process-group-level signal delivery effect (e.g. a pty group/session
leadership relationship causing the kernel itself to deliver SIGHUP
somewhere unexpected) rather than an application-level bug, which this
investigation does not currently have instrumentation to test and would
need to be reported as a new open question rather than invented evidence.

## Item 3: deliberate slot-order inversion

Setup: spawn A, B, C (creation order, monotonic fds — verified via lsof).
Kill A (the oldest). Spawn D. Verify via `lsof`, BEFORE any further kill,
whether D's fd block is numerically LOWER than B's and C's (i.e., D
reused A's freed block) — if the daemon/OS/module does not reuse the
freed slot this way (e.g., fds keep allocating monotonically upward
regardless of frees), this is reported as "inversion not achieved" and
**no row below is counted**, per steward's instruction.

If the inversion IS achieved (live set by creation order: B, C, D; by fd
order: D, B, C):

- **Row 3a — kill B** (creation-order-oldest of the live B/C/D set).
  - Prediction under Round 2/3's creation-order "rule C": the oldest-kill
    special case fires (hits index N-2 of the live-by-creation-order
    set = **C**).
  - Prediction under an fd-adjacency hypothesis (victim = the session
    whose fd block sits immediately below the killed session's, mirroring
    how "predecessor" and "fd-adjacent-below" were indistinguishable in
    every prior round's always-monotonic setup): **D** dies (D's reused,
    low block sits below B's).
  - These two predictions differ — that is what makes this row decisive.
    Falsification: rule C (creation-order) is weakened if D dies instead
    of C; the fd-adjacency hypothesis is falsified if C dies instead of
    D; if neither B's nor D's death-shape data is clean 2/3+ agreement
    for one specific victim, report "no stable outcome," not a forced
    pick.
- **Row 3b — kill D** (creation-order-newest, but fd-order-lowest/edge).
  - Prediction under creation-order rule C (ordinary newest-kill case,
    not the oldest special case): predecessor by creation order dies =
    **C**.
  - Prediction under a strict fd-adjacency hypothesis: D has no fd block
    below it (it is the fd-order minimum) — analogous to the original
    "oldest has no predecessor" edge case, so either NO bystander dies,
    or an anomalous target is hit.
  - Falsification: if C dies cleanly (2/3+), this favors creation-order
    over literal fd position (since D, by fd, has no valid fd-predecessor
    yet a bystander still dies exactly where creation-order predicts) —
    a clean falsification of "the mechanism is keyed to literal fd
    number" as opposed to some other per-session identifier that happens
    to correlate with fd number only when allocation is monotonic. If no
    one dies, or something other than C dies, that instead favors the
    fd-position hypothesis and is reported as such.

n=3 reps per row (3a, 3b), plus the setup verification itself reported
with its own lsof evidence either way.

## Item 4: victim-shape row (fat stubs)

Replace the thin `trap ...; cat` stub with a "fat" stub that, at startup:
spawns 2-3 long-lived child processes (e.g. `sleep infinity &` a few
times), one of which itself spawns a grandchild, and opens 1-2 extra
pipes/ptys of its own (e.g. via `script`/`pty` helper or a background
`cat` on a fifo) — approximating a real `claude` CLI's process tree and
fd footprint more closely than the current single-process stub. Spawn
three such fat sessions (P, Q, R, standard fresh monotonic daemon, no
inversion needed for this item). Run the same three rows as Round 3's
F1/F2/F3 (kill newest, kill oldest, kill before-newest), n=3 each.

**Prediction**: rule C continues to hold unchanged (predecessor dies;
oldest's kill hits the second-newest) — the working assumption is that
ghostel tracks exactly one pty/reaper pair per ghostel session regardless
of how many OTHER, ghostel-unaware child processes that session's own
shell happens to spawn, so extra fds/processes hanging off a session
should not change which session's ghostel-native bookkeeping slot is
adjacent to which.

**Falsification**: if the victim differs from rule C's prediction for fat
stubs on any row where thin stubs (Rounds 1-3) matched it cleanly, this
FALSIFIES "victim shape doesn't matter" and implicates something
proportional to per-session fd/process count (e.g. a byte-offset or fd-
count-based index rather than a pure creation-order-position index) as a
live candidate — which would also be a plausible reason a real `claude`
session's live-fleet behavior (rich process tree, many fds) diverges from
this investigation's own thin-stub isolated data as much as it does.

## Sample-size limits (stated now)

Items 1 and 4: 9 kill trials each (3 rows × n=3), same shape/discipline
as Rounds 1-3. Item 3: up to 6 kill trials (2 rows × n=3) IF the
inversion is achieved, 0 if not (reported, not padded). Item 2: 9 kill
trials IF the build succeeds and loads, 0 (SKIPPED, with the blocker
named) if not. One machine, one day, same Emacs/ghostel/claude-code-ide
build as prior rounds where applicable (item 2's instrumented build is
necessarily a different binary from the live-loaded module — its
FUNCTIONAL behavior, not its logging, is expected to match, since only
log lines are added; this assumption is stated, not proven, and any
observed behavior change versus Rounds 1-3's thin-stub rows on the SAME
row shape would itself be reported as a discrepancy). This round, even at
full success on every item, still cannot generalize past this one
machine and day, and does not add live-fleet data.

## Safety boundary (restated, unchanged)

Isolated daemon(s) only, distinct socket names per concurrent daemon to
avoid any cross-daemon confusion. No bare `emacsclient`. No kill-buffer /
delete-process / signal aimed at the live daemon, not even read-only for
this round's own additional checks. The live-loaded ghostel module and
`~/.emacs.d/elpa/ghostel-20260823.1350` are never edited, rebuilt in
place, or pointed to by the live daemon's load-path. All daemons and any
build/toolchain processes started for this round are stopped/cleaned up
when done.

---

## Round 4 results — Item 2: native build

(Item 2 only; items 1/3/4 were run concurrently by a separate worker and
are reported in their own section, appended separately, above or below
this one — this section does not depend on or alter their content.)

### Toolchain and build

`zig` was **not already present**; installed via `brew install zig`
(bottled `0.16.0_1`, user-prefix `/opt/homebrew`, no sudo) — matches
`build.zig`'s `comptime` requirement of exactly Zig 0.16.0. The ghostel
source (`src/`, `build.zig`, `build.zig.zon`, `vendor/`) was copied from
`~/.emacs.d/elpa/ghostel-20260823.1350` into a scratchpad build
directory; the live elpa directory was never written to. `zig build`
fetched the vendored `ghostty` dependency over the network per
`build.zig.zon` and **built cleanly on the first structurally-complete
attempt** (two earlier attempts failed on this investigation's own
instrumentation code — Zig 0.16 moved file APIs into `std.Io.Dir`, not
`std.fs`, and a bare integer literal can't cross a C-variadic boundary
without an explicit cast — both fixed in the instrumentation, not in
ghostel's own code). Output:
`<scratchpad>/ghostel-r4a-build/zig-out/ghostel-module.dylib`, sidecar
`ghostel-module.version` = `0.51.0` (matches the live/isolated daemons'
expected version, confirmed via `ghostel-module-directory`'s version
gate rather than assumed).

Instrumentation added (to the scratchpad copy only, never to the live
elpa package): logging in `PosixPtyProcess.zig`'s `deinitAndWait` (before
`pty.deinit()` and again before closing `wake_pipe`, printing `pid`,
`primary_fd`, `replica_fd`, `wake_pipe`, thread id) and in
`NativeProcess.zig`'s `reapChild`/`finishEventChannel` (printing the
backend's pid, `event_writer` fd, exit code, thread id). First attempt
logged via `sys.write(STDERR_FILENO, ...)` on the theory that inherited
stderr would do — **this was tested and found wrong**: a plain
`(message "PING")` sent to the running isolated daemon *after* its
startup banner already did not reach the redirected stderr file either
(the startup banner itself, printed before Emacs finishes daemonizing,
did) — so Emacs's daemonization detaches/redirects standard streams
after startup, and any post-startup write to inherited fd 2 is lost.
Fixed by having the instrumentation open, append to, and close a real
file (`/tmp/ghostel-r4a-reaper.log`) on every log call, via the same raw
`sys.open`/`sys.write`/`sys.close` style already used elsewhere in
`PosixPtyProcess.zig` — no `std.Io`/`Dir` threading needed through free
functions.

### Loaded module path (as requested)

The isolated daemon (`ccb-repro-r4a`) had `ghostel-module-directory` set
to the scratchpad build's `zig-out/` directory *before* `(require
'ghostel)`, which is the documented seam (`ghostel-module-install.el`)
for pointing at a native module outside the package tree. Confirmed
loaded via `(ghostel--module-version)` → `"0.51.0"` and `(featurep
'ghostel-module)` → `t` immediately after daemon start. The live daemon's
own `load-path`/module directory was never touched.

### Kill rows: raw observation

Same F1/F2/F3 shape as Round 3, n=3 each, one long-running daemon (not
restarted between reps — item 2's own spec did not require it, unlike
item 6's fresh-vs-aged comparison). 9/9 kills, zero discards:

| Row | Killed | n | Victim (all 3 reps) | Survivor |
|---|---|---|---|---|
| F1 | Z (newest) | 3 | Y | X |
| F2 | X (oldest) | 3 | Y | Z |
| F3 | Y (before-newest) | 3 | X | Z |

Identical to Round 2 and Round 3's own F1/F2/F3 data and to rule C's
prediction, on an independently rebuilt module — 9/9, no exceptions.

### Native-level finding (the direct trace Round 3 could not get without `dtrace`)

For every one of the 9 trials, the reaper log shows **exactly two**
`reapChild`/`deinitAndWait` groups: one for the pid I explicitly killed,
one for the bystander — never a third, and never one for the session
that survived. The killed session's own reap always reports
`exit_code=137` (`128 + SIGKILL`, i.e. `WIFSIGNALED`, consistent with
ghostel's own pipe-sentinel calling `signal-process ... 9` directly on
its target). The bystander's own reap always reports **`exit_code=0`**
(`WIFEXITED` with status 0 — a *normal* exit, not a signaled one) — this
is a new, independent confirmation (from the native module's own exit
status, not from Rounds 1-3's separately-read stub trap log) that the
bystander's own child process received some signal its own trap handler
caught and responded to by calling `exit 0`, exactly as the stub script's
`trap ... exit 0` would produce.

Cross-checked directly against the pre-kill fd-block map (trial 1, native
pids x=53208/y=53213/z=53222, kill z): Y's own recorded block was
`25,26` (pipe pair) `+ 27` (ptmx); the reaper log for pid `53213` (Y)
reports `primary_fd=27`, matching exactly. Z's own recorded block was
`34,35 + 36`; the reaper log for pid `53222` (Z, the one explicitly
killed) reports `primary_fd=36`, matching exactly. **No cross-session fd
appears in either.** Fd-level re-verification for trials 2-9 individually
was not completed with the same rigor (later trials accumulate several
still-alive surviving sessions from earlier reps, since only F1/F2's two
casualties die per rep — X in F1's case, Z in F2/F3's case, survive and
pile up — making fd-block correlation by hand error-prone without a
proper spawn-order-tracking parser I did not build this round); this is
stated as a scope limitation, not glossed over. The aggregate,
whole-log-level evidence still holds without needing that per-trial
correlation: across all 18 `reapChild` groups (9 killed + 9 bystanders),
**the surviving session in every trial never appears in the reaper log at
all** — no reaper thread, for any of the 9 trials, ever touched the
survivor's resources.

### Inference (separated from the above)

- **H_reaper-cross-session-close (item 5): FALSIFIED**, per the
  pre-registered condition ("every captured close()/deinitAndWait call
  across all 9 trials resolves only to the killed session's own fd
  block") — directly confirmed for trial 1's fd numbers, and supported at
  the whole-log level (exactly 2 reapers per trial, always matching the
  killed pid and the bystander pid, the survivor never appearing) for all
  9. Per the pre-registration's own next step for this outcome: the
  cross-session-close mechanism is not what is happening: the bystander's
  own reaper runs cleanly on the bystander's own resources. The
  live candidate becomes a **process-group/session-level signal delivery
  effect** — something outside ghostel's Zig teardown code delivers a
  real, trappable signal to the bystander's own child, which this
  investigation does not have instrumentation to trace further (it would
  require tracing kernel-level pty/session/process-group state, not
  application code) and is reported as a new open question, not invented
  evidence.
- The exit-code distinction (137 vs. 0) independently corroborates
  Rounds 1-3's stub-trap-log-based finding that the killed session dies
  by an untrappable signal (SIGKILL) while the bystander dies via a
  trappable one its own trap handler catches — this is now confirmed from
  a second, independent data source (the native module's own reported
  exit status) rather than resting on the elisp/stub-log method alone.
- This does not identify WHAT delivers the signal to the bystander or
  WHY it targets specifically the predecessor-by-creation-order (or
  second-newest, for the oldest-kill case) — that remains open, same as
  every prior round.

### Sample-size / scope honesty (Item 2)

9 kill trials, zero discards, one machine, one day, one independently
rebuilt module (functionally intended to match 0.51.0 except for the
added logging). This directly rules out the specific "wrong-fd close by
the module's own reaper" mechanism for the trials captured — it does NOT
identify the true mechanism, does not trace kernel/process-group signal
delivery, and the fd-level cross-check was only done rigorously for one
of the 9 trials (stated above, not hidden). All daemons and build
processes for this item were stopped/cleaned up; confirmed via `ps` that
no `ccb-repro-r4a` daemon or its stub processes remained running
afterward.

---

## Round 4 results — Items 1, 3, 4

Run in parallel with Item 2 (a separate fork), isolated sockets
`ccb-repro-r4b1-*` (item 1), `ccb-repro-r4b3-*` (item 3),
`ccb-repro-r4b4-*` (item 4). `emacs-version` matched Emacs 30.2. No real
`claude` binary was launched (explicitly verified in `init-r4b.el`/
`init-r4b-fat.el`, both of which set `claude-code-ide-cli-path` before
any spawn).

### Methodological correction made before the pre-registered rows ran

`wait_and_report`, reused from Round 3's driver, broke out of its polling
loop on the FIRST poll that found any victim. Before running any item-1
row, a manual check showed a case where a SECOND session's stub also
logged a real `HUP` a few seconds later — a possible second bystander
Round 1-3's own driver could never have seen, because it always stopped
polling at the first hit. Fixed for this round only: the poll loop now
always runs its full window (12s, extended from Round 3's 8s) and reports
every session whose buffer disappeared, with which poll it was first
missing. Re-run after the fix, that specific case did NOT reproduce a
second victim (n=1 each way, inconclusive on its own) — flagged here as
an open question for a future round (is a second, later bystander ever
real, or was that one occurrence a stub-restart artifact coincidentally
timed near the kill?), not resolved by this round's data. All items below
used the fixed, full-window poller.

### Item 1: elisp-layer advice trace — raw observation

9/9 kill trials (F1/F2/F3, n=3 each), zero discards. Victims: F1
(kill newest) → before-newest, 3/3; F2 (kill oldest) → before-newest
(second-newest), 3/3; F3 (kill before-newest) → oldest, 3/3 — matching
Round 2/3's rule C exactly, 9/9.

A naive automated check (does any `delete-process`/`kill-process`/
`signal-process`/`process-send-eof` call's target resolve to the
bystander's own pid?) flagged **0/3 F1, 0/3 F2, but 3/3 F3** as "hits."
Manual backtrace inspection of all three F3 hits (identical shape in
every rep) shows this is NOT elisp picking the wrong target. The actual
sequence, from the trace (F3 rep 1, X=pid 41016 the bystander, Y=pid
41028 the killed target):

1. `17:50:35.872 signal-process target=41028 ...` — `(signal-process
   41028 9)`, i.e. Y's own real pid, called directly to kill the actual
   `kill-buffer` target. Correct.
2. `17:50:35.891` (19ms later) — `(signal-process 41016 9)` PLUS a
   `delete-process` on the process object literally named
   `ghostel-native-process` (Emacs's own uniquification: the *first*
   ghostel native process object created in this daemon, i.e. X's own,
   since X was spawned first) whose `ghostel--native-pid` property reads
   back **41016 — X's own real pid**. The backtrace shows this call
   originates from inside a **sentinel invoked for that same process
   object**, with an event string beginning `"finished"` — i.e. X's own
   tracked process independently reported a finish/exit event, and
   elisp's sentinel then correctly (if redundantly, since the process is
   already ending) signals and deletes X's own, already-finishing
   process.

This is the same shape in F3 reps 2 and 3 (X's own pid in both cases,
same ~15-19ms gap after the real target's own kill signal). **Item 1's
finding, read correctly (not by the naive automated flag alone): elisp
never targets a session other than the one whose own process object's
sentinel is firing.** The wider net (more call sites, full backtraces)
CONFIRMS Rounds 1 and 3's narrower finding rather than falsifying it —
per the pre-registration's own prediction. The open question this raises,
not answered here, is *why* X's own tracked process enters a "finished"
state within ~19ms of a *different* session being killed — which is
exactly the same gap Item 2 (run in parallel) independently converges on:
Item 2's native reaper trace shows the bystander's own child exits with
`exit_code=0` (a trappable signal caught by its own trap), never touching
another session's fd. Together, items 1 and 2 triangulate the same
conclusion from two independent instrumentation layers: **neither elisp
nor the native module's own reaper ever targets the wrong session — the
bystander's own process receives a real signal from somewhere outside
both of those, most likely at the kernel process-group/session level**,
which neither fork's instrumentation could trace further this round.

`ghostel--kill-native-processes-on-exit` (the `kill-emacs-hook`) never
fired during any of the 9 trials, as expected (it only runs on Emacs
shutdown, not a single `kill-buffer`).

### Item 3: deliberate slot-order inversion — raw observation

**Deviation from the literal pre-registration, stated plainly**: the
pre-registered setup (spawn A,B,C; kill A the oldest; spawn D) could not
be used as written — killing A collaterally kills the second-newest too
(Round 2/3's own established oldest-kill rule), collapsing the intended
B,C,D triad to a pair before D was even spawned. Adapted (and this
adaptation is itself informative, see below): spawn A,B,C,E (4 sessions);
kill B (not oldest, not newest of the 4) to free a slot; spawn D; use
whichever two of {A,C,E} actually survive, plus D, as the live triad for
the decisive rows.

**Unplanned finding from the setup step itself**: killing B (creation
position 2 of 4) was expected, by naive extension of the established
"predecessor dies" rule, to kill A (position 1). Instead, in the first
setup attempt, **C (position 3, the *successor*, not the predecessor)
died** — the established rule, derived only from N=3 pools in Rounds
1-3, does **not** simply generalize to "kill position i, position i-1
dies" at N=4. This is reported as a new, real, unplanned data point, not
smoothed over. In three subsequent setup runs (used for the counted rows
below), the collateral casualty was consistently **C** again (A and E
survived every time) — so for N=4, killing position 2 consistently killed
position 3, not position 1, across 4/4 setup attempts total. This
directly means: whatever "predecessor" meant at N=3 is not simply
"index-1" at N=4; the live pool size or absolute position changes which
neighbor dies.

Inversion (D's fd lower than at least one longer-lived survivor's fd) was
**achieved in all 4 setup attempts used** (survivors A, E each time; D
reused B's freed slot, landing fd-wise BETWEEN A's original low block and
E's original high block — i.e., D sits fd-adjacent-below E while being
newest by creation, which is the decisive inversion needed).

Live triad every time: by creation order, A (oldest) then E then D
(newest, spawned last). By fd order: A (lowest, untouched original
block), D (middle, reused B's freed low-but-not-lowest block), E
(highest, untouched original block) — so creation order and fd order
disagree specifically about D and E's relative position, which is the
decoupling this item needs.

- **Row 3a — kill A** (creation-oldest of the live triad, ALSO the
  fd-minimum, no fd-neighbor below it): victim = **E**, 3/3 clean.
  Matches creation-order rule C's oldest-kill special case (hits the
  second-newest of the live-by-creation set [A,E,D] = E). Does NOT match
  any fd-adjacency-below hypothesis (A has no lower fd-neighbor to blame;
  a death occurred anyway, and it targeted the creation-order prediction
  exactly).
- **Row 3b — kill D** (creation-newest of the live triad, fd-MIDDLE, not
  fd-edge): victim = **E**, 3/3 clean. Matches creation-order rule C's
  ordinary predecessor case (predecessor of D by creation order = E).
  Does NOT match an fd-adjacency-below hypothesis, which would predict A
  (D's nearest lower-fd neighbor) — A survived every time.

6/6 trials, zero discards (beyond the pre-registered non-count of setup
attempts that fail the inversion/survivor-count check, of which there
were none in the counted batch — the one earlier attempt using the
original A-kill setup design was discarded before any row ran, per the
pre-registration's own rule, and is not counted as a trial).

### Item 4: victim-shape row (fat stubs) — raw observation

Fat stub spawns 2 long-lived children, one parent-of-a-grandchild triple,
and an extra fifo/pipe of its own (verified present via the stub's own
process tree at spawn time; cleaned up post-kill via `pkill` on
identifiable child names, since a real `SIGKILL` to the stub — matching
ghostel's own kill path — does not run the stub's bash `EXIT` trap and so
cannot self-clean its own children).

9/9 kill trials (F1/F2/F3, n=3 each), zero discards: F1 (kill newest) →
before-newest, 3/3; F2 (kill oldest) → before-newest (second-newest),
3/3; F3 (kill before-newest) → oldest, 3/3 — **identical to Rounds 1-3's
thin-stub results and to this round's own Item 1 thin-stub rows.**

### Inference (Items 1, 3, 4; separated from the above)

- **Item 1 prediction CONFIRMED**: elisp-layer targeting is correct in
  every trial, including on a wider instrumentation net (more call
  sites, full backtraces) than Rounds 1/3 used. The naive automated
  "wrong-target" flag in F3 was a false positive from not reading the
  backtrace; corrected by manual inspection, reported above rather than
  either hidden or left unexplained.
- **Item 3 (H_fd-block-reuse vs. creation-order rule C), DECISIVELY
  separated**: with fd order and creation order genuinely decoupled (a
  real achievement Round 3 could not manage), **creation-order rule C
  predicted the victim correctly in 6/6 trials; a literal fd-adjacency
  hypothesis was wrong in 6/6** (predicting no-death/A for row 3a, A for
  row 3b; the actual victim was E both times). This is the clearest
  falsification yet of "the mechanism is keyed to fd number" and the
  clearest confirmation that whatever key it uses tracks **creation
  order among the currently-live set**, not fd/slot position — though
  Item 3's own unplanned N=4 finding (predecessor-rule does not simply
  generalize past N=3) shows "creation order" itself is not as simple as
  "index-1," and the exact indexing rule remains open.
- **Item 4 prediction CONFIRMED**: victim shape (fat, multi-process,
  multi-fd stubs vs. thin single-process stubs) does not change the
  victim. This weakens "session fd/process count" as an explanation for
  why the live fleet's rich-process-tree sessions behave differently from
  this investigation's stub data (Item 4 at least shows shape alone,
  independent of fd-block position, is not the reason) — the live-fleet
  divergence (Correction, commit `6166757`) remains open and is not
  resolved by this finding.
- Rule C (as refined by Item 3's N=4 caveat) continues to fit every
  isolated-daemon trial across Rounds 2-4 with zero exceptions at N=3; it
  still only explains 2 of 5 real live-fleet deaths, unchanged.

### Sample-size / scope honesty (Items 1, 3, 4)

Item 1: 9 trials, 0 discards. Item 3: 6 counted trials (2 rows × n=3), 1
setup attempt discarded per its own pre-registered rule (inversion not
achieved under the ORIGINAL A-kill design) before adapting the setup —
the adapted design's 4/4 setup attempts all achieved inversion, so no
further discards under the adapted design. Item 4: 9 trials, 0 discards.
One machine, one day, same build. This round shows the elisp layer is
clean (Item 1), that fd/slot position does not drive the victim even
when deliberately decoupled from creation order (Item 3), and that
victim shape does not change the outcome (Item 4) — combined with Item
2's parallel finding (native reaper is also clean), this narrows the
remaining live candidate to a kernel/process-group-level signal delivery
effect neither fork could instrument further this round. It does not
identify that mechanism, does not add live-fleet data, and Item 3's
open N=4 indexing question is a new gap, not a closed one.

All `ccb-repro-r4b1-*`, `ccb-repro-r4b3-*`, and `ccb-repro-r4b4-*`
daemons were stopped; confirmed via `ps` that no daemon, stub, or
fat-stub child process remained running afterward.

---

## Draft upstream issue: WITHDRAWN (post-Round 4)

The draft upstream issue written in Round 2 (pre-registration commit
`2bd2d80`, reaffirmed "unchanged recommendation" in the Round 2 results)
proposed a mechanism: a raw pty-master fd closed on a detached,
unsynchronized reaper thread (`PosixPtyProcess.zig`'s `deinitAndWait`),
closing the wrong session's fd. Round 4 item 2 (native build results,
commit `c619ee5`) directly instrumented and traced every `close()`/
`deinitAndWait` call across 9 kill trials and found the reaper never
touches any fd outside the killed session's own block — the survivor
never appears in the reaper log at all, in any trial. That falsifies
the specific mechanism the draft issue describes.

**The draft is WITHDRAWN. It will not be filed against
`github.com/dakra/ghostel` as written.** The text above is left
unedited (insert-only correction, per standing practice in this doc) so
the reasoning trail stays intact; this section is the authoritative
statement that it no longer reflects the current best understanding of
the mechanism. Any future upstream report should be written fresh, from
whatever Round 5+ establishes, not by patching the withdrawn draft.

---

# Round 5 pre-registration: inherited event-channel fd leak

Written before any Round 5 run. Frozen once committed; results appended
below it, never edited into it. One round, per steward's instruction.
Isolated daemon only; the live daemon is never touched — no kills, and
no `lsof` beyond what was already relayed read-only by butler.

## The lead (relayed, not yet measured by me)

Butler relayed a read-only `ps`+`lsof` measurement on the live fleet:
every `claude` child process holds inherited copies of OTHER sessions'
Emacs event-channel pipe ends. Example: child `57310` (`ttys006`) holds
fds `17, 28, 38, 48, 58, 78` — the same pipe ends as Emacs fds `16/17,
27/28, 37/38, 47/48, 57/58, 77/78`, i.e. the dup'd event-channel pairs
immediately preceding each earlier session's ptmx (the same block shape
Round 3/4 already mapped). Source fact, independently checkable in the
Emacs 30 source already read in Round 3: `process.c:8604`'s
`open_channel_for_module` calls plain `dup()`, which does not set
`FD_CLOEXEC` — `[추론]`: the module's event-writer fd survives every
later child's `fork()`+`exec()`, landing in each subsequently-spawned
session's own child process.

**Correction to the lead, folded in before any run** (butler/x600, the
original per-tty count list was in tty order, not creation order;
re-measured by `ps lstart` on m1, and independently by x600 on Linux):
the real shape is four specific, separately-testable properties, not
just "grows with creation order":

1. **Monotone**: per-child inherited-fd count n = 1..10 is strictly
   monotone in CREATION order (not tty/device order, which the original
   relay was sorted by and which obscured this).
2. **Nested**: each child holds the immediately-earlier child's entire
   inherited set, PLUS exactly one more (its own set is a strict
   superset of size |earlier|+1, not just the same count).
3. **ptmx-1**: every inherited fd number equals SOME earlier session's
   `(ptmx fd) - 1` — i.e. the SECOND member of that session's dup'd pair
   (matching the block shape: pipe-pair immediately followed by ptmx, so
   `ptmx-1` is the pair's higher-numbered fd), not the first member.
4. **Own write end**: each child ALSO holds its OWN session's event
   write end (so the very first/oldest child, with nothing earlier to
   inherit, still holds exactly one such fd — its own — not zero); x600
   confirmed a negative control of 0 for a process with no ghostel event
   fd at all, so "own write end" is a real, present fd, not an artifact
   of the counting method.

This is a plausible mechanism distinct from everything Rounds 1-4 ruled
out: it is a cross-session link held by a DIFFERENT PROCESS (the
bystander's own child), not by elisp or by ghostel's reaper thread in
the killed session's own process — exactly the kind of thing neither of
Round 4's instrumentation layers could have seen.

## Item (a): reproduce the inheritance, isolated daemon

Spawn 5-6 stub sessions in sequence (S1..S6). For each newly-spawned
child's own pid, `lsof -p <child-pid>` its fd table. For every
EARLIER session Si (i < current), build its event-channel pair + ptmx
block the same way Round 3/4 did (pipe-pair fds immediately preceding
Si's ptmx fd, read from the Emacs daemon's own `lsof -p <daemon-pid>`
at Si's spawn time). Check whether the newest child's fd table contains
an fd whose **device+inode** (not just fd number — `lsof`'s `TYPE`/
`DEVICE`/`NODE` columns, matched against the daemon's own entry for that
fd number, not assumed from numeric coincidence alone) matches Si's
event-channel pipe.

**Prediction**: for S1..S6 spawned in creation order, test each of the
four corrected properties directly, per child (device+inode match, not
numeric coincidence, per fd claimed):
1. Monotone — child Si's inherited-fd count strictly increases with i.
2. Nested — Si's inherited set ⊇ S(i-1)'s inherited set, plus exactly
   one new fd.
3. ptmx-1 — every inherited fd in Si equals some earlier Sj's
   `(ptmx fd) - 1`.
4. Own write end — every Si (including S1, the oldest, with nothing
   earlier to inherit) holds exactly one fd that is ITS OWN `ptmx-1`,
   so S1's total is 1 (its own), not 0.

**Falsification**: reported PER PROPERTY, not as one pass/fail — e.g. if
monotone+nested+own-write-end hold but some inherited fd is NOT at
`ptmx-1`, that is stated as "3 of 4 properties confirmed, ptmx-1
falsified," not rounded to a single verdict. If ALL FOUR properties fail
(zero inheritance of any kind, across all 5-6 spawns), this FALSIFIES
"the leak reproduces on this build" outright — reported as a real
discrepancy against the live fleet's own relayed (and now twice
independently re-measured, on two OSes) measurement, not smoothed over,
and item (b)'s treatment/control rows do not proceed (nothing to treat);
the round instead reports the discrepancy and stops there.

## Item (b): treatment vs. control

**Only if item (a) reproduces the leak.** Build TWO instrumented copies
of the native module from the Round 4 item-2 scratchpad base (or a
fresh copy of the same source, if that scratchpad was cleaned up —
`zig` itself, once installed via `brew`, does not need reinstalling):

- **Control**: the Round 4 item-2 instrumented copy as-is (close()/
  reaper logging only, no fd-leak fix) — or the plain, unmodified
  0.51.0 module if rebuilding the exact item-2 copy is not practical;
  whichever is used is stated explicitly in the results.
- **Treatment**: the same copy, PLUS a fix for the leak: immediately
  after the module receives the event-channel fd from Emacs (wherever
  `NativeProcess.zig`/`module.zig` stores it — read the actual call
  site before patching, don't guess), call `fcntl(fd, F_SETFD,
  FD_CLOEXEC)` on it. **If that specific fd is not reachable/settable
  from the module's own code** (e.g. Emacs owns it before the module
  ever sees it, or the API doesn't expose a raw fd), fall back to
  closing all non-standard fds in the forked pty child, in
  `PosixPtyProcess.zig`'s fork path, before its `execve()` — this is
  the steward's own stated fallback. State plainly which of the two
  approaches was used and why.

Verify with `lsof` (same device+inode method as item (a)) that newly
spawned children under the TREATMENT build no longer inherit earlier
sessions' event-channel fds, before running any kill row.

**Interpretation of "same session, same n" (stated explicitly since the
literal instruction is ambiguous about whether one Emacs process can
run both builds at once — it cannot, since only one native module can
be loaded per Emacs process)**: "same session" is read as one
back-to-back investigative run, same day/setup/stub shape, comparing a
TREATMENT daemon (patched module loaded) against a CONTROL daemon
(unpatched module loaded), not a literal single Emacs process running
both. If this reading is wrong, that is exactly the kind of
misinterpretation to flag back, not silently proceed past.

Run the standard three rows (kill Z/newest, kill Y/before-newest, kill
X/oldest — matching every prior round's F1/F2/F3 shape) on BOTH the
treatment daemon and the control daemon, n=3 reps each (18 kills total).

**Decision rule (amended by butler/x600 before any run, folded in here):
record TWO outcomes SEPARATELY per row, not one aggregate verdict**:

(i) Do bystander deaths STOP under treatment (0/3 or close, per row)
    while the SAME row on the control daemon continues to show them at
    the established rate (≥2/3, matching Rounds 1-4)?
(ii) Does the NESTING property (item (a)'s property 2, checked the same
     way, via `lsof` device+inode) DISAPPEAR under treatment — i.e. do
     newly-spawned children under the treatment build no longer inherit
     earlier sessions' event-channel fds at all?

Read per row, using the pre-registered table (verbatim from butler/
x600):
- **Deaths stop AND nesting gone** ⇒ consistent with the leak BEING the
  mechanism.
- **Deaths stop but nesting remains** ⇒ the leak is NOT the mechanism;
  the treatment changed something else, and that must be identified
  before claiming anything about the leak itself.
- **Nesting gone but deaths persist** ⇒ the leak is real but NOT
  causal — reported plainly, not downplayed.
- (A fourth, unlisted cell — deaths persist AND nesting remains — would
  mean the treatment didn't actually take effect; reported as a failed
  treatment attempt, not evidence about the hypothesis either way.)

Each row's own (i)+(ii) pair is stated individually, never aggregated
into one round-level verdict — a row can land in a different cell than
another row, and that difference is itself reported, not averaged away.

## Sample-size limits (stated now)

Item (a): 5-6 spawns, one daemon, one machine, one day — enough to show
presence/absence of the qualitative inheritance pattern on this build,
not to reproduce the live fleet's exact per-tty counts. Item (b): up to
18 kill trials (2 builds × 3 rows × n=3) IF item (a) reproduces; 0 if it
doesn't (reported, not padded). Building an instrumented module is the
same one-attempt-then-report-blocked discipline as Round 4 item 2: a
genuine, reasonable attempt at the CLOEXEC fix or the fallback, not an
open-ended toolchain fight. Discards (setup failure, ambiguous lsof
read, non-attach of a daemon) are counted and reported with reasons.

## Safety boundary (restated, unchanged)

Isolated daemon(s) only, distinct socket names for treatment vs.
control to avoid confusion. No bare `emacsclient`. No kill-buffer /
delete-process / signal / `lsof` beyond what butler already relayed
read-only aimed at the live daemon. The live-loaded ghostel module and
`~/.emacs.d/elpa/ghostel-20260823.1350` are never edited, rebuilt in
place, or pointed to by the live daemon's load-path. No upstream filing
this round regardless of outcome — steward routes that decision. All
daemons and build/toolchain processes started for this round are
stopped/cleaned up when done.

---

## Round 5 results

### Setup

Isolated daemons only: `ccb-repro-r5a` (item (a), reproduction),
`ccb-repro-r5-control` and `ccb-repro-r5-treatment` (item (b), each
loaded via `ghostel-module-directory` pointed at its own scratchpad
build — never the live elpa dir or live daemon). `zig` (0.16.0) was
already installed from Round 4; no reinstall needed. `claude-code-ide-cli-path`
explicitly set to `stub-claude.sh` in every init file before any spawn —
verified before first use each time.

### Item (a): reproduction — raw observation

S1..S6 spawned in creation order on `ccb-repro-r5a` (daemon pid 757).
For each child, its own fd table was compared to the daemon's own
`lsof` snapshot by DEVICE column (lsof's pipe-identity field on this
platform — an exact string match against the daemon's own entry for
the claimed fd, not a numeric coincidence):

| Child (native pid) | Inherited+own fds | Count |
|---|---|---|
| S1 (1197) | [17] | 1 |
| S2 (1851) | [17, 26] | 2 |
| S3 (1873) | [17, 26, 35] | 3 |
| S4 (1925) | [17, 26, 35, 44] | 4 |
| S5 (1941) | [17, 26, 35, 44, 53] | 5 |
| S6 (2001) | [17, 26, 35, 44, 53, 62] | 6 |

Daemon's own blocks (verified against the same snapshot): S1 pipe-pair
16/17, ptmx 18; S2 25/26, ptmx 27; S3 34/35, ptmx 36; S4 43/44, ptmx 45;
S5 52/53, ptmx 54; S6 61/62, ptmx 63 — every pipe-pair's two fds share
the identical DEVICE value (confirming they are `dup()`s of the same
underlying pipe end, matching `process.c:8604`'s plain `dup()` call
exactly, no separate allocation).

**All four properties CONFIRMED, per-property, zero ambiguity**:
1. **Monotone**: 1,2,3,4,5,6 — strictly increasing with creation order.
2. **Nested**: every consecutive pair (S1→S2, S2→S3, S3→S4, S4→S5,
   S5→S6) is the previous set plus exactly one new fd. 5/5 transitions
   clean.
3. **ptmx-1**: every fd in every child's set equals that session's own
   `(ptmx fd) - 1` exactly — 17=18-1, 26=27-1, 35=36-1, 44=45-1,
   53=54-1, 62=63-1. 6/6, exact.
4. **Own write end**: S1 (the oldest, nothing earlier to inherit) holds
   exactly `[17]` — its own `ptmx-1` — not `[]`. Every later child's
   newest fd is its own `ptmx-1` (S4's `44`, etc). Confirmed for all 6.

Zero discards. The isolated build reproduces the relayed live-fleet
measurement's corrected shape exactly, on all four properties
independently, not just qualitatively.

### Item (b): treatment vs. control — raw observation

**Fix used**: the module-side `fcntl(F_SETFD, FD_CLOEXEC)` approach was
directly reachable and used (not the exec-time fallback). The exact
call site: `GhostelTerm.zig`'s `ghostel--spawn-native-process` impl
calls `env.openChannel(pipe_val)` to get the raw event-channel fd
before passing it to `term.spawnNativeProcess`; the fix captures that
fd into a local, calls `std.c.fcntl(fd, std.c.F.SETFD, @as(c_int,
std.c.FD_CLOEXEC))` on it immediately, then passes the same fd onward
unchanged. Both builds compiled cleanly on the first attempt (module
version confirmed `0.51.0` for both, matching the live/isolated
baseline).

**Pre-kill nesting check (input (ii), before any kill)**: control
(unpatched) reproduced the same nesting pattern as item (a) (S1:[17],
S2:[17,26], S3:[17,26,35] — 3 sessions checked, consistent). Treatment
(patched): **zero** inherited or own-write-end pipe fds in any of 3
freshly-spawned children — the fix removes the leak completely,
including each session's own write end in its own child, not just
others'. Re-verified AFTER all 9 treatment kills below (a 10th, final
spawn): still zero leaked fds — the fix held for the whole run, not
just at the start.

**Kill rows, n=3 each, both daemons (18 kills total, zero discards)**:

| Row | Killed | Control victim (3/3) | Treatment victim (3/3) |
|---|---|---|---|
| F1 | Z (newest) | Y | Y |
| F2 | X (oldest) | Y | Y |
| F3 | Y (before-newest) | X | X |

**Every row: identical victim under treatment and control.** Input (i)
(do deaths stop under treatment?) is NO for every row — 9/9 treatment
kills match 9/9 control kills exactly, despite input (ii) (nesting
gone?) being YES, confirmed both before and after the full kill
sequence.

### Inference (separated from the above)

- **Item (a)**: the relayed lead reproduces exactly, on the corrected
  (monotone/nested/ptmx-1/own-write-end) shape butler/x600 supplied —
  not just the original, tty-order-confounded version. This is a real,
  confirmed leak on this build, independently of whether it turns out
  to be causal.
- **Item (b), read against the pre-registered table**: every row lands
  in the **"Nesting gone but deaths persist"** cell. Per the
  pre-registered reading: **the leak is real but NOT causal.** The
  `FD_CLOEXEC` fix demonstrably and completely closes the fd-inheritance
  leak (item (a)'s properties all disappear under treatment, checked
  both before and after the kill sequence) while having zero effect on
  which session dies or whether one dies at all. This FALSIFIES the
  Round 5 lead as the mechanism, per its own pre-registered decision
  rule — reported plainly, not downplayed.
- Combined with Round 4 (elisp clean, native reaper clean) and this
  round, THREE independently-instrumented candidate mechanisms are now
  cleared: wrong elisp target, wrong-fd native close, and inherited
  event-channel fd. Rule C (predecessor dies; oldest's kill hits the
  second-newest, with the N=4 caveat from Round 4 item 3) continues to
  fit every isolated N=3 trial across Rounds 2, 3, 4, and now 5 with
  zero exceptions — the mechanism producing that specific pattern is
  still not identified at the code level, and increasingly looks like
  it sits below every instrumentation layer this investigation has been
  able to reach from Lisp or from a rebuilt native module (e.g. genuine
  kernel/pty/process-group state, as Round 4 already flagged as the
  remaining candidate).
- No new live-fleet data this round; the Correction (commit `6166757`,
  rule C fits only 2/5 real deaths) is unaffected either way by this
  round's isolated-only findings.

### Sample-size / scope honesty (Round 5)

Item (a): 6 spawns, one daemon, one day — enough to confirm all four
properties present and exact on this build; does not reproduce the live
fleet's literal per-tty fd numbers (build/version/uptime-dependent) nor
prove the mechanism is identical across machines, only that the same
structural leak exists here too. Item (b): 18 kill trials (9 control +
9 treatment), zero discards, one machine, one day, two independently
built module variants differing by exactly one `fcntl` call plus the
capture of its return value into a local (no other code changes). This
directly rules out the fd-inheritance leak as causal for the pattern
tested — it does not rule out a DIFFERENT causal role for the leak
under a scenario this round didn't test (e.g. many more sessions,
different kill patterns, or interaction with the still-unidentified
kernel-level candidate), and does not identify what does cause the
bystander death.

All daemons (`ccb-repro-r5a`, `ccb-repro-r5-control`,
`ccb-repro-r5-treatment`) and the zig build processes were stopped;
confirmed via `ps` and per-pid checks that no leftover daemon, stub, or
build process remained running afterward.

# Pre-registration: Round 6 — exit-control arm

Written before any Round 6 run. Frozen once committed; results get
appended below, never edited into it. Dispatched by the steward, under
butler/정수님's explicit authorization for this one narrow round only —
the HOLD announced after Round 5 otherwise stands and resumes
immediately after this round's report.

## Background (why this round, not measured by me)

Every prior round (1, 3, 4, 5) triggered the "bystander death" signature
using an explicit `kill-buffer` (or equivalent forced native close) on
the target session, while ≥2 (established: ≥3) other ghostel sessions
were alive. Round 1's own pre-registration planned a "typed `exit`
(control arm)" trial as a baseline comparison, but no round's results
ever report it having actually been run — confirmed by grep across this
entire document for every kill/delete-process/exit/sentinel mention: all
executed trials in Rounds 1, 3, 4, and 5 used an externally-initiated
kill as the sole trigger. Separately, in this session, the steward asked
a read-only question about retiring a worker via in-session `/exit`
(child exits on its own) instead of `kill-buffer`; the honest answer
given was "not covered" — Round 4's own converging inference (items 1+2:
neither elisp nor the native reaper ever targets the wrong session; the
bystander's own process receives a real signal from somewhere outside
both, "most likely at the kernel process-group/session level") does not
rule out self-exit as an equally valid trigger for that same class of
kernel-level effect, since POSIX session-leader-exit → SIGHUP-to-
foreground-process-group is triggered by ANY termination of a session
leader, not specifically by how Emacs asked it to die. This round exists
to close that specific, previously-unrun gap — nothing else.

## What this pre-registration commits to before seeing results

### Setup

Isolated `ccb-repro-r6`-named daemon only (fresh, not reusing any prior
round's daemon). Victims: real `claude-code-ide--create-terminal-session`
ghostel sessions (`claude-code-ide-terminal-backend` = `ghostel`),
`claude-code-ide-cli-path` pointed at a stub script — same family as
every prior round's stub, `trap ... HUP TERM; cat` — chosen specifically
because closing its stdin (EOF) makes `cat` terminate **on its own**,
exit code 0, with no signal delivered to it from anywhere. This is the
closest local analogue to a real `claude` session's user-typed `/exit`:
the child process ends itself; nothing external signals it, calls
`kill-buffer`, `delete-process`, or `close_topic` on it, and its own
Emacs-side buffer is not killed by this trial (matching the literal
question asked: "the Claude process exits on its own, the Emacs buffer
stays open, nobody calls kill-buffer/close_topic").

Spawn three sessions in order A, B, C (matching every prior round's
three-session shape, the smallest setup under which the bystander
pattern has ever reproduced). Confirm via `(process-live-p proc)` and
`(process-get proc 'ghostel--native-pid)` that all three are alive and
distinct before triggering anything.

### Trial

**Trigger self-exit on C (the newest)** — the exact position that, under
every prior round's kill-arm F1 row (kill Z/newest), reliably killed B
(before-newest) 3/3 in Rounds 4 and 5 and matched the same pattern in
Round 1. Self-exit C by closing its pty's write end / sending EOF to its
stdin (whichever the ghostel session's process object actually exposes —
read the real API before the run, do not guess) rather than any signal
or Emacs-side kill call. Then poll for up to 12s (Round 4's fixed,
full-window poller) whether B (before-newest) or A (oldest) shows the
bystander-death signature: an unprompted `HUP`/exit trap-log entry or a
`ghostel--events-filter` numeric exit-status event, with neither
`kill-buffer`, `delete-process`, nor `signal-process` ever having been
called on it by anything in this trial.

n=3 reps (fresh A/B/C each time, same daemon). Zero discards planned;
if any rep needs to be discarded, state exactly why, per this
investigation's standing practice.

### Interpretation rules (decided now, not after)

- **Self-exit reproduces the mechanism** if, in ≥2/3 reps, B shows the
  bystander-death signature (real HUP/exit event on B's own real child,
  confirmed via backtrace the same way Round 4 items 1+2 did — not the
  naive automated flag alone) within the poll window, with no kill call
  of any kind observed targeting B or C beyond C's own self-initiated
  EOF/exit.
- **Self-exit does NOT reproduce the mechanism** if 0/3 or 1/3 reps show
  it — read as evidence (on this machine, this day, n=3) that an
  externally-triggered kill/signal on the target is necessary, and a
  session's own graceful self-termination is NOT sufficient to trigger
  the same effect. This would falsify the concern raised in this
  session's "not covered" answer, on this machine, at this n — it would
  NOT retroactively prove self-exit is safe on the live fleet (see
  sample-size limits).
- **Ambiguous / setup failure** (e.g. the stub's EOF path doesn't cleanly
  produce a signal-free exit, or C's own death can't be distinguished
  from an externally-caused one) is reported as such, verbatim, and not
  forced into either of the above.

### Falsification conditions

- The "self-exit reproduces" reading is FALSIFIED if any of the 3 reps
  that show a bystander-death signature on B also show a `kill-buffer`,
  `delete-process`, or `signal-process` call logged against B or C from
  any source other than C's own natural termination path — i.e. if the
  effect can be explained by an ordinary kill sneaking into the trial
  rather than genuine self-exit.
- The "self-exit does NOT reproduce" reading is FALSIFIED (i.e. treated
  as inconclusive, not confirmed-safe) if the poll window or trap-log
  instrumentation itself is shown to have missed an event during the
  run (e.g. Emacs's event loop wasn't pumped again before the final
  check, the same false-negative risk Round 1 flagged for its own
  "clean" pairs) — in that case this round reports "inconclusive," not
  "safe."

### Sample-size / scope honesty (stated now)

n=3 self-exit reps, one machine, one day, one narrow position (self-exit
the newest of exactly 3 sessions, checking for the before-newest
bystander). This can show presence or absence of the effect under THIS
specific trigger and shape, on this build, today. It does NOT test
self-exit of the oldest or before-newest position, does not test >3
sessions, does not establish an incidence rate, and does not by itself
resolve whether `/exit` + `cc-butler--roster-forget` is safe on the live
fleet — a "does not reproduce" result narrows the open question, it does
not close it.

### Safety note (unchanged from every prior round)

Isolated `ccb-repro-r6` daemon only. No bare `emacsclient` (always `-s
ccb-repro-r6`). No `kill-buffer`, `delete-process`, or signal aimed at
the live daemon, not even read-only beyond what's already relayed.
Victims are cheap stub sessions only, never the real `claude` binary —
confirm `claude-code-ide-cli-path` is pointed at the stub before
spawning anything, per the standing hazard noted in every prior round.
All daemon and any build/toolchain processes stopped and confirmed via
`ps` when done.

## Addendum (butler adopts x600's two points, before any Round 6 run)

Written before any Round 6 row was run — the pre-registration above is
already committed/pushed (`9cf2552`), so per standing practice this is a
separate, clearly-labelled addendum, not an edit into the frozen text
above. Still ONE round, still an isolated daemon, still after Task 1.

### Point 1: N≈10, paired negative control (not N=3, not unpaired)

The N=3 design above is **superseded** by this addendum on two points:

- **N≈10, not 3.** The victim rule is creation-order-dependent, and
  Round 4 item 3 already showed the naive "predecessor dies" rule does
  NOT simply extend past N=3 (killing position 2 of 4 hit the
  *successor*, position 3, not position 1). Assuming "self-exit the
  newest ⇒ check the before-newest" at N≈10 would be extending an
  already-falsified extrapolation. Instead: spawn N≈10 sessions, trigger
  the event (kill or self-exit) on the newest, and **observe which
  session(s), if any, show the signature — do not assume the position
  in advance.**
- **Paired negative control, same N, same daemon, mandatory.** Before
  any self-exit row is read as meaning anything: on a fresh N≈10 spawn
  in the SAME daemon, `kill-buffer` the newest and confirm a bystander
  death occurs somewhere in the set. **If kill-buffer does NOT reproduce
  a bystander death at N≈10, the self-exit row is uninformative and is
  reported as such — it does NOT get read as "self-exit is safe."**
  Interpretation rule, exact: **"/exit safe" holds ONLY IF (kill-buffer
  kills a bystander at this N, this daemon) AND (self-exit, same N, same
  daemon, does not)**. Any other combination (kill doesn't reproduce;
  both reproduce; neither reproduces) is reported as its own outcome,
  not forced into "safe" or "unsafe."
- **Daemon age is an explicit, untested axis.** The real fleet daemon is
  long-lived (days); a freshly-spawned `ccb-repro-r6` daemon cannot
  cheaply reproduce that. This round's result applies to a
  freshly-started daemon only — age-dependence is neither confirmed nor
  ruled out, stated plainly as scope, not silently assumed away.

### Point 2: state-of-receiving-session rows

Record the STATE of the session that receives the self-exit-equivalent
action, one row per state, self-exit still targeting the newest session
in a fresh N≈10 spawn each time:

1. **idle** (0k context, blocked on read — the baseline shape used in
   every prior round and in this addendum's Point-1 rows).
2. **mid-turn** (approximated with a stub: actively writing to stdout in
   a loop at the moment EOF/exit is attempted, rather than blocked on
   read).
3. **unsubmitted text in the input box** (approximated at the pty layer:
   characters written into the pty's canonical-mode input queue with NO
   trailing newline before the exit-equivalent action is sent — this
   tests whether a pending, unterminated line changes whether the
   process-level EOF is delivered/accepted, which is a real pty-line-
   discipline property, not specific to the real CLI's own line editor).
4. **open menu or wizard** (approximated with a stub placed into raw/
   non-canonical terminal mode via `stty raw` before the exit-equivalent
   action, as the closest available proxy for a TUI alternate-screen/
   input-capture mode — stated plainly as an approximation, not the real
   CLI's actual menu code).
5. **unresponsive / long subagent** (approximated with a stub that is
   busy — e.g. a tight sleep loop not reading its own stdin at all — for
   several seconds spanning the exit-equivalent attempt).

**"Does not accept the exit-equivalent action" (e.g. EOF sent but the
stub does not terminate within the poll window) is itself a valid,
reportable boundary outcome for that state row — not a failure of the
round, and not silently retried into a different state.** Where a state
cannot be triggered without deviating from the stub-only / no-real-
`claude`-binary safety boundary, that row is reported as "not testable
under this round's safety boundaries," not approximated by relaxing the
boundary.

n=1 rep per state (5 states) — this is explicitly a boundary-mapping
pass, not a statistical claim; only the Point-1 paired design carries
n=3 and a "safe"/"unsafe" read.

### Correction to Point 2, before any row ran

**Point 2 (the 5 state-of-session rows) is UNTESTED by this round, not
silently dropped.** Flagged by butler before any Part-2 row was
attempted: whether a session in a given state (mid-turn, typed-but-
unsubmitted text, open menu/wizard, unresponsive) accepts `/exit` is a
behavior of the real Claude Code CLI's own TUI/line-editor/screen-mode
handling — a shell stub (`trap ... HUP TERM; cat` or any lightly
extended variant of it) has no such states to approximate faithfully,
and forcing a pty-level proxy for them (as originally sketched above)
would answer a different, stub-specific question, not the one asked.
This round runs Point 1 only. Point 2 remains open, and would need
either the real `claude` CLI (a real hazard, ruled out for this round's
scope — victims here are stub sessions only) or a differently-scoped
future round to test.

### Cost note (told to the steward before starting, per instruction)

All sessions in this addendum, both arms and all state rows, are the
same cheap stub CLI every prior round has used (`trap ... HUP TERM;
cat`, or a lightly extended variant for states 2-5 above) — not the real
`claude` binary, zero API token cost, running inside the isolated
`ccb-repro-r6` Emacs daemon, which the live fleet's session cap does not
track. Reported to the steward before spinning up anything; proceeding
only after acknowledgement.

# Round 6 results — exit-control arm (Point 1 only; Point 2 untested)

Executed per the Round 6 pre-registration (`9cf2552`), addendum
(`30add76`), and the Point-2-untested correction (`c300cd0`). Raw logs
live in the executing fork's scratchpad (`ccb-repro/r6-out/*.txt`,
`*.calls.txt`), not committed.

## Observation (raw, machine-checkable)

Setup: fresh isolated `ccb-repro-r6` daemon, `claude-code-ide-cli-path`
confirmed = stub before any spawn, backend `ghostel`, cc-butler NOT
loaded (its concurrent-ghostel guard cannot fire). Each rep: 10 fresh
stub sessions S1..S10, all confirmed alive with 10 distinct native pids,
trigger on S10 (newest), 12 polls at 1s across S1..S9. Signature = the
stub's own `HUP <pid>` trap line + `ghostel--events-filter` "129" on the
bystander's own pipe + its buffer disappearing.

**Control (kill-buffer on S10), n=3:** bystander = S9 (creation position
N-1, the predecessor of the newest), 3/3; S1-S8 alive at +12s in all
three, no second bystander. Elisp `signal-process` targeted only S10's
own pid before S9 died; S9's own pid was signalled only after its "129"
event, in S9's own cleanup (c1: `.126 signal-process` S10's pid, `.145
EVENTS-FILTER "129"`, `.146 signal-process` S9's pid).

**Treatment (self-exit on S10), n=3:** 0 bystanders; S1-S9 alive at +12s
in all three, no HUP/TERM lines. Trigger = Ctrl-D written into S10's pty
(`ghostel-send-string "\C-d"`), so `cat` sees EOF and the stub ends
itself (`CAT-RETURNED`, `EXIT-TRAP`, reaper event "0"). `process-send-eof`
on the Lisp process object did not work (pipe, `process-id` nil) and was
not used. Independently re-checked by me on all three treatment logs:
between `TRIGGER-BEGIN` and `TRIGGER-END` no `kill-buffer`,
`delete-process`, or `signal-process` was logged.

**Unplanned observation, contradicts a premise of the steward's
question:** after a natural self-exit the buffer does NOT stay open.
~13ms after the "0" event, `ghostel--events-filter`/sentinel calls
`delete-process` and `signal-process 9` on S10's own already-dead pid,
then `claude-code-ide--cleanup-on-exit`, which calls `kill-buffer` on
S10's own buffer — automatic, on S10's own objects, no bystander
followed. In the kill arm the same teardown is entered through the live
`kill-buffer` with a `signal-process 9` on S10's LIVE pid, and the
bystander dies.

Deviations (from the fork, stated plainly): (1) a zsh word-splitting
slip made one run labelled `c` execute the self-exit branch; control
reps were rerun as c2/c3, net n=3 per arm (kill = c1,c2,c3; self-exit =
t1,c,t). (2) Consequently order was c1,t1,c,t,c2,c3, not interleaved;
c2/c3 ran in a slightly older daemon. (3) In c1 only, S1 restarted once
(stub exited and relaunched); no effect on S9/S10. (4) Stub timestamps
have `.3N` artefacts (BSD `date`); ordering taken from the Emacs-side
log. (5) The auto-cleanup-on-natural-exit behaviour was observed here,
not verified against the live daemon.

## Inference (separated from the above)

- Per the addendum's exact rule: control reproduced a bystander (3/3)
  AND self-exit did not (0/3), same N, same daemon ⇒ **"/exit safe"
  holds — for exactly this scope**: N=10, newest position only, stub
  sessions, Ctrl-D-on-pty trigger, one machine, one day, a daemon
  minutes old (~70 stub spawns).
- Rule C (predecessor of the newest dies) reproduced at N=10 under
  kill-buffer, 3/3 — the first N>4 data point; the Round 4 item 3 N=4
  anomaly concerned killing a MIDDLE position and is not contradicted.
- The result is consistent with (does not prove) the trigger being a
  signal delivered to a LIVE pid during teardown, rather than
  `kill-buffer` as such: the self-exit path also ends in `kill-buffer`
  on the session's own buffer, but only after the process is already
  dead, and produced no bystander. This is inference on n=3.
- The steward's proposed retirement sequence ("process exits on its own,
  buffer stays open, then roster-forget") does not match observed
  behaviour: the buffer is auto-killed by claude-code-ide's own cleanup.
  The observed safe path is "process exits on its own → auto-cleanup".

## Not tested / scope

Point 2 (state of the session receiving `/exit`) untested, as
pre-registered. Daemon age untested (explicit axis). Real `claude` CLI
`/exit` not tested (stub only; the optional real-session row was not
run). Self-exit of non-newest positions, N≠10, >3 reps not tested. The
real-CLI `/exit` may end differently than Ctrl-D-to-`cat` (e.g. exit
handler delays, child processes), which this round cannot speak to.

All `ccb-repro-r6` processes stopped; verified via `ps` by both the fork
and me: 0 ccb-repro, 0 stub, 0 zig processes, no r6 socket. Live daemon
never addressed.

# Round 6 follow-up (doc-only, no runs): status, queued round-7 row, gap ranking

Added after Round 6 results (`ed7a756`), on a follow-up from x600 via
butler. Insert-only; nothing above is rewritten. No experiment was run
for this section.

## Status line

**Self-exit clean for newest-position stubs only; untested for
non-newest.** Position is the disqualifying gap: both fleets retire OLD
idle sessions, never the newest, and Round 6 only exercised the newest
slot (S10 of 10). Round 6's "/exit safe" verdict therefore does NOT
cover the way sessions are actually retired in practice.

## Queued round-7 row (NOT run; HOLD stands)

Self-exit a NON-newest session (e.g. S3 of N=10, isolated daemon, stub
sessions, same Ctrl-D-into-pty trigger, no kill-buffer/delete-process/
signal-process from Lisp during the trigger). Check whether the
~13ms-late claude-code-ide cleanup (delete-process/signal-process on the
already-dead pid, then kill-buffer on the session's own buffer) still
lands with no bystander death. Purpose: separate the ORDERING hypothesis
(a signal to a LIVE pid during teardown is the trigger; the dead-pid
cleanup path is harmless whatever the slot) from the POSITION hypothesis
(the slot itself matters, e.g. creation-order effects on neighbours).
Include a PAIRED `kill-buffer` control on the same non-newest slot, same
N, same daemon; the self-exit row is only interpretable if the control
reproduces a bystander there (the Round 6 addendum's rule, unchanged).
Pass/fail and the exact interpretation table are to be pre-registered
before that round runs, not here.

## Ranking of uncovered items (most to least important)

1. Non-newest position (the queued round-7 row above).
2. Real `claude` CLI `/exit` (stub Ctrl-D-to-`cat` may differ: exit
   handlers, child processes).
3. Daemon age (the live daemon is long-lived; Round 6's was minutes old).
4. Other N.
