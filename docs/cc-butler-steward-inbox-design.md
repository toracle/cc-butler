# A batched steward inbox — design only, no code

Status: **design proposal, no code written**, per
`~/.emacs.d/cc-butler/butler/docs/butler-brief-2026-08-03-steward-inbox-design.md`
(정수님 approved design-only). Session: `cc-butler-general` (this one), per the
brief's own assignment — same root as the compaction driver.

**Three premises are corrected before anything else, since designing on top
of a wrong one would build on sand.** The first two are the brief's own
stale premises; the third is a correction to this document's own first
draft, caught by the steward before this reached 정수님 — recorded here
rather than silently fixed, per this project's standing practice of leaving
the trail visible.

0. **This document's own first draft claimed the notification hook was
   pull-only, like `report_to_steward`. That was wrong — confirmed wrong by
   both static code and a live runtime query.** `cc-butler-orchestrator.el
   :975-989`, `cc-butler--forward-to-ops`, is *also* registered on
   `cc-butler-notification-functions` (`:994`), alongside
   `cc-butler--queue-on-notification`. It calls `cc-butler--send-input`
   directly — types `"[cc-butler] Worker %s needs attention: %s"` into the
   ops session's terminal and, when `cc-butler-forward` is `'submit` (its
   defcustom default, `:949-956`), presses Return too. A live introspection
   query on the running fleet (not just the file) confirmed `cc-butler-
   forward` is currently set to `submit` and both hooks are active. The
   only skip conditions in `cc-butler--forward-to-ops` are the notifying
   session being the ops session itself, or no live ops buffer — neither
   applies to routine worker traffic. **So the per-event interrupt is not
   an over-applied governance policy; it is this specific, currently-active
   forwarder, unconditionally submitting on every worker notification.**
   This changes the recommended intervention point below (batch *this
   function*, not edit a `.md` file) but not the shape of the fix — see
   "How ten queued costs one turn," corrected.
1. **"압축이 조용해야 걸린다" is no longer the problem it was.** PR #35
   (merged) added `ignore-busy`/`force=true` to the compaction driver. Since
   merge, 5 live force-compactions have run on real fleet sessions —
   context drop and model restore both independently confirmed each time.
   The brief's requirement 4 ("compaction interaction") is consequently much
   smaller than the brief assumed; see the dedicated section below.
2. **Every `cc-butler-compact.el` line number the brief cites (`:457`,
   `:439`, `:772`) is stale, and worse, may have been read from the wrong
   copy.** `(symbol-file 'cc-butler-compact--menu-p 'defun)` inside the
   running Emacs resolves to
   `/Users/jeongsoopark/projects/cc-butler-general/cc-butler/cc-butler-compact.el`
   — **not** `~/projects/cc-butler/`, which is what `locate-library`
   misleadingly suggests (that's a `load-path` artifact, not what's
   actually loaded — confirmed independently in this session, matching the
   steward's own finding by the same method). Every citation below was
   re-verified against the `cc-butler-general` copy directly.

## Diagnosis, re-verified against the live copy

### How a worker event reaches the steward today

Claude Code's own notification hook fires `cc-butler-emit-notification`,
which runs the `cc-butler-notification-functions` abnormal hook. **Two
listeners are on it, and they do different things:**

- `cc-butler--queue-on-notification` (`cc-butler-notifications.el:184-192`)
  marks the session waiting, pushes into the in-memory inbox
  (`cc-butler--inbox-push`, `cc-butler-session.el:480`), and triggers a
  dashboard repaint. Pull-only, as originally stated.
- `cc-butler--forward-to-ops` (`cc-butler-orchestrator.el:975-989`, hooked
  at `:994`) calls `cc-butler--send-input` directly on the ops (steward)
  session: types `"[cc-butler] Worker %s needs attention: %s"` and, because
  `cc-butler-forward` defaults to `'submit` (`:949-956`) and is confirmed
  set to `submit` on the running fleet, **presses Return too.** This is an
  unconditional, structural interrupt — every worker notification becomes a
  steward turn, by design, right now. (Premise 0 above.)

