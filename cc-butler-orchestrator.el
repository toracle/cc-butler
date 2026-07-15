;;; cc-butler-orchestrator.el --- Butler/worker orchestration for cc-butler  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jeongsoo Park
;; SPDX-License-Identifier: MIT

;; Turns the session manager into a control plane: a designated *butler*
;; Claude session drives the *worker* sessions through Emacs.  Emacs is the
;; bus — workers are reached through their ghostel shells.
;;
;; Two directions:
;;
;;   PULL  — the butler actively inspects and commands workers via three MCP
;;           tools it can call:
;;             list_claude_sessions   what's running, who's waiting, branches
;;             read_session_output    a worker's current screen
;;             send_to_session        type a prompt into a worker and submit
;;
;;   PUSH  — when a worker posts a notification (needs input / done), the event
;;           is forwarded into the butler's terminal so it can aggregate and
;;           proactively report to you over its own remote-control channel.
;;
;; You remote-control ONE session (the butler) from your phone; it becomes the
;; situation room for the rest.  Designate it with `b' in the manager buffer.

(require 'cc-butler-session)
(require 'cc-butler-notifications)
(require 'claude-code-ide)
(require 'json)

;; The up-direction tools optionally route through the durable maildir inbox
;; (`cc-butler-mail', loaded after this file); declared so the byte-compiler is
;; content and the runtime dispatch on `cc-butler-message-transport' works.
(declare-function cc-butler-mail-up-report "cc-butler-mail" (from-dir body))
(declare-function cc-butler-mail-up-decision "cc-butler-mail" (from-dir summary needs))
(declare-function cc-butler-mail-up-drain "cc-butler-mail" (agent-dir))
(declare-function cc-butler--check-inbox-drain-as "cc-butler-mail" (agent-name))
(declare-function cc-butler-decision-create "cc-butler-decision" (from-dir summary needs options))
(declare-function cc-butler--decision-parse-options "cc-butler-decision" (s))
(declare-function cc-butler-docs--auto-log "cc-butler-docs" (dir body))
(defvar cc-butler-decision-workflow)

;;;; ------------------------------------------------------------------
;;;; Addressing, reading, sending
;;;; ------------------------------------------------------------------

(defun cc-butler--dir-by-name (name)
  "Return the working-dir of the live session whose display name is NAME."
  (catch 'hit
    (maphash (lambda (dir proc)
               (when (and (process-live-p proc)
                          (equal (cc-butler--display-name dir) name))
                 (throw 'hit dir)))
             claude-code-ide--processes)
    nil))

(defun cc-butler--caller-dir ()
  "Return the working-dir of the session that invoked the current MCP tool."
  (plist-get (claude-code-ide-mcp-server-get-session-context) :project-dir))

(defun cc-butler--refresh-terminal-text (buffer)
  "Force BUFFER's text to be re-synced from the live ghostel grid.
ghostel only repaints a buffer that is displayed in a window; a
background session buffer is never redisplayed, so its text can be a
stale frame.  Drive a full `ghostel--redraw' directly (the same call
ghostel makes on config changes) so the text reflects the current frame
without needing a window."
  (with-current-buffer buffer
    (when (and (boundp 'ghostel--term) ghostel--term (fboundp 'ghostel--redraw))
      (let ((inhibit-read-only t))
        (ignore-errors (ghostel--redraw ghostel--term t))))))

