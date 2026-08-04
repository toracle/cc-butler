# Session handoff — cc-butler worker, 2026-08-04

Written because of a planned desktop move (disk survives, session context does
not). This is for a FRESH session with zero memory of today to pick up from.
Nothing new started after this was written; no subagents in flight.

## Standing hold — read this first

**#40, #41, #42 are filed and deliberately UNSTARTED. This is a hold, not
neglect.** cc-butler is infrastructure running live while it is being edited —
a launcher/tool change only affects sessions started after it lands, and
twelve-ish workers are live right now. The explicit instruction today was:
investigate and propose, do not implement, do not reload, do not restart the
session manager. **A fresh session reading "three open issues, nobody working
them" should NOT helpfully pick one up** — check with the steward/butler first;
the hold may still be in force.

Weekly usage cap is exhausted; fleet is on usage credits until **2026-08-05
19:00 KST**. Don't burn budget starting new implementation work before then
without checking that's actually authorized.

## What happened today, in order

1. **Governance-store hygiene** (earlier in the day, largely closed out):
   landed batches of untracked `governance/*.md` notes into git multiple times
   (recurring pattern — notes written directly with `Write`/`record_principle`
   sit untracked until someone catches it via `git status`). Also reconciled
   `main` with `origin/main` via merge (this repo's established convention —
   see `git log --oneline --merges`, no rebase commits anywhere in history).

2. **cc-butler#40** — filed, NOT implemented. `cc-butler-restore-sessions`
   (`cc-butler-persist.el:165-182`) drives a `dolist` over dead roster records
   through `cc-butler--resume-in` with **no error boundary**. One slow starter
   triggers `cc-butler--wait-for-session-ready`'s deliberate `error` (by
   design, cc-butler-session.el:1350-1352) and that aborts the ENTIRE batch —
   silently: later roster entries are never attempted, and the end message
   ("N recorded session(s) not running") can't distinguish "found N dead" from
   "aborted after N". Confirmed via a real 2026-08-04 incident (10:26 KST
   post-crash restore, launched 2 of 12, aborted on a session that was
   actually healthy — merely slow to paint its input row). **Important
   misattribution trap already caught**: the error message names `cc-butler#8`
   (closed 2026-07-21) — that's the CLOSED issue whose fix this readiness
   check IS; do not re-read this as a reopened #8. Confirmed via git log that
   the actual buggy code (`7abff86`, "Fix #8...") predates a later 45-commit
   pull entirely — #40 is NOT caused by that pull, it's a 2-week-old latent
   defect that simply had never been exercised by a real multi-session
   slow-starter before this crash. Workaround that actually recovered the
   fleet that morning (already used live, not hypothetical):
   `/home/toracle/.emacs.d/cc-butler/butler/docs/fleet-relaunch-2026-08-04.el`
   — wraps each `cc-butler--resume-in` call in `with-demoted-errors`, and
   evaluates its liveness guard at *fire time* inside each staggered timer
   (not at schedule time), because `cc-butler--resume-in` has no internal
   re-entrancy guard of its own.