`report_to_steward` (`cc-butler-tool-report-to-steward`,
`cc-butler-orchestrator.el:1282-1318`) is genuinely pull-only, as
originally stated — it writes into `cc-butler--inbox`/maildir and refreshes
the dashboard, no terminal write. `pending_events`
(`cc-butler-tool-inbox`, `:1326-1354`) drains that queue on pull, and a
`UserPromptSubmit` hook (`check-pending-events.sh`,
`cc-butler--pending-events-hook-sh`, `:684-723`) already re-drains it into
whatever turn the steward next takes, as `additionalContext` — for free, no
extra turn spent.

**So the interrupt-per-event problem is not a governance policy applied too
broadly — it is `cc-butler--forward-to-ops` itself, currently wired to
submit unconditionally.**
[`governance/report-up-is-a-push.md`](../governance/report-up-is-a-push.md)
is a real policy (written after a 2026-07-13 incident where the steward
treated `escalate_to_butler` + dashboard as a report and the butler, waiting
for one, never got it) and remains correct for the case it was written for
— an explicitly-acknowledged dispatch. It is not, on inspection, the cause
of the ambient per-notification interrupt; that lever is `cc-butler-forward`
and its forwarder function, not a `.md` file. `cc-butler--send-input`
(`cc-butler-orchestrator.el:236-271`, both `send_to_session` and the
forwarder's underlying primitive) types text and presses Return
unconditionally — there is no batching, no busy-check, no coalescing at
that layer, by design (it is a direct, synchronous write) — which is
exactly why the fix belongs one level up, wrapping the caller, not that
primitive.

### `pending_decisions` — the existing analogue for `butler` — and why it works

`escalate_to_butler` (`cc-butler-tool-escalate-to-butler`,
`cc-butler-orchestrator.el:1024-1053`) pushes into `cc-butler--butler-inbox`
or the maildir (`cc-butler-mail-up-decision`, `cc-butler-mail.el:199`) —
**deliver-only, no poke**, structurally identical to `report_to_steward`.
`pending_decisions` drains it, and the same `UserPromptSubmit`-hook pattern
re-injects backlog into whatever turn the butler next takes
(`check-pending-decisions.sh`, `:625-682`). It delivers "N queued, one
drain" *because nothing ever pokes the butler on arrival* — the butler's
turns are driven by 정수님 talking to it directly, an external cadence that
already exists for other reasons. **The steward has no equivalent external
cadence.** That asymmetry — not a missing queue — is the actual gap, and is
the central problem this design has to solve: a pull queue with no reliable
puller eventually means requirement 3 ("아무도 안 깨우면 영영 잠") happens for
real, which is exactly the failure `report-up-is-a-push.md` was written to
prevent. **The fix is not "always push" (today's answer, and the cause of
the interrupt storm) or "never push" (requirement 3's failure) — it is a
bounded, self-driven cadence, detailed below.**

## #39 as a corroborating constraint, not just a mention

`cc-butler#39` (filed the same day) found that `read_session_output` returns
ambiguous empty output for sessions at ~0k context, and — more relevantly
here — that the compaction driver's own menu-open guard
(`cc-butler-compact--menu-p`, riding `cc-butler--read-output`) shares that
same degraded path and fails silent-negative on those sessions. Two
consequences for this design specifically:

- **Any new wake-decision logic in this design must not be built on
  screen-scraping.** The classification of "is this worker event
  wake-worthy" should key off structured data already available at the
  call site (the `report_to_steward`/`escalate_to_butler` arguments
  themselves, or the notification event's own `:body`/`:title` plist keys)
  — never a fresh terminal read of the *reporting* session, which may
  itself be near-0k and degraded.
- **This directly reinforces the brief's optional third axis** (steward's
  fleet model belongs in files, not live context) for a second, independent
  reason beyond "compaction summaries are lossy": once a session is
  compacted to 0k, recovering anything from its *screen* afterward is
  exactly the unreliable path #39 documents. Anything that must survive a
  compaction — the steward's own model of the fleet, or anyone else's need
  to reconstruct what a just-compacted session was doing — has to live in a
  file/log/transcript-mtime-based read, not a screen read.

## Proposed design

### The wake / no-wake boundary

Per the brief's requirement 1, almost verbatim:

- **No-wake (dashboard/pull only):** routine state changes — a worker
  finished, a worker is waiting for input with nothing further asked, a
  worker's notification carries no `needs` (or `needs` is absent/"nothing").
  These already land in `cc-butler--inbox`/maildir via the existing
  mechanisms above; nothing new is required for them to be *visible* — what
  changes is that they stop being independently typed into the steward's
  terminal.
- **Wake-worthy (should eventually reach the steward as an active
  interrupt):** blocked, failed, or an explicit non-empty `needs` — i.e.
  exactly the signal `report_to_steward`'s own schema already carries
  (`summary`/`status`/`needs`, `cc-butler-orchestrator.el:1282`). No new
  event-classification vocabulary is needed; the existing tool arguments
  already distinguish "informing" from "needs a decision" (an empty/absent
  `needs` vs. a real one) — this design proposes *acting* on that
  distinction, not inventing it.

The paragraph above covers **tool-reported** traffic only. Events arriving
on the raw notification hook are classified by the next section — decided
separately (Q4), because the `needs` rule structurally cannot reach them.

### Raw-event wake classification — decided design (2026-08-10)

**Decision (steward, 2026-08-10): raw events are never blanket no-wake.
Classification is an allowlist of explicitly-harmless no-wake types; every
raw event not on it wakes.** Rationale as decided: a worker blocked on a
permission prompt cannot call any tool — `report_to_steward` is unreachable
from exactly the state that most needs a wake — so any rule of the form
"only tool-reported `needs` wakes" silences the most dangerous case. A
denylist ages with every new risk and its failure is silent; an allowlist
excludes the unknown by default, and in this gap the silent side is the
dangerous side.

**What the classifier actually has to key on.** The event path is: Claude
Code emits an OSC 9 / OSC 777 terminal notification → ghostel's native
parser (`ghostel--handle-notification`) → `cc-butler--on-ghostel-notification`
(`cc-butler-notifications.el:64-81`) → the EVENT plist
(`:title`/`:body`/`:buffer`/`:session`/`:name`). Claude Code's
notifications are OSC 9-style, which carries **no separate title** —
ghostel passes the message as `body` with an empty title
(`ghostel-default-notify`'s docstring records this). So the only
classification keys that exist at this layer are **the body string and the
session identity**; there is no event-type enum anywhere in the path.
Every classifier is therefore string matching on harness-emitted text,
which can drift across Claude Code versions — and this is the second
reason the allowlist direction is right: **default-wake makes string drift
fail-visible.** A changed string falls out of the allowlist and produces
extra wakes (noise that announces itself and prompts an allowlist update);
under a denylist the same drift silences events, and nothing announces
that.

**Observed inventory (2026-08-10, ~10-worker fleet, steward's live
observation — recorded here as the empirical basis, per the decision):**

| Raw event body | Observed | Worker state | Disposition |
|---|---|---|---|
| "Claude needs your permission to use …" | permission prompts | fully blocked, cannot call tools | **wake** — the motivating case |
| "Claude is waiting for your input" | dozens/day | ambiguous — see below | **deferred wake** |
| turn-finished / done-type bodies | routine | free; can call `report_to_steward` if anything is actually needed | **no-wake** (allowlist) |
| anything unrecognized | — | unknown | **wake** (by construction) |

The initial no-wake allowlist is exactly the done-type bodies: the only
events where the worker is both not blocked and able to use the tool path
for anything real. The allowlist lives in one inspectable defcustom — a
list of body patterns with a disposition each (`no-wake` / `wake` /
`deferred`), defaulting conservative (empty list = everything wakes).
Events with `:session nil` (unmanaged buffers) keep today's behavior and
are out of scope.

**"Claude is waiting for your input" — the one genuinely ambiguous type.**
The steward's live observation: of the dozens received on 2026-08-10, a
large share were harmless idle — a worker waiting on its own background
subagent, where the harness emits the idle notification even though the
session is mid-orchestration — and some were genuine waiting-for-a-reply.
Telling them apart today required reading each session's screen: a
per-event cost paid every few minutes, and precisely the degraded
screen-read path the #39 constraint forbids this design from building on.
So this classification problem is not hypothetical; it is a cost being
paid on every fleet turn right now.

Under a plain allowlist this type must wake (ambiguous is not harmless) —
but dozens of mostly-harmless wakes per day reproduces the interrupt storm
this design exists to kill. Proposed disposition: **deferred wake.**

- On arrival: land in the inbox as always (durable, visible), no push;
  start or refresh a per-session deferral clock.
- The two meanings differ in what happens *next*, and that difference is
  visible in structured data: a worker idling on its own subagent resumes
  by itself — its transcript advances when the subagent completes. A
  worker genuinely waiting for a reply stays static until someone answers.
  So: if the session's transcript mtime (the same file-based read
  `cc-butler--transcript-idle-p` already uses — a file stat, not a screen
  read) shows no progress for a deferral window W, escalate to wake.
- **Stated honestly: this does not fully separate the two meanings.** A
  worker waiting W-plus minutes on one long-running subagent looks, in
  transcript mtime, identical to one waiting for a human — its main
  transcript is static until the subagent completes. The deferral
  therefore errs toward wake (the safe direction), and what it buys is a
  bound, not a resolution: dozens of immediate interrupts become at most
  one deferred wake per session per window, coalesced further by the
  busy-gate's batching. Known caveat, already documented on branch
  `fix/status-context-liveness-threshold`: transcript mtime tracks file
  writes, not turns — advancing mtime proves activity; static mtime is
  what W interprets.
- Rejected alternative: inferring "has live background tasks" by reading
  the harness's own task/session files on disk. Possible, but couples the
  gate to undocumented harness-internal layout — a worse version of the
  string-matching fragility above, without the fail-visible property.

**Unclassifiable residue — the honest answer to "does any type remain?":
yes, this one, partially.** The idle event's two meanings cannot be
separated by any structured signal available at this layer (body, session,
file mtimes); deferred wake bounds the cost of the ambiguity without
resolving it. Resolving it for real requires the emitter to say *why* it
is waiting — Claude Code currently emits the same body string whether or
not background tasks are running when the turn ends. That is an upstream
observation worth filing, not something this design can fix from below.

### How "ten queued costs one turn" is actually guaranteed

The concrete intervention point is `cc-butler--forward-to-ops`
(`cc-butler-orchestrator.el:975-989`) itself — not a governance document.
Reuse three mechanisms that already exist in this exact codebase around it,
rather than building a fourth queueing system:

1. **Replace the forwarder's unconditional submit with a debounced,
   gated one.** `cc-butler-forward` is already a defcustom with a `nil`
   option (`:949-956`) — turning per-event forwarding off entirely is
   already one config change away, but *only* off is not enough on its own
   (see point 3). The actual fix: when a wake-worthy notification arrives,
   check `cc-butler--transcript-idle-p` (`cc-butler-session.el:300`,
   already used by the compaction busy-guard) on the steward's own dir. If
   the steward is free, push **once**, summarizing *everything currently
   sitting in the inbox* — not just the triggering item. If ten wake-worthy
   events land while the steward is mid-turn, none of them push
   individually; they sit in the existing durable inbox
   (`cc-butler--inbox`/maildir, already populated by
   `cc-butler--queue-on-notification` regardless of what the forwarder
   does). This is a small, isolated change — one function, already sitting
   alone on one hook — not a rewrite.
2. **Free absorption on the steward's own next turn.** The
   `UserPromptSubmit` hook pattern that already drains `pending_events` into
   `additionalContext` for free (`:684-723`) needs no change to do the same
   for whatever piled up while the steward was busy — the moment the
   steward next turns for *any* reason, the backlog rides along at zero
   extra-turn cost. This is the same mechanism `pending_decisions` already
   relies on for butler.
3. **A periodic backstop, same shape as the existing 900s fleet monitor**
   (`cc-butler-compact-monitor-interval`, `cc-butler-compact.el:1162`,
   registered via `run-with-timer` at `:1318`) — **and this one is not
   optional, it's the other half of point 1.** Once
   `cc-butler--forward-to-ops` stops submitting per-event, the only thing
   that ever gets the steward to turn is either an organic turn for some
   unrelated reason (point 2) or this timer — the `UserPromptSubmit` hook
   that drains `pending_events` only fires when a *prompt* already arrives,
   it does not itself generate one. Batching without this backstop just
   reproduces requirement 3's failure ("아무도 안 깨우면 영영 잠") in a new
   form: turn the forwarder to `nil` alone, with nothing to replace its
   waking role, and the steward stops being woken at all. So the timer
   checks: is the inbox still non-empty, and did no organic turn/drain
   happen during the whole interval? If so, fire exactly one push. This is
   what actually satisfies requirement 3 — a bounded worst case (one
   interval) instead of "however long until someone notices," which is
   what happened to today's relay-loss incident (see below).

Point 1 already gives single genuine escalations the same low latency they
have today when the steward is free — batching only kicks in under actual
congestion (steward busy, backlog piling up), which is exactly where the
brief's "10 events, 10 turns" complaint actually bites.

### Compaction interaction — smaller than the brief assumed, but not zero

`cc-butler-compact-large-sessions` (`cc-butler-compact.el:1115-1150`) already
calls `cc-butler-compact--blocked-reason` with `ignore-busy = t`
(`:1134`), and its docstring is explicit that butler/steward are
deliberately not excluded (`:453-455`, `:1122-1129`): **an over-threshold
coordinator is compacted regardless of how busy it is.** So the specific
fear in the brief's requirement 4 — "큐 드레인이 idle window를 리셋하면 아무것도
나아지지 않습니다" — does not apply to the sweep path at all; busy was never
a blocker there to begin with, before or after this design.

What *isn't* automatic: the 900s monitor only **reports** an over-threshold
candidate (`cc-butler-compact--report-to-ops`, `:1267-1291`); nothing
currently invokes `compact_large_sessions` on its own. That gap is
independent of this design and is a genuine open choice (see below) rather
than something this design needs to solve to satisfy requirement 4.

### Durability-first delivery — how this handles today's relay-loss incident

The brief's "don't add layers" instruction explicitly requires that any
pushback address how today's relay failure would be handled. Concretely:
butler's `send_to_session` toward the steward timed out, and the content
survived only because it happened to also be saved to a file — not because
the delivery path itself is durable. `cc-butler--send-input` is a direct,
synchronous terminal write with no queue behind it; if the type-and-Return
doesn't land, there is nothing left to retry from.

This design's answer: **every item aimed at the steward is written to the
existing durable inbox/maildir first, and a live push (point 1 above) is
always a best-effort accelerant on top of that write, never the only copy.**
`report_to_steward` already does this today (it writes to
`cc-butler--inbox`/maildir before anything else). The change is to make
`send_to_session`-based escalations follow the same rule — write durably,
then attempt the push — so a failed/timed-out push degrades to "picked up
at the next organic turn or at the next backstop tick" (bounded by the
timer interval) instead of "gone until someone happens to notice a file."

### On "don't add layers"

The brief's prohibition is specifically about **not inserting a new
intermediary session/process** between butler and steward or between worker
and steward ("중간 관리자") — the brief's own reasoning cites hop count and
today's relay losses. Nothing proposed here adds a hop: the debounce gate
and the backstop timer live *inside* the same `cc-butler-general` session
the brief already assigned, reading and writing the same inbox structures
that already exist. No new session, no new process, no new party in the
relay path. What changes is *when* the existing steward process reacts to
what has already arrived, plus (per the point above) making sure it arrives
durably before anything tries to push it live. That is a scope distinction
worth stating explicitly, since "layer" could otherwise be misread to
prohibit this too.

## What gets dropped — nothing silently

Per the brief's explicit "조용히 잃는 것이 최악": nothing described here
removes any event from existing storage. Routine state changes stop being
independently typed into the steward's terminal — they still land in
`cc-butler--inbox`/maildir and are visible via `pending_events`/dashboard/
`session_status`, exactly as they are today. The one real, named tradeoff:
**a wake-worthy event that arrives while the steward is busy waits up to one
backstop interval before an active push, if no organic turn happens
sooner.** That interval is a tunable (proposed default: reuse
`cc-butler-compact-monitor-interval`'s existing 900s, or a shorter,
separately-configurable value if 15 minutes of worst-case delay for a
genuine escalation is judged too slow) — this is the one number a human
should set deliberately rather than have it default silently.

## Migration

Everything above is new Elisp: wrapping `cc-butler--forward-to-ops` with the
gate in point 1, plus one new timer registration for point 3. No
documentation/policy change is required for this to work —
`report-up-is-a-push.md` turned out not to be the cause (premise 0), so
revising it, if done at all, is independent cleanup, not a dependency of
this migration. Loadable the same way every change this session has been
loaded and tested:
`cc-butler-use-checkout` to point the live fleet at a branch, `
reload_butler_code` to hot-swap without restarting Emacs or dropping any
session, exactly the process PR #35 went through. No fleet restart, no
session loss, is required at any point.

## Explicitly not proposed

- Auto-invoking `compact_large_sessions` from the monitor timer without a
  human/steward decision — that's a separate, currently-open question (see
  below), not something this inbox design needs in order to satisfy
  requirement 4.
