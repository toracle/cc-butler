---
name: butler-good-worker-behavior-is-quiet-so-salience-tracks-noise-not-importance
description: "'A worker that parks correctly, respects a scope boundary, or mentions a finding in passing produces the LOWEST-salience output precisely when it is behaving best — so the fleet's oldest unattended work hides in silences and trailing sentences, not in anything that announces itself'"
metadata:
  node_type: memory
  type: feedback
---

A well-behaved worker is **quiet**. It parks instead of pestering, it declines to touch what is out of scope, and it mentions the thing it noticed on the way past as a subordinate clause. Every one of those is the discipline working — and every one produces output with **almost no salience**.

The consequence is uncomfortable: **attention flows to noise, and age accumulates in silence.** The better the fleet behaves, the more systematically the steward's attention mis-allocates. Nothing is broken, no one is careless, and the oldest unattended item is invisible by construction.

**Why:** 2026-08-08 evening, three instances inside one hour, all found only because an idle window prompted a look rather than a report demanding one:

1. **`monocle-skills` — silence read as noise.** The fleet-check hook had been emitting *"N workers waiting a while — could be a stuck dialog"* for hours and the steward had classified it as routine. Actually opening the flagged sessions found one still holding an offer to run a census script that answered a question already resolved. The hook was right the whole time; it had been correct so often that its correctness became background.

2. **`monocle-iros` — correct parking made a four-day block invisible.** The worker finished a shutdown handoff on 08-04, committed and pushed it, reported, and stopped — exactly per discipline. Three items needing 정수님 (four credentials, and two product decisions) never reached the dashboard, so **he was never given the chance to answer for four days**. Meanwhile the branch drifted to 130 commits behind `main`, and its own handoff said *"open the PR before the branch ages further."* A worker that had behaved worse — nagged, or left the thread visibly open — would have been handled sooner. Compare [[butler-externalizing-is-not-delivering]]: there the artifact existed and no one was told; here the *waiting* existed and no one was told.

3. **`uv.lock` — the real finding was a trailing clause.** In a report about a rebase, the last sentence noted an unrelated dirty `uv.lock` left untouched as out of scope. That aside turned out to be a four-week-old defect: `devel`'s lockfile out of sync with its own `pyproject.toml`, pinning `pillow 12.2.0` against a declared `pillow<12` cap that exists because Lambda's AL2 glibc 2.26 cannot load pillow 12.x wheels (`monocle-tool-server#215`). The worker was *right* not to fix it — regenerating a lockfile changes workspace-wide resolution and had it "tidied up," 167 lines of dependency change would have ridden inside an unrelated PR. Correct restraint, reported correctly, in the least prominent position available.

Note what unites them: in each case the worker did the right thing, and doing the right thing is what made the signal faint.

**How to apply:**

- **Read the last paragraph of a report as carefully as the first.** Findings a worker judges out of scope get demoted to a closing aside — and out-of-scope is uncorrelated with unimportant. It usually means *nobody owns this*, which is why it is old.
- **When a worker says "I noticed X but left it alone," that is a handoff, not a footnote.** Confirm the restraint was right (it usually is), then decide who owns X. Restraint plus no owner equals another four weeks.
- **A quietly parked worker is a claim you have not checked.** Periodically open long-idle sessions instead of reasoning about them. "Waiting" describes the session, not whether anything is owed to someone outside it.
- **Do not let a recurring warning become background.** A hook that is usually routine is not thereby always routine; the cost of opening four screens is minutes, and the thing it catches has by then been aging for days.
- **Blocked-on-a-human is the highest-decay state in the fleet.** It looks identical to progress from outside and costs nothing to maintain, so it survives indefinitely. Anything a worker awaits from the human belongs on the dashboard the moment it is known — see [[butler-a-hold-is-not-a-decision-until-he-hears-it]].
- **Use idle windows for sweeps, not for waiting.** All three of these surfaced while the fleet was parked awaiting approvals. Idle time is when low-salience state is discoverable, because nothing louder is competing.
- Related: [[butler-worker-context-hygiene]] (the same shape for handoff docs — a doc appended-to but never re-entered goes stale at its entry point), [[butler-an-offer-of-next-steps-is-a-question]].
