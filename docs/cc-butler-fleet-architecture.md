# Fleet architecture: roles, channels, and how they actually behave

This describes the interaction topology cc-butler runs today: a human
(정수님) orchestrating a fleet of Claude Code sessions through two
intermediary roles. It is written from the code (`cc-butler-*.el`) and from
the governance store's incident record, not from how the design was
originally intended — several places below are conventions enforced by
prompt text and habit, not by the runtime, and that gap is called out where
it matters.

## Topology

```
                 정수님 (human)
                     │
     Emacs keybindings, doc-inbox (decisions.org),
     or typing directly into any session's terminal
                     │
                     ▼
              ┌─────────────┐
              │   Butler    │   pending_decisions (pull) ◄── escalate_to_butler
              │ (user-facing)│
              └─────────────┘
                     ▲
                     │ list_claude_sessions, read_session_output,
                     │ send_to_session, compact_session, new_topic,
                     │ close_topic, record_principle, butler_dashboard
                     ▼
              ┌─────────────┐
              │   Steward   │   pending_events (pull, destructive) ◄── report_to_steward (push)
              │ (fleet-wide)│
              └─────────────┘
                     ▲
                     │ same control-plane tools as above
                     ▼
        ┌────────────┼────────────┐
        ▼            ▼            ▼
   ┌─────────┐  ┌─────────┐  ┌─────────┐
   │ Worker 1│  │ Worker 2│  │ Worker N│   check_inbox (pull, non-destructive)
   └─────────┘  └─────────┘  └─────────┘
```

**Single mode:** when no steward session exists, the butler plays both
roles — `cc-butler--ops-dir` resolves to `(or cc-butler--steward
cc-butler--butler)`, and `cc-butler--split-p` is true only when a distinct
steward is actually running (`cc-butler-orchestrator.el:979-993`). Nothing
else in the topology changes; the butler just absorbs the steward's
fleet-facing tool calls.

## Roles: designation pointers, not session types

There is no role enum. A role is a `defvar` holding a session's working
directory, plus a rank function that classifies any directory against it:

```elisp
(defun cc-butler--role-rank (dir)
  (cond ((and (boundp 'cc-butler--butler) (equal dir cc-butler--butler)) 0)
        ((and (boundp 'cc-butler--steward) (equal dir cc-butler--steward)) 1)
        (t 2)))
```

- **Butler** — `cc-butler--butler`, set by `cc-butler-start-butler`
  (`cc-butler-orchestrator.el:840-852`). "Interfaces with the human and
  drives the worker sessions through the orchestration MCP tools."
- **Steward** — `cc-butler--steward`, set by `cc-butler-start-steward`
  (`:927-944`). "Receives the worker firehose ... and escalates only
  decisions to the butler."
- **Worker** — the residual case (rank 2). No designation variable of its
  own.
- **Human** — not a session at all; interacts via Emacs keybindings and the
  butler's decision-inbox/maildir channel.

All three session roles are spawned through one shared path,
`cc-butler--launch-session` / `cc-butler--start-session-in`
(`cc-butler-workspace.el:135-139`), specifically so that worker, butler, and
steward launch configuration cannot drift apart from each other.