- Any new intermediary session between butler/worker and steward.
- Changing what `pending_events`/`escalate_to_butler`/`report_to_steward`
  store or how they're drained on pull — only when/whether a *live push*
  additionally happens changes.
- Implementing any of this. Per the brief: design only.

## Related defect in the primitive this forwarder calls

`cc-butler--forward-to-ops` writes through `cc-butler--send-input`
(`cc-butler-orchestrator.el:236-271`), which has its own, separate atomicity
defect: a `sleep-for` yield between typing and submitting lets another
cc-butler timer interleave mid-sequence. That defect and its fix are
covered in `send-input-atomicity-proposal.md` — this design's debounce/gate
around the forwarder does not fix it, and the two documents should be read
together rather than either being closed as if it covered the other.

## Open questions — decision sheet (consolidated 2026-08-10)

Q1–Q3 carry over from this document's first draft; Q4–Q6 were surfaced by a
re-read of the full design on 2026-08-10. Options are laid out with their
tradeoffs; none was chosen by this document's author — every item went up.

**Status after the steward's 2026-08-10 ruling:** Q3 → decided (B: leave
as-is plus one cross-reference line — applied, see
`governance/report-up-is-a-push.md`). Q4 → decided in direction
(allowlist, default-wake) — the worked-out design is the "Raw-event wake
classification" section above. Q5 → decided (A: atomicity fix lands first;
C explicitly rejected as a baby-step violation, and a gate landed first
would be validated on a non-atomic send, so a gate failure could not be
attributed). Q1, Q2, Q6 → escalated to 정수님, pending (Q2 carries the
steward's endorsement of the decoupling argument: reusing 900s silently
couples escalation latency to compaction tuning, so a separate knob is
right regardless of the value chosen).

