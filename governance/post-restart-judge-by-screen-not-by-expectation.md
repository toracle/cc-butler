---
name: butler-post-restart-judge-by-screen-not-by-expectation
description: "After a host restart, three plausible reads of a recovered fleet were wrong — judge each session by its screen, never by a prior expectation, a context number, or a batch tool's exit"
metadata:
  node_type: memory
  type: feedback
---

After an OS/machine restart, decide every session's state by READING ITS SCREEN. A prior expectation, a context figure, and a restore command's outcome are all claims about the fleet, and on 2026-08-04 all three were wrong in the same hour — each in a way that reads as solid evidence.

**Why:**

Three specific misreads, from one recovery of a 12-worker fleet:

1. *The stuck-rate expectation was badly miscalibrated.* The older note `steward-post-restart-fleet-recovery` says "~half the fleet sits frozen at the resume-gate chooser." This time it was **1 of 12**, not 6. Had we swept on the expectation instead of the screens, we would have hunted five sessions that were never stuck. The reliable tell held, though: the frozen one was the only session showing **no model** in `list_claude_sessions`, and its screen carried the chooser verbatim. Unstick with `1`.

2. *CTX=0 does not mean context was lost.* `monocle-16-scheduler` reported `CTX=0 0%` — indistinguishable from a session that came up fresh and empty. Its screen showed the resume banner, restored skills, and references to its own prior outputs: the transcript was fully restored, and the counter simply is not charged until the session's first turn. The steward that came back genuinely empty looked identical on the meter.

3. *A batch restore's abort says nothing about the sessions it names.* `M-x cc-butler-restore-sessions` died after 2 of 12 with an error naming `monocle-jarvice-1130` — which was alive and perfectly healthy, merely slower than the 5s readiness check (cc-butler#8). The error was about the check's timing, not the session's health.

**How to apply:**

- Sweep with `list_claude_sessions`, then confirm each session with `read_session_output`. A registry row, a context number, and a command's exit code are all secondary to the screen.
- Missing model in the listing → likely at the resume-gate chooser → confirm on screen → send `1`.
- Treat `CTX=0` as *unknown*, not as *lost*. Look for the resume banner before concluding a session needs rehydrating.
- When a launch/restore tool errors while naming a session, check that session before believing it failed — the failure may be in the verification, not the thing verified.
- Before the first `send_to_session` to any recovered worker, check its input row: a restart can leave real unsubmitted text there (`monocle-skills` held a stray `2`), and your message will be concatenated onto it as `2<your text>`. Clear it first.

This corrects, and should be read alongside, the older `steward-post-restart-fleet-recovery` note; it is the same discipline as `steward-verify-the-running-artifact` and `suspiciously-uniform-is-the-instruments-fingerprint` applied to fleet recovery.
