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
(require 'cc-butler-governance)
(require 'claude-code-ide)
(require 'json)

;; The up-direction tools optionally route through the durable maildir inbox
;; (`cc-butler-mail', loaded after this file); declared so the byte-compiler is
;; content and the runtime dispatch on `cc-butler-message-transport' works.
(declare-function cc-butler-mail-up-report "cc-butler-mail" (from-dir body))
(declare-function cc-butler-mail-up-decision "cc-butler-mail" (from-dir summary needs))
(declare-function cc-butler-mail-up-drain "cc-butler-mail" (agent-dir))
(declare-function cc-butler--check-inbox-drain-as "cc-butler-mail" (agent-name))
(declare-function cc-butler-decision-create "cc-butler-decision" (from-dir summary needs options &optional kind))
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

(defun cc-butler--output-buffer-and-bounds (dir &optional lines)
  "Return (BUF START . END) for the last LINES (default 40) of DIR's
terminal screen, after a force-refresh, or nil if the buffer isn't live.
Bounded by `cc-butler-session-io-timeout' so a stuck redraw cannot hang
the caller.  Shared by `cc-butler--read-output' (plain text, properties
stripped) and `cc-butler--read-output-redacted' (ghost-input-line-aware,
which needs BUF itself — the terminal cursor lives on the buffer, not in
any string cut out of it).

The window is anchored on the tail of the buffer's REAL content, not on
`point-max' — a grid redraw pads unused rows below the actual content
with blank lines all the way to `point-max' (e.g. right after a screen
clear, when the cursor sits near the top of a grid much taller than the
visible content), and a literal last-LINES-by-count window would then
land entirely inside that padding and report nothing (cc-butler#39)."
  (with-timeout (cc-butler-session-io-timeout
                 (error "Timed out reading session %s's output after %ss (redraw or buffer access may be stuck)"
                        (cc-butler--display-name dir) cc-butler-session-io-timeout))
    (let ((buf (get-buffer (claude-code-ide--get-buffer-name dir))))
      ;; A failed refresh leaves the last frame that DID render sitting in the
      ;; buffer.  Serving it would present old text as the current screen, and a
      ;; caller acting on that — answering a permission dialog it cannot
      ;; actually see — is the expensive mistake.  Report nothing instead.
      (when (and (buffer-live-p buf) (cc-butler--refresh-terminal-text buf))
        (with-current-buffer buf
          (let* ((n (max 1 (or lines 40)))
                 ;; A grid redraw pads unused rows below the actual content
                 ;; with blank lines all the way to `point-max' — e.g. right
                 ;; after a screen clear, when the cursor sits near the top
                 ;; of a grid much taller than the visible content
                 ;; (cc-butler#39).  Anchor on the tail of the REAL content,
                 ;; not the tail of the buffer, so that padding doesn't push
                 ;; the actual last N lines out of the window entirely.  A
                 ;; buffer that is blank throughout falls back to
                 ;; `point-max' unchanged — still, correctly, "no output".
                 (end (save-excursion
                        (goto-char (point-max))
                        (skip-chars-backward " \t\n")
                        (if (bobp) (point-max) (line-end-position))))
                 (start (save-excursion (goto-char end)
                                        (forward-line (- n))
                                        (line-beginning-position))))
            (cons buf (cons start end))))))))

(defun cc-butler--read-output (dir &optional lines)
  "Return the last LINES (default 40) of session DIR's terminal screen, as
plain text.  See `cc-butler--output-buffer-and-bounds'."
  (when-let ((bb (cc-butler--output-buffer-and-bounds dir lines)))
    (with-current-buffer (car bb)
      (string-trim (buffer-substring-no-properties (cadr bb) (cddr bb))))))

(defconst cc-butler--ghost-marker "❯ [ghost suggestion, not user input]"
  "Stand-in for an input row that holds a painted suggestion, not input.")

(defconst cc-butler--unreadable-input-marker
  "❯ [input row UNVERIFIED — could not tell real input from a ghost suggestion; redacted]"
  "Stand-in for an input row whose ghost-vs-real state could not be read.
Says so out loud, deliberately.  The alternative to a noisy marker is
handing a reader a clean-looking line that was actually a guess, and a
guess that reads as a human instruction is the whole failure mode this
redaction exists to prevent.  A reader who sees this can go look at the
session; a reader handed a confident wrong answer cannot know to.")

(defun cc-butler--redact-ghost-input-line (start end)
  "Return the current buffer's text between START and END, with the live
input row replaced by a marker unless it holds text a human really typed.

The row is LOCATED by the border rules that frame it
\(`cc-butler--find-input-line', anchored on the U+2500 rule CHARACTER, never
on a color).  What is IN it is judged by `cc-butler--input-state' — the
terminal cursor.  A row that is empty once padding is stripped is left
alone either way: there is no text in it to be misread, and a marker there
would be noise on every idle session in the fleet.

FAIL-SAFE DIRECTION, read_session_output: an UNKNOWN state is treated as
GHOST and redacted.  What this answer gates is whether to SHOW a row to a
reader.  A ghost suggestion shown as real input gets read as an instruction
from the human — on 2026-07-23 a painted sentence very nearly became one —
and nothing downstream can audit it back to the screen it came from.  A
real line withheld is withheld VISIBLY: the marker is right there, and the
reader can open the session.  So the unreadable case is redacted, and it
carries `cc-butler--unreadable-input-marker' rather than the ghost marker
so that a guess is never presented as a determination.  The compaction
guard in `cc-butler-compact--typed-text' gates the opposite thing and takes
UNKNOWN the opposite way; that is why `cc-butler--input-state' reports
three outcomes instead of a boolean.

DELETED HERE 2026-07-24 (cc-butler#6): this used to compare the row's face
FOREGROUND against a constant — #a7a7a7 on #262626.  Measured live on this
fleet, ghost text is painted #8686a8 on #00005f, so the comparison never
once matched; and because the old fail-safe leaned the other way (\"cannot
tell -> real input\"), every ghost row was silently promoted to real input.
Styling is not state.  Do not reintroduce a color check here — that is the
third time this codebase has paid for one."
  (save-excursion
    (let* ((line-beg (cc-butler--find-input-line start end))
           (line-end (and line-beg (save-excursion (goto-char line-beg)
                                                   (line-end-position))))
           (painted (and line-beg
                         (cc-butler--strip-input-pad
                          (buffer-substring-no-properties line-beg line-end))))
           (marker (and painted (not (string-empty-p painted))
                        (pcase (car (cc-butler--input-state))
                          ('real nil)
                          ('ghost cc-butler--ghost-marker)
                          (_ cc-butler--unreadable-input-marker)))))
      (if marker
          (concat (buffer-substring-no-properties start line-beg)
                  marker
                  (buffer-substring-no-properties line-end end))
        (buffer-substring-no-properties start end)))))

(defun cc-butler--break-status-markers (text)
  "Make any echoed statusline markers in TEXT human-readable but UN-SCRAPABLE.
`read_session_output' renders ANOTHER session's terminal into the caller's
scrollback; a `CTX:'/`MODEL:' statusline marker echoed there could be
misattributed as the caller's OWN by a positional scrape (the 2026-07-27
misattribution).  Rewriting the colon form to `=' keeps the values fully
visible for human verification (CTX=371538, MODEL=Opus-4.8 — the numbers are
NOT stripped) while removing the exact `CTX:'/`MODEL:' shape the statusline
scrape requires, so a coordinator's scrollback can never poison session_status.
Defense-in-depth alongside the bottom-chrome anchor in
`cc-butler-cleanup--statusline-fields'.  Only affects text handed to a reader
of ANOTHER session; a worker verifying its OWN buffer still sees the real
CTX:/MODEL: statusline."
  (replace-regexp-in-string
   "MODEL:" "MODEL="
   (replace-regexp-in-string "CTX:" "CTX=" text)))

(defun cc-butler--read-output-redacted (dir &optional lines)
  "Like `cc-butler--read-output', but the live input row is replaced with a
plain marker unless a human really typed into it — used by the
`read_session_output' MCP tool so a caller can never mistake a painted
suggestion for a blocker, an authorization, or data.  A row whose state
cannot be determined is redacted too, and says so.  Echoed `CTX:'/`MODEL:'
statusline markers are additionally broken to `CTX='/`MODEL=' (still readable,
no longer scrapable) so another session's marker cannot be misread as the
caller's own — see `cc-butler--break-status-markers'.  See
`cc-butler--redact-ghost-input-line' and governance principle
butler-ghost-text-not-a-blocker-authorization-or-data."
  (when-let ((bb (cc-butler--output-buffer-and-bounds dir lines)))
    (with-current-buffer (car bb)
      (cc-butler--break-status-markers
       (string-trim (cc-butler--redact-ghost-input-line (cadr bb) (cddr bb)))))))

(defcustom cc-butler-submit-delay 0.1
  "Seconds to wait after sending text before the submitting Return.
The worker's input must settle before Enter or the Return is dropped and
nothing submits (the same delay `claude-code-ide-send-prompt' uses).
Spent as a non-yielding busy-wait (`cc-butler--settle') so nothing can
run between the typing and the Return, so Emacs is unresponsive for this
long on every submitting send — keep it small."
  :type 'number
  :group 'cc-butler)

(defun cc-butler--settle (seconds)
  "Let SECONDS of wall clock pass WITHOUT yielding to Emacs.
A no-op when SECONDS is nil or not positive.

The busy-wait is deliberate, and the whole point of this function.
`sleep-for', `sit-for', `accept-process-output' and `redisplay' all give
timers a chance to run; Elisp being single-threaded, a stretch of code
with none of those forms in it is atomic with respect to every cc-butler
timer.  Used between the two halves of a terminal write (type, then
Return), a yielding wait is precisely the hole another timer slips
through to type and submit its own text on the same session — see
`cc-butler--send-input'.

Waiting without yielding is sufficient here because the thing we are
waiting on is not Emacs: the bytes we just wrote have already been handed
to the pty and are consumed by the OS and the worker subprocess, which
run regardless of what Emacs does.  Only wall-clock time is needed, not
Emacs attention.  The price is that Emacs is unresponsive for the
duration, which is why the caller's delay is a fraction of a second
\(`cc-butler-submit-delay', 0.1s) — cheap next to a dropped Return or a
corrupted prompt."
  (when (and (numberp seconds) (> seconds 0))
    (let ((deadline (+ (float-time) seconds)))
      (while (< (float-time) deadline)
        ;; Spin on purpose.  Anything that waits here would run timers.
        nil))))

(defun cc-butler--send-input (dir text &optional submit)
  "Type TEXT into session DIR's terminal; when SUBMIT, also press Return.
Claude treats a raw LF as a submit, so multi-line TEXT is delivered as a
bracketed paste (\\e[200~..\\e[201~) — Claude enables paste mode, which
keeps the embedded newlines literal so only the final Return submits.
Carriage returns are normalized to LF and stray ESC bytes are stripped so
the body cannot break out of the paste or submit mid-prompt.  A short
settle delay precedes the Return so it is not dropped before the input is
processed.

That delay deliberately does NOT yield (`cc-butler--settle', a busy-wait,
not `sleep-for').  Typing and submitting are two writes that must reach
the worker as one indivisible act, and a yielding wait between them lets
another timer — mail delivery, the compaction monitor, a dispatch — call
this same function on this same session, type and submit its own text,
and leave our Return to land on whatever state it produced.  That is the
2026-07-23 race: a command left typed-but-unsubmitted, and stale text
prepended to the next dispatch.  Keep this sequence free of `sleep-for',
`sit-for', `accept-process-output' and `redisplay'."
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
          (cc-butler--settle cc-butler-submit-delay)
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
The per-project directory (Claude's `/'-and-`.'-to-`-' slug of the path) is the
shared `cc-butler--claude-project-dir'; the memory dir is its `memory/'
subdirectory."
  (when-let ((proj (cc-butler--claude-project-dir project-dir)))
    (expand-file-name "memory/" proj)))

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
     (format (concat "- **operating-principle source of truth:** `%s`\n"
                     "  (one `.md` per principle, runtime-neutral). `M-x"
                     " cc-butler-governance-regenerate`\n  refreshes each note's cached"
                     " *body* from the store and add-only syncs\n  `MEMORY.md`'s index"
                     " (tracked: cc-butler#36) — but \"add-only\" means three\n  different"
                     " things depending on what changed:\n"
                     "  1. **New note** → regenerate appends a correctly-named index line"
                     " by itself.\n     Never hand-add a line for a new note — a"
                     " hand-written one can miss the\n     real cached filename (e.g. the"
                     " `butler-` prefix) and sit duplicated next to\n     the correct"
                     " auto-generated line instead of replacing it.\n"
                     "  2. **An existing note's `description:` changed** → regenerate does"
                     " NOT\n     rewrite its index line (it only checks whether a line for"
                     " the slug exists,\n     not whether it's current). Hand-patching that"
                     " one line is the only way to\n     fix it — this is exactly what #36"
                     " tracks and remains open for.\n"
                     "  3. **\"Index check: 0 un-indexed\" is not \"index matches"
                     " store.\"** It only\n     counts slugs with zero lines; a slug whose"
                     " line is stale-but-present still\n     reads as 0, so a green check"
                     " here says nothing about whether descriptions\n     are current.\n")
             (abbreviate-file-name (cc-butler-governance-store)))
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

;; Screen predicates from cc-butler-compact (which loads after this module,
;; so calls are fboundp-guarded — same pattern as `cc-butler-mail-journal-send'
;; in `cc-butler-tool-send-session' and `cc-butler-compact-fleet-summary'
;; below).
(declare-function cc-butler-compact--menu-p "cc-butler-compact" (screen))
(declare-function cc-butler-compact--pending-input-p "cc-butler-compact" (dir))

(defvar cc-butler--fleet-dialog-first-seen (make-hash-table :test 'equal)
  "Map session working-dir -> float-time its on-screen blocker was first
detected, for the fleet check's de-duplication.  Same bargain as
`cc-butler-compact--last-report': a standing situation is restated in an
abbreviated \"(continuing)\" form rather than re-announced as new every
turn — and never silently dropped, because a blocker that stops being
mentioned reads as a blocker that cleared.  An entry survives an
unreadable scan on purpose (a failed read is not evidence the dialog
cleared) and is removed only when a successful read shows a clean
screen, or when the session itself is gone.")

(defun cc-butler--fleet-dialog-state (dir)
  "Return what session DIR's screen measurably shows, by reading it now.
`menu' — an open numbered choice menu/dialog is visible on screen
\(`cc-butler-compact--menu-p').  `input' — typed-but-unsubmitted text is
sitting in the input box (`cc-butler-compact--pending-input-p').
`unreadable' — the screen could not be read, so nothing is known either
way.  nil — the screen was read successfully and shows neither.  These
are the same measured signals the compaction pre-flight guards act on
\(`cc-butler-compact--menu-block-reason'), reused here as observation."
  (condition-case nil
      (let ((screen (cc-butler--read-output dir 40)))
        (cond
         ((null screen) 'unreadable)
         ((cc-butler-compact--menu-p screen) 'menu)
         ((cc-butler-compact--pending-input-p dir) 'input)))
    (error 'unreadable)))

(defun cc-butler--fleet-dialog-summary ()
  "Return a string listing sessions whose SCREEN actually shows a blocking
dialog/menu or unsubmitted input, or nil when there is nothing to say.
Scans every live session (`cc-butler--sessions') regardless of any
waiting/idle flag — the flags are exactly what can freeze, and a frozen
session with a dialog up was the real miss.  Excludes the butler/steward
roles themselves, as before: this is about fleet members, not the
reader's own state.

Replaces the stale-waiting clock alarm — \"in `cc-butler--waiting' longer
than `cc-butler-fleet-stale-waiting-seconds'\", a defcustom deleted with
it 2026-08-21 — whose only predicate was elapsed time: it re-flagged routinely parked workers
on every steward turn (11 at once, zero actual dialogs among them on the
day it was measured) while structurally excluding a session whose
waiting flag was stuck at nil with a dialog genuinely on screen — which
then sat unanswered for over a day.  Time on a clock implies nothing by
itself; only the screen says whether something needs answering.

Sessions whose screen cannot be read are listed separately as
unverified, never silently dropped — a failed read is not evidence of
absence.  Returns nil without claiming anything when cc-butler-compact's
screen predicates are not loaded (that module loads after this one)."
  (when (fboundp 'cc-butler-compact--menu-p)
    (let ((now (float-time)) live rows unreadable)
      (dolist (s (cc-butler--sessions))
        (let ((dir (plist-get s :dir)))
          (push dir live)
          (unless (or (equal dir cc-butler--butler)
                      (equal dir cc-butler--steward))
            (pcase (cc-butler--fleet-dialog-state dir)
              ('unreadable
               (push (format "- %s" (cc-butler--display-name dir)) unreadable))
              ('nil (remhash dir cc-butler--fleet-dialog-first-seen))
              (kind
               (let ((what (if (eq kind 'menu)
                               "a choice menu/dialog is visible on screen"
                             "unsubmitted text is sitting in the input box"))
                     (first (gethash dir cc-butler--fleet-dialog-first-seen)))
                 (push (if first
                           (format "- %s — %s (continuing, first detected %dm ago)"
                                   (cc-butler--display-name dir) what
                                   (round (/ (- now first) 60)))
                         (puthash dir now cc-butler--fleet-dialog-first-seen)
                         (format "- %s — %s" (cc-butler--display-name dir) what))
                       rows)))))))
      ;; Entries for sessions that no longer exist are stale state, not
      ;; standing situations — drop them.
      (maphash (lambda (dir _)
                 (unless (member dir live)
                   (remhash dir cc-butler--fleet-dialog-first-seen)))
               cc-butler--fleet-dialog-first-seen)
      (when (or rows unreadable)
        (mapconcat
         #'identity
         (delq nil
               (list
                (when rows
                  (format "🔍 Fleet check: %d session(s) with a dialog/menu or unsubmitted input visible on screen — read_session_output to see it, then answer or clear it:\n%s"
                          (length rows)
                          (mapconcat #'identity (nreverse rows) "\n")))
                (when unreadable
                  (format "🔍 Fleet check: %d session(s) whose screen could not be read — unverified either way, not evidence of absence; read_session_output to check:\n%s"
                          (length unreadable)
                          (mapconcat #'identity (nreverse unreadable) "\n")))))
         "\n\n")))))

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
dialog check. Any subset may be absent; returns \"\" when all
three are empty."
  (let* ((inbox (cc-butler--inbox-urgent-block "steward"))
         (events (cc-butler-tool-inbox))
         (has-events (not (equal events "No pending worker events.")))
         ;; Guarded like `ceiling' below, and for a sharper reason: this walks
         ;; every session and reads every screen, so it is a larger error
         ;; surface than the drain that precedes it — and it runs AFTER that
         ;; drain.  An unguarded failure here would take the drained events
         ;; down with it.  A missing nudge is a small loss; a swallowed worker
         ;; report is not.
         (dialogs (ignore-errors (cc-butler--fleet-dialog-summary)))
         ;; cc-butler-compact loads after this module, so reach it late.
         ;; Same bargain as the fleet dialog check: elisp reports what is
         ;; over the context ceiling, the steward decides when to act.
         (ceiling (and (fboundp 'cc-butler-compact-fleet-summary)
                       (ignore-errors (cc-butler-compact-fleet-summary)))))
    (mapconcat #'identity
               (delq nil (list inbox (and has-events events) dialogs ceiling))
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
queue (MCP tool `pending_events'), and a fleet dialog check — on
every turn. Same `cc-butler-message-transport' fragility applies to the
pending_events half identically; see that function's docstring."
  "#!/usr/bin/env bash
# UserPromptSubmit hook: mechanically drains cc-butler's pending_events
# (worker firehose) queue, check_inbox (ask_worker replies), and a fleet
# dialog check on every turn and injects them as context, so the
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

(defcustom cc-butler-forward-gate t
  "When non-nil, worker notifications go through the batched, gated
forwarder (classification + idle gate + backstop) instead of being typed
into the ops terminal one interrupt per event.  nil restores the legacy
unconditional per-event forward — the live-rollback lever: flipping this
variable changes behavior immediately, no reload required.
See docs/cc-butler-steward-inbox-design.md."
  :type 'boolean :group 'cc-butler)

(defcustom cc-butler-forward-classify-alist
  '(("waiting for your input" . deferred))
  "Allowlist classifying raw notification events by body (title fallback).
Each entry is (REGEXP . DISPOSITION); the first match wins.  DISPOSITION:

  no-wake  -> inbox only; never actively pushed.
  deferred -> inbox now; pushed only if the session then stays static
              for `cc-butler-forward-defer-window' (see
              `cc-butler--forward-defer').
  wake     -> gated push now (`cc-butler--forward-wake').

An event matching NO entry is `wake' BY CONSTRUCTION — this list names
what is known-harmless, never what is dangerous.  A denylist ages with
every new risk and its failure is silent; this direction makes drift in
the harness's notification strings fail-visible instead (an unmatched
string produces extra wakes, which announce themselves), and it keeps
the one case that can never speak for itself — a worker blocked on a
permission prompt cannot call any MCP tool — waking by default.

The initial no-wake set is deliberately EMPTY: add an entry only for a
body string actually observed from a session that was verifiably free
(e.g. turn-finished notifications), not for one assumed to exist."
  :type '(alist :key-type regexp
                :value-type (choice (const no-wake) (const deferred) (const wake)))
  :group 'cc-butler)

(defcustom cc-butler-forward-idle-threshold 60
  "Seconds since the ops session's newest transcript write below which the
live push is withheld (the event stays in the durable inbox for the
backstop or the ops session's own next turn).  Deliberately a SEPARATE
knob from `cc-butler-idle-threshold' (600s): that window answers \"is it
safe to destroy this session's context\", this one answers \"is the ops
session mid-turn right now\" — coupling them would make escalation
latency a silent side effect of compaction tuning (the same argument
that split `cc-butler-forward-backstop-interval' from the compaction
monitor's interval)."
  :type 'number :group 'cc-butler)

(defcustom cc-butler-forward-defer-window 600
  "Seconds a `deferred' event waits before it may escalate to a push.
Starting point, not a settled constant — tune in operation."
  :type 'number :group 'cc-butler)

(defcustom cc-butler-forward-backstop-interval 3600
  "Seconds between backstop sweeps (`cc-butler--forward-backstop'), the
bounded worst-case latency for a wake-worthy event that arrived while
the ops session was busy.  Initial value 3600s is an operating STARTING
POINT (decided 2026-08-10), expected to be tuned in operation — it is a
separate defcustom precisely so tuning it never silently retunes the
compaction monitor, and vice versa."
  :type 'number :group 'cc-butler)

(defvar cc-butler--forward-deferred (make-hash-table :test #'equal)
  "dir -> plist (:since FLOAT-TIME :body STRING :timer TIMER) for events
classified `deferred' and not yet resolved or escalated.")

(defvar cc-butler--forward-last-push nil
  "`float-time' of the last live push into the ops terminal, or nil.")

(defvar cc-butler--forward-backstop-timer nil
  "The repeating backstop timer, or nil.")

(defun cc-butler--forward-classify (event)
  "Classify EVENT via `cc-butler-forward-classify-alist'.
Returns `no-wake', `deferred' or `wake'; unmatched is `wake' by
construction (see the alist's docstring).  Keys off the event's own
:body/:title strings — never a fresh read of the reporting session's
screen, which may itself be degraded (cc-butler#39)."
  (let ((text (or (plist-get event :body) (plist-get event :title) "")))
    (or (cdr (assoc text cc-butler-forward-classify-alist
                    (lambda (re s) (string-match-p re s))))
        'wake)))

(defun cc-butler--forward-ops-free-p (ops)
  "Non-nil when OPS looks free enough to type into right now.

Two independent checks, both must pass:

- TRANSCRIPT: nil when OPS's newest transcript write is fresher than
  `cc-butler-forward-idle-threshold', or when no transcript can be found
  at all — a session whose state cannot be confirmed must not be typed
  into. On this axis, same fail-safe direction as the compaction gate.

- INPUT BOX: nil when OPS's own input box holds text a human actually
  typed, via `cc-butler-compact--pending-input-p' — reusing the
  cursor-based real/ghost/unknown judgement in `cc-butler--input-state'
  rather than a new probe (a painted ghost suggestion is not real input
  and does not block; see that function's docstring for why no color
  check can tell the two apart). On THIS axis, an earlier version of this
  docstring claimed blanket parity with the compaction gate while this
  check did not exist yet — true only on the transcript/unknown axis
  above, false here, since a reader who stopped at \"same as compaction\"
  had no reason to suspect a typed human draft could still be typed over.
  It cannot anymore: `cc-butler-compact--pending-input-p' returns non-nil
  (blocking) on a real draft, and, like the compaction gate, also on an
  UNKNOWN box read. The push is only ever an accelerant — the event is
  already durable in the inbox regardless — so declining to push costs
  latency, while typing over an unread human sentence destroys it
  outright; that asymmetry is why unknown blocks here too, same as it
  does for compaction, rather than defaulting to allow."
  (let ((last (cc-butler--session-last-activity ops)))
    (and last (>= (- (float-time) last) cc-butler-forward-idle-threshold)
         (not (cc-butler-compact--pending-input-p ops)))))

(defun cc-butler--forward-pending-count ()
  "How many worker events are sitting undrained for the ops session.
Under the maildir transport the in-memory `cc-butler--inbox' is not the
authority, so count the ops box's new/ files instead."
  (if (and (boundp 'cc-butler-message-transport)
           (eq cc-butler-message-transport 'maildir)
           (fboundp 'cc-butler--mail-box))
      (let ((new (expand-file-name
                  "new" (cc-butler--mail-box
                         (if (cc-butler--split-p) "steward" "butler")))))
        (if (file-directory-p new)
            (length (directory-files new nil "^[^.]"))
          0))
    (length cc-butler--inbox)))

(defun cc-butler--forward-push-batched (ops trigger)
  "Type ONE batched summary into OPS: TRIGGER plus the pending backlog size.
This is the single live-push primitive of the gated forwarder — every
push summarizes everything currently pending, never just the triggering
event, so ten queued events cost one turn.  The push is an accelerant
over the durable inbox, never the only copy: the event already landed
there via `cc-butler--queue-on-notification' before this runs."
  (let ((n (cc-butler--forward-pending-count)))
    (cc-butler--send-input
     ops
     (format "[cc-butler] %s%s — drain with pending_events"
             trigger
             (if (> n 1) (format " (+%d more pending)" (1- n)) ""))
     (eq cc-butler-forward 'submit))
    (setq cc-butler--forward-last-push (float-time))))

(defun cc-butler--forward-wake (ops dir text)
  "Gated push for a wake-worthy event from DIR with TEXT.
Pushes immediately when OPS is free (single genuine escalations keep
today's low latency); otherwise leaves the event to the durable inbox —
absorbed for free on the ops session's next organic turn via the
UserPromptSubmit drain, or pushed by the backstop within one
`cc-butler-forward-backstop-interval'."
  (if (cc-butler--forward-ops-free-p ops)
      (cc-butler--forward-push-batched
       ops (format "Worker %s needs attention: %s"
                   (cc-butler--who-dir dir) text))
    (cc-butler--log "forward: ops busy, %s queued for backstop │ %s"
                    (cc-butler--who-dir dir) text)))

(defun cc-butler--forward-defer (ops dir text)
  "Register a `deferred' event from DIR and (re)arm its check timer.

HONEST LIMIT — do not read this as disambiguation: an idle notification
from a worker waiting on its own background sub-agent and one from a
worker genuinely waiting for a reply are indistinguishable in every
structured signal available at this layer (body, session, file mtimes).
The deferral BOUNDS THE COST of that ambiguity, it does not resolve it:
a session static past the window escalates, so a long sub-agent wait
does wake the ops session — the error goes toward wake on purpose, and
dozens of immediate interrupts become at most one deferred wake per
session per window.  Transcript mtime tracks file writes, not turns
(see `cc-butler--session-last-activity')."
  (let* ((prev (gethash dir cc-butler--forward-deferred))
         (old-timer (plist-get prev :timer)))
    (when (timerp old-timer) (cancel-timer old-timer))
    (puthash dir
             (list :since (float-time) :body text
                   :timer (run-with-timer cc-butler-forward-defer-window nil
                                          #'cc-butler--forward-defer-check
                                          ops dir))
             cc-butler--forward-deferred)))

(defun cc-butler--forward-defer-check (ops dir)
  "Escalate DIR's deferred event if the session never progressed.
Progress = any transcript write since the event was recorded (the
session resumed by itself — a sub-agent completed, a turn ran); such an
event resolves silently.  A session still static after the window
escalates through the normal wake gate.  Either way the entry is
dropped: the durable inbox still holds the event, so nothing is lost."
  (when-let ((entry (gethash dir cc-butler--forward-deferred)))
    (remhash dir cc-butler--forward-deferred)
    (let ((last (cc-butler--session-last-activity dir)))
      (if (and last (> last (plist-get entry :since)))
          (cc-butler--log "forward: deferred %s self-resolved"
                          (cc-butler--who-dir dir))
        (cc-butler--forward-wake ops dir
                                 (format "%s (idle %ss, no progress)"
                                         (plist-get entry :body)
                                         cc-butler-forward-defer-window))))))

(defun cc-butler--forward-backstop ()
  "Periodic sweep: push once if events sit undrained and nothing woke ops.
This is the other half of the gate — without it, turning off per-event
forwarding would just recreate \"nobody wakes the steward, it sleeps
forever\" in a new form.  Fires at most one push per interval, only when
the inbox is non-empty (a drain empties it, so pending>0 means no
organic drain happened), no live push happened within the interval, and
ops is free to be typed into (a busy ops session absorbs the backlog on
its own next turn via the UserPromptSubmit drain instead)."
  (when-let* ((cc-butler-forward)
              (cc-butler-forward-gate)
              (ops (cc-butler--ops-dir))
              (mbuf (get-buffer (claude-code-ide--get-buffer-name ops)))
              ((buffer-live-p mbuf))
              ((> (cc-butler--forward-pending-count) 0))
              ((or (null cc-butler--forward-last-push)
                   (>= (- (float-time) cc-butler--forward-last-push)
                       cc-butler-forward-backstop-interval)))
              ((cc-butler--forward-ops-free-p ops)))
    (cc-butler--forward-push-batched
     ops (format "%d worker events pending, none delivered for a while"
                 (cc-butler--forward-pending-count)))))

(defun cc-butler--forward-to-ops (event)
  "Forward a worker EVENT toward the ops (steward, else butler) session.
With `cc-butler-forward-gate' non-nil this is the batched, gated path:
classify (`cc-butler--forward-classify'), then no-wake events rest in
the durable inbox, deferred events arm a window, and wake events push
through the idle gate.  With the gate nil this is the legacy behavior —
one typed interrupt per event, unconditionally.
The user-facing butler is never nudged in split mode; only the steward is."
  (when-let* ((mode cc-butler-forward)
              (ops (cc-butler--ops-dir))
              (dir (plist-get event :session))
              ((not (equal dir ops)))
              (mbuf (get-buffer (claude-code-ide--get-buffer-name ops)))
              ((buffer-live-p mbuf)))
    (let ((text (or (plist-get event :body) (plist-get event :title) "")))
      (if (not cc-butler-forward-gate)
          (cc-butler--send-input
           ops
           (format "[cc-butler] Worker %s needs attention: %s"
                   (cc-butler--who-dir dir) text)
           (eq mode 'submit))
        (pcase (cc-butler--forward-classify event)
          ('no-wake (cc-butler--log "forward: no-wake %s │ %s"
                                    (cc-butler--who-dir dir) text))
          ('deferred (cc-butler--forward-defer ops dir text))
          (_ (cc-butler--forward-wake ops dir text)))))))

(defun cc-butler--forward-backstop-ensure-timer ()
  "(Re)register the backstop timer; idempotent for hot reloads."
  (when (timerp cc-butler--forward-backstop-timer)
    (cancel-timer cc-butler--forward-backstop-timer))
  (setq cc-butler--forward-backstop-timer
        (run-with-timer cc-butler-forward-backstop-interval
                        cc-butler-forward-backstop-interval
                        #'cc-butler--forward-backstop)))

(cc-butler--forward-backstop-ensure-timer)

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
  "Append a decision (SUMMARY/NEEDS from session FROM) to the shared doc.
SUMMARY may be multi-line; continuation lines are indented two spaces under
the heading (same convention as the daily log's
`cc-butler-docs--render-log-entry') so an embedded newline cannot land as a
bare, unindented line -- which, at column 0 starting with `* ', could even
be misread as a new heading by anything scanning this file structurally.
NEEDS is not split the same way: in practice it stays a short one-line ask,
and this file's own `from:'/`needs:' sub-lines already assume single-line
values -- flagged here, not fixed, since nothing observed exercises it."
  (when-let ((file (cc-butler--decisions-file)))
    (make-directory (file-name-directory file) t)
    (let* ((new (not (file-exists-p file)))
           (summary-lines (split-string (string-trim (or summary "")) "\n"))
           (summary-head (or (car summary-lines) ""))
           (summary-rest (cdr summary-lines)))
      (write-region
       (concat (when new "#+TITLE: Open decisions\n#+STARTUP: showeverything\n\n")
               (format "* %s %s\n" (format-time-string "[%Y-%m-%d %a %H:%M]") summary-head)
               (when summary-rest
                 (concat (mapconcat (lambda (l) (concat "  " l)) summary-rest "\n") "\n"))
               (when from (format "  from: %s\n" (cc-butler--who-dir from)))
               (when (and needs (stringp needs) (not (string-empty-p (string-trim needs))))
                 (format "  needs: %s\n" (string-trim needs))))
       nil file t 'silent))))

(defun cc-butler--escalate-kind (kind)
  "Normalize an `escalate_to_butler' KIND string to `decision' or `note'.
Anything other than exactly \"notification\" (trimmed, case-insensitive)
-- including nil, a typo, or garbage -- falls back to `decision'. That
is the safe direction: a real decision silently downgraded to a
read-only notification could go unanswered without anyone noticing,
while a notification that stays answerable is only today's status quo,
not a new failure. See governance
escalate-to-butler-is-decision-only-a-notification-sent-through-it-never-closes."
  (if (and kind (stringp kind)
           (string-equal (downcase (string-trim kind)) "notification"))
      'note
    'decision))

(defun cc-butler-tool-escalate-to-butler (summary &optional needs options kind)
  "MCP tool (steward -> butler): raise a DECISION or a NOTIFICATION for
the butler to relay to the human.
SUMMARY is the question or status, NEEDS is what is needed (decisions
only), OPTIONS an optional string of choices (one `Label — tradeoff'
per line) for a pick-one answer, and KIND \"decision\" (default) or
\"notification\". Types NOTHING into any terminal.

KIND governs whether this needs an answer at all. Ask before calling:
would anything the human could say change what happens next? If not,
this is a notification, not a decision — see governance
escalate-to-butler-is-decision-only-a-notification-sent-through-it-never-closes
for why getting this wrong silently manufactures a backlog that looks
like neglect but is really miscategorization. A notification renders
read-only through the same delivery pipeline as a decision, into the
SAME open/ directory -- it does not land in done/ on arrival, and
closing it (open/ -> done/) still takes a manual `r' (mark-read), same
as a decision. What actually differs: it is never answerable, and it
is excluded from the ⚖ mode-line count and the pending_decisions
backlog line (`cc-butler--decision-open-files-and-oldest' classifies
by filename, not by directory), so it does not inflate the
answer-required number the way a real decision would.

When the decision workflow is active, both kinds render as a document
in 정수님's inbox; otherwise (workflow off) this always queues for
`pending_decisions' as a plain entry regardless of KIND — that legacy
path has no notion of a read-only item, so KIND only has teeth once
the workflow is on. Either way it is appended to the shared
`decisions.org'."
  (unless (and summary (stringp summary) (not (string-empty-p (string-trim summary))))
    (error "A decision summary is required"))
  (let* ((self (cc-butler--caller-dir))
         (s (string-trim summary))
         (n (and needs (stringp needs)
                 (not (string-empty-p (string-trim needs))) (string-trim needs)))
         (k (cc-butler--escalate-kind kind)))
    (cond
     ;; human adapter create-path: decision/note → 정수님's inbox (the watcher renders it)
     ((bound-and-true-p cc-butler-decision-workflow)
      (cc-butler-decision-create self s n (cc-butler--decision-parse-options options) k))
     ;; durable agent path: butler's maildir inbox
     ((eq cc-butler-message-transport 'maildir)
      (cc-butler-mail-up-decision self s n))
     ;; legacy in-memory queue
     (t (push (list :time (current-time) :dir self
                    :name (and self (cc-butler--display-name self))
                    :summary s :needs n)
              cc-butler--butler-inbox)))
    (cc-butler--append-decision self s needs)   ; decisions.org audit doc, all paths
    ;; Ops log gets a short gist, never the raw summary S (arbitrary,
    ;; possibly multi-line -- see `cc-butler--log-message'); the full text
    ;; already lives in decisions.org above, and also goes to the message
    ;; log so a reader has one consistent place to find any event's full
    ;; body, matching report/relay below instead of one exception among them.
    (cc-butler--log "%s -> butler [%s] │ escalated (%d chars, see msg log)"
                    (if self (cc-butler--who-dir self) "steward") k (length s))
    (cc-butler--log-message "escalate" (if self (cc-butler--who-dir self) "steward")
                            "butler" s)
    (cc-butler--maybe-refresh)
    (if (eq k 'note)
        "Sent as a notification (read-only; no answer expected)."
      "Escalated the decision (rendered for 정수님 when the workflow is on, else queued for pending_decisions).")))

;;;; ---- draining without destroying ---------------------------------

;; A drain used to empty its queue BETWEEN reading the items and rendering
;; them, and "empty" meant discard.  Two consequences, both silent:
;;
;;   - anything that went wrong while rendering unwound past a clear that had
;;     already happened, so the items were gone and no string was ever
;;     returned;
;;   - delivery can still fail AFTER the drain — the hook is killed at its
;;     10s timeout, `jq' is missing, the client drops the context — and
;;     nothing downstream could recover the items or even notice.
;;
;; So: render first, clear last, and keep what was drained.  The maildir
;; transport already works this way — it renames messages into `archive/'
;; rather than deleting them — this brings the in-memory queues in line with
;; the convention rather than inventing one.
;;
;; This is a partial remedy and worth naming as such: it turns unrecoverable
;; silent loss into recoverable silent loss.  Knowing a delivery failed still
;; requires someone to look.  A full fix needs the consumer to acknowledge
;; receipt, which means changing the hook script — deliberately out of scope,
;; because hook templates are written once and never refreshed, so that change
;; would ship to nobody until each session's home is regenerated by hand.

(defcustom cc-butler-drained-keep 20
  "How many drained items each queue keeps for recovery.
A window for answering \"was this delivered?\", not a log."
  :type 'integer :group 'cc-butler)

(defvar cc-butler--butler-inbox-drained nil
  "Recently drained decisions, newest last.  See `cc-butler-drained-keep'.")

(defvar cc-butler--inbox-drained nil
  "Recently drained worker events, newest last.  See `cc-butler-drained-keep'.")

(defun cc-butler--archive-drained (archive items)
  "Return ARCHIVE with ITEMS appended, trimmed to `cc-butler-drained-keep'."
  (let ((all (append archive items)))
    (if (> (length all) cc-butler-drained-keep)
        (nthcdr (- (length all) cc-butler-drained-keep) all)
      all)))

(defun cc-butler--nothing-pending (sentinel archive)
  "SENTINEL, plus what ARCHIVE says was recently handed to someone else.
An empty queue means either \"nothing was sent\" or \"something was sent and
another consumer already took it\".  Both drains race — the hook runs every
turn — so the second case is the common one, and reading it as the first is
how an ordinary hand-off gets reported as a lost message."
  (if (null archive)
      sentinel
    (format "%s  (%d recently delivered, latest %s)"
            sentinel (length archive)
            (format-time-string "%H:%M"
                                (plist-get (car (last archive)) :time)))))

(defun cc-butler-tool-pending-decisions ()
  "MCP tool (butler): drain the quiet decision queue (steward escalations).

When `cc-butler-decision-workflow' is active, `escalate_to_butler' routes
decisions entirely to the human-adapter's answerable org documents
(`open/'), never to this drain -- see `cc-butler-decision-workflow''s own
KNOWN-GAP docstring in cc-butler-decision.el. That made this function
able to say \"No pending decisions\" while hundreds sat unaddressed in
open/, asserting a falsehood rather than reporting nothing. A read-only,
non-destructive backlog line (`cc-butler--decision-open-backlog-line')
is appended below when that workflow is on, so this tool stops lying by
omission -- it still does not list or drain those documents individually,
only says how many and how stale the oldest is."
  (let ((drained
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
               (cc-butler--nothing-pending "No pending decisions."
                                           cc-butler--butler-inbox-drained)
             (let* ((events (reverse cc-butler--butler-inbox))
                    ;; Render BEFORE touching the queue: if this signals, the items
                    ;; are still there to try again with.
                    (text (mapconcat
                           (lambda (e)
                             (format "- [%s] %s%s%s"
                                     (format-time-string "%H:%M" (plist-get e :time))
                                     (plist-get e :summary)
                                     (if (plist-get e :name) (format " (from %s)" (plist-get e :name)) "")
                                     (if (plist-get e :needs) (format " . needs: %s" (plist-get e :needs)) "")))
                           events "\n")))
               (setq cc-butler--butler-inbox-drained
                     (cc-butler--archive-drained cc-butler--butler-inbox-drained events))
               (setq cc-butler--butler-inbox nil)
               text))))
        (backlog (and (bound-and-true-p cc-butler-decision-workflow)
                      (fboundp 'cc-butler--decision-open-backlog-line)
                      (ignore-errors (cc-butler--decision-open-backlog-line)))))
    (cond ((null backlog) drained)
          ((equal drained "No pending decisions.") backlog)
          (t (concat drained "\n\n" backlog)))))

(setq claude-code-ide-mcp-server-tools
      (seq-remove
       (lambda (spec)
         (member (plist-get (claude-code-ide--normalize-tool-spec spec) :name)
                 '("escalate_to_butler" "pending_decisions")))
       claude-code-ide-mcp-server-tools))

(claude-code-ide-make-tool
 :function #'cc-butler-tool-escalate-to-butler
 :name "escalate_to_butler"
 :description "Steward only: raise a DECISION or send a NOTIFICATION to the user-facing butler's quiet queue. A decision needs a human answer (a choice, an approval, missing info) — use it for that, not routine progress. A notification (kind='notification') is for status that only needs to be READ — a correction, a completion, a 'you should know this' — and renders read-only, same as a decision, in the same open/ location; it is never answerable, and it does not count toward the ⚖ answer-required backlog (indicator or pending_decisions), but a human still closes it with one keypress (r) rather than it disappearing on its own. Ask yourself first: would anything the human could say change what happens next? If not, send it as a notification. Getting this wrong (sending status as a decision) silently accumulates as a backlog that looks like neglect but is really miscategorized FYIs. The butler drains decisions via pending_decisions and relays the answer back to you with send_to_session; a notification has nothing to relay back."
 :args '((:name "summary"
                :type string
                :description "The decision or status, stated plainly (e.g. 'billing worker: use Stripe or Paddle?' or 'retracting my earlier mixin hypothesis — it was wrong').")
         (:name "needs"
                :type string
                :description "Decisions only: exactly what you need from the human (a choice, an approval, missing info). Leave empty for a notification — there is nothing to need."
                :optional t)
         (:name "options"
                :type string
                :description "Decisions only: choices for a pick-one answer, one per line as 'Label — tradeoff' (tradeoff optional), e.g. 'Stripe — lower fees\\nPaddle — handles VAT'. Rendered as selectable options in the decision document. Ignored for a notification."
                :optional t)
         (:name "kind"
                :type string
                :description "'decision' (default) if this needs a pick-one/approve answer; 'notification' if it's status only and should be READ, not answered. Anything other than exactly 'notification' is treated as a decision — when unsure, the default is the safe choice."
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
        ;; :osc and :status are DIFFERENT facts about a session (see
        ;; `cc-butler--sessions'): :osc is the live activity title the
        ;; harness pushes via OSC escape (what it's doing right now); :status
        ;; is a human-readable note a session deliberately left via
        ;; `set_session_info' (e.g. "parked -- PR #112 open, waiting on
        ;; merge"). `list_claude_sessions' used to render only :osc, so a
        ;; session that had explicitly left a status note looked identical
        ;; to one idling with nothing to say -- the steward could not tell
        ;; "parked with a reason" from "just sitting there". Both are now
        ;; surfaced, each under its own label so they stay distinguishable
        ;; instead of being concatenated into one ambiguous string. Each
        ;; optional field is self-contained (carries its own leading " | "
        ;; only when non-empty) so an absent field never leaves a stray
        ;; separator or empty segment in the row.
        (push (format "- %s%s | %s | branch:%s%s%s%s%s"
                      (cc-butler--display-name dir)
                      (cond ((equal dir self) " (you)")
                            ((equal dir cc-butler--butler) " (butler)")
                            (t ""))
                      (if (cc-butler--waiting-p dir) "WAITING-FOR-INPUT" "running")
                      (let ((b (plist-get s :branch))) (if (string-empty-p b) "-" b))
                      (let ((f (plist-get s :forge))) (if (string-empty-p f) "" (concat " " f)))
                      (let ((o (plist-get s :osc))) (if (string-empty-p o) "" (concat " | activity:" o)))
                      (let ((st (plist-get s :status))) (if (string-empty-p st) "" (concat " | status:" st)))
                      (let ((m (and (fboundp 'cc-butler-cleanup-model-tag)
                                    (cc-butler-cleanup-model-tag dir))))
                        (if m (concat " | " m) "")))
              rows)))
    (if rows (mapconcat #'identity (nreverse rows) "\n") "No active Claude sessions")))

(defun cc-butler-tool-read-session (name &optional lines)
  "MCP tool: return the recent terminal output of session NAME.
An input row holding a ghost/autocomplete suggestion — or one whose state
could not be read at all — is redacted to a plain marker rather than
returned as if it were real input.  See `cc-butler--read-output-redacted'."
  (let ((dir (cc-butler--dir-by-name name)))
    (if (not dir)
        (format "No session named %S.  Call list_claude_sessions for names." name)
      (let ((out (cc-butler--read-output-redacted dir (and lines (truncate lines)))))
        (cond
         ;; "the screen is empty" and "we do not know what the screen says" are
         ;; different facts.  Collapsing them into one reassuring string is what
         ;; let a frozen terminal read as ordinary output for hours.
         ((null out)
          (format "(could not read %s's screen: its terminal text could not be refreshed, \
so it may be stale.  Deliberately not showing the last frame — acting on an old \
screen is worse than seeing none.  Check the cc-butler log for the refresh error.)"
                  name))
         ((string-empty-p out) "(no output)")
         (t out))))))

(defun cc-butler--relay-command-p (text)
  "Non-nil when TEXT is a bare slash command rather than a message.
A command is an OPERATION on the session, not prose for anyone to read, and
prefixing it would put the attribution at the start of the input — `/model opus'
would then arrive as text instead of running.  The sender is still logged."
  (and (stringp text)
       (string-prefix-p "/" (string-trim-left text))
       (not (string-search "\n" (string-trim text)))))

(defun cc-butler--relay-attribution (self dir)
  "Return the line marking a message as relayed from SELF to DIR.

Written by the CODE, never by the sending model.  Text delivered this way lands
in the target's input box looking exactly like something a human typed, so
without this a session cannot tell a peer's suggestion from an instruction and a
message carries whatever authority the reader assumes.  Asking each sender to
label itself is asking it to remember; this cannot be forgotten.

It attests the CHANNEL, not the origin: it says which session delivered the
text, not who authored the intent behind it.  A relayed instruction and the
sender's own opinion are indistinguishable here by design — `From' (the origin
author, per the provenance SDD §8) is deliberately NOT set, because nothing in
the code can tell relaying from deciding, and inventing a default would be
deciding an open policy question in passing.

The identity is trustworthy: a session's id is minted at launch into its own MCP
config and recovered server-side from the request path, so a session cannot
claim to be another.  Name AND id, because display names can collide."
  (format "[cc-butler · %s]"
          (cc-butler--via-string
           (list (cc-butler--who-dir self) (cc-butler--display-name dir)))))

(defun cc-butler-tool-send-session (name text)
  "MCP tool: type TEXT into session NAME and submit it.
The text is prefixed with a line naming the sending session — see
`cc-butler--relay-attribution'."
  (let ((self (cc-butler--caller-dir))
        (dir (cc-butler--dir-by-name name)))
    (cond
     ((not dir)
      (format "No session named %S.  Call list_claude_sessions for names." name))
     ;; Decide this BEFORE the send.  The identity is legitimately absent on
     ;; several paths — no MCP request in scope (a timer, a hook, a bare
     ;; `emacsclient --eval'), or a session id that is stale or was never
     ;; registered — and it used to be caught only when formatting the log
     ;; line, AFTER the text had been delivered.  The sender was told it
     ;; failed while the receiver had the message, and a sender that believes
     ;; it failed re-sends, delivering the same instruction twice.  A nil
     ;; identity also silently disables the self-send guard below.
     ;; Which path produced it in the wild could not be determined from the
     ;; code; `claude-code-ide-debug' logs the session id on every request and
     ;; would settle it.  Matches report_to_steward, which already refuses.
     ((not self)
      (error "No calling session context for this request"))
     ((equal dir self)
      (error "Refusing to send to the calling session itself"))
     (t
      (cc-butler--send-input
       dir (if (cc-butler--relay-command-p text)
               text
             (concat (cc-butler--relay-attribution self dir) "\n" text))
       t)
      (cc-butler--clear-waiting dir)       ; commanding a worker attends to it
      ;; Ops log gets a short gist, never the raw TEXT (which is arbitrary and
      ;; can be multi-line -- see `cc-butler--log-message'); the full body
      ;; goes to the message log instead, unconditionally (unlike the
      ;; fboundp-guarded mail journal below, this does not depend on
      ;; cc-butler-mail being loaded).
      (cc-butler--log "%s → %s │ sent (%d chars, see msg log)"
                      (cc-butler--who-dir self) (cc-butler--who-dir dir) (length text))
      (cc-butler--log-message "relay" (cc-butler--who-dir self) (cc-butler--who-dir dir) text)
      ;; Channel journal: the messenger channel's audit record (mail deliveries
      ;; journal themselves in `cc-butler--mail-file-deliver').  fboundp-guarded
      ;; because cc-butler-mail requires THIS module, so requiring it back would
      ;; be a cycle — same pattern as `cc-butler-docs--auto-log' below.  The
      ;; journal fn is itself non-fatal (`ignore-errors'): recording never
      ;; breaks a send that already succeeded.
      (when (fboundp 'cc-butler-mail-journal-send)
        (cc-butler-mail-journal-send self name text))
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
        (cc-butler--nothing-pending "No pending worker events."
                                    cc-butler--inbox-drained)
      (let* ((events (reverse cc-butler--inbox))
             ;; Render BEFORE clearing — same reason as the decision queue,
             ;; and this payload goes on to compute a fleet scan afterwards,
             ;; which is a larger error surface than the drain itself.
             (text (mapconcat (lambda (e)
                                (format "- [%s] %s: %s"
                                        (format-time-string "%H:%M" (plist-get e :time))
                                        (cc-butler--who (plist-get e :name) (plist-get e :id))
                                        (plist-get e :body)))
                              events "\n")))
        (setq cc-butler--inbox-drained
              (cc-butler--archive-drained cc-butler--inbox-drained events))
        (setq cc-butler--inbox nil)
        text))))

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
 :description "List the other live Claude Code sessions running in this Emacs (the workers you orchestrate): their stable name, whether each is WAITING-FOR-INPUT, its git branch, its live activity title (what it's doing right now), any status note it deliberately left via set_session_info (e.g. parked with a reason), and (when known) the model it's running. Call this first to learn the names used by read_session_output and send_to_session."
 :args nil)

(claude-code-ide-make-tool
 :function #'cc-butler-tool-read-session
 :name "read_session_output"
 :description "Read the recent terminal screen of another Claude session by name, to see what it is doing or asking. The text is that session's live TUI screen (may include UI chrome). The input row is returned only when the session's terminal cursor shows a human really typed into it; a ghost/autocomplete suggestion painted into an empty box is replaced with a plain marker, and a row whose state cannot be determined is replaced with an UNVERIFIED marker rather than shown as if it were real input."
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