### Q1 — should the 900s monitor auto-invoke compaction, or keep reporting only?

Today `cc-butler-compact--report-to-ops` (`cc-butler-compact.el:1267-1291`)
only *reports* an over-threshold candidate; nothing invokes
`compact_large_sessions` unprompted. `force=true` (PR #35) removed the
mechanical blocker, so this is now purely a human-in-the-loop question.

- **A. Status quo (report-only).** A human sees every coordinator compaction
  before it happens. Cost: an over-threshold session sits at 400k+ until
  someone acts — the exact pressure class behind the 2026-08-09 host
  resource crisis — and the report itself is one more steward interrupt.
- **B. Auto-invoke for everything over threshold.** Ceiling enforcement gets
  a bounded worst case with no human latency. Cost: compaction is lossy, and
  a timer — not a person — picks the moment a mid-investigation coordinator
  loses its nuance; per the #39 constraint above, post-compact
  reconstruction from a screen is unreliable, so this option *upgrades the
  brief's optional third axis (fleet state in files) from nice-to-have to
  prerequisite.*
- **C. Auto for workers, report-only for butler/steward.** Limits blast
  radius to sessions whose state is more often externalized (PRs, files,
  reports). Cost: `compact_large_sessions`'s own docstring deliberately
  refuses to exempt coordinators (`:453-455`, `:1122-1129`) — C quietly
  reintroduces the exemption that decision removed, and coordinators are
  precisely the sessions that grow largest.

### Q2 — backstop interval: reuse 900s, or a separate shorter knob?

The one named tradeoff of the whole design: a wake-worthy event arriving
while the steward is busy waits up to one backstop interval.

- **A. Reuse `cc-butler-compact-monitor-interval` (900s).** Zero new knobs.
  Cost: a genuine escalation can wait 15 minutes worst-case, and the two
  timers become silently coupled — retuning the compaction monitor later
  would retune escalation latency as a side effect nobody asked for.
- **B. Separate defcustom, shorter (e.g. 120–300s).** Bounded latency close
  to today's per-event behavior under congestion; decoupled from compaction
  tuning. Cost: one more tunable, and more empty-inbox timer wakeups.
- The coupling argument in A cuts toward a separate knob *regardless of the
  value chosen* — but the value itself is the number the human should set
  deliberately (per "What gets dropped" above).

### Q3 — `report-up-is-a-push.md`: confirm leave-as-is, or add a pointer?

Effectively resolved by premise 0 (the policy was not the cause and stays
correct for the dispatch-acknowledgment case it documents). Residual choice:

- **A. Close as-is.** No churn.
- **B. Add one cross-reference line** pointing at `cc-butler--forward-to-ops`
  / `cc-butler-forward` as the actual per-event interrupt lever. Cost: a
  policy doc edit; benefit: the next reader doesn't repeat the misdiagnosis
  this document's own first draft made.

### Q4 — wake classification for raw notification events (design gap, not a tuning knob)

The wake/no-wake boundary is fully specified for `report_to_steward` traffic
(the `needs` argument) but only gestured at for the *notification hook* path
("the event's own `:body`/`:title` plist keys"). Claude Code notifications
include at least: permission requests, idle-waiting, task completion. Which
of those are wake-worthy, and where does that mapping live?

- **A. All raw notifications are no-wake; only an explicit non-empty `needs`
  wakes.** Simplest rule, no string matching. **Cost — and this is the one
  place this design could silently regress today's behavior:** a worker
  stuck on a permission prompt cannot call `report_to_steward` at all (it is
  blocked at the harness level, before any tool call), so under A the case
  that most needs a wake never generates one. Today's unconditional
  forwarder, whatever its faults, does wake for it.
- **B. Classify by notification type/title allowlist** (permission-request →
  wake; idle/finished → no-wake). Cost: couples the gate to strings the
  harness emits, which can drift across Claude Code versions. It is,
  however, structured event metadata — not a screen read — so it stays
  within the #39 constraint.

### Q5 — sequencing against the `send-input` atomicity fix

The gated forwarder still writes through `cc-butler--send-input`, whose
type-then-submit interleaving defect is documented separately
(`send-input-atomicity-proposal.md`). Landing order is a real choice:

- **A. Atomicity fix first.** The gate's batched push is exactly the kind of
  long, multi-line send most exposed to mid-sequence interleaving; building
  the gate on the fixed primitive avoids validating it twice.
- **B. Inbox gate first.** The gate reduces send *frequency*, shrinking the
  race surface even with the primitive unfixed; the atomicity fix's scope is
  unchanged either way.
- **C. Same branch.** One review pass, no intermediate state. Cost: couples
  two independently-reviewable changes — against this project's baby-step
  discipline, and a revert of one drags the other.

### Q6 — scope of the durability-first rule

"Write durably, then push" is stated above for items *aimed at the steward*.
Undecided: does the rule cover **all** `send_to_session`-based escalations
(any session → any session), or only the butler→steward path that produced
the relay-loss incident?

- **A. Steward-bound traffic only.** Minimal change matching the observed
  failure. Cost: worker→worker or steward→worker sends keep the
  fire-and-forget failure mode, waiting for their own incident.
- **B. Every escalation-class send.** One rule, no per-path exceptions.
  Cost: needs a durable inbox equivalent *per recipient class* — workers
  don't currently have one, so B implies new storage, which starts to brush
  against the brief's "don't add layers" boundary (new structures, though
  not new sessions).
