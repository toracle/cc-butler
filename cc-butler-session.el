;;; cc-butler-session.el --- Claude Code Session Manager (cc-butler)  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jeongsoo Park
;; SPDX-License-Identifier: MIT

;; A lightweight, cmux-like session manager for `claude-code-ide':
;;
;;  - A sticky left-hand list of live Claude sessions, each rendered as a
;;    multi-line block (title / status / branch + PR) so it stays readable in
;;    a narrow side window.  Moving between entries shows that session's
;;    terminal in the main window.
;;  - Per-session metadata (title / status) that the *running* Claude can set
;;    about itself through the Emacs MCP bridge (tool `set_session_info').
;;  - Auxiliary info per session: git branch, plus best-effort PR number.
;;  - Buffer / display naming based on a `.projectile' marker walked up from
;;    the working directory, so sessions launched inside a meta-repo get the
;;    *topic parent's* name instead of all collapsing to the meta-repo name.
;;
;; Personal, non-packaged config drop-in.  Entry point: M-x cc-butler.

(require 'claude-code-ide)
(require 'claude-code-ide-mcp-server)
(require 'subr-x)
(require 'seq)

;;;; ------------------------------------------------------------------
;;;; Channel launch flag (shared by the topic/session launchers)
;;;; ------------------------------------------------------------------

(defcustom cc-butler-channel-args ""
  "Extra `claude' CLI args appended when launching a cc-butler session.
Use to enable a cc-butler channel, e.g.
  \"--dangerously-load-development-channels server:cc-butlertest\"
An empty string adds nothing."
  :type 'string
  :group 'cc-butler)

