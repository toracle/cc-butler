;;; cc-butler-orchestrator.el --- Butler/worker orchestration for cc-butler  -*- lexical-binding: t; -*-

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

(defun cc-butler--read-output (dir &optional lines)
  "Return the last LINES (default 40) of session DIR's terminal screen.
The terminal text is force-refreshed first so the capture is always the
current frame, even for a background (non-displayed) buffer."
  (let ((buf (get-buffer (claude-code-ide--get-buffer-name dir))))
    (when (buffer-live-p buf)
      (cc-butler--refresh-terminal-text buf)
      (with-current-buffer buf
        (let* ((n (max 1 (or lines 40)))
               (start (save-excursion (goto-char (point-max))
                                      (forward-line (- n))
                                      (line-beginning-position))))
          (string-trim (buffer-substring-no-properties start (point-max))))))))

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
    t))

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
  (expand-file-name "cc-butler" user-emacs-directory)
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
                       " (decision-routing,\n  DoD-vs-goal, evaluation-independence,"
                       " decision-proposal-format,\n  warmblood-talent-philosophy, …)"
                       " — load these to keep operating discipline.\n")
               (abbreviate-file-name mem)))
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

(defun cc-butler--butler-claude-md ()
  "Return the bootstrap CLAUDE.md text for the butler (front-of-house) role."
  (concat
   "# Butler (front-of-house)\n\n"
   (cc-butler--roles-metaphor "butler")
   "The human speaks to **you**, in a calm channel — worker nudges do NOT reach\n"
   "you. Your job is to present the decisions that need the human, cleanly, and\n"
   "to relay the answers back down.\n\n"
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
   "`butler_log`. Once a steward is started, hand that firehose over to it.\n\n"
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
   "1. Call `pending_events` first — worker reports (`report_to_butler`) and\n"
   "   notifications land here; nudges are also typed at you. This is your inbox.\n"
   "2. Dispatch and unblock: `read_session_output` to see a worker's screen,\n"
   "   `send_to_session` to answer, task, or unblock it. Track each toward its DoD.\n"
   "3. Keep the picture current: `butler_dashboard` (the sessions table is built\n"
   "   automatically — you add the overview and open decisions) and `butler_log`\n"
   "   the durable timeline.\n"
   "4. When something needs a human decision, `escalate_to_butler(summary, needs)`\n"
   "   — do NOT ask the human yourself; route it through the butler, who presents\n"
   "   it and relays the answer back to you.\n\n"
   "## Tools\n\n"
   "- `list_claude_sessions` / `read_session_output` / `send_to_session`.\n"
   "- `pending_events` — drain the worker firehose.\n"
   "- `butler_log` / `butler_dashboard` — durable log + snapshot, under `docs/`.\n"
   "- `escalate_to_butler` — raise a decision to the butler.\n\n"
   "Keep workers moving, and never let the state of the fleet live only in the\n"
   "chat scrollback.\n"))