(defcustom cc-butler-session-io-timeout 8
  "Seconds before reading or writing a session's terminal buffer gives up.
Bounds `cc-butler--read-output'/`cc-butler--send-input' — without this, a
stuck redraw or wedged terminal in ONE session hangs the calling MCP
request indefinitely (observed: callers were left waiting the full 300s
client-side timeout with no Emacs-side bound at all).  Because
`cc-butler--read-output' is also the fallback path for every session
list row's model/context tag on a cache miss, a single wedged session can
otherwise freeze `cc-butler--maybe-refresh' — and with it every tool that
triggers a refresh (report_to_steward, escalate_to_butler, ...), not just
direct read_session_output/send_to_session calls."
  :type 'number
  :group 'cc-butler)

(defun cc-butler--read-output (dir &optional lines)
  "Return the last LINES (default 40) of session DIR's terminal screen.
The terminal text is force-refreshed first so the capture is always the
current frame, even for a background (non-displayed) buffer.  Bounded by
`cc-butler-session-io-timeout' so a stuck redraw cannot hang the caller."
  (with-timeout (cc-butler-session-io-timeout
                 (error "Timed out reading session %s's output after %ss (redraw or buffer access may be stuck)"
                        (cc-butler--display-name dir) cc-butler-session-io-timeout))
    (let ((buf (get-buffer (claude-code-ide--get-buffer-name dir))))
      (when (buffer-live-p buf)
        (cc-butler--refresh-terminal-text buf)
        (with-current-buffer buf
          (let* ((n (max 1 (or lines 40)))
                 (start (save-excursion (goto-char (point-max))
                                        (forward-line (- n))
                                        (line-beginning-position))))
            (string-trim (buffer-substring-no-properties start (point-max)))))))))

(defcustom cc-butler-submit-delay 0.1
  "Seconds to wait after sending text before the submitting Return.
The worker's input must settle before Enter or the Return is dropped and
nothing submits (the same delay `claude-code-ide-send-prompt' uses)."
  :type 'number
  :group 'cc-butler)

(defun cc-butler--send-input (dir text &optional submit)
  "Type TEXT into session DIR's terminal; when SUBMIT, also press Return.
Claude treats a raw LF as a submit, so multi-line TEXT is delivered as a
bracketed paste (\\e[200~..\\e[201~) — Claude enables paste mode, which
keeps the embedded newlines literal so only the final Return submits.
Carriage returns are normalized to LF and stray ESC bytes are stripped so
the body cannot break out of the paste or submit mid-prompt.  A short
settle delay precedes the Return so it is not dropped before the input is
processed."
  (with-timeout (cc-butler-session-io-timeout
                 (error "Timed out sending input to session %s after %ss (terminal may be stuck; text may be partially delivered)"
                        (cc-butler--display-name dir) cc-butler-session-io-timeout))
    (let* ((buf (get-buffer (claude-code-ide--get-buffer-name dir)))
           (body (replace-regexp-in-string
                  "\e" ""
                  (replace-regexp-in-string "\r\n?" "\n" (or text "")))))
      (unless (buffer-live-p buf)
        (error "No live terminal for session %s" dir))
      (with-current-buffer buf
        (if (string-search "\n" body)
            (claude-code-ide--terminal-send-string (concat "\e[200~" body "\e[201~"))
          (claude-code-ide--terminal-send-string body))
        (when submit
          (sleep-for cc-butler-submit-delay)
          (claude-code-ide--terminal-send-return)))
      t)))

;;;; ------------------------------------------------------------------
;;;; Butler designation
;;;; ------------------------------------------------------------------

(defun cc-butler-set-butler ()
  "Designate the session at point as the butler (toggle)."
  (interactive)
  (let ((dir (cc-butler--dir-at-point)))
    (unless dir (user-error "No session at point"))
    (setq cc-butler--butler (unless (equal dir cc-butler--butler) dir))
    (message "cc-butler: butler %s"
             (if cc-butler--butler
                 (format "set to %s" (cc-butler--display-name cc-butler--butler))
               "cleared"))
    (cc-butler--maybe-refresh)))

(with-eval-after-load 'cc-butler-session
  (when (boundp 'cc-butler-mode-map)
    (define-key cc-butler-mode-map "b" #'cc-butler-set-butler)))

;;;; ------------------------------------------------------------------
;;;; The butler as a first-class session (home + bootstrap + launch)
;;;; ------------------------------------------------------------------
;;
;; Rather than marking an arbitrary session the butler, the package launches a
;; dedicated butler session in its own home directory, scaffolding a role
;; `CLAUDE.md' there on first run.  This makes "start the butler" a one-command
;; operation for a fresh install.

(defcustom cc-butler-home
  (expand-file-name "cc-butler/butler" user-emacs-directory)
  "Working directory the butler session runs in (its home).
`cc-butler-start-butler' creates it on demand, scaffolding a `.projectile'
marker and a role `CLAUDE.md'.  Point this at an existing directory (e.g.
a prior butler home) to reuse its contents."
  :type 'directory
  :group 'cc-butler)

(defun cc-butler--claude-memory-dir (project-dir)
  "Return the Claude per-project memory directory for PROJECT-DIR, or nil.
Claude encodes a project path by replacing `/' and `.' with `-'."
  (when project-dir
    (expand-file-name
     (concat (replace-regexp-in-string
              "[/.]" "-" (directory-file-name (expand-file-name project-dir)))
             "/memory/")
     "~/.claude/projects/")))

(defun cc-butler--shared-state-note ()
  "Return a CLAUDE.md section pointing both roles at the shared docs + memory.
Locations are derived from the butler home (the shared operational home)."
  (let* ((home (or cc-butler--butler cc-butler-home))
         (docs (abbreviate-file-name (expand-file-name "docs/" home)))
         (mem (cc-butler--claude-memory-dir home)))
    (concat
     "## Shared state (both roles read this)\n\n"
     (format "Operational state is shared under `%s`:\n" docs)
     (format "- `%sdashboard.org` — current fleet snapshot + open decisions.\n" docs)
     (format "- `%ssteward-handoff.md` — in-flight dispatch handoff (when present).\n" docs)
     (when mem
       (format (concat "- shared memory: `%sMEMORY.md` and the notes it indexes"
                       " (subagent-first,\n  worker-context-hygiene,"
                       " relay-safe-worker-decisions, decision-routing,"
                       " DoD-vs-goal, evaluation-independence,"
                       "\n  decision-proposal-format, verify-delivery,"
                       " institutionalize-learning,\n  …) — load these to keep"
                       " operating discipline.\n")
               (abbreviate-file-name mem)))
     (concat "- **operating-principle source of truth:** the cc-butler repo store"
             " `governance/`\n  (one `.md` per principle, runtime-neutral). The"
             " shared memory above is a\n  *generated cache* of it — route a new"
             " operational learning by editing the\n  store + `M-x"
             " cc-butler-governance-regenerate`, not by hand-editing memory.\n")
     "\n")))

(defun cc-butler--roles-metaphor (which)
  "Return the shared household-metaphor section; WHICH is `butler' or `steward'."
  (concat
   "## Household roles (don't confuse them)\n\n"
   "A cc-butler fleet has two coordinating roles. In Korean both translate to\n"
   "\"집사\", but they are different:\n\n"
   "- **butler** — *front-of-house*: faces the master (the human), keeps a calm\n"
   "  channel, holds the decision queue. Never relays worker chatter to the boss.\n"
   "- **steward** — *below-stairs, operations chief*: faces the workers, receives\n"
   "  their reports, dispatches and tracks them, and escalates only *decisions*\n"
   "  up to the butler.\n\n"
   (format "You are the **%s**.\n\n" which)))

(defun cc-butler--learning-duty (which)
  "Return the standing recurrence-prevention learning duty for role WHICH.
WHICH is `butler' or `steward'."
  (let ((mem (abbreviate-file-name
              (or (cc-butler--claude-memory-dir (or cc-butler--butler cc-butler-home))
                  "~/.claude/projects/-home-toracle--ccsm/memory/"))))
    (concat
     "## Standing duty — route recurrence-prevention learning to a durable home\n\n"
     "When a recurring or circling problem is finally resolved well, do NOT let\n"
     "the prevention knowledge die in this session's scrollback — it is lost on a\n"
     "clear. Right after resolving, ask and ROUTE (this is the `reflective-learning`\n"
     "discipline):\n\n"
     "1. Will this recur?  2. What is the *minimal* artifact that prevents it?\n"
     "3. Where must it live so it is *recalled* next time?\n\n"
     "Route by scope:\n"
     (format (concat "- **operational / coordination** → the shared ccsm memory"
                     " (`%sMEMORY.md`\n  + the note it indexes) — the home you load"
                     " at startup, so it is actually recalled.\n")
             mem)
     "- **reusable engineering discipline** → a shared-skills-repo skill (fires by\n"
     "  trigger), e.g. global-consistency.\n"
     "- **repo-specific pitfall** → that repo's own `CLAUDE.md` (e.g. one\n"
     "  normalization point for a subdomain).\n"
     "- **cross-repo fact** → the vault.\n\n"
     (if (eq which 'steward)
         (concat
          "You see the worker/repo firehose, so you own **worker, repo, and\n"
          "engineering** learnings: when the same friction recurs across turns or\n"
          "workers, route it *now* rather than re-solving it later. Operational and\n"
          "coordination learnings go to the shared ccsm memory above.\n\n")
       (concat
        "You own **operational** learnings — how the boss likes to decide and be\n"
        "briefed, coordination patterns: route those to the shared ccsm memory\n"
        "(and interview-confirmed preferences to `user-profile.org`).\n\n")))))

(defun cc-butler--butler-claude-md ()
  "Return the bootstrap CLAUDE.md text for the butler (front-of-house) role."
  (concat
   "# Butler (front-of-house)\n\n"
   (cc-butler--roles-metaphor "butler")
   "The human speaks to **you**, in a calm channel — worker nudges do NOT reach\n"
   "you. Your job is to present the decisions that need the human, cleanly, and\n"
   "to relay the answers back down.\n\n"
   "## How to communicate\n\n"
   "Explain *kindly* — meaning the explanation is kind, not merely the tone.\n"
   "Write in sentences and short narrative, not word-lists or fragment bullets.\n"
   "Be concise but complete: tell the boss what they need to know, fully, and no\n"
   "more. Aim for the register of a good coach or consultant — clear and\n"
   "unhurried, never verbose, and never leaving the boss confused.\n\n"
   "## On a clean start — get to know the boss\n\n"
   "At startup, read `user-profile.org` in this home — it records what you've\n"
   "learned about the boss (how to address them, how they like you to explain).\n"
   "If it is filled, begin already knowing them.\n\n"
   "If it is a clean start (the profile is still unfilled), *interview the boss*\n"
   "before diving in: work through `interview-inventory.org`, ask each item\n"
   "plainly — do not assume the answers (e.g. how to address them) — and record\n"
   "the answers into `user-profile.org`. As you go, if you notice something worth\n"
   "asking every new boss up front, append it to `interview-inventory.org` so\n"
   "future starts know to ask it. Keep this complementary to the memory system:\n"
   "the profile holds interview-confirmed preferences only.\n\n"
   "## Each turn\n\n"
   "1. Call `pending_decisions` — the decisions the steward has escalated for the\n"
   "   human. Present them plainly; never dump the worker firehose at the boss.\n"
   "2. Get the human's answer, then relay it down to the steward with\n"
   "   `send_to_session` (find its name via `list_claude_sessions`).\n"
   "3. When the human asks something specific about a worker, you may\n"
   "   `read_session_output` / `send_to_session` that worker directly.\n\n"
   "## Tools\n\n"
   "- `pending_decisions` — drain your quiet decision queue.\n"
   "- `list_claude_sessions` / `read_session_output` / `send_to_session`.\n"
   "- `butler_dashboard` — the current snapshot (read it to brief the human).\n\n"
   "## Single mode\n\n"
   "If no steward session is running, you also play the steward: drain\n"
   "`pending_events`, dispatch workers, and maintain `butler_dashboard` /\n"
   "`butler_log`. Once a steward is started, hand that firehose over to it.\n"
   "Carry the steward's context-hygiene duty too while you do: tell every\n"
   "worker you dispatch to delegate to subagents, and clear any worker whose\n"
   "context has grown unbounded (`subagent-first`, `worker-context-hygiene`).\n"
   "Also carry relay safety: tell every worker to prefer `report_to_steward`/\n"
   "`escalate_to_butler` over `AskUserQuestion`, and check a worker's screen\n"
   "with `read_session_output` before texting it free-form — your single\n"
   "submit-Enter can otherwise land on an open wizard's highlighted default\n"
   "instead of delivering your text (`relay-safe-worker-decisions`).\n\n"
   (cc-butler--learning-duty 'butler)
   (cc-butler--shared-state-note)))

(defun cc-butler--steward-claude-md ()
  "Return the bootstrap CLAUDE.md text for the steward (operations) role."
  (concat
   "# Steward (below-stairs, operations chief)\n\n"
   (cc-butler--roles-metaphor "steward")
   "You receive the worker firehose and run operations. You do NOT face the\n"
   "human directly — you escalate decisions to the butler, who does.\n\n"
   "## On startup — do this FIRST, before any action\n\n"
   "You are a fresh session inheriting a running fleet. Load context before you\n"
   "dispatch anything:\n\n"
   "1. Read the handoff + snapshot: `steward-handoff.md` and `dashboard.org` in\n"
   "   the shared docs dir (below) — the in-flight dispatch state (what was sent\n"
   "   to which worker, what is awaited) and the open decisions.\n"
   "2. Load the shared memory (below).\n"
   "3. `pending_events` (drain the inbox) + `list_claude_sessions` (see the live\n"
   "   fleet). Reconcile with the handoff.\n"
   "4. THEN act. Do not re-dispatch or duplicate in-flight work.\n\n"
   (cc-butler--shared-state-note)
   "## Each turn\n\n"
   "1. Call `pending_events` first — worker reports (`report_to_steward`) and\n"
   "   notifications land here; nudges are also typed at you. This is your inbox.\n"
   "2. Dispatch and unblock: `read_session_output` to see a worker's screen,\n"
   "   `send_to_session` to answer, task, or unblock it. Track each toward its DoD.\n"
   "   Before sending free-form text (not an answer to a question you asked), check\n"
   "   the worker's screen first — a visible interactive prompt/menu is live, and\n"
   "   your one submit-Enter will hit whatever is highlighted there, not deliver\n"
   "   your text (see `relay-safe-worker-decisions` below).\n"
   "   Every dispatch or check-in tells the worker to delegate substantial reads,\n"
   "   searches, and investigations to its own subagents and keep its own main\n"
   "   thread thin — a standing habit, not a one-time reminder — and to prefer\n"
   "   `report_to_steward`/`escalate_to_butler` over `AskUserQuestion` for any\n"
   "   human-decision request, since it is under fleet orchestration, not a human\n"
   "   at its keyboard.\n"
   "3. Keep the picture current: `butler_dashboard` (the sessions table is built\n"
   "   automatically — you add the overview and open decisions) and `butler_log`\n"
   "   the durable timeline.\n"
   "4. When something needs a human decision, `escalate_to_butler(summary, needs)`\n"
   "   — do NOT ask the human yourself; route it through the butler, who presents\n"
   "   it and relays the answer back to you.\n"
   "5. When a recurring issue finally resolves well, ROUTE the prevention learning\n"
   "   to its durable home (the standing duty below) *before moving on* — don't\n"
   "   leave it in scrollback to re-solve next time.\n\n"
   "## Context hygiene — a standing duty, not just a checklist item\n\n"
   "Two levers, both yours to pull:\n"
   "1. **Upstream (cheap):** every dispatch/check-in above tells the worker to\n"
   "   delegate to subagents by default — don't wait until it is already large.\n"
   "2. **Downstream (backstop):** watch each worker's context-window usage; at a\n"
   "   safe point (WAITING, not mid-edit) drive it through externalize → verify →\n"
   "   clear → re-hydrate, the same discipline the butler applies to itself.\n"
   "See `subagent-first` and `worker-context-hygiene` in the governance store for\n"
   "the full rationale and safe sequence.\n\n"
   "## Relay safety — AskUserQuestion does not compose with send_to_session\n\n"
   "`AskUserQuestion` assumes a human at the keyboard; `send_to_session` types\n"
   "text and presses Enter exactly once, at the end. If a worker's wizard is open\n"
   "when your text lands, that Enter hits the wizard's highlighted default, not\n"
   "your message — silently swallowed on both ends. So, as a standing duty (not\n"
   "a one-time reminder, same failure mode as context hygiene above):\n"
   "1. Tell every worker you dispatch to prefer `report_to_steward`/\n"
   "   `escalate_to_butler` over `AskUserQuestion` for human-decision requests —\n"
   "   both are pull-based (drained via `pending_events`/`pending_decisions`),\n"
   "   so there is no live wizard to collide with.\n"
   "2. Before texting a worker free-form (not answering a question you asked),\n"
   "   `read_session_output` it first — a visible prompt/menu means the next\n"
   "   Enter you send is live and dangerous.\n"
   "See `relay-safe-worker-decisions` in the governance store for the full\n"
   "rationale — this has recurred, steward included, so restate it every time.\n\n"
   "## Tools\n\n"
   "- `list_claude_sessions` / `read_session_output` / `send_to_session`.\n"
   "- `pending_events` — drain the worker firehose.\n"
   "- `butler_log` / `butler_dashboard` — durable log + snapshot, under `docs/`.\n"
   "- `escalate_to_butler` — raise a decision to the butler.\n\n"
   (cc-butler--learning-duty 'steward)
   "Keep workers moving, and never let the state of the fleet live only in the\n"
   "chat scrollback.\n"))

(defun cc-butler--haiku-summarizer-agent-md ()
  "Return the `.claude/agents/haiku-summarizer.md' sub-agent definition —
the reusable device for `haiku-summarization-delegation': a single tool call
for \"read this long file/output, answer this one question, return only the
distilled answer,\" priced and speeded for haiku since it takes no judgment."
  (concat
   "---\n"
   "name: haiku-summarizer\n"
   "description: Summarize or extract a specific answer from a long document, "
   "log, or tool/session output. Use this BEFORE reading any long file "
   "directly — hand it the exact file/output and the question the summary "
   "must answer; it returns only the distilled answer, never a copy of the "
   "source. Only for pure extraction with no judgment call; if the task "
   "requires weighing options or verifying a claim, use the default model "
   "instead.\n"
   "model: haiku\n"
   "tools: Read, Grep, Glob\n"
   "---\n\n"
   "Read the file or output you were given and answer the exact question you "
   "were asked — nothing else.\n\n"
   "Return only the distilled answer: the facts, quotes, or conclusions "
   "needed, with file:line references where useful. Never return a copy or "
   "paraphrase of the full source, and never pad the answer with "
   "commentary about what you did.\n\n"
   "If the question can't be answered from what you were given, say so "
   "plainly instead of guessing.\n"))

(defun cc-butler--inbox-urgent-block (agent-name)
  "Return AGENT-NAME's check_inbox content (ask_worker replies/queries),
front-loaded with an unread count so it can't get lost among other
notifications — or nil when empty. Written 2026-07-09 after a real
ask_worker reply sat unread for a long stretch while the reader was
absorbed in an unrelated task. Uses `cc-butler--check-inbox-drain-as',
not `cc-butler-tool-check-inbox' — see that function's docstring for
why (caller-dir resolves to nil from a bare `emacsclient --eval')."
  (pcase-let ((`(,n . ,formatted) (cc-butler--check-inbox-drain-as agent-name)))
    (when (> n 0)
      (format "📥 %d unread inbox message(s) — handle before anything else this turn:\n%s"
              n formatted))))

(defcustom cc-butler-fleet-stale-waiting-seconds 120
  "Seconds a worker session must sit WAITING-FOR-INPUT before the
steward's pending_events hook flags it as possibly stuck (e.g. an
unnoticed AskUserQuestion dialog) rather than routinely idle.
See `cc-butler--fleet-stale-waiting-summary'."
  :type 'number
  :group 'cc-butler)

(defun cc-butler--fleet-stale-waiting-summary ()
  "Return a string flagging workers WAITING-FOR-INPUT longer than
`cc-butler-fleet-stale-waiting-seconds', or nil when none. Excludes the
butler/steward roles themselves — this is about fleet members going
quiet, not the reader's own state. A structural, every-turn version of
what a busy steward would otherwise have to remember to go check."
  (let ((now (float-time)) rows)
    (dolist (s (cc-butler--sessions))
      (let* ((dir (plist-get s :dir))
             (since (cc-butler--waiting-p dir)))
        (when (and since
                   (>= (- now since) cc-butler-fleet-stale-waiting-seconds)
                   (not (equal dir cc-butler--butler))
                   (not (equal dir cc-butler--steward)))
          (push (format "- %s (waiting %ds)" (cc-butler--display-name dir)
                        (round (- now since)))
                rows))))
    (when rows
      (format "🔍 Fleet check: %d worker(s) waiting a while with no report — could be a stuck dialog (e.g. AskUserQuestion) rather than routine idle; read_session_output to check:\n%s"
              (length rows) (mapconcat #'identity (nreverse rows) "\n")))))

(defun cc-butler--pending-decisions-hook-payload ()
  "Combined payload for the butler's pending_decisions hook: an urgent
check_inbox block (ask_worker replies) followed by the drained decision
queue. Either half may be absent; returns \"\" when both are empty."
  (let* ((inbox (cc-butler--inbox-urgent-block "butler"))
         (decisions (cc-butler-tool-pending-decisions))
         (has-decisions (not (equal decisions "No pending decisions."))))
    (mapconcat #'identity (delq nil (list inbox (and has-decisions decisions))) "\n\n")))

(defun cc-butler--pending-events-hook-payload ()
  "Combined payload for the steward's pending_events hook: an urgent
check_inbox block, the drained worker-event queue, and a fleet
stale-waiting nudge. Any subset may be absent; returns \"\" when all
three are empty."
  (let* ((inbox (cc-butler--inbox-urgent-block "steward"))
         (events (cc-butler-tool-inbox))
         (has-events (not (equal events "No pending worker events.")))
         (stale (cc-butler--fleet-stale-waiting-summary)))
    (mapconcat #'identity
               (delq nil (list inbox (and has-events events) stale))
               "\n\n")))

(defun cc-butler--pending-decisions-hook-sh ()
  "Return the butler's `check-pending-decisions.sh' UserPromptSubmit hook.
Mechanically drains `cc-butler--pending-decisions-hook-payload' (check_inbox
+ pending_decisions) via `emacsclient' on every turn and injects the
result as context, so the butler is never relying on remembering to
check either itself.

KNOWN FRAGILITY (baked into the script's own comment too): the
pending_decisions half of the payload is caller-independent and safe
only while `cc-butler-message-transport' is `in-memory' (the default).
If switched to `maildir', the tool's maildir branch calls
`cc-butler--caller-dir', which resolves the invoking MCP tool call's
session context; a bare `emacsclient --eval' is not one, so it returns
nil there and that half silently breaks (empty, or the wrong mailbox
drained). The check_inbox half is NOT affected — it drains
`cc-butler--ch-drain' directly with the static \"butler\" identity, which
doesn't depend on caller-dir at all. Revisit the decisions half if you
migrate transports."
  "#!/usr/bin/env bash
# UserPromptSubmit hook: mechanically drains cc-butler's pending_decisions
# queue AND check_inbox (ask_worker replies) on every turn and injects them
# as context, so the butler never has to remember to check either itself.
# Written 2026-07-06 (decisions) / extended 2026-07-09 (inbox) after each
# manual check got skipped for a stretch and something real went unnoticed.
#
# Uses write-region (not --eval's own quoted return value) so newlines,
# quotes, and backslashes survive byte-exact into the JSON payload via
# `jq -Rs`.
#
# KNOWN FRAGILITY (pending_decisions half only): cc-butler-tool-pending-decisions
# is caller-independent and safe to call from a bare `emacsclient --eval'
# (as this hook does) only while `cc-butler-message-transport' is
# `in-memory' (the current default) — in that mode it drains a plain
# global queue with no notion of \"caller\". If that transport is ever
# switched to `maildir', its maildir branch calls `cc-butler--caller-dir',
# which resolves the *invoking MCP tool call's* session context — a bare
# emacsclient --eval from this hook is not an MCP tool call, so
# `cc-butler--caller-dir' returns nil there and that half silently breaks
# (empty, or the wrong mailbox drained). The check_inbox half drains
# directly by the static \"butler\" identity and is unaffected. Revisit the
# decisions half if you migrate transports. See check-pending-events.sh
# (steward) for the identical decisions-side fragility.
set -euo pipefail

tmpfile=\"$(mktemp)\"
trap 'rm -f \"$tmpfile\"' EXIT

emacsclient --eval \"(write-region (cc-butler--pending-decisions-hook-payload) nil \\\"$tmpfile\\\")\" >/dev/null 2>&1 || exit 0

content=\"$(cat \"$tmpfile\" 2>/dev/null || true)\"

if [ -z \"$content\" ]; then
  exit 0
fi

jq -n --arg ctx \"$content\" \\
  '{hookSpecificOutput: {hookEventName: \"UserPromptSubmit\", additionalContext: (\"[cc-butler] auto-drained by hook — present these to 정수님 now:\\n\" + $ctx)}}'
")

(defun cc-butler--pending-events-hook-sh ()
  "Return the steward's `check-pending-events.sh' UserPromptSubmit hook.
Mirrors `cc-butler--pending-decisions-hook-sh' (butler): drains
`cc-butler--pending-events-hook-payload' — check_inbox, the worker-event
queue (MCP tool `pending_events'), and a fleet stale-waiting nudge — on
every turn. Same `cc-butler-message-transport' fragility applies to the
pending_events half identically; see that function's docstring."
  "#!/usr/bin/env bash
# UserPromptSubmit hook: mechanically drains cc-butler's pending_events
# (worker firehose) queue, check_inbox (ask_worker replies), and a fleet
# stale-waiting scan on every turn and injects them as context, so the
# steward never has to remember to check any of them itself. Mirrors the
# butler's check-pending-decisions.sh, written 2026-07-06 after a manual
# pending_decisions check got skipped for an entire long conversation and
# a real escalation went unnoticed; extended 2026-07-09 (inbox + fleet
# check) after a busy steward missed a worker stuck at an unnoticed
# dialog while absorbed in another task.
#
# Uses write-region (not --eval's own quoted return value) so newlines,
# quotes, and backslashes in event text survive byte-exact into the JSON
# payload via `jq -Rs`.
#
# KNOWN FRAGILITY (pending_events half only): cc-butler-tool-inbox is
# caller-independent and safe to call from a bare `emacsclient --eval'
# (as this hook does) only while `cc-butler-message-transport' is
# `in-memory' (the current default) — in that mode it drains a plain
# global queue with no notion of \"caller\". If that transport is ever
# switched to `maildir', cc-butler-tool-inbox's maildir branch calls
# `cc-butler--caller-dir', which resolves the *invoking MCP tool call's*
# session context — a bare emacsclient --eval from this hook is not an
# MCP tool call, so `cc-butler--caller-dir' returns nil there and that
# half silently breaks (empty queue, or the wrong mailbox drained). The
# check_inbox and fleet-check halves are unaffected. Revisit the events
# half if you migrate transports.
set -euo pipefail

tmpfile=\"$(mktemp)\"
trap 'rm -f \"$tmpfile\"' EXIT

emacsclient --eval \"(write-region (cc-butler--pending-events-hook-payload) nil \\\"$tmpfile\\\")\" >/dev/null 2>&1 || exit 0

content=\"$(cat \"$tmpfile\" 2>/dev/null || true)\"

if [ -z \"$content\" ]; then
  exit 0
fi

jq -n --arg ctx \"$content\" \\
  '{hookSpecificOutput: {hookEventName: \"UserPromptSubmit\", additionalContext: (\"[cc-butler] auto-drained by hook — act on these now:\\n\" + $ctx)}}'
")

(defun cc-butler--hook-settings-json (hook-file status-message)
  "Return a `.claude/settings.json' JSON string wiring HOOK-FILE as a
UserPromptSubmit hook, shown as STATUS-MESSAGE while it runs."
  (json-encode
   (list :hooks
         (list :UserPromptSubmit
               (vector
                (list :hooks
                      (vector
                       (list :type "command"
                             :command hook-file
                             :timeout 10
                             :statusMessage status-message))))))))

(defun cc-butler--ensure-hook-settings-json (home hook-relpath status-message)
  "Scaffold HOME's `.claude/settings.json' wiring HOOK-RELPATH as a
UserPromptSubmit hook, unless a settings file already exists there —
never clobbers a hand-edited one, the same convention as the worker
statusLine scaffold in `cc-butler-cleanup-install-statusline'."
  (let ((file (expand-file-name ".claude/settings.json" home)))
    (unless (file-exists-p file)
      (make-directory (file-name-directory file) t)
      (write-region
       (cc-butler--hook-settings-json (expand-file-name hook-relpath home) status-message)
       nil file nil 'silent))))

(defun cc-butler--user-profile-template ()
  "Return the initial (empty) user-profile file the interview fills."
  (concat
   "#+TITLE: User profile — interview-confirmed preferences\n"
   "#+STARTUP: showeverything\n\n"
   "The butler loads this at startup to begin already knowing the boss. It holds\n"
   "ONLY preferences confirmed by the clean-start interview — complementary to,\n"
   "not overlapping with, the memory system's general user notes.\n\n"
   "* Address :: how to address the boss (name / honorific) — [not yet asked]\n"
   "* Communication :: preferred tone, level of detail, explanation style — [not yet asked]\n"
   "* Working style :: pace, ask-vs-decide, preferred formats — [not yet asked]\n"))

(defun cc-butler--interview-inventory-template ()
  "Return the initial clean-start interview inventory (grows over time)."
  (concat
   "#+TITLE: Clean-start interview — inventory\n"
   "#+STARTUP: showeverything\n\n"
   "What the butler asks the boss on a clean start, to personalize. This list\n"
   "GROWS over time: when you find something worth asking every new boss up\n"
   "front, append it here.\n\n"
   "* How should I address you? (name / honorific) — never assume.\n"
   "* How do you prefer I communicate? (tone, level of detail, explanation style)\n"
   "* Any other working-style preferences? (pace, when to ask vs. decide, formats)\n"))

(defun cc-butler--ensure-butler-home ()
  "Create `cc-butler-home' with its markers if missing; return the directory.
Scaffolds the role `CLAUDE.md', an empty `user-profile.org' (the interview
fills it), and an `interview-inventory.org' (the questions to ask)."
  (let ((home (file-name-as-directory (expand-file-name cc-butler-home))))
    (make-directory home t)
    (pcase-dolist (`(,name . ,gen)
                   `((".projectile" . ,(lambda () ""))
                     ("CLAUDE.md" . cc-butler--butler-claude-md)
                     ("user-profile.org" . cc-butler--user-profile-template)
                     ("interview-inventory.org" . cc-butler--interview-inventory-template)
                     (".claude/agents/haiku-summarizer.md" . cc-butler--haiku-summarizer-agent-md)
                     (".claude/hooks/check-pending-decisions.sh" . cc-butler--pending-decisions-hook-sh)))
      (let ((file (expand-file-name name home)))
        (make-directory (file-name-directory file) t)
        (unless (file-exists-p file)
          (write-region (funcall gen) nil file nil 'silent))
        (when (string-suffix-p ".sh" name)
          (set-file-modes file #o755))))
    (cc-butler--ensure-hook-settings-json
     home ".claude/hooks/check-pending-decisions.sh" "Checking pending decisions...")
    home))

(defun cc-butler--live-dir-p (dir)
  "Return non-nil when a live Claude session runs in DIR."
  (let ((target (file-name-as-directory (expand-file-name dir))) found)
    (maphash (lambda (d proc)
               (when (and (process-live-p proc)
                          (equal (file-name-as-directory (expand-file-name d))
                                 target))
                 (setq found t)))
             claude-code-ide--processes)
    found))

;;;###autoload
(defun cc-butler-start-butler ()
  "Launch (or focus) the dedicated butler session in `cc-butler-home'.
Scaffolds the home (`.projectile' + role `CLAUDE.md') on first run,
designates the session as the butler, and opens the manager.  Idempotent:
if a butler session is already running there, it is just focused."
  (interactive)
  (let ((home (cc-butler--ensure-butler-home)))
    (if (cc-butler--live-dir-p home)
        (message "cc-butler: butler already running in %s" home)
      (cc-butler--launch-session home)
      (message "cc-butler: started butler in %s" home))
    (setq cc-butler--butler home)
    (cc-butler)))

(defcustom cc-butler-steward-home
  (expand-file-name "cc-butler/steward" user-emacs-directory)
  "Working directory the steward (operations) session runs in.
`cc-butler-start-steward' creates it on demand with a role `CLAUDE.md'.
Must differ from `cc-butler-home' (two sessions cannot share a directory)."
  :type 'directory
  :group 'cc-butler)

(defun cc-butler--ensure-steward-home ()
  "Create `cc-butler-steward-home' with its markers if missing; return it."
  (let ((home (file-name-as-directory (expand-file-name cc-butler-steward-home))))
    (make-directory home t)
    (pcase-dolist (`(,name . ,gen)
                   `((".projectile" . ,(lambda () ""))
                     ("CLAUDE.md" . cc-butler--steward-claude-md)
                     (".claude/agents/haiku-summarizer.md" . cc-butler--haiku-summarizer-agent-md)
                     (".claude/hooks/check-pending-events.sh" . cc-butler--pending-events-hook-sh)))
      (let ((file (expand-file-name name home)))
        (make-directory (file-name-directory file) t)
        (unless (file-exists-p file)
          (write-region (funcall gen) nil file nil 'silent))
        (when (string-suffix-p ".sh" name)
          (set-file-modes file #o755))))
    (cc-butler--ensure-hook-settings-json
     home ".claude/hooks/check-pending-events.sh" "Checking pending worker events...")
    home))

(defun cc-butler--regenerate-role-home (home claude-md-fn hook-relname hook-fn status-message)
  "Force-rewrite HOME's generated-cache files (CLAUDE.md + its
UserPromptSubmit hook script) from the current template functions.
Unlike `cc-butler--ensure-butler-home'/`cc-butler--ensure-steward-home',
this OVERWRITES even when the files already exist — the whole point is to
propagate template edits into an already-scaffolded, already-running home.
Never touches user-authored files (user-profile.org,
interview-inventory.org) or a hand-edited settings.json. No-ops (returns
nil) if HOME doesn't exist yet — this is a refresh, not initial scaffold."
  (let ((home (file-name-as-directory (expand-file-name home))))
    (when (file-directory-p home)
      (write-region (funcall claude-md-fn) nil (expand-file-name "CLAUDE.md" home) nil 'silent)
      (let ((file (expand-file-name (concat ".claude/hooks/" hook-relname) home)))
        (make-directory (file-name-directory file) t)
        (write-region (funcall hook-fn) nil file nil 'silent)
        (set-file-modes file #o755))
      (cc-butler--ensure-hook-settings-json
       home (concat ".claude/hooks/" hook-relname) status-message)
      t)))

;;;###autoload
(defun cc-butler-home-regenerate ()
  "Regenerate the butler's and steward's CLAUDE.md + UserPromptSubmit hook
from the current template functions — a generated cache of them, the same
relationship `cc-butler-governance-regenerate' has to the governance
store. `cc-butler--ensure-butler-home'/`cc-butler--ensure-steward-home'
only ever write these once (`unless file-exists-p'), so template edits
never reach an already-scaffolded home without calling this. Returns the
count of homes refreshed."
  (interactive)
  (let ((n 0))
    (when (cc-butler--regenerate-role-home
           cc-butler-home #'cc-butler--butler-claude-md
           "check-pending-decisions.sh" #'cc-butler--pending-decisions-hook-sh
           "Checking pending decisions...")
      (setq n (1+ n)))
    (when (cc-butler--regenerate-role-home
           cc-butler-steward-home #'cc-butler--steward-claude-md
           "check-pending-events.sh" #'cc-butler--pending-events-hook-sh
           "Checking pending worker events...")
      (setq n (1+ n)))
    (when (called-interactively-p 'interactive)
      (message "cc-butler: regenerated %d home(s)" n))
    n))

;;;###autoload
(defun cc-butler-start-steward ()
  "Launch (or focus) the steward session in `cc-butler-steward-home'.
Scaffolds the home (`.projectile' + steward role `CLAUDE.md') on first run,
designates it the steward, and opens the manager.  Once the steward runs,
the worker firehose (nudges + `report_to_steward') routes to it instead of
the butler (split mode).  Idempotent."
  (interactive)
  (let ((home (cc-butler--ensure-steward-home)))
    (when (equal (file-name-as-directory (expand-file-name home))
                 (and cc-butler-home
                      (file-name-as-directory (expand-file-name cc-butler-home))))
      (user-error "Steward home must differ from the butler home"))
    (if (cc-butler--live-dir-p home)
        (message "cc-butler: steward already running in %s" home)
      (cc-butler--launch-session home)
      (message "cc-butler: started steward in %s (worker firehose now routes here)" home))
    (setq cc-butler--steward home)
    (cc-butler)))

(with-eval-after-load 'cc-butler-session
  (when (boundp 'cc-butler-mode-map)
    (define-key cc-butler-mode-map "B" #'cc-butler-start-butler)
    (define-key cc-butler-mode-map "S" #'cc-butler-start-steward)))

;;;; ------------------------------------------------------------------
;;;; Launch a session joined to the cc-butler channel
;;;; ------------------------------------------------------------------

;;;###autoload
(defun cc-butler-launch-with-channel ()
  "Start a Claude session in the current project with the cc-butler channel.
Requires `cc-butler-channel-args' to be set (the `--channels' /
`--dangerously-load-development-channels' flag for your channel server)."
  (interactive)
  (when (string-empty-p (string-trim (or cc-butler-channel-args "")))
    (user-error "Set `cc-butler-channel-args' to a channel launch flag first"))
  (cc-butler--with-channel (claude-code-ide)))

;;;; ------------------------------------------------------------------
;;;; PUSH: forward worker events to the butler
;;;; ------------------------------------------------------------------

(defcustom cc-butler-forward 'submit
  "How worker notifications are forwarded to the butler session.
nil     -> do not forward
notify  -> type a one-line summary into the butler, do NOT submit
submit  -> type the summary and submit it, so the butler reacts at once"
  :type '(choice (const :tag "Off" nil)
                 (const :tag "Type only" notify)
                 (const :tag "Type and submit" submit))
  :group 'cc-butler)

(defvar cc-butler--steward nil
  "Working-dir of the designated steward session, or nil.
The steward is the internal-orchestration role: it receives the worker
firehose (nudges + `report_to_steward') and escalates only decisions to the
butler.  When nil, cc-butler runs in single mode and the butler plays both
roles (backward compatible).")

(defun cc-butler--ops-dir ()
  "The session that receives the worker firehose.
The steward when one is designated, else the butler (single mode)."
  (or cc-butler--steward cc-butler--butler))

(defun cc-butler--split-p ()
  "Return non-nil when a distinct steward session is designated (split mode)."
  (and cc-butler--steward (not (equal cc-butler--steward cc-butler--butler))))

(defun cc-butler--forward-to-ops (event)
  "Forward a worker EVENT into the ops (steward, else butler) terminal.
The user-facing butler is never nudged in split mode; only the steward is."
  (when-let* ((mode cc-butler-forward)
              (ops (cc-butler--ops-dir))
              (dir (plist-get event :session))
              ((not (equal dir ops)))
              (mbuf (get-buffer (claude-code-ide--get-buffer-name ops)))
              ((buffer-live-p mbuf)))
    (cc-butler--send-input
     ops
     (format "[cc-butler] Worker %s needs attention: %s"
             (cc-butler--who-dir dir)
             (or (plist-get event :body) (plist-get event :title) ""))
     (eq mode 'submit))))

;; Swap the old single-target forwarder for the ops-aware one (idempotent on
;; reload; the old symbol is simply removed from the hook if present).
(remove-hook 'cc-butler-notification-functions 'cc-butler--forward-to-butler)
(add-hook 'cc-butler-notification-functions #'cc-butler--forward-to-ops)

;;;; ------------------------------------------------------------------
;;;; butler <- steward: the quiet decision channel
;;;; ------------------------------------------------------------------

(defvar cc-butler--butler-inbox nil
  "The butler's quiet decision queue: escalations from the steward.
Separate from the worker firehose (`cc-butler--inbox') so the user-facing
butler only ever sees decisions, drained via `pending_decisions'.")

(defun cc-butler--decisions-file ()
  "Return the shared open-decisions Org file (under the butler home), or nil."
  (when cc-butler--butler
    (expand-file-name "docs/decisions.org"
                      (file-name-as-directory (expand-file-name cc-butler--butler)))))

(defun cc-butler--append-decision (from summary needs)
  "Append a decision (SUMMARY/NEEDS from session FROM) to the shared doc."
  (when-let ((file (cc-butler--decisions-file)))
    (make-directory (file-name-directory file) t)
    (let ((new (not (file-exists-p file))))
      (write-region
       (concat (when new "#+TITLE: Open decisions\n#+STARTUP: showeverything\n\n")
               (format "* %s %s\n" (format-time-string "[%Y-%m-%d %a %H:%M]") summary)
               (when from (format "  from: %s\n" (cc-butler--who-dir from)))
               (when (and needs (stringp needs) (not (string-empty-p (string-trim needs))))
                 (format "  needs: %s\n" (string-trim needs))))
       nil file t 'silent))))

(defun cc-butler-tool-escalate-to-butler (summary &optional needs options)
  "MCP tool (steward -> butler): raise a decision for the human to answer.
SUMMARY is the question, NEEDS what is needed, and OPTIONS an optional string
of choices (one `Label — tradeoff' per line) for a pick-one answer.  Types
NOTHING into any terminal.  When the decision workflow is active the decision
is rendered as a document in 정수님's inbox; otherwise it queues for
`pending_decisions'.  Either way it is appended to the shared `decisions.org'."
  (unless (and summary (stringp summary) (not (string-empty-p (string-trim summary))))
    (error "A decision summary is required"))
  (let* ((self (cc-butler--caller-dir))
         (s (string-trim summary))
         (n (and needs (stringp needs)
                 (not (string-empty-p (string-trim needs))) (string-trim needs))))
    (cond
     ;; human adapter create-path: decision → 정수님's inbox (the watcher renders it)
     ((bound-and-true-p cc-butler-decision-workflow)
      (cc-butler-decision-create self s n (cc-butler--decision-parse-options options)))
     ;; durable agent path: butler's maildir inbox
     ((eq cc-butler-message-transport 'maildir)
      (cc-butler-mail-up-decision self s n))
     ;; legacy in-memory queue
     (t (push (list :time (current-time) :dir self
                    :name (and self (cc-butler--display-name self))
                    :summary s :needs n)
              cc-butler--butler-inbox)))
    (cc-butler--append-decision self s needs)   ; decisions.org audit doc, all paths
    (cc-butler--log "%s -> butler [decision] | %s"
                    (if self (cc-butler--who-dir self) "steward") s)
    (cc-butler--maybe-refresh)
    "Escalated the decision (rendered for 정수님 when the workflow is on, else queued for pending_decisions)."))

(defun cc-butler-tool-pending-decisions ()
  "MCP tool (butler): drain the quiet decision queue (steward escalations)."
  (if (eq cc-butler-message-transport 'maildir)
      (let ((msgs (cc-butler-mail-up-drain (cc-butler--caller-dir))))
        (if (null msgs) "No pending decisions."
          (mapconcat
           (lambda (m)
             (format "- %s%s%s" (plist-get m :summary)
                     (if (plist-get m :from) (format " (from %s)" (plist-get m :from)) "")
                     (if (plist-get m :needs) (format " . needs: %s" (plist-get m :needs)) "")))
           msgs "\n")))
    (if (null cc-butler--butler-inbox)
        "No pending decisions."
      (let ((events (reverse cc-butler--butler-inbox)))
        (setq cc-butler--butler-inbox nil)
        (mapconcat
         (lambda (e)
           (format "- [%s] %s%s%s"
                   (format-time-string "%H:%M" (plist-get e :time))
                   (plist-get e :summary)
                   (if (plist-get e :name) (format " (from %s)" (plist-get e :name)) "")
                   (if (plist-get e :needs) (format " . needs: %s" (plist-get e :needs)) "")))
         events "\n")))))

(setq claude-code-ide-mcp-server-tools
      (seq-remove
       (lambda (spec)
         (member (plist-get (claude-code-ide--normalize-tool-spec spec) :name)
                 '("escalate_to_butler" "pending_decisions")))
       claude-code-ide-mcp-server-tools))

(claude-code-ide-make-tool
 :function #'cc-butler-tool-escalate-to-butler
 :name "escalate_to_butler"
 :description "Steward only: raise a DECISION to the user-facing butler's quiet queue, for the butler to present to the human. Use it when something genuinely needs a human decision or input (not routine progress — that stays with you). The butler drains this via pending_decisions and relays the answer back to you with send_to_session. State the decision plainly in `summary' and exactly what is needed in `needs'."
 :args '((:name "summary"
                :type string
                :description "The decision to be made, stated plainly (e.g. 'billing worker: use Stripe or Paddle?').")
         (:name "needs"
                :type string
                :description "Exactly what you need from the human (a choice, an approval, missing info). Optional."
                :optional t)
         (:name "options"
                :type string
                :description "Optional choices for a pick-one answer, one per line as 'Label — tradeoff' (tradeoff optional), e.g. 'Stripe — lower fees\\nPaddle — handles VAT'. Rendered as selectable options in the decision document."
                :optional t)))

(claude-code-ide-make-tool
 :function #'cc-butler-tool-pending-decisions
 :name "pending_decisions"
 :description "Butler only: drain your quiet decision queue — the decisions the steward has escalated for the human to decide. Call it at the start of a turn (and when nudged) to see what needs the boss's attention, without the worker firehose. Returns the decisions and clears them; present them cleanly to the human, then relay each answer down to the steward with send_to_session."
 :args nil)

;;;; ------------------------------------------------------------------
;;;; MCP tools (the butler's hands)
;;;; ------------------------------------------------------------------

(defun cc-butler-tool-list-sessions ()
  "MCP tool: list the live Claude sessions for the butler."
  (let ((self (cc-butler--caller-dir))
        (rows '()))
    (dolist (s (cc-butler--sessions))
      (let ((dir (plist-get s :dir)))
        (push (format "- %s%s | %s | branch:%s%s | %s%s"
                      (cc-butler--display-name dir)
                      (cond ((equal dir self) " (you)")
                            ((equal dir cc-butler--butler) " (butler)")
                            (t ""))
                      (if (cc-butler--waiting-p dir) "WAITING-FOR-INPUT" "running")
                      (let ((b (plist-get s :branch))) (if (string-empty-p b) "-" b))
                      (let ((f (plist-get s :forge))) (if (string-empty-p f) "" (concat " " f)))
                      (let ((o (plist-get s :osc))) (if (string-empty-p o) "" o))
                      (let ((m (and (fboundp 'cc-butler-cleanup-model-tag)
                                    (cc-butler-cleanup-model-tag dir))))
                        (if m (concat " | " m) "")))
              rows)))
    (if rows (mapconcat #'identity (nreverse rows) "\n") "No active Claude sessions")))

(defun cc-butler-tool-read-session (name &optional lines)
  "MCP tool: return the recent terminal output of session NAME."
  (let ((dir (cc-butler--dir-by-name name)))
    (if (not dir)
        (format "No session named %S.  Call list_claude_sessions for names." name)
      (or (cc-butler--read-output dir (and lines (truncate lines)))
          "(no output)"))))

(defun cc-butler-tool-send-session (name text)
  "MCP tool: type TEXT into session NAME and submit it."
  (let ((self (cc-butler--caller-dir))
        (dir (cc-butler--dir-by-name name)))
    (cond
     ((not dir)
      (format "No session named %S.  Call list_claude_sessions for names." name))
     ((equal dir self)
      (error "Refusing to send to the calling session itself"))
     (t
      (cc-butler--send-input dir text t)
      (cc-butler--clear-waiting dir)       ; commanding a worker attends to it
      (cc-butler--log "%s → %s │ %s" (cc-butler--who-dir self) (cc-butler--who-dir dir) text)
      (cc-butler--maybe-refresh)
      (format "Sent to %s and submitted." name)))))

(defun cc-butler-tool-report-to-steward (summary &optional status needs)
  "MCP tool: a worker reports to the steward with real content.
SUMMARY is what happened / what was done, STATUS the current state, and
NEEDS what the worker needs from the human (all teed to the inbox and
log).  The caller's session name and id are attached automatically.

NOTE: despite the name, this does NOT reach the butler — it lands in the
steward's worker-firehose queue (`cc-butler--inbox' / `pending_events').
Only the steward can put something in front of the human, via
`escalate_to_butler'. This function was named/documented as reporting
\"to the butler\" until 2026-07-09; that was a bug (worker reports were
silently landing with the steward instead, and the butler had no
auto-hook onto this queue at all), not the intended two-tier design —
see `cc-butler-tool-report-to-butler' below, kept only as a deprecated
alias for already-connected callers."
  (let ((self (cc-butler--caller-dir)))
    (unless self
      (error "No calling session context for this report"))
    (let* ((parts (delq nil
                        (list (and (stringp summary) (not (string-empty-p summary)) summary)
                              (and (stringp status) (not (string-empty-p status))
                                   (concat "status: " status))
                              (and (stringp needs) (not (string-empty-p needs))
                                   (concat "needs: " needs)))))
           (msg (if parts (string-join parts " · ") "(empty report)")))
      (if (eq cc-butler-message-transport 'maildir)
          ;; The maildir path doesn't route through `cc-butler--inbox-push',
          ;; so it misses that function's advice-based auto-log — log
          ;; directly here instead, so "report -> logged" holds under
          ;; either transport, not just the in-memory default.
          (progn
            (cc-butler-mail-up-report self msg)
            (when (fboundp 'cc-butler-docs--auto-log)
              (cc-butler-docs--auto-log self msg)))
        (cc-butler--inbox-push self msg))
      (cc-butler--maybe-refresh)
      (format "Reported to the steward as %s." (cc-butler--who-dir self)))))

(defalias 'cc-butler-tool-report-to-butler 'cc-butler-tool-report-to-steward
  "Deprecated alias — see `cc-butler-tool-report-to-steward'.
Kept only so an already-connected session that still has the old MCP
tool name `report_to_butler' cached doesn't hit a hard tool-not-found
error mid-task. New callers should use `report_to_steward'.")

(defun cc-butler-tool-inbox ()
  "MCP tool: return and clear the steward's pending worker events.
This is the pull side of the bus: worker notifications (needs input /
done) are queued in Emacs and drained here, so the steward gets them
without anything being typed into its input box."
  (if (eq cc-butler-message-transport 'maildir)
      (let ((msgs (cc-butler-mail-up-drain (cc-butler--caller-dir))))
        (if (null msgs) "No pending worker events."
          (mapconcat (lambda (m)
                       (format "- %s: %s" (or (plist-get m :from) "?")
                               (plist-get m :body)))
                     msgs "\n")))
    (if (null cc-butler--inbox)
        "No pending worker events."
      (let ((events (reverse cc-butler--inbox)))
        (setq cc-butler--inbox nil)
        (mapconcat (lambda (e)
                     (format "- [%s] %s: %s"
                             (format-time-string "%H:%M" (plist-get e :time))
                             (cc-butler--who (plist-get e :name) (plist-get e :id))
                             (plist-get e :body)))
                   events "\n")))))

;; Idempotent (re)registration: drop prior copies before adding.
(setq claude-code-ide-mcp-server-tools
      (seq-remove
       (lambda (spec)
         (member (plist-get (claude-code-ide--normalize-tool-spec spec) :name)
                 '("list_claude_sessions" "read_session_output"
                   "send_to_session" "pending_events"
                   "report_to_steward" "report_to_butler")))
       claude-code-ide-mcp-server-tools))

(claude-code-ide-make-tool
 :function #'cc-butler-tool-inbox
 :name "pending_events"
 :description "Steward only: drain your inbox of pending events from worker sessions that need attention (a worker asked a question, finished, reported via report_to_steward, or hit a prompt), newest last. Each line is a timestamped worker name (with its session id) and message. Call this at the start of each turn (and whenever you are nudged) to learn what changed without anything being typed into your input box. Returns the events and clears them."
 :args nil)

(claude-code-ide-make-tool
 :function #'cc-butler-tool-report-to-steward
 :name "report_to_steward"
 :description "Report up to the steward with real content — not just 'I need attention'. State WHAT happened / what you did, the current STATE, and exactly what you NEED (a decision, input, or nothing). Your session name and id are attached automatically; the steward drains this via pending_events and tracks/dispatches you from there. This does NOT reach the human/butler directly — the steward escalates to the butler only when something genuinely needs a human decision. Call it when you finish, get blocked, or have a status update."
 :args '((:name "summary"
                :type string
                :description "What happened or what you did — the substance of the report (e.g. 'implemented invoice PDF rendering, all tests pass').")
         (:name "status"
                :type string
                :description "Current state, e.g. 'PR #42 open, CI green' or 'blocked on the DB migration'. Optional."
                :optional t)
         (:name "needs"
                :type string
                :description "What you need to proceed, e.g. 'review this PR' or 'which auth method to use'. Omit (or 'nothing') if you are only informing. Optional."
                :optional t)))

(claude-code-ide-make-tool
 :function #'cc-butler-tool-report-to-butler
 :name "report_to_butler"
 :description "DEPRECATED — renamed to `report_to_steward' on 2026-07-09 (this tool never actually reached the butler; it always landed with the steward). Kept only so already-connected sessions don't hit a tool-not-found error. Use report_to_steward instead."
 :args '((:name "summary"
                :type string
                :description "What happened or what you did — the substance of the report (e.g. 'implemented invoice PDF rendering, all tests pass').")
         (:name "status"
                :type string
                :description "Current state, e.g. 'PR #42 open, CI green' or 'blocked on the DB migration'. Optional."
                :optional t)
         (:name "needs"
                :type string
                :description "What you need to proceed. Omit (or 'nothing') if you are only informing. Optional."
                :optional t)))

(claude-code-ide-make-tool
 :function #'cc-butler-tool-list-sessions
 :name "list_claude_sessions"
 :description "List the other live Claude Code sessions running in this Emacs (the workers you orchestrate): their stable name, whether each is WAITING-FOR-INPUT, its git branch, its current activity title, and (when known) the model it's running. Call this first to learn the names used by read_session_output and send_to_session."
 :args nil)

(claude-code-ide-make-tool
 :function #'cc-butler-tool-read-session
 :name "read_session_output"
 :description "Read the recent terminal screen of another Claude session by name, to see what it is doing or asking. The text is that session's live TUI screen (may include UI chrome)."
 :args '((:name "name"
                :type string
                :description "Session name from list_claude_sessions (e.g. 'app-billing').")
         (:name "lines"
                :type integer
                :description "How many trailing lines to return (default 40)."
                :optional t)))

(claude-code-ide-make-tool
 :function #'cc-butler-tool-send-session
 :name "send_to_session"
 :description "Type a prompt/answer into another Claude session by name and submit it (press Enter), to direct that worker. Use to answer a worker's question, give it a task, or unblock it. You cannot send to yourself. Multi-line is supported: include newlines in text — they are delivered as a paste and stay literal, and Enter is pressed only once, at the end, to submit. CAUTION when sending free-form text (not answering a question you just asked): if the target has an open interactive prompt or menu (e.g. from AskUserQuestion), your one submit-Enter lands on whatever is highlighted there, not on your text — it is silently swallowed on both ends. Check with read_session_output first when unsure, and tell dispatched workers to prefer report_to_steward/escalate_to_butler over AskUserQuestion so this cannot happen."
 :args '((:name "name"
                :type string
                :description "Target session name from list_claude_sessions.")
         (:name "text"
                :type string
                :description "The text to type into that session before submitting. May contain newlines for a multi-line prompt; only the final submit presses Enter.")))

(provide 'cc-butler-orchestrator)
;;; cc-butler-orchestrator.el ends here
