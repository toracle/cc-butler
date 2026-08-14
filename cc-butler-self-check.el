;;; cc-butler-self-check.el --- periodic elisp self-check (existence -> consistency)  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jeongsoo Park
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Four defects on 2026-08-14 shared one shape: a value computed once, never
;; re-checked, found by accident, reporting success the whole time it was
;; wrong -- the MCP server port a session's argv baked in, the North Star
;; pulse file pointed at a directory that no longer existed, the governance
;; memory dir written to one place while the running code read from another
;; (see `cc-butler-governance.el''s own 2026-07-23 commentary), and the
;; `cc-butler' module load path itself being whatever the mutable dev
;; checkout happened to hold at restart time.  All four would pass an
;; EXISTENCE check ("is the variable set", "does the directory exist").
;; None would pass a CONSISTENCY check ("does the thing this points at match
;; the thing it is supposed to match, RIGHT NOW").  A fifth, the vault path
;; (`WARMBLE_JUMBLE_PATH' vs. `cc-butler-governance-store'), was found the
;; same night by another worker and is the cleanest illustration of the
;; thesis: both paths exist, both are genuine vault clones of the same
;; origin, so only asking "do they agree" catches it.
;;
;; This module is the periodic mechanical check for that whole class: a
;; registry of named checks, each returning (:ok BOOL :detail STRING), run
;; on a timer and reported two ways -- a quiet per-tick log no matter the
;; result, and a push notification ONLY on a check's ok<->fail transition
;; (both directions, so a fix is announced as loudly as a break).
;;
;; Modeled on two patterns already proven in this codebase rather than
;; inventing new ones: the timer + idle-safe-firing + interactive-command
;; shape of `cc-butler-north-star.el', and the "never read the variable
;; directly, ask the resolver function" discipline of
;; `cc-butler-governance-store' / `cc-butler-governance--load-dir' -- each
;; check below is a pair of small resolver functions (what does the config
;; say vs. what does reality say) so each half is independently stubbable
;; in tests.
;;
;; See ~/.emacs.d/cc-butler/butler/docs/design-periodic-self-check-2026-08-14.md
;; for the full design brief this module implements.

;;; Code:

(require 'cl-lib)
(require 'cus-edit)
(require 'seq)
(require 'subr-x)
(require 'cc-butler-session)
(require 'cc-butler-orchestrator)
(require 'cc-butler-governance)
(require 'cc-butler-docs)
(require 'cc-butler-north-star)

;; `cc-butler-source-dir' lives in cc-butler.el, which requires THIS file --
;; the reference is forward at compile time and resolved at run time, the
;; same pattern `cc-butler-session.el' already uses for
;; `cc-butler--source-diagnostics'.
(declare-function cc-butler-source-dir "cc-butler" ())

;;;; ------------------------------------------------------------------
;;;; Check 1: MCP port -- bound port == every live session's actual port
;;;; ------------------------------------------------------------------

(defun cc-butler-self-check--mcp-bound-port ()
  "Reality: the port `claude-code-ide-mcp-server' is ACTUALLY bound to, or nil.
Deliberately reads `claude-code-ide-mcp-server--port' (set at `ws-start'
success), never `claude-code-ide-mcp-server-port' (only the configured
*desired* port, which can be nil for auto-select) -- confusing those two
is the existence-only mistake that let a rebind go unnoticed on 2026-08-14."
  (and (boundp 'claude-code-ide-mcp-server--port)
       claude-code-ide-mcp-server--port))

(defun cc-butler-self-check--proc-env-port (pid)
  "Return the CLAUDE_CODE_SSE_PORT baked into PID's environment, or nil.
Read from /proc/PID/environ (Linux) -- the port a session's `claude' CLI
process was actually launched with, which a later server rebind does not
retroactively update."
  (let ((file (format "/proc/%d/environ" pid)))
    (and (file-readable-p file)
         (ignore-errors
           (with-temp-buffer
             (insert-file-contents-literally file)
             (let ((entry (seq-find
                           (lambda (v) (string-prefix-p "CLAUDE_CODE_SSE_PORT=" v))
                           (split-string (buffer-string) "\0" t))))
               (and entry
                    (string-to-number
                     (substring entry (length "CLAUDE_CODE_SSE_PORT="))))))))))

(defun cc-butler-self-check--session-ports ()
  "Return an alist of (DIR . PORT), PORT being the connection port each live
fleet session was actually launched with.  Sourced from `cc-butler--sessions'
-- the fleet's existing liveness roster -- and each session's real process,
not a new session-tracking mechanism.  A session whose port cannot be
determined (process gone, /proc unavailable) is simply omitted, never
reported as a mismatch."
  (delq nil
        (mapcar
         (lambda (s)
           (let* ((dir (plist-get s :dir))
                  (process (claude-code-ide--get-process dir))
                  (pid (and process (process-live-p process) (process-id process)))
                  (port (and pid (cc-butler-self-check--proc-env-port pid))))
             (and port (cons dir port))))
         (cc-butler--sessions))))

(defun cc-butler-self-check--mcp-port ()
  "Check 1: the bound MCP port matches every live session's actual port.
Fails on the exact 2026-08-14 failure mode: a session spawned before a
rebind, now silently pointed at a dead port."
  (let ((bound (cc-butler-self-check--mcp-bound-port))
        (sessions (cc-butler-self-check--session-ports)))
    (cond
     ((null bound)
      (list :ok nil
            :detail "MCP port: server not bound (claude-code-ide-mcp-server--port is nil) — no fleet session can be reaching it"))
     (t
      (let ((mismatched (seq-filter (lambda (sp) (/= (cdr sp) bound)) sessions)))
        (if mismatched
            (list :ok nil
                  :detail (format "MCP port: bound to %d, but %d live session(s) connected to a different port: %s"
                                  bound (length mismatched)
                                  (mapconcat (lambda (sp) (format "%s=%d" (car sp) (cdr sp)))
                                             mismatched ", ")))
          (list :ok t
                :detail (format "MCP port: bound to %d, matches all %d live session(s) with a known port"
                                bound (length sessions)))))))))

;;;; ------------------------------------------------------------------
;;;; Check 2: governance memory dir -- write path == read path
;;;; ------------------------------------------------------------------

(defun cc-butler-self-check--governance-write-dir ()
  "Reality A (write path): where `regenerate_governance' actually writes."
  cc-butler-governance-memory-dir)

(defun cc-butler-self-check--governance-read-dir ()
  "Reality B (read path): where the running butler's own CLAUDE.md actually
points a session at for shared memory -- the same derivation
`cc-butler--shared-state-note' / `cc-butler--learning-duty' already use,
anchored to the currently designated butler home (falling back to
`cc-butler-home' before one is designated)."
  (cc-butler--claude-memory-dir (or cc-butler--butler cc-butler-home)))

(defun cc-butler-self-check--governance-memory-dir ()
  "Check 2: the governance memory write path and the butler's own read path
must resolve to the same directory.  A direct instance of the governance
principle `one-path-for-write-and-read' -- a write landing somewhere the
reader never looks reports success while landing nothing, exactly the
2026-07-23 incident recorded in `cc-butler-governance.el''s own commentary."
  (let* ((write (cc-butler-self-check--governance-write-dir))
         (read (cc-butler-self-check--governance-read-dir))
         (write-abs (and write (file-name-as-directory (expand-file-name write))))
         (read-abs (and read (file-name-as-directory (expand-file-name read)))))
    (if (and write-abs read-abs (equal write-abs read-abs))
        (list :ok t
              :detail (format "governance memory dir: write path and read path agree (%s)"
                              (abbreviate-file-name write-abs)))
      (list :ok nil
            :detail (format "governance memory dir: write path (%s) != read path (%s) — see governance one-path-for-write-and-read"
                            (and write-abs (abbreviate-file-name write-abs))
                            (and read-abs (abbreviate-file-name read-abs)))))))

;;;; ------------------------------------------------------------------
;;;; Check 3: North Star file -- exists, and inside the CURRENT store
;;;; ------------------------------------------------------------------

(defun cc-butler-self-check--north-star-file ()
  "Check 3: `cc-butler-north-star-file' exists on disk, lives inside the
CURRENTLY effective `cc-butler-governance-store', and (only once PR #73
lands) passes `cc-butler--north-star-file-namespaced-p'.  PR #73's check
is a load/fire-time gate; this adds the periodic half -- catching a file
that was correct at configuration time but has since been orphaned by a
governance-dir move (exactly the 2026-08-14 root cause) even if its
basename still looks fine."
  (let* ((file cc-butler-north-star-file)
         (exists (and file (file-exists-p file)))
         (store (file-name-as-directory (expand-file-name (cc-butler-governance-store))))
         (dir-matches
          (and exists
               (equal (file-name-as-directory (expand-file-name (file-name-directory file)))
                      store)))
         (namespaced (if (fboundp 'cc-butler--north-star-file-namespaced-p)
                          (cc-butler--north-star-file-namespaced-p file)
                        'not-checked)))
    (cond
     ((not file)
      (list :ok nil :detail "north-star file: cc-butler-north-star-file is unset"))
     ((not exists)
      (list :ok nil :detail (format "north-star file: %s does not exist on disk" file)))
     ((not dir-matches)
      (list :ok nil
            :detail (format "north-star file: %s is not inside the currently effective governance store (%s)"
                            file store)))
     ((eq namespaced nil)
      (list :ok nil
            :detail (format "north-star file: %s failed the namespaced-basename check (cc-butler--north-star-file-namespaced-p)"
                            file)))
     (t
      (list :ok t
            :detail (format "north-star file: %s exists, inside the current governance store%s"
                            file
                            (if (eq namespaced 'not-checked)
                                " (namespaced-basename check not available — PR #73 not loaded)"
                              "")))))))

;;;; ------------------------------------------------------------------
;;;; Check 4: module load path -- DELIBERATE PARTIAL IMPLEMENTATION
;;;; ------------------------------------------------------------------

(defun cc-butler-self-check--module-load-path ()
  "Check 4 (partial by design -- see the design doc, verdict 3): the full
\"running code == stable install location\" comparison needs the
`.emacs.d' stable-path decision (a separate, still-open PR #1) as a
baseline, which does not exist yet.  What CAN run today: PR #74's
`cc-butler--commit-merged-p' ancestry check, which independently catches
the hot-load-of-unmerged-code half of this defect class (the actual
2026-08-14 PR #71 incident) even with no stable-path baseline.  Guarded
by `fboundp' since PR #74 may not
be merged in a given fleet; when it is not, this reports :ok t with a
detail string that says explicitly WHY it was not checked -- a bare
\"not checked\" would be indistinguishable from a real pass, repeating
tonight's exact mistake one level up."
  (if (fboundp 'cc-butler--commit-merged-p)
      (let ((verdict (cc-butler--commit-merged-p (cc-butler-source-dir))))
        (if (eq verdict 'unmerged)
            (list :ok nil
                  :detail (format "module load path: running code is UNMERGED — not reachable from origin/main (cc-butler--commit-merged-p -> %s); this is a hot-load of unreleased code"
                                  verdict))
          (list :ok t
                :detail (format "module load path: running code is reachable from origin/main (cc-butler--commit-merged-p -> %s). NOTE: this only checks ancestry, not stable-install-path equality — that half is still pending .emacs.d PR #1"
                                verdict))))
    (list :ok t
          :detail "module load path: not verified — no stable-install-path baseline yet, pending .emacs.d PR #1, and the ancestry-check dependency (PR #74's cc-butler--commit-merged-p) is not loaded in this fleet")))

;;;; ------------------------------------------------------------------
;;;; Check 5: persisted vs. live -- would this survive a restart?
;;;; ------------------------------------------------------------------

(defcustom cc-butler-self-check-tracked-variables
  '(cc-butler-north-star-file claude-code-ide-mcp-server-port)
  "Customizable variables periodically checked for persisted-vs-live drift
by check 5 (`cc-butler-self-check--persisted-vs-live').  A value only
`setq''d live (not through `customize-set-variable'/`customize-save-variable')
survives until the next restart and then reverts silently -- exactly what
bit three variables at once on 2026-08-14.  Extensible the same way the
check registry is."
  :type '(repeat symbol)
  :group 'cc-butler)

(defun cc-butler-self-check--persisted-vs-live ()
  "Check 5: every tracked variable's `custom-variable-state' is `saved' or
`standard' -- i.e. would still hold this value after an Emacs restart.
`set'/`changed'/`themed'/`rogue' all mean a live-patched value a restart
silently discards -- per 2026-08-14 framing, the more load-bearing question
(\"is this correct AFTER a restart\"), distinct from \"is this correct
right now\"."
  (let (bad)
    (dolist (sym cc-butler-self-check-tracked-variables)
      (when (boundp sym)
        (let ((state (custom-variable-state sym (symbol-value sym))))
          (unless (memq state '(saved standard))
            (push (cons sym state) bad)))))
    (setq bad (nreverse bad))
    (if bad
        (list :ok nil
              :detail (format "persisted vs live: %s"
                              (mapconcat
                               (lambda (b) (format "%s is `%s' (not saved/standard)" (car b) (cdr b)))
                               bad "; ")))
      (list :ok t
            :detail (format "persisted vs live: all %d tracked variable(s) are saved/standard"
                            (length cc-butler-self-check-tracked-variables))))))

;;;; ------------------------------------------------------------------
;;;; Check 6: vault path -- WARMBLE_JUMBLE_PATH vs. the governance store
;;;; ------------------------------------------------------------------

(defun cc-butler-self-check--vault-path ()
  "Check 6: `WARMBLE_JUMBLE_PATH' (if set) resolves to the same directory
`cc-butler-governance-store' actually reads from.  Both can be genuine
vault clones of the same origin, so no existence check catches a drift --
only asking whether they agree does.  cc-butler's own correctness does
not depend on this env var (the Emacs daemon does not inherit it); this
exists as a canary for OTHER tooling (wb-para's vault_paths.py,
push-vault.sh, the Stop hook) silently operating on a stale clone.
Reports only -- never edits `~/.zshrc' or any other shell config."
  (let* ((env (getenv "WARMBLE_JUMBLE_PATH"))
         (env-abs (and env (not (string-empty-p env))
                       (file-name-as-directory (expand-file-name env))))
         (store (file-name-as-directory (expand-file-name (cc-butler-governance-store)))))
    (cond
     ((not env-abs)
      (list :ok t :detail "vault path: WARMBLE_JUMBLE_PATH not set — nothing to compare"))
     ((equal env-abs store)
      (list :ok t
            :detail (format "vault path: WARMBLE_JUMBLE_PATH matches the governance store (%s)" store)))
     (t
      (list :ok nil
            :detail (format "vault path: WARMBLE_JUMBLE_PATH (%s) != governance store (%s)"
                            env-abs store))))))

;;;; ------------------------------------------------------------------
;;;; Registry
;;;; ------------------------------------------------------------------

(defvar cc-butler-self-check--checks
  '(("mcp-port" . cc-butler-self-check--mcp-port)
    ("governance-memory-dir" . cc-butler-self-check--governance-memory-dir)
    ("north-star-file" . cc-butler-self-check--north-star-file)
    ("module-load-path" . cc-butler-self-check--module-load-path)
    ("persisted-vs-live" . cc-butler-self-check--persisted-vs-live)
    ("vault-path" . cc-butler-self-check--vault-path))
  "Alist of (NAME . FUNCTION).  FUNCTION takes no args, returns a plist
\(:ok BOOL :detail STRING).  Extensible -- new checks are just new entries,
so this does not stay a fixed list of six forever.")

(defun cc-butler-self-check-run ()
  "Run every registered check.  Return an alist of (NAME . PLIST)."
  (mapcar (lambda (c) (cons (car c) (funcall (cdr c)))) cc-butler-self-check--checks))

;;;; ------------------------------------------------------------------
;;;; Reporting: quiet every tick, loud only on a transition
;;;; ------------------------------------------------------------------

(defvar cc-butler-self-check--previous nil
  "Alist NAME -> last-observed :ok value, for transition detection.
Absent on the very first tick a check is ever observed -- with no prior
state there is no transition to report, so the first observation of any
check never itself triggers an escalation, only establishes the baseline
future ticks compare against.")

(defun cc-butler-self-check--summary-line (results)
  "One-line ok/FAIL summary of RESULTS, for the quiet per-tick log."
  (mapconcat (lambda (r) (format "%s=%s" (car r) (if (plist-get (cdr r) :ok) "ok" "FAIL")))
             results " "))

(defun cc-butler-self-check--report (results)
  "Report RESULTS: a quiet per-tick summary no matter what, plus a loud
`display-warning' when anything is failing, plus a notification-kind
escalation for each check whose :ok flipped since the last tick (either
direction -- a fix must be announced as loudly as a break, or a human
carries a stale failure notification forever)."
  (let ((failing (seq-filter (lambda (r) (not (plist-get (cdr r) :ok))) results)))
    (when failing
      (display-warning
       'cc-butler-self-check
       (format "cc-butler self-check: %d failing — %s"
               (length failing)
               (mapconcat (lambda (r) (plist-get (cdr r) :detail)) failing " | "))))
    (ignore-errors
      (cc-butler-tool-log (format "self-check: %s" (cc-butler-self-check--summary-line results))
                           "event"))
    (dolist (r results)
      (let* ((name (car r))
             (ok (plist-get (cdr r) :ok))
             (cell (assoc name cc-butler-self-check--previous)))
        (if cell
            (progn
              (when (not (eq (cdr cell) ok))
                (ignore-errors
                  (cc-butler-tool-escalate-to-butler
                   (format "cc-butler self-check: `%s' %s — %s"
                           name (if ok "RECOVERED" "started FAILING")
                           (plist-get (cdr r) :detail))
                   nil nil "notification")))
              (setcdr cell ok))
          (push (cons name ok) cc-butler-self-check--previous)))))
  results)

;;;; ------------------------------------------------------------------
;;;; Timer + interactive command (mirrors cc-butler-north-star.el)
;;;; ------------------------------------------------------------------

(defcustom cc-butler-self-check-interval (* 15 60)
  "Seconds between self-check ticks.  15 minutes, uniform across all checks
\(verdict 1 -- differentiate only once evidence demands it; every check
here is a cheap local-state comparison, none is network- or terminal-I/O-
bound, and every 2026-08-14 incident was wrong for hours, not minutes)."
  :type 'number
  :group 'cc-butler)

(defvar cc-butler--self-check-timer nil
  "Repeating timer driving `cc-butler--self-check-fire', or nil before first use.")

(defun cc-butler--self-check-fire ()
  "Timer callback: run every check and report.  Unconditional -- unlike
`cc-butler--north-star-fire' this never types into any session's terminal,
so it does not need to gate on butler idleness."
  (cc-butler-self-check--report (cc-butler-self-check-run)))

;;;###autoload
(defun cc-butler-self-check ()
  "Run the self-check right now and report a one-line summary.
Mirrors `cc-butler-north-star-check' -- always messages, never silent."
  (interactive)
  (let ((results (cc-butler-self-check--report (cc-butler-self-check-run))))
    (message "cc-butler self-check: %s" (cc-butler-self-check--summary-line results))
    results))

(defun cc-butler--self-check-ensure-timer ()
  "(Re)register the self-check timer; idempotent for hot reloads."
  (when (timerp cc-butler--self-check-timer)
    (cancel-timer cc-butler--self-check-timer))
  (setq cc-butler--self-check-timer
        (run-with-timer cc-butler-self-check-interval
                         cc-butler-self-check-interval
                         #'cc-butler--self-check-fire)))

(cc-butler--self-check-ensure-timer)

;;;; ------------------------------------------------------------------
;;;; MCP tool: pull the full state on demand
;;;; ------------------------------------------------------------------

(defun cc-butler-tool-self-check ()
  "MCP tool: run the self-check on demand and return EVERY check's state,
ok and failing both -- a clean run should be positively confirmable, not
just silent."
  (let ((results (cc-butler-self-check-run)))
    (mapconcat
     (lambda (r)
       (format "[%s] %s — %s"
               (if (plist-get (cdr r) :ok) "OK" "FAIL")
               (car r) (plist-get (cdr r) :detail)))
     results "\n")))

;; Idempotent registration.
(when (fboundp 'claude-code-ide-make-tool)
  (setq claude-code-ide-mcp-server-tools
        (seq-remove
         (lambda (spec)
           (member (plist-get (claude-code-ide--normalize-tool-spec spec) :name)
                   '("self_check")))
         claude-code-ide-mcp-server-tools))
  (claude-code-ide-make-tool
   :function #'cc-butler-tool-self-check
   :name "self_check"
   :description "Pull the full state of cc-butler's periodic consistency self-check (existence -> consistency), on demand, from any fleet session. Six checks: MCP bound port vs. each live session's actual connection port; governance memory write-path vs. read-path; the North Star file's existence + location inside the current governance store; the running module code's ancestry vs. origin/main (deliberately partial -- pending a separate stable-install-path decision); tracked customizable variables' persisted-vs-live state (would this survive a restart); and WARMBLE_JUMBLE_PATH vs. the governance store (a cross-tool vault-drift canary). Returns EVERY check's state, ok and failing both -- a clean run is positively confirmable, not just silent."
   :args nil))

(provide 'cc-butler-self-check)
;;; cc-butler-self-check.el ends here