(defun cc-butler--ensure-butler-home ()
  "Create `cc-butler-home' with its markers if missing; return the directory."
  (let ((home (file-name-as-directory (expand-file-name cc-butler-home))))
    (make-directory home t)
    (let ((proj (expand-file-name ".projectile" home))
          (cmd  (expand-file-name "CLAUDE.md" home)))
      (unless (file-exists-p proj) (write-region "" nil proj nil 'silent))
      (unless (file-exists-p cmd)
        (write-region (cc-butler--butler-claude-md) nil cmd nil 'silent)))
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
      (let ((default-directory home))
        (cc-butler--with-channel (claude-code-ide)))
      (message "cc-butler: started butler in %s" home))
    (setq cc-butler--butler home)
    (cc-butler)))

(defcustom cc-butler-steward-home
  (expand-file-name "cc-butler-steward" user-emacs-directory)
  "Working directory the steward (operations) session runs in.
`cc-butler-start-steward' creates it on demand with a role `CLAUDE.md'.
Must differ from `cc-butler-home' (two sessions cannot share a directory)."
  :type 'directory
  :group 'cc-butler)

(defun cc-butler--ensure-steward-home ()
  "Create `cc-butler-steward-home' with its markers if missing; return it."
  (let ((home (file-name-as-directory (expand-file-name cc-butler-steward-home))))
    (make-directory home t)
    (let ((proj (expand-file-name ".projectile" home))
          (cmd  (expand-file-name "CLAUDE.md" home)))
      (unless (file-exists-p proj) (write-region "" nil proj nil 'silent))
      (unless (file-exists-p cmd)
        (write-region (cc-butler--steward-claude-md) nil cmd nil 'silent)))
    home))

;;;###autoload
(defun cc-butler-start-steward ()
  "Launch (or focus) the steward session in `cc-butler-steward-home'.
Scaffolds the home (`.projectile' + steward role `CLAUDE.md') on first run,
designates it the steward, and opens the manager.  Once the steward runs,
the worker firehose (nudges + `report_to_butler') routes to it instead of
the butler (split mode).  Idempotent."
  (interactive)
  (let ((home (cc-butler--ensure-steward-home)))
    (when (equal (file-name-as-directory (expand-file-name home))
                 (and cc-butler-home
                      (file-name-as-directory (expand-file-name cc-butler-home))))
      (user-error "Steward home must differ from the butler home"))
    (if (cc-butler--live-dir-p home)
        (message "cc-butler: steward already running in %s" home)
      (let ((default-directory home))
        (cc-butler--with-channel (claude-code-ide)))
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
firehose (nudges + `report_to_butler') and escalates only decisions to the
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

(defun cc-butler-tool-escalate-to-butler (summary &optional needs)
  "MCP tool (steward -> butler): raise a decision to the butler's quiet queue.
Pushes onto the butler's decision inbox, appends to the shared
`decisions.org', and types ONE quiet line into the butler (never submitted
automatically).  This is the only thing that reaches the user-facing butler."
  (unless (and summary (stringp summary) (not (string-empty-p (string-trim summary))))
    (error "A decision summary is required"))
  (let ((self (cc-butler--caller-dir))
        (s (string-trim summary)))
    (push (list :time (current-time) :dir self
                :name (and self (cc-butler--display-name self))
                :summary s
                :needs (and needs (stringp needs)
                            (not (string-empty-p (string-trim needs))) (string-trim needs)))
          cc-butler--butler-inbox)
    (cc-butler--append-decision self s needs)
    (cc-butler--log "%s -> butler [decision] | %s"
                    (if self (cc-butler--who-dir self) "steward") s)
    (when-let* ((butler cc-butler--butler)
                (buf (get-buffer (claude-code-ide--get-buffer-name butler)))
                ((buffer-live-p buf)))
      (cc-butler--send-input butler (format "[decision waiting] %s" s) nil))
    (cc-butler--maybe-refresh)
    "Escalated to the butler's decision queue."))

(defun cc-butler-tool-pending-decisions ()
  "MCP tool (butler): drain the quiet decision queue (steward escalations)."
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
       events "\n"))))

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
        (push (format "- %s%s | %s | branch:%s%s | %s"
                      (cc-butler--display-name dir)
                      (cond ((equal dir self) " (you)")
                            ((equal dir cc-butler--butler) " (butler)")
                            (t ""))
                      (if (cc-butler--waiting-p dir) "WAITING-FOR-INPUT" "running")
                      (let ((b (plist-get s :branch))) (if (string-empty-p b) "-" b))
                      (let ((f (plist-get s :forge))) (if (string-empty-p f) "" (concat " " f)))
                      (let ((o (plist-get s :osc))) (if (string-empty-p o) "" o)))
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

(defun cc-butler-tool-report-to-butler (summary &optional status needs)
  "MCP tool: a worker reports to the butler with real content.
SUMMARY is what happened / what was done, STATUS the current state, and
NEEDS what the worker needs from the human (all teed to the inbox and
log).  The caller's session name and id are attached automatically."
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
      (cc-butler--inbox-push self msg)
      (cc-butler--maybe-refresh)
      (format "Reported to the butler as %s." (cc-butler--who-dir self)))))

(defun cc-butler-tool-inbox ()
  "MCP tool: return and clear the butler's pending worker events.
This is the pull side of the bus: worker notifications (needs input /
done) are queued in Emacs and drained here, so the butler gets them
without anything being typed into its input box."
  (if (null cc-butler--inbox)
      "No pending worker events."
    (let ((events (reverse cc-butler--inbox)))
      (setq cc-butler--inbox nil)
      (mapconcat (lambda (e)
                   (format "- [%s] %s: %s"
                           (format-time-string "%H:%M" (plist-get e :time))
                           (cc-butler--who (plist-get e :name) (plist-get e :id))
                           (plist-get e :body)))
                 events "\n"))))

;; Idempotent (re)registration: drop prior copies before adding.
(setq claude-code-ide-mcp-server-tools
      (seq-remove
       (lambda (spec)
         (member (plist-get (claude-code-ide--normalize-tool-spec spec) :name)
                 '("list_claude_sessions" "read_session_output"
                   "send_to_session" "pending_events" "report_to_butler")))
       claude-code-ide-mcp-server-tools))

(claude-code-ide-make-tool
 :function #'cc-butler-tool-inbox
 :name "pending_events"
 :description "Drain the butler's inbox: pending events from worker sessions that need attention (a worker asked a question, finished, reported, or hit a prompt), newest last. Each line is a timestamped worker name (with its session id) and message. Call this at the start of each turn (and whenever you are nudged) to learn what changed without anything being typed into your input box. Returns the events and clears them."
 :args nil)

(claude-code-ide-make-tool
 :function #'cc-butler-tool-report-to-butler
 :name "report_to_butler"
 :description "Report up to the butler/orchestrator with real content — not just 'I need attention'. State WHAT happened / what you did, the current STATE, and exactly what you NEED from the human (a decision, input, or nothing). Your session name and id are attached automatically; the butler reads it from its inbox and relays a summary to the human. Call it when you finish, get blocked, or need a decision."
 :args '((:name "summary"
                :type string
                :description "What happened or what you did — the substance of the report (e.g. 'implemented invoice PDF rendering, all tests pass').")
         (:name "status"
                :type string
                :description "Current state, e.g. 'PR #42 open, CI green' or 'blocked on the DB migration'. Optional."
                :optional t)
         (:name "needs"
                :type string
                :description "What you need from the human/butler to proceed, e.g. 'approve the merge' or 'which auth method to use'. Omit (or 'nothing') if you are only informing. Optional."
                :optional t)))

(claude-code-ide-make-tool
 :function #'cc-butler-tool-list-sessions
 :name "list_claude_sessions"
 :description "List the other live Claude Code sessions running in this Emacs (the workers you orchestrate): their stable name, whether each is WAITING-FOR-INPUT, its git branch, and its current activity title. Call this first to learn the names used by read_session_output and send_to_session."
 :args nil)

(claude-code-ide-make-tool
 :function #'cc-butler-tool-read-session
 :name "read_session_output"
 :description "Read the recent terminal screen of another Claude session by name, to see what it is doing or asking. The text is that session's live TUI screen (may include UI chrome)."
 :args '((:name "name"
                :type string
                :description "Session name from list_claude_sessions (e.g. 'monocle-billing').")
         (:name "lines"
                :type integer
                :description "How many trailing lines to return (default 40)."
                :optional t)))

(claude-code-ide-make-tool
 :function #'cc-butler-tool-send-session
 :name "send_to_session"
 :description "Type a prompt/answer into another Claude session by name and submit it (press Enter), to direct that worker. Use to answer a worker's question, give it a task, or unblock it. You cannot send to yourself. Multi-line is supported: include newlines in text — they are delivered as a paste and stay literal, and Enter is pressed only once, at the end, to submit."
 :args '((:name "name"
                :type string
                :description "Target session name from list_claude_sessions.")
         (:name "text"
                :type string
                :description "The text to type into that session before submitting. May contain newlines for a multi-line prompt; only the final submit presses Enter.")))

(provide 'cc-butler-orchestrator)
;;; cc-butler-orchestrator.el ends here