**MCP tools are registered globally, not per role.** Every session gets the
same tool list (`claude-code-ide-mcp-allowed-tools` defaults to `auto`,
passing every tool to every session — `cc-butler-cleanup.el:1057-1065`).
Where a tool's docstring says "steward only" or "butler only", that is
prompt-level convention, not a runtime gate, and it is not uniformly
enforced in the implementation. `escalate_to_butler` is the clearest case:
its docstring reads `"MCP tool (steward -> butler)"`, but the function body
(`cc-butler-orchestrator.el:1044-1069`) only resolves `(cc-butler--caller-dir)`
to *some* live session and queues — it never compares the caller against
`cc-butler--steward`. A worker calling it directly works, bypasses the
steward's `pending_events` queue entirely, and lands straight in the
butler's `pending_decisions`. Governance notes worker-side guidance that
relies on this actually working (`governance/relay-safe-worker-decisions.md`
tells a blocked worker to use `report_to_steward` "or `escalate_to_butler` —
when it needs a decision and nothing else is blocking it"), so the gap
between docstring and enforcement is at minimum load-bearing, not
accidental — but it is still a gap: nothing stops a worker from escalating
past the steward by mistake, either. A minority of tools do enforce their
role restriction in code — `close_topic` checks
`cc-butler-cleanup--worker-p` and refuses to run against a butler or
steward directory (`cc-butler-cleanup.el:975-1049`).

## Channels

| Tool | Typical caller | Direction | Push / pull | Notes |
|---|---|---|---|---|
| `list_claude_sessions` | butler, steward | control-plane → any | — | name, waiting state, branch, activity, model |
| `read_session_output` | butler, steward | control-plane → worker | — | reads the target's live terminal screen |
| `send_to_session` | butler, steward | control-plane → worker | push | types text + **one** Enter into the target's terminal, as an ordinary user turn |
| `report_to_steward` | worker | worker → steward | push | lands in the steward's firehose (`pending_events`); does **not** reach the butler |
| `report_to_butler` | worker (deprecated) | worker → steward | push | alias — despite the name, it lands with the steward, not the butler |
| `pending_events` | steward | steward pulls | pull, **destructive** | drains and clears the steward's inbox; a non-steward caller silently destroys undelivered reports |
| `escalate_to_butler` | steward (by convention; unenforced — see above) | → butler | push into a pull queue | queues into `pending_decisions`; also appended to `docs/decisions.org` as an audit trail |
| `pending_decisions` | butler | butler pulls | pull | drains the decision queue `escalate_to_butler` fills |
| `check_inbox` | worker | self pulls | pull, non-destructive | the worker-safe equivalent of `pending_events` |
| `ask_worker` / `reply_message` | butler, steward / worker | → worker / worker → asker | push / push | a question-and-answer pair; the reply auto-routes to the asker's inbox |
| `session_status` | butler, steward | control-plane → any | — | context size, model, compaction eligibility |
| `compact_session` / `compact_large_sessions` | butler, steward | control-plane → any / fleet | — | drives `/compact`; the fleet sweep includes butler and steward by design |
| `reload_butler_code` | any | self / dev-plane | — | hot-reloads cc-butler's own elisp from disk; no effect on any session's context |
| `new_topic` / `close_topic` | butler, steward | control-plane → spawn / kill worker | — | `close_topic` is role-gated in code and excluded from auto-allow, so it always prompts a human |
| `record_principle` / `regenerate_governance` | butler, steward | → governance store | — | see below |
| `butler_dashboard` / `butler_log` | butler | → docs | — | `dashboard.org` sessions table is always regenerated live; only the overview/decisions text is caller-supplied |

Two failure modes are common enough to be worth stating as properties of
the channels themselves, not as one-off bugs:

- **A push's own success return is not proof of delivery.** The delivery
  event happens at the receiver, never at the sender or the queue in
  between (`governance/putting-it-in-a-queue-is-not-delivering-it.md`). This
  is not hypothetical: `report_to_butler`'s return string once literally
  named the *steward* as the recipient
  (`governance/verify-delivery-at-the-recipient-not-the-return-string.md`),
  and an `escalate_to_butler` call sat undrained for 40+ minutes on four
  separate occasions in one day while the butler told 정수님 nothing further
  was needed. The standing fix is to nudge (`send_to_session`) after a push
  and then read the recipient's screen to confirm the content actually
  landed (`governance/after-send-check-recipient-state.md`).
- **`send_to_session` collides with anything already open on the target's
  screen.** It presses Enter exactly once, at the end. If the target has an
  interactive menu open (an `AskUserQuestion` wizard, a slash-command
  follow-up), that Enter lands on whatever is already highlighted there —
  the dispatched text is silently discarded on both ends, with no error
  (`governance/relay-safe-worker-decisions.md`,
  `governance/a-slash-command-eats-the-message-that-follows-it.md`). A
  billing worker once sat frozen for roughly three hours waiting on an
  answer that had actually been swallowed this way.

## Escalation and hold semantics

The standing test for what gets escalated to 정수님, stated by him directly
and reaffirmed since, is **reversibility, not importance or visibility**:
two-way, reversible decisions are made by the butler or steward per his
existing judgment principles, with the outcome reported afterward, not
asked for beforehand. Only genuinely one-way actions — a production
deploy/go-live, a real customer-data or billing mutation, a history
rewrite, a delete — get surfaced before they happen
(`governance/reversibility-is-the-escalation-test.md`). Silence on a
reversible fork is authorization to keep moving; re-pinging on it is itself
treated as a failure mode. The one carve-out: an otherwise-reversible
engineering choice that touches a safety control (dropping a guard,
widening access) still surfaces the security delta even when the
engineering choice itself is autonomous.

A few sharper rules sit under that test:

- Check whether a question is answerable by a cheap, repeatable observation
  (a diff, a grep, a test run) before spending a human decision on it
  (`governance/check-whether-it-is-measurable-before-escalating-it-as-a-decision.md`).
- An escalation must name a concrete action, not a resource label — "the
  staging API key" is unanswerable, "log in as tenant admin → `POST
  /api/v1/auths/api_key` → use the returned token" is
  (`governance/escalate-the-action-not-the-label.md`). The same note
  documents an incident where four distinct resource needs across six
  tracks got collapsed into one aggregated phrase, manufacturing a blocker
  that didn't actually apply to most of them.
- Holding something quietly is not the same as surfacing the hold — a hold
  has to be routed to 정수님 in the same turn it's decided, with the
  concrete cost of shipping versus waiting, or he never gets the chance to
  override it (`governance/a-hold-is-not-a-decision-until-he-hears-it.md`).
  Telling a worker to "wait for the human's answer" makes that escalation
  load-bearing: if it's never actually sent, the worker waits correctly and
  indefinitely for an answer nobody requested — this has produced real
  multi-day stalls.
- A decision made under delegated authority is attributed to the delegate
  (butler or steward) that made it, never written up as "정수님 decided" —
  misattribution puts words in his mouth and makes a later reversal look
  like self-contradiction
  (`governance/attribute-a-delegated-decision-to-the-delegate-not-the-human.md`).
  Symmetrically, a delegate's own suggestion cannot lift a constraint 정수님
  set directly on a worker; only he can lift it, and the worker holding the
  constraint is the only party that reliably knows it exists
  (`governance/a-delegates-instruction-does-not-lift-the-principals-constraint.md`).

## Trust: why a plain-text channel needs judgment, not obedience

`send_to_session` delivers as an ordinary user turn. Nothing on the
receiving end distinguishes a legitimate dispatch from injected text — the
only asymmetry is that a genuine dispatch can point at something the
receiver can independently check (a governance file path, a `HANDOFF.md`,
`butler_log`), while an attacker asserting authority cannot. The documented
rule is: **when a receiver can't verify an instruction, it should refuse,
and the correct response from the sender is to change channel — point at a
checkable artifact — never to assert authority harder**
(`governance/a-channel-that-carries-authority-must-be-verifiable-by-the-receiver.md`).
This has played out for real, more than once: worker sessions have refused
steward instructions that asserted unverifiable facts (a claimed 정수님
ruling, a claimed migration-trace request, a claimed classifier workaround)
and were right to, in every recorded case. It cuts the other way too — an
instruction stripped of its rationale can become textually identical to an
injection payload even when the sender's intent was benign
(`governance/an-instruction-stripped-of-its-reason-is-shaped-like-an-injection.md`);
the mitigating habit is to always send the *why* alongside a
constraint-shaped instruction, and to send *less*, not more persuasion, when
authenticity can't be established.

## Context and compaction

The standing ceiling (from 정수님, via `docs/steward-standing-criteria.md`)
is to keep every session under 400k tokens, with 500k tolerated only when
genuinely necessary. The steward owns fleet-wide compaction timing and
execution, and is expected to manage its own size the same way — it is
routinely one of the largest sessions running. `compact_large_sessions`
sweeps everything over threshold, largest first, and deliberately includes
the butler and steward rather than exempting them.

Compaction itself is a three-step sequence — downgrade model, run
`/compact`, restore model — each of which needs its own submission; a
bundled multi-line send only executes the first step. Two failure modes
worth knowing about: a **queued** (non-forced) compaction is not cancelled
by a **forced** one on the same session, so it can fire later and
re-summarize away everything sent in the interim
(`governance/a-queued-compaction-outlives-the-force-that-preempted-it.md`);
and `CTX=0` immediately after a resume or compaction is frequently a
display artifact rather than real state, so it should be confirmed against
the resume banner or restored-skills markers rather than trusted at face
value.

## Governance store: institutional memory as a first-class system

`governance/*.md` is one principle per file — a durable record of specific
incidents and the rule extracted from each, with a Why/How-to-apply
structure. `record_principle` writes the file, regenerates the cache, and
reads its own write back to verify it landed. `regenerate_governance`
copies the store into the Claude Code memory directory and keeps
`MEMORY.md` (the hand-maintained index every session actually loads) in
sync — a note can be perfectly regenerated and still never be recalled if
nothing in that index points at it.

PR #50 in this repo (`fc8fd85`, currently open) is a concrete instance of
the store auditing itself: `regenerate_governance` used to check only
store→index sync and report "0 un-indexed" as if the index were fully
verified, when in fact an index→store direction (dangling index entries
after a deletion) and description drift (a stale index line surviving an
in-place edit) both existed unchecked. The fix adds the missing direction
and a report-only drift check, rather than trusting the tool's own
optimistic summary.

## Known gaps, as of this writing

- **`escalate_to_butler` has no caller-role check.** "Steward only" is
  documentation and convention; any worker can call it directly today (see
  Roles, above).
- **`report_to_butler` is a deprecated alias that lands with the steward,
  not the butler**, despite its name — kept only so already-connected
  sessions don't hit a tool-not-found error.
- **`pending_events` is destructive on read** and is the steward's inbox
  specifically; any other caller draining it silently destroys undelivered
  worker reports.
- **`rearm_session` is disabled** (its body is now `(user-error ...)`)
  following a 2026-07-04 incident; picking up newly-registered tools after
  a `reload_butler_code` currently requires a human to manually reconnect
  from a session's `/mcp` panel.
- **Post-restart resume can silently strand sessions.** Claude Code's own
  `--continue` resume can park a session at its startup chooser
  ("resume from summary" / "resume full session") while
  `list_claude_sessions` still reports it `running` — this has produced
  false "fully recovered" reports across at least three separate restarts
  (open: issue #4).
- **No CI workflow exists** despite 422 ERT tests in the repo (open: issue
  #51).

## References

- `docs/cc-butler-fleet-recovery.md` — manual recovery procedure and the
  restart-stall incidents behind it.
- `docs/cc-butler-source-selection-design.md` — a related but distinct
  concern: which *copy* of cc-butler's own code is running, not agent
  roles.
- `governance/README.md` and `governance/institutionalize-learning.md` —
  the governance store's own design.
- Governance files cited inline above, under `governance/`.