3. **Session-list "jiggle" investigation** (정수님's original report, made
   just before a machine crash at ~06:05 KST that day): investigated via 3
   parallel subagents (git archaeology, render/refresh mechanism tracing,
   registry-vs-screen liveness tracing). Findings:
   - The pull 정수님 suspected (`a5b766f..d109c5c`, merged 2026-08-03 20:31 KST,
     45 commits / 11 days of backlog) DID include a genuine render-corruption
     fix (`9815cac`, "A render must not restart inside itself") — but **live,
     real-time inspection of the running daemon at the time of the report
     confirmed that fix was already loaded and NOT the active cause** (the
     `cc-butler--rendering` reentrancy guard was bound, value nil, not stuck).
   - Actual mechanism (CONFIRMED via source): `cc-butler--maybe-refresh` has
     **~11 undebounced call sites** (MCP tools like `report_to_steward`,
     `escalate_to_butler`, `send_to_session`, `set_session_info`, a
     notification hook, per-session poll timers) that each trigger a full
     `erase-buffer`+rebuild with zero coalescing — old architecture (day-1),
     but scales badly with fleet size (10-14 live sessions → frequent
     same-second collisions → visible flicker). This is the CONFIRMED root
     cause.
   - A second, related hypothesis (the ONE debounced path,
     `cc-butler--schedule-refresh`, uses `run-with-idle-timer 0.3s`, and
     Emacs's idle clock isn't reset by subprocess output, so it might degrade
     toward firing almost immediately under load) was tested via an isolated
     `emacs --batch` reproduction and came back **UNDETERMINED, honestly** —
     batch mode's `noninteractive` gates the whole idle-clock mechanism at the
     C layer, so `current-idle-time` never leaves `nil` and idle timers never
     fire at all in that harness, regardless of burst pattern. Three seeding
     attempts (fake input events, `execute-kbd-macro`, etc.) confirmed this is
     structural, not a fixable script. Testing it for real needs an actual
     interactive Emacs with genuine terminal input — i.e., the live daemon,
     which was explicitly off-limits (a live read-only `current-idle-time`
     probe was considered and correctly rejected: it would itself perturb the
     idle clock it's trying to measure — a self-confound, don't attempt it).
   - The frozen-but-reported-"running" registry gap (a session stuck at
     Claude Code's own `--continue` resume-gate chooser, but cc-butler's
     `process-live-p`-only liveness check calls it healthy) is **CONFIRMED
     unrelated to the pull** — unchanged since the package's very first
     commit (2026-07-03), already filed as **cc-butler#4**, deliberately
     still unimplemented ("landing a change there mid-incident is how you
     turn one bug into two" — direct quote from `docs/cc-butler-fleet-recovery.md`).
   - **Conclusion: TWO separate bugs (jiggle, #40), not one**, plus a third
     pre-existing unrelated item (#4). Proposed (NOT implemented) fix for the
     jiggle: route all ~11 undebounced call sites through the existing
     `cc-butler--schedule-refresh` debounce; separately, switching
     `run-with-idle-timer`→`run-with-timer` there is "validated-safe" (proven
     to coalesce correctly in the batch reproduction) but NOT
     "validated-necessary" (whether the idle-timer path was ever actually
     broken live remains unknown) — keep that distinction if anyone picks
     this up; don't claim more than was tested.

4. **cc-butler#41** — filed, NOT implemented, but essentially COMPLETE as an
   argument (see below), needs no further investigation, only a design
   decision + implementation whenever that's authorized. `record_principle`
   (and any direct `Write` to `governance/*.md`) writes into the store and
   never commits it to git — so notes sit untracked until someone happens to
   run `git status`. **Four same-day (2026-08-04) instances, four DISTINCT
   write paths**, documented in the issue comments
   (issuecomment-5166621317/5166706883/5166771418 from earlier context, plus
   issuecomment-5175150496 and -5175185537 from this session): governance
   notes via direct `Write`, governance notes via `record_principle` (steward's
   own AWS-ruling note — the strongest instance: `record_principle` verified
   the note existed on disk and reported success, and THAT verification is
   exactly what makes the missing-commit gap invisible — "verified written" ≠
   "verified durable"), this session's own `docs/proposal-worker-aws-isolation.md`
   (plain `Write`, no git integration at all), and — the sharpest instance,
   about the fleet itself — **the butler's own home repo
   `~/.emacs.d/cc-butler/butler` had ZERO commits and no remote all day**:
   `dashboard.org`, the daily log, every steward handoff (including whatever
   this exact clear-and-rehydrate procedure depends on) existed only as loose
   files on one disk until the butler fixed it today. One `git status` would
   have caught it. This is a CLASS of bug now, not one tool's defect — see
   #41 for the full argument, nothing further to add there without a design
   decision.

5. **cc-butler#42** — filed, NOT implemented. Workers only have
   `report_to_steward`; there's no worker-reachable `report_to_butler`. When
   the butler dispatches directly to a worker (bypassing the steward), the
   worker's result still routes to the steward by construction, who then has
   to spend a turn forwarding it — defeating the point of direct dispatch.
   Three options sketched in the issue (follow-the-dispatcher metadata, a
   parallel `report_to_butler` tool, one unified tool branching on dispatch
   metadata) — deliberately NOT decided. Also carries a second, related
   hazard found today: the steward and a worker can commit to the **same
   checkout** (`/home/toracle/projects/cc-butler`) simultaneously with no
   isolation — today it stayed clean only because both sides happened to use
   scoped `git add <path>` rather than `-A`; that's a coincidence, not a
   design. Fix sketched (not chosen): continued scoped-add discipline (relies
   on habit) vs. an actual `git worktree` per concurrent writer (enforced,
   costs setup).

6. **AWS worker-isolation proposal** — `docs/proposal-worker-aws-isolation.md`
   (this file's sibling), committed as `750a22c`, pushed. Full technical
   proposal (not implemented) for making AWS profiles unreachable from
   worker-launched sessions, per 정수님's ruling ("워커는 가급적 AWS profile을
   읽거나 사용할 수 없게 합시다"). Summary: one shared launch chokepoint
   (`cc-butler--with-channel`, `cc-butler-session.el:38-44`, used identically
   by both `cc-butler--launch-session` and `cc-butler--resume-in`) is where a
   `process-environment` override would redirect `AWS_CONFIG_FILE`/
   `AWS_SHARED_CREDENTIALS_FILE` to empty paths AND set `CLAUDE_CONFIG_DIR` to
   a fleet-only settings.json carrying a `Bash(aws *)` deny-rule. One
   unverified link (honestly flagged, not assumed): `ghostel-exec`'s own
   internals were never read, so whether `process-environment` survives all
   the way to the OS-level spawn is inferred (surrounding code appends rather
   than resets), not observed. One design gap (fine-with-a-caveat, not
   unsafe): today's launch path has zero role branching — butler, steward,
   worker are the literal same function call — so uniform denial is the
   *cheap* default, but a future butler/steward exception would need new
   plumbing that doesn't exist today. The two genuinely-AWS-needing tracks
   (prd-bastion policy confirmation on `monocle-stark`, the 16-scheduler CDK
   deploy on `monocle-jarvice-stg`) are explicitly routed to a cred-host, CI,
   or 정수님 by hand — never back through a reopened worker hole. Cutover
   note: this only ever affects sessions *launched after* the change loads;
   the fix does not retroactively touch already-live worker processes'
   environment, so full fleet coverage is gradual (next natural
   restart/crash-recovery) unless 정수님 separately decides an immediate
   blanket restart is worth the disruption — that's a distinct decision from
   "land the fix."

## Open questions worth recording, not resolving

- **Where does durable fleet state belong, and is its content safe on a
  remote?** This is a design decision for 정수님, not a chore for a worker to
  default on. Triggered today because the butler's own home repo had no
  remote at all, making the fleet's own "externalize to git, PUSHED" gate
  literally unmeetable for its own operational state.
- Whether `record_principle`/`regenerate_governance` (and any future
  `Write`-based store mutation) should auto-commit — raised earlier, still
  undecided, not to be decided unilaterally by a worker.
- Whether an immediate blanket restart of all live workers is worth doing to
  close the AWS-isolation gap faster than gradual natural attrition, IF/WHEN
  that proposal is ever approved and implemented — not now, not without a
  separate explicit decision.

## What is NOT in flight

No subagents running. No uncommitted code changes anywhere in
`/home/toracle/projects/cc-butler` beyond this handoff file itself (verify with
`git status` — should show nothing else, or only this file, at the moment this
was written). No push attempted for THIS file yet — see the commit this
accompanied for that status, reported separately via `report_to_steward` per
standing practice (post-status and commit-status as separate facts, never
merged into one word).