(defmacro cc-butler--with-channel (&rest body)
  "Run BODY with the channel args added to `claude-code-ide-cli-extra-flags'."
  (declare (indent 0))
  `(let ((claude-code-ide-cli-extra-flags
          (string-trim (concat (or claude-code-ide-cli-extra-flags "")
                               " " cc-butler-channel-args))))
     ,@body))

;;;; ------------------------------------------------------------------
;;;; Display naming: nearest ancestor holding `.projectile'
;;;; ------------------------------------------------------------------

(defcustom cc-butler-project-marker ".projectile"
  "Marker file used to choose the directory a session is named after.
Sessions are named after the nearest ancestor of the working directory
that contains this file.  Defaults to `.projectile' for compatibility
with the projectile package."
  :type 'string
  :group 'cc-butler)

(defun cc-butler--display-name (directory)
  "Return the topic name for DIRECTORY.
That is the basename of the nearest ancestor containing
`cc-butler-project-marker', or DIRECTORY's own basename when no marker is
found.  This is the single source of truth shared by the buffer name and
the session-list title."
  (let ((root (and directory
                   (locate-dominating-file directory cc-butler-project-marker))))
    (file-name-nondirectory
     (directory-file-name (expand-file-name (or root directory))))))

(defun cc-butler-buffer-name (directory)
  "Name a Claude session buffer for DIRECTORY (see `cc-butler--display-name')."
  (format "*claude-code[%s]*" (cc-butler--display-name directory)))

(setq claude-code-ide-buffer-name-function #'cc-butler-buffer-name)

;;;; ------------------------------------------------------------------
;;;; Per-session metadata (set by Claude via MCP)
;;;; ------------------------------------------------------------------

(defvar cc-butler--meta (make-hash-table :test 'equal)
  "Map a canonical working-dir (the session key) to a metadata plist.
Recognized keys: :title :status :updated.")

(defun cc-butler--meta-get (dir)
  "Return the metadata plist for session DIR, or nil."
  (gethash dir cc-butler--meta))

(defun cc-butler--meta-set (dir &rest kvs)
  "Merge KVS (a plist) into the metadata for session DIR."
  (let ((plist (gethash dir cc-butler--meta)))
    (while kvs
      (setq plist (plist-put plist (pop kvs) (pop kvs))))
    (setq plist (plist-put plist :updated (current-time)))
    (puthash dir plist cc-butler--meta)
    plist))

;;;; ------------------------------------------------------------------
;;;; Auxiliary git / forge info
;;;; ------------------------------------------------------------------

(defvar cc-butler--branch-cache (make-hash-table :test 'equal)
  "Map working-dir -> (TIMESTAMP . BRANCH); a short TTL avoids spawning git
on every redraw when titles change rapidly.")

(defun cc-butler--git-branch-1 (dir)
  "Return the current git branch for DIR, or nil (uncached)."
  (let ((default-directory dir))
    (ignore-errors
      (with-temp-buffer
        (when (eq 0 (process-file "git" nil t nil
                                  "rev-parse" "--abbrev-ref" "HEAD"))
          (let ((b (string-trim (buffer-string))))
            (unless (string-empty-p b) b)))))))

(defun cc-butler--git-branch (dir)
  "Return the current git branch for DIR, or nil, cached for 5s."
  (when (and dir (file-directory-p dir))
    (let ((cached (gethash dir cc-butler--branch-cache))
          (now (float-time)))
      (if (and cached (< (- now (car cached)) 5.0))
          (cdr cached)
        (let ((branch (cc-butler--git-branch-1 dir)))
          (puthash dir (cons now branch) cc-butler--branch-cache)
          branch)))))

;;;; OSC terminal title (the task summary Claude emits as it works)

(defun cc-butler--osc-title (buffer)
  "Return the live terminal title of BUFFER (ghostel OSC 2), or nil.
claude-code-ide disables ghostel's title-based *renaming*, but the
terminal still tracks the title; read it straight from the term object."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and (boundp 'ghostel--term) ghostel--term
                 (fboundp 'ghostel--get-title))
        (let ((title (ignore-errors (ghostel--get-title ghostel--term))))
          (and (stringp title)
               (not (string-empty-p (string-trim title)))
               (string-trim title)))))))

(defcustom cc-butler-enable-forge t
  "When non-nil, fetch PR info via the `gh' CLI asynchronously."
  :type 'boolean
  :group 'cc-butler)

(defvar cc-butler--forge-cache (make-hash-table :test 'equal)
  "Map working-dir -> forge info string (e.g. \"PR #12\"), best effort.")

(defun cc-butler--forge-fetch (dir)
  "Asynchronously fetch the PR number for DIR via `gh', then refresh."
  (when (and cc-butler-enable-forge
             (executable-find "gh")
             dir (file-directory-p dir))
    (let ((default-directory dir))
      (ignore-errors
        (make-process
         :name "cc-butler-gh"
         :buffer (generate-new-buffer " *cc-butler-gh*")
         :command '("gh" "pr" "view" "--json" "number" "-q" ".number")
         :noquery t
         :sentinel
         (lambda (proc _event)
           (when (memq (process-status proc) '(exit signal))
             (let ((out (with-current-buffer (process-buffer proc)
                          (string-trim (buffer-string)))))
               (puthash dir
                        (and (string-match-p "\\`[0-9]+\\'" out)
                             (format "PR #%s" out))
                        cc-butler--forge-cache))
             (when (buffer-live-p (process-buffer proc))
               (kill-buffer (process-buffer proc)))
             (cc-butler--maybe-refresh))))))))

;;;; ------------------------------------------------------------------
;;;; Session enumeration
;;;; ------------------------------------------------------------------

(defun cc-butler--sessions ()
  "Return a list of session plists for all live Claude sessions.
Each plist has :dir :session-id :buffer :title :status :branch :forge."
  (claude-code-ide--cleanup-dead-processes)
  (let (out)
    (maphash
     (lambda (dir process)
       (when (process-live-p process)
         (let* ((bufname (claude-code-ide--get-buffer-name dir))
                (buffer (get-buffer bufname))
                (meta (cc-butler--meta-get dir)))
           (push (list :dir dir
                       :session-id (gethash dir claude-code-ide--session-ids)
                       :buffer buffer
                       :title (or (plist-get meta :title)
                                  (cc-butler--display-name dir))
                       :osc (or (cc-butler--osc-title buffer) "")
                       :status (or (plist-get meta :status) "")
                       :branch (or (cc-butler--git-branch dir) "")
                       :forge (or (gethash dir cc-butler--forge-cache) ""))
                 out))))
     claude-code-ide--processes)
    (nreverse out)))

(defun cc-butler--dir-for-buffer (buffer)
  "Return the session working-dir whose terminal is BUFFER, or nil."
  (let ((name (buffer-name buffer)) found)
    (maphash (lambda (dir _proc)
               (when (and (not found)
                          (equal name (claude-code-ide--get-buffer-name dir)))
                 (setq found dir)))
             claude-code-ide--processes)
    found))

(defvar cc-butler--butler nil
  "Working-dir of the designated butler session, or nil.
The butler is a special Claude session that interfaces with the human and
drives the worker sessions through the orchestration MCP tools, receiving
forwarded worker events.  It is pinned to the top of the list.")

(defvar cc-butler--waiting (make-hash-table :test 'equal)
  "Map a session working-dir -> float-time when it began awaiting user input.
Sessions present here sort to the top of the list as an approval queue,
oldest request first (FIFO); absence means the session is not waiting.")

(defun cc-butler--waiting-p (dir)
  "Return the wait timestamp for DIR, or nil when it is not waiting."
  (gethash dir cc-butler--waiting))

(defun cc-butler--mark-waiting (dir)
  "Record that session DIR began awaiting user input (keep the earliest time)."
  (when (and dir (not (gethash dir cc-butler--waiting)))
    (puthash dir (float-time) cc-butler--waiting)))

(defun cc-butler--clear-waiting (dir)
  "Mark session DIR as no longer awaiting input."
  (when dir (remhash dir cc-butler--waiting)))

(defcustom cc-butler-message-transport 'in-memory
  "Transport for up-direction agent messages (report / escalate / drains).
`in-memory' (default) keeps the volatile queues; `maildir' routes them
through a durable, lock-free, auditable file inbox (see `cc-butler-mail').
Switchable at runtime for rollback."
  :type '(choice (const :tag "In-memory queues" in-memory)
                 (const :tag "Durable maildir inbox" maildir))
  :group 'cc-butler)

(defvar cc-butler--inbox nil
  "Pending worker events for the butler to pull (newest pushed to the front).
Each entry is a plist (:time :dir :name :body).  Drained by the
`pending_events' MCP tool.")

;;;; Identity + butler<->worker message log

(defun cc-butler--session-id (dir)
  "Return the claude-code-ide session id for DIR, or nil."
  (gethash dir claude-code-ide--session-ids))

(defun cc-butler--who (name id)
  "Format a session label from NAME and session ID."
  (if (and id (stringp id) (not (string-empty-p id)))
      (format "%s (%s)" name id)
    (or name "?")))

(defun cc-butler--who-dir (dir)
  "Format the session label (name + id) for session DIR."
  (cc-butler--who (cc-butler--display-name dir) (cc-butler--session-id dir)))

(defcustom cc-butler-log-buffer-name "*cc-butler-log*"
  "Name of the cc-butler message-log buffer that tees butler<->worker traffic."
  :type 'string
  :group 'cc-butler)

(define-derived-mode cc-butler-log-mode special-mode "cc-butler-Log"
  "Major mode for the cc-butler butler<->worker message log.")

(defun cc-butler--log (fmt &rest args)
  "Append a timestamped FMT/ARGS line to `cc-butler-log-buffer-name'."
  (let ((buf (get-buffer-create cc-butler-log-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'cc-butler-log-mode) (cc-butler-log-mode))
      (let ((inhibit-read-only t))
        (save-excursion
          (goto-char (point-max))
          (insert (format-time-string "[%H:%M:%S] ")
                  (apply #'format fmt args) "\n")))
      (dolist (w (get-buffer-window-list buf nil t))
        (set-window-point w (point-max))))))

(defun cc-butler-show-log ()
  "Pop to the cc-butler message-log buffer."
  (interactive)
  (pop-to-buffer (get-buffer-create cc-butler-log-buffer-name)))

(defun cc-butler--inbox-push (dir body)
  "Record a worker event from session DIR with BODY into the butler inbox.
The worker's name and session id are attached, and the event is teed to
the cc-butler log."
  (push (list :time (current-time)
              :dir dir
              :name (cc-butler--display-name dir)
              :id (cc-butler--session-id dir)
              :body (or body ""))
        cc-butler--inbox)
  (cc-butler--log "%s → butler │ %s" (cc-butler--who-dir dir) (or body "")))

;; The steward is designated in `cc-butler-orchestrator' (loaded after this
;; file); forward-declare it so the list UI can pin/label it.
(defvar cc-butler--steward)

(defun cc-butler--role-rank (dir)
  "Return the pin rank for DIR: butler 0, steward 1, everything else 2."
  (cond ((and (boundp 'cc-butler--butler) (equal dir cc-butler--butler)) 0)
        ((and (boundp 'cc-butler--steward) (equal dir cc-butler--steward)) 1)
        (t 2)))

(defun cc-butler--session-label (dir default)
  "Return the sidebar label for session DIR.
The two coordinating roles show as fixed names; everything else uses
DEFAULT (its title / topic name)."
  (cond ((eq (cc-butler--role-rank dir) 0) "Butler")
        ((eq (cc-butler--role-rank dir) 1) "Steward")
        (t default)))

(defun cc-butler--ordered (sessions)
  "Sort SESSIONS for display.
The butler is pinned to slot 1 and the steward to slot 2.  Below them, workers
keep a FIXED order (alphabetical by working directory) regardless of state —
a session awaiting input is marked visually (⏳, `warning' face) rather than
reordered, so a row's position while you are navigating never shifts out from
under the cursor just because some session's wait-state flipped mid-move."
  (sort (copy-sequence sessions)
        (lambda (a b)
          (let ((ra (cc-butler--role-rank (plist-get a :dir)))
                (rb (cc-butler--role-rank (plist-get b :dir))))
            (cond
             ((/= ra rb) (< ra rb))
             ((= ra 2) (string< (plist-get a :dir) (plist-get b :dir)))
             (t nil))))))

;;;; ------------------------------------------------------------------
;;;; List UI (multi-line entries in a sticky side window)
;;;; ------------------------------------------------------------------

(defcustom cc-butler-list-width 40
  "Width, in columns, of the sticky session-list side window."
  :type 'integer
  :group 'cc-butler)

(defvar cc-butler--list-buffer-name "*claude-sessions*"
  "Name of the session-list buffer.")

(defvar cc-butler--main-window nil
  "The window the session manager uses to display session terminals.")

(defvar-local cc-butler--entries nil
  "Ordered list of (DIR . START-POS) for the rendered entries.")

(defvar-local cc-butler--hl-overlay nil
  "Overlay highlighting the currently selected entry block.")

(defvar-keymap cc-butler-mode-map
  :doc "Keymap for `cc-butler-mode'."
  "n"        #'cc-butler-next
  "p"        #'cc-butler-prev
  "<down>"   #'cc-butler-next
  "<up>"     #'cc-butler-prev
  "C-n"      #'cc-butler-next
  "C-p"      #'cc-butler-prev
  "RET"      #'cc-butler-visit
  "SPC"      #'cc-butler-preview
  "g"        #'cc-butler-refresh
  "c"        #'cc-butler-new-session
  "l"        #'cc-butler-show-log
  "h"        #'cc-butler-doctor
  "q"        #'cc-butler-quit)

(define-derived-mode cc-butler-mode special-mode "CC-Sessions"
  "Major mode for the Claude Code session manager."
  (buffer-disable-undo)
  (setq-local cursor-in-non-selected-windows nil))

;;;; Rendering

(defun cc-butler--render ()
  "Render all live sessions as multi-line blocks in the current buffer,
preserving the cursor's current session across the redraw when possible
(falls back to point-min only if that session is no longer present)."
  (let ((inhibit-read-only t)
        (dir (cc-butler--dir-at-point))
        (sessions (cc-butler--ordered (cc-butler--sessions)))
        entries)
    (erase-buffer)
    (if (null sessions)
        (insert (propertize "No active Claude sessions.\n\n" 'face 'shadow)
                (propertize "c" 'face 'bold) " start   "
                (propertize "g" 'face 'bold) " refresh   "
                (propertize "q" 'face 'bold) " quit\n")
      (dolist (s sessions)
        (let ((start (point))
              (title (plist-get s :title))
              (osc (plist-get s :osc))
              (status (plist-get s :status))
              (branch (plist-get s :branch))
              (forge (plist-get s :forge)))
          (push (cons (plist-get s :dir) start) entries)
          (let* ((d (plist-get s :dir))
                 (rank (cc-butler--role-rank d))
                 (waiting (cc-butler--waiting-p d)))
            (insert (propertize (concat (cond ((= rank 0) "★ ")   ; butler
                                              ((= rank 1) "⚙ ")   ; steward
                                              (waiting "⏳ ")
                                              (t "● "))
                                        (cc-butler--session-label d title)
                                        ;; inbox unread badge next to the butler
                                        (or (and (= rank 0) (fboundp 'cc-butler-inbox-count)
                                                 (let ((n (cc-butler-inbox-count)))
                                                   (and (> n 0) (format "  ⚖%d" n))))
                                            ""))
                                'face (cond ((= rank 0) 'font-lock-keyword-face)
                                            ((= rank 1) 'font-lock-function-name-face)
                                            (waiting 'warning)
                                            (t 'bold)))
                    "\n"))
          (unless (string-empty-p osc)
            (insert "   " (propertize osc 'face 'italic) "\n"))
          (unless (string-empty-p status)
            (insert "   " (propertize status 'face 'font-lock-string-face) "\n"))
          (let* ((sd (plist-get s :dir))
                 (meta (mapconcat
                        #'identity
                        (delq nil
                              (list (unless (string-empty-p branch)
                                      (concat "⎇ " branch))
                                    (unless (string-empty-p forge) forge)))
                        "   "))
                 ;; Context-length feedback tag (e.g. "ctx 187k"), provided by
                 ;; the cleaner module when loaded; highlighted once it crosses
                 ;; the cleanup threshold so 200k candidates stand out.
                 (ctx (and (fboundp 'cc-butler-cleanup-context-tag)
                           (cc-butler-cleanup-context-tag sd)))
                 (ctx-hot (and ctx (fboundp 'cc-butler-cleanup-context-over-threshold-p)
                               (cc-butler-cleanup-context-over-threshold-p sd)))
                 ;; Which model the session is running (e.g. "Sonnet-5"),
                 ;; scraped from the same statusLine feed as `ctx'.
                 (model (and (fboundp 'cc-butler-cleanup-model-tag)
                             (cc-butler-cleanup-model-tag sd)))
                 (segments (delq nil
                                 (list (unless (string-empty-p meta)
                                         (propertize meta 'face 'font-lock-comment-face))
                                       (and model
                                            (propertize model 'face 'font-lock-type-face))
                                       (and ctx
                                            (propertize ctx 'face (if ctx-hot 'warning
                                                                    'font-lock-comment-face)))))))
            (when segments
              (insert "   " (mapconcat #'identity segments "   ") "\n")))
          (insert "\n")
          (put-text-property start (point) 'cc-butler-dir (plist-get s :dir)))))
    (setq cc-butler--entries (nreverse entries))
    (if-let ((e (and dir (assoc dir cc-butler--entries))))
        (goto-char (cdr e))
      (goto-char (point-min)))
    (cc-butler--highlight)))

(defun cc-butler--list-buffer ()
  "Return the session-list buffer, (re)rendering its contents."
  (let ((buf (get-buffer-create cc-butler--list-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'cc-butler-mode)
        (cc-butler-mode))
      (cc-butler--render))
    buf))

(defun cc-butler--dir-at-point ()
  "Return the session working-dir for the entry at point, or nil."
  (get-text-property (point) 'cc-butler-dir))

(defun cc-butler--current-index ()
  "Index into `cc-butler--entries' of the entry containing point, or nil."
  (let ((pt (point)) (i 0) idx)
    (dolist (e cc-butler--entries)
      (when (>= pt (cdr e)) (setq idx i))
      (setq i (1+ i)))
    idx))

(defun cc-butler--entry-end (i)
  "Buffer position at which entry I ends."
  (if (< (1+ i) (length cc-butler--entries))
      (cdr (nth (1+ i) cc-butler--entries))
    (point-max)))

(defun cc-butler--highlight ()
  "Highlight the entry block at point."
  (when-let ((i (cc-butler--current-index)))
    (unless (overlayp cc-butler--hl-overlay)
      (setq cc-butler--hl-overlay (make-overlay 1 1)))
    (move-overlay cc-butler--hl-overlay
                  (cdr (nth i cc-butler--entries))
                  (cc-butler--entry-end i)
                  (current-buffer))
    (overlay-put cc-butler--hl-overlay 'face 'highlight)))

(defun cc-butler--reprint ()
  "Re-render the list in place; `cc-butler--render' itself keeps the cursor on
the selected session when possible."
  (when-let ((buf (get-buffer cc-butler--list-buffer-name)))
    (with-current-buffer buf
      (cc-butler--render))))

(defun cc-butler--maybe-refresh ()
  "Re-render the list if its buffer exists (safe to call from anywhere)."
  (when (get-buffer cc-butler--list-buffer-name)
    (cc-butler--reprint)))

;;;; Live updates from terminal title changes

(defvar cc-butler--refresh-timer nil
  "Debounce timer for live refreshes triggered by terminal title changes.")

(defun cc-butler--schedule-refresh ()
  "Debounced reprint, only while the list window is visible."
  (when (get-buffer-window cc-butler--list-buffer-name)
    (when (timerp cc-butler--refresh-timer)
      (cancel-timer cc-butler--refresh-timer))
    (setq cc-butler--refresh-timer
          (run-with-idle-timer 0.3 nil #'cc-butler--reprint))))

(defun cc-butler--on-title-change (&rest _)
  "Advice on `ghostel--set-title': nudge the manager to refresh live.
Claude emits an OSC 2 title as it works; the module funcalls
`ghostel--set-title' on each change, which we ride to update the list."
  (cc-butler--schedule-refresh))

(with-eval-after-load 'ghostel
  (when (fboundp 'ghostel--set-title)
    (advice-add 'ghostel--set-title :after #'cc-butler--on-title-change)))

;;;; Reflect session start / stop in the manager

(defun cc-butler--on-session-change (&rest _)
  "Advice: refresh the manager when a session is registered or torn down.
`claude-code-ide--set-process' adds a session to the registry (the point
at which it becomes enumerable), and `claude-code-ide--cleanup-on-exit'
removes it."
  (cc-butler--schedule-refresh))

(advice-add 'claude-code-ide--set-process :after #'cc-butler--on-session-change)
(advice-add 'claude-code-ide--cleanup-on-exit :after #'cc-butler--on-session-change)

;;;; Navigation / preview

(defun cc-butler--main-win ()
  "Return a live window for showing session terminals, creating one if needed."
  (let ((list-win (get-buffer-window cc-butler--list-buffer-name)))
    (if (and (window-live-p cc-butler--main-window)
             (not (eq cc-butler--main-window list-win)))
        cc-butler--main-window
      (setq cc-butler--main-window
            (or (seq-find (lambda (w)
                            (and (not (eq w list-win))
                                 (not (window-dedicated-p w))))
                          (window-list))
                (and (window-live-p list-win)
                     (split-window list-win nil 'right)))))))

(defcustom cc-butler-terminal-min-width 80
  "Columns a session's PTY is never sized below.

A new session's terminal buffer is not displayed in any window when it is
created, and the size that eventually reaches the PTY comes from whatever
window it first lands in — `claude-code-ide--sync-terminal-dimensions'
applies `window-body-width' with no lower bound.  With the frame split
narrow, sessions have come up at ELEVEN columns: the TUI cannot lay out its
input row, so keystrokes go nowhere and the session presents as \"input
doesn't work\" rather than as a size problem, which is what makes it
expensive to diagnose.

80x24 is the conventional terminal floor and what ghostel itself falls back
to when no window is available."
  :type 'integer :group 'cc-butler)

(defcustom cc-butler-terminal-min-height 24
  "Rows a session's PTY is never sized below.  See
`cc-butler-terminal-min-width' — same reasoning, same floor."
  :type 'integer :group 'cc-butler)

(defun cc-butler--pty-size-floor (buf)
  "Raise BUF's terminal to the configured floor if it sits below it.
Returns the (ROWS . COLS) enforced, or nil when nothing needed doing.

Both writes matter and they are not the same thing: `set-process-window-size'
is the pty ioctl, which is what the CLI on the far end reads, while
`ghostel--set-size-with-cell-dims' is libghostty's own grid, which is what
gets rendered into the buffer.  Fixing one and not the other leaves the
process and the display disagreeing about how wide the world is."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (let* ((proc (get-buffer-process buf))
             (rows (max (or (bound-and-true-p ghostel--term-rows) 0)
                        cc-butler-terminal-min-height))
             (cols (max (or (bound-and-true-p ghostel--term-cols) 0)
                        cc-butler-terminal-min-width)))
        (when (and (process-live-p proc)
                   (or (> rows (or (bound-and-true-p ghostel--term-rows) 0))
                       (> cols (or (bound-and-true-p ghostel--term-cols) 0))))
          (ignore-errors (set-process-window-size proc rows cols))
          (when-let ((term (and (fboundp 'ghostel--set-size-with-cell-dims)
                                (bound-and-true-p ghostel--term))))
            (ignore-errors
              (ghostel--set-size-with-cell-dims term rows cols)))
          (cc-butler--log "session: %s │ pty raised to %dx%d (was %sx%s)"
                          (buffer-name buf) rows cols
                          (or (bound-and-true-p ghostel--term-rows) "?")
                          (or (bound-and-true-p ghostel--term-cols) "?"))
          (cons rows cols))))))

(defun cc-butler--ensure-pty-size (dir)
  "Enforce the PTY floor on session DIR, whatever the window layout is.
Called on the launch path, where the terminal has never been displayed and
so has no window to take an honest size from."
  (cc-butler--pty-size-floor
   (get-buffer (claude-code-ide--get-buffer-name dir))))

(defun cc-butler--terminal-resize (buffer window)
  "Resize the ghostel terminal in BUFFER to fit WINDOW and redraw.
`set-window-buffer' does not run `window-size-change-functions', so
ghostel never resizes the PTY to the preview window; without this, claude
keeps rendering at its previous grid size and the preview shows stale or
clipped output.  Deferred so the buffer-change hook anchors the window
first."
  (when (and (buffer-live-p buffer) (window-live-p window))
    (run-at-time
     0 nil
     (lambda ()
       (when (and (buffer-live-p buffer) (window-live-p window)
                  (eq (window-buffer window) buffer))
         (with-current-buffer buffer
           (when (and (derived-mode-p 'ghostel-mode)
                      (fboundp 'ghostel--adjust-size))
             ;; Size the PTY to the LARGEST window showing the session (the
             ;; preview), not the default smallest — otherwise a second,
             ;; smaller window showing the same buffer shrinks the grid and
             ;; clips the preview.  Restored immediately.
             (let ((orig (default-value 'window-adjust-process-window-size-function)))
               (setq-default window-adjust-process-window-size-function
                             #'window-adjust-process-window-size-largest)
               (unwind-protect
                   (ignore-errors (ghostel--adjust-size window))
                 (setq-default window-adjust-process-window-size-function orig))))))))))

(defun cc-butler--fit-pty-largest (window)
  "Size the current ghostel buffer's PTY to WINDOW under the -largest policy
(so a second, smaller window showing the session does not shrink the grid)."
  (when (and (derived-mode-p 'ghostel-mode) (fboundp 'ghostel--adjust-size)
             (window-live-p window))
    (let ((orig (default-value 'window-adjust-process-window-size-function)))
      (setq-default window-adjust-process-window-size-function
                    #'window-adjust-process-window-size-largest)
      (unwind-protect (ignore-errors (ghostel--adjust-size window))
        (setq-default window-adjust-process-window-size-function orig))
      ;; A refit is sized from a window, so it can drop back under the floor
      ;; the moment the frame is split narrow.  Re-apply it here, or the
      ;; launch-time guarantee lasts only until the first layout change.
      (cc-butler--pty-size-floor (current-buffer)))))

(defun cc-butler--session-refit-on-change ()
  "Buffer-local `window-configuration-change-hook': re-fit the PTY to the
LARGEST window on any layout change (windmove / `C-x o'), not only on a
cc-butler preview — so a session never shrinks to the smallest window."
  (when-let ((win (get-buffer-window (current-buffer))))
    (cc-butler--fit-pty-largest win)))

(defun cc-butler--configure-session-buffer (buf)
  "Install the uniform cc-butler session config on ghostel BUF (idempotent).
Currently: a persistent -largest window-fit that covers windmove, not just
previews.  Return BUF."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (add-hook 'window-configuration-change-hook
                #'cc-butler--session-refit-on-change nil t)))
  buf)

(defun cc-butler--configure-session (dir)
  "Apply the uniform config to session DIR's buffer once it exists (deferred,
since the launch is async)."
  (run-at-time
   0.5 nil
   (lambda ()
     (cc-butler--configure-session-buffer
      (get-buffer (claude-code-ide--get-buffer-name dir))))))

(defun cc-butler--launch-preflight-diagnostics ()
  "Return a list of (SEVERITY . MESSAGE) launch-environment problems.
Checked BEFORE `claude-code-ide' is invoked so a fresh-install gap surfaces
as a clear `user-error' instead of a silent no-op or the cryptic bare
\"Invalid buffer\" error ghostel raises when its exec path is wrong — the
exact failure mode that made a first `B'/`S' press look like \"the shortcut
doesn't work\" on a freshly-installed machine (2026-07-06).  SEVERITY is
`error' (the launch will almost certainly fail) or `warn' (cc-butler's
ghostel-specific UI features — OSC-title tracking, terminal resize, screen
refresh — degrade, but the session still launches under another backend).
None of this is configured by `cc-butler' itself or declared in its
Package-Requires; it lives in the user's own Emacs init."
  (let ((backend (and (boundp 'claude-code-ide-terminal-backend)
                       claude-code-ide-terminal-backend))
        (cli (and (boundp 'claude-code-ide-cli-path) claude-code-ide-cli-path))
        problems)
    (unless (executable-find (or cli "claude"))
      (push (cons 'error
                   (format "claude CLI %S is not executable/found on PATH — set `claude-code-ide-cli-path' to an absolute path to the `claude' binary"
                           (or cli "claude")))
            problems))
    (if (eq backend 'ghostel)
        (progn
          (unless (featurep 'ghostel)
            (push (cons 'error
                         "`claude-code-ide-terminal-backend' is `ghostel' but the `ghostel' package is not installed/loaded — launches will fail. Install ghostel, or switch the backend to `vterm' or `eat'.")
                  problems))
          (when (and (stringp cli) (string-prefix-p "~" cli))
            (push (cons 'error
                         "`claude-code-ide-cli-path' starts with `~' — the ghostel backend spawns it via execvp with no shell, so `~' is never expanded and the process dies instantly (surfaces as a bare \"Invalid buffer\" error). Set it to an absolute path, e.g. via `executable-find'.")
                  problems)))
      (push (cons 'warn
                   (format "`claude-code-ide-terminal-backend' is `%s', not `ghostel' — cc-butler's OSC-title tracking, terminal resize, and screen-refresh features are ghostel-specific and will silently no-op under this backend."
                           (or backend "unset")))
            problems))
    (nreverse problems)))

;;;###autoload
(defun cc-butler-doctor ()
  "Check for fresh-install gaps that make a cc-butler session launch fail
silently or misbehave (missing ghostel, an unexpanded `~' in
`claude-code-ide-cli-path', a non-ghostel terminal backend, or no `claude'
CLI on PATH) and report them in `*cc-butler-doctor*'.  None of these are
cc-butler bugs — they are Emacs-init/environment setup this package
depends on but cannot install or verify for you."
  (interactive)
  (let ((problems (cc-butler--launch-preflight-diagnostics)))
    (with-current-buffer (get-buffer-create "*cc-butler-doctor*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (if (null problems)
            (insert "cc-butler: no known fresh-install gaps detected.\n")
          (dolist (p problems)
            (insert (format "[%s] %s\n\n" (upcase (symbol-name (car p))) (cdr p))))))
      (goto-char (point-min))
      (special-mode)
      (display-buffer (current-buffer)))))

;;;; ------------------------------------------------------------------
;;;; Terminal-text access (moved here from cc-butler-orchestrator.el
;;;; 2026-07-21, cc-butler#8 — both `cc-butler--launch-session' below and
;;;; `cc-butler--resume-in' need these to detect launch readiness, and
;;;; session.el sits below orchestrator.el in the require graph, so this
;;;; is the shared layer both can reach without a circular require)
;;;; ------------------------------------------------------------------

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

(defconst cc-butler--border-rule-char ?─
  "The box-drawing horizontal-rule character Claude Code draws immediately
above and below the live input row. Anchor on this CONTENT, not color —
measured foreground varies by session/theme (#0891b2 on one session,
#888888 on five others sampled 2026-07-21), the same theme-dependency
already known to affect the ghost/autocomplete color signature (see
cc-butler#6). The character itself was stable across every session
sampled.")

(defun cc-butler--border-line-p ()
  "Return non-nil if the line at point is a border rule: a run of
`cc-butler--border-rule-char' framing both ends of the line, regardless
of color. Not required to be PURELY the rule character — Claude Code
sometimes draws a short title (a branch/topic name) embedded in the
middle of the top border (confirmed 2026-07-21, e.g. \"───── some-topic
──\"), so this checks framing, not purity."
  (let ((text (string-trim (buffer-substring-no-properties
                             (line-beginning-position) (line-end-position))))
        (rule3 (make-string 3 cc-butler--border-rule-char))
        (rule2 (make-string 2 cc-butler--border-rule-char)))
    (and (> (length text) 3)
         (string-prefix-p rule3 text)
         (string-suffix-p rule2 text))))

(defun cc-butler--find-input-line (start end)
  "Search START..END for the input row: the single line sandwiched
between two consecutive border-rule lines (`cc-butler--border-line-p') —
the box Claude Code draws around the live input area, present whether
that area is empty, holds a ghost suggestion, or holds real typed text.
Return the buffer position of the row's start, preferring the LAST such
sandwich (closest to END), or nil if none is found."
  (save-excursion
    (goto-char start)
    (let (result)
      (while (< (point) end)
        (if (cc-butler--border-line-p)
            (progn
              (forward-line 1)
              (when (< (point) end)
                (let ((candidate (point)))
                  (forward-line 1)
                  (when (and (< (point) end) (cc-butler--border-line-p))
                    (setq result candidate))
                  (goto-char candidate))))
          (forward-line 1)))
      result)))

;;;; ------------------------------------------------------------------
;;;; Launch readiness (cc-butler#8, 2026-07-21) — a freshly spawned
;;;; `claude' CLI process is not immediately ready to read stdin.  A send
;;;; landing in that window is silently dropped, with no error and no
;;;; sign in `list_claude_sessions' that anything was wrong.  Gate ONCE,
;;;; right after spawn, rather than on every `send_to_session' call — a
;;;; busy session legitimately shows no input row too (mid permission
;;;; prompt, mid a "switch model?" confirmation, mid tool-call rendering,
;;;; all confirmed live 2026-07-21), so a per-send gate would add latency
;;;; or hang on ordinary sends that have nothing wrong with them.
;;;; ------------------------------------------------------------------

(defcustom cc-butler-launch-ready-timeout 5
  "Seconds to wait, right after a session's process is spawned, for its
input box to actually render before giving up. See
`cc-butler--wait-for-session-ready'."
  :type 'number
  :group 'cc-butler)

(defconst cc-butler--trust-dialog-marker "Quick safety check:"
  "Literal text unique to Claude Code's one-time \"trust this folder?\"
screen, shown the first time a directory is opened (confirmed 2026-07-21
on two never-before-launched directories). Anchor detection on this
exact phrase, not on the numbered-option layout alone or on color —
another first-run dialog could share that shape, and this codebase has
already been burned twice today by a color assumption that varied by
theme (`cc-butler--border-rule-char', `cc-butler--ghost-face-p')."
  )

(defun cc-butler--trust-dialog-showing-p (buf)
  "Return non-nil if BUF's terminal currently shows the folder-trust
screen (`cc-butler--trust-dialog-marker') with \"Yes, I trust this
folder\" as the highlighted/default option. Both the marker phrase AND
the exact option wording are required — a dialog that merely mentions
trust, or shares the numbered-option shape for an unrelated first-run
warning (e.g. an MCP permission prompt), must not be mistaken for this
one and auto-accepted (cc-butler#8)."
  (with-current-buffer buf
    (save-excursion
      (goto-char (point-min))
      (and (search-forward cc-butler--trust-dialog-marker nil t)
           (progn (goto-char (point-min))
                  (search-forward "❯ 1. Yes, I trust this folder" nil t))))))

(defun cc-butler--wait-for-session-ready (dir)
  "Block until DIR's session buffer shows a live input row (see
`cc-butler--find-input-line'), or `cc-butler-launch-ready-timeout'
elapses.  Called once, right after a session's process is spawned, by
both `cc-butler--launch-session' and `cc-butler--resume-in' — the two
places a `claude' process is started — so neither can return a false
\"launched\" into which a caller's first `send_to_session' silently
vanishes (cc-butler#8).

Along the way, if the one-time folder-trust screen is showing (always
true on a directory Claude Code has never opened before — the exact
scenario 정수님's original report was about, a fresh environment full of
new directories), accept it once (a bare Return; \"Yes, trust\" is the
pre-highlighted default) and keep polling for the real input row
afterward, rather than timing out on a session that is actually alive
and just waiting for a yes/no answer. Accepted at most once per call —
never re-sent if the screen is still transitioning — so a slow render
can't cause a second Return to land on whatever comes next.

Claude Code itself eventually auto-accepts this screen if left alone
(confirmed: it does NOT hang forever, but takes 15-65s, unbounded and
far past this function's timeout) — waiting it out is not an
alternative to answering it directly.

Signals an error on timeout rather than returning silently: a caller
that believes launch succeeded when the session never became reachable
is worse off than one told plainly that it didn't."
  (let ((buf (get-buffer (claude-code-ide--get-buffer-name dir)))
        (trust-accepted nil))
    (unless (buffer-live-p buf)
      (error "cc-butler: no terminal buffer for %s right after launch" dir))
    (with-timeout (cc-butler-launch-ready-timeout
                   (error "cc-butler: session %s did not show a live input row within %ss of launch (cc-butler#8)"
                          (cc-butler--display-name dir) cc-butler-launch-ready-timeout))
      (while (not (with-current-buffer buf
                    (cc-butler--refresh-terminal-text buf)
                    (let ((start (save-excursion (goto-char (point-max))
                                                  (forward-line -40)
                                                  (point))))
                      (cc-butler--find-input-line start (point-max)))))
        (if (and (not trust-accepted) (cc-butler--trust-dialog-showing-p buf))
            (progn
              (with-current-buffer buf (claude-code-ide--terminal-send-return))
              (setq trust-accepted t))
          (sleep-for 0.1))))))

(defun cc-butler--launch-session (dir)
  "The ONE path every role launches through — butler, steward, and workers —
so their ghostel config cannot diverge (global-consistency).  Launches a
channel-joined Claude session in DIR and applies the uniform config.
Runs `cc-butler--launch-preflight-diagnostics' first so a fresh-install
misconfiguration is a loud, actionable `user-error', not a silent no-op.
Blocks until the session is actually ready to receive input (see
`cc-butler--wait-for-session-ready') before returning, so a caller can
never be handed a false-ready session (cc-butler#8)."
  (dolist (p (cc-butler--launch-preflight-diagnostics))
    (if (eq (car p) 'error)
        (user-error "cc-butler: %s" (cdr p))
      (message "cc-butler: %s" (cdr p))))
  (let ((default-directory (file-name-as-directory (expand-file-name dir))))
    (cc-butler--with-channel (claude-code-ide))
    (cc-butler--configure-session dir))
  ;; Before the readiness wait, not after: that wait watches for the TUI's
  ;; input row, and a terminal eleven columns wide cannot draw one.  Sizing
  ;; first means a narrow frame costs nothing; sizing after would mean
  ;; timing out on a session that was only ever too narrow to look ready.
  (cc-butler--ensure-pty-size dir)
  (cc-butler--wait-for-session-ready dir))

(defvar cc-butler-after-preview-functions nil
  "Abnormal hook run after a session terminal is shown in the main window.
Each function receives (DIR MAIN-WINDOW).  The document-panel module
(`cc-butler-doc-panel') rides this to add or tear down the per-session
document split *before* the terminal is resized to its final width.")

(defun cc-butler-preview ()
  "Show the session at point in the main window, staying in the list."
  (interactive)
  (let* ((dir (cc-butler--dir-at-point))
         (buf (and dir (get-buffer (claude-code-ide--get-buffer-name dir))))
         (win (cc-butler--main-win)))
    (when (and (buffer-live-p buf) (window-live-p win))
      (set-window-buffer win buf)
      (run-hook-with-args 'cc-butler-after-preview-functions dir win)
      (cc-butler--terminal-resize buf win))))

(defun cc-butler--goto-index (i)
  "Move to entry I, highlight it and preview its session."
  (when (and cc-butler--entries (>= i 0) (< i (length cc-butler--entries)))
    (goto-char (cdr (nth i cc-butler--entries)))
    (cc-butler--highlight)
    (cc-butler-preview)))

(defun cc-butler-next ()
  "Move to the next session and preview it."
  (interactive)
  (let ((i (or (cc-butler--current-index) -1)))
    (cc-butler--goto-index (min (1+ i) (1- (length cc-butler--entries))))))

(defun cc-butler-prev ()
  "Move to the previous session and preview it."
  (interactive)
  (let ((i (or (cc-butler--current-index) 0)))
    (cc-butler--goto-index (max (1- i) 0))))

(defun cc-butler-visit ()
  "Preview the session at point, select its window, and clear it from the queue.
Visiting a session means you are attending to it, so it leaves the
input-waiting queue."
  (interactive)
  (cc-butler--clear-waiting (cc-butler--dir-at-point))
  (cc-butler-preview)
  (when (window-live-p (cc-butler--main-win))
    (select-window (cc-butler--main-win)))
  (cc-butler--maybe-refresh))

(defun cc-butler-refresh ()
  "Refresh the session list and re-fetch forge info."
  (interactive)
  (when cc-butler-enable-forge
    (dolist (s (cc-butler--sessions))
      (cc-butler--forge-fetch (plist-get s :dir))))
  (cc-butler--reprint))

;; `cc-butler-new-session' moved to cc-butler-workspace.el 2026-07-21
;; (cc-butler#7) — it needs `cc-butler--scaffold'/`cc-butler--start-session-in',
;; which live there, and workspace.el requires session.el, not the reverse.

(defun cc-butler-quit ()
  "Close the session-list side window."
  (interactive)
  (when-let ((win (get-buffer-window cc-butler--list-buffer-name)))
    (delete-window win)))

;;;###autoload
(defun cc-butler ()
  "Open the Claude Code Session Manager."
  (interactive)
  (let ((list-buf (cc-butler--list-buffer)))
    (delete-other-windows)
    (setq cc-butler--main-window (selected-window))
    (let ((list-win (display-buffer-in-side-window
                     list-buf
                     `((side . left) (slot . 0)
                       (window-width . ,cc-butler-list-width)
                       (preserve-size . (t . nil))))))
      (when (window-live-p list-win)
        (set-window-dedicated-p list-win t)
        (select-window list-win)
        (goto-char (point-min))
        (cc-butler--highlight)
        (cc-butler-preview))
      (when cc-butler-enable-forge
        (dolist (s (cc-butler--sessions))
          (cc-butler--forge-fetch (plist-get s :dir)))))))

;;;; ------------------------------------------------------------------
;;;; MCP tool: let Claude set its own title / status
;;;; ------------------------------------------------------------------

(defun cc-butler-tool-set-session-info (&optional title status)
  "MCP tool: let the calling Claude session set its own TITLE/STATUS."
  (let* ((ctx (claude-code-ide-mcp-server-get-session-context))
         (dir (plist-get ctx :project-dir)))
    (unless dir
      (error "No active Claude session context for this request"))
    (apply #'cc-butler--meta-set dir
           (append (when (and title (stringp title) (not (string-empty-p title)))
                     (list :title title))
                   (when (and status (stringp status))
                     (list :status status))))
    (cc-butler--maybe-refresh)
    (format "Updated session '%s': title=%s status=%s"
            (cc-butler--display-name dir)
            (or title "(unchanged)")
            (or status "(unchanged)"))))

;; Make (re)loading idempotent: drop any previously-registered tool of the
;; same name before registering, so reloads don't accumulate duplicates.
(setq claude-code-ide-mcp-server-tools
      (seq-remove
       (lambda (spec)
         (equal "set_session_info"
                (plist-get (claude-code-ide--normalize-tool-spec spec) :name)))
       claude-code-ide-mcp-server-tools))

(claude-code-ide-make-tool
 :function #'cc-butler-tool-set-session-info
 :name "set_session_info"
 :description "Set THIS Claude session's display title and/or status line in the Emacs session manager so the human can track multiple sessions at a glance. Use a short title naming the task/topic (e.g. 'billing: invoice PDF') and a concise status describing what you are doing right now (e.g. 'writing tests', 'waiting on review'). Call it whenever your focus changes."
 :args '((:name "title"
                :type string
                :description "Short task/topic title for this session. Optional; omit to leave unchanged."
                :optional t)
         (:name "status"
                :type string
                :description "Concise current status / subtitle. Optional; omit to leave unchanged."
                :optional t)))

(provide 'cc-butler-session)
;;; cc-butler-session.el ends here
