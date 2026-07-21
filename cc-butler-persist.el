;;; cc-butler-persist.el --- Persist the session roster for crash recovery  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jeongsoo Park
;; SPDX-License-Identifier: MIT

;; Claude Code sessions live only in the running Emacs: if the daemon dies (for
;; example under mosh, when a disconnected client stops draining a pipe and the
;; daemon blocks on a write), the whole fleet is lost.  This module keeps a
;; durable snapshot of the session *roster* on disk, so after a restart each
;; session can be resumed with its previous conversation intact.
;;
;; Recovery uses `claude --continue' per working directory — the non-interactive
;; "resume the most recent conversation here" — which is the automatable form of
;; "restore the last session as-is".  (`claude --resume' without a conversation
;; id is interactive; we don't persist Claude's conversation ids, so --continue
;; is the reliable choice.  Override via `cc-butler-resume-args'.)

(require 'cc-butler-session)
(require 'cc-butler-orchestrator)
(require 'seq)
(require 'subr-x)

(defcustom cc-butler-roster-file
  (expand-file-name "cc-butler-sessions.eld" user-emacs-directory)
  "File the live session roster is snapshotted to for crash recovery.
Fleet-wide (not tied to the butler home), so it survives independently."
  :type 'file
  :group 'cc-butler)

(defcustom cc-butler-resume-args '("--continue")
  "Extra `claude' CLI args used to resume a session's previous conversation.
The default `--continue' resumes the most recent conversation in the
session's working directory (restore last state, non-interactive)."
  :type '(repeat string)
  :group 'cc-butler)

;;;; ------------------------------------------------------------------
;;;; Saving the roster
;;;; ------------------------------------------------------------------

(defun cc-butler--dir-key (dir)
  "Normalize DIR for identity comparisons across roster records."
  (file-name-as-directory (expand-file-name dir)))

(defun cc-butler--roster-write (records)
  "Write RECORDS to `cc-butler-roster-file' as the whole persisted roster."
  (ignore-errors
    (with-temp-file cc-butler-roster-file
      (let ((print-length nil) (print-level nil))
        (prin1 (list :saved (current-time) :sessions records) (current-buffer))
        (insert "\n")))))

(defun cc-butler--roster-records ()
  "Return a serializable snapshot of the roster: every live session, plus any
previously-persisted record not currently live whose directory still exists.
Sessions die one at a time (a mass teardown, e.g. an OS shutdown, is never
atomic), and the save is debounced — so merging in the last-known roster
instead of overwriting it outright keeps a transient dip in the live set
(e.g. only butler+steward up) from clobbering the durable record of every
other session.

A stale record is kept only while its directory still exists AND it has not
been explicitly forgotten (`cc-butler--roster-forget', called when a topic is
retired on purpose) — directory existence alone only reliably signals
retirement for a cc-butler-SCAFFOLDED topic (deleted by `cc-butler-close-topic');
a session opened on an existing project repo is never deleted that way, so
its retirement must be signaled explicitly instead.

`:butler' is forced to nil on every stale record: it is a liveness-derived
field, so letting it survive as stale truth would let a dead record outrank
the actual current butler on the next restore (last-write-wins there)."
  (let* ((live (mapcar (lambda (s)
                          (let ((dir (plist-get s :dir)))
                            (list :dir dir
                                  :name (cc-butler--display-name dir)
                                  :title (plist-get s :title)
                                  :status (plist-get s :status)
                                  :branch (plist-get s :branch)
                                  :butler (equal dir cc-butler--butler))))
                        (cc-butler--sessions)))
         (live-keys (mapcar (lambda (r) (cc-butler--dir-key (plist-get r :dir))) live))
         (stale (mapcar (lambda (r) (list :dir (plist-get r :dir)
                                          :name (plist-get r :name)
                                          :title (plist-get r :title)
                                          :status (plist-get r :status)
                                          :branch (plist-get r :branch)
                                          :butler nil))
                        (seq-filter
                         (lambda (r)
                           (and (consp r) (stringp (plist-get r :dir))
                                (not (member (cc-butler--dir-key (plist-get r :dir)) live-keys))
                                (file-directory-p (plist-get r :dir))))
                         (cc-butler--load-roster)))))
    (append live stale)))

(defun cc-butler--save-roster (&rest _)
  "Write the current roster to `cc-butler-roster-file'."
  (cc-butler--roster-write (cc-butler--roster-records)))

(defun cc-butler--roster-forget (dir)
  "Remove any persisted record for DIR from the roster file.
Call this when a session is retired ON PURPOSE — directory existence alone
cannot tell \"intentionally retired\" apart from \"died mid-shutdown\", so an
explicit forget is the only correct signal for a session whose directory
`cc-butler-close-topic' will never delete (an existing project repo)."
  (let ((key (cc-butler--dir-key dir)))
    (cc-butler--roster-write
     (seq-remove (lambda (r)
                   (and (consp r) (stringp (plist-get r :dir))
                        (equal (cc-butler--dir-key (plist-get r :dir)) key)))
                 (cc-butler--load-roster)))))

(defvar cc-butler--roster-timer nil
  "Idle timer debouncing roster saves.")

(defun cc-butler--roster-save-soon (&rest _)
  "Schedule a debounced roster save (safe to call from hooks/advice)."
  (when (timerp cc-butler--roster-timer)
    (cancel-timer cc-butler--roster-timer))
  (setq cc-butler--roster-timer
        (run-with-idle-timer 1.0 nil #'cc-butler--save-roster)))

;; Save whenever the session set or the butler designation changes.
(advice-add 'claude-code-ide--set-process :after #'cc-butler--roster-save-soon)
(advice-add 'claude-code-ide--cleanup-on-exit :after #'cc-butler--roster-save-soon)
(advice-add 'cc-butler-set-butler :after #'cc-butler--roster-save-soon)

;;;; ------------------------------------------------------------------
;;;; Loading + resuming
;;;; ------------------------------------------------------------------

(defun cc-butler--load-roster ()
  "Return the saved roster records, or nil."
  (when (file-exists-p cc-butler-roster-file)
    (ignore-errors
      (with-temp-buffer
        (insert-file-contents cc-butler-roster-file)
        (plist-get (read (current-buffer)) :sessions)))))

(defun cc-butler--dead-records ()
  "Return roster records whose session is not currently running."
  (seq-remove (lambda (r) (cc-butler--live-dir-p (plist-get r :dir)))
              (cc-butler--load-roster)))

(defun cc-butler--resume-in (dir)
  "Launch a Claude session in DIR resuming its previous conversation."
  (let ((claude-code-ide-cli-extra-flags
         (string-trim (concat (or claude-code-ide-cli-extra-flags "")
                              " " (mapconcat #'identity cc-butler-resume-args " "))))
        (default-directory (file-name-as-directory (expand-file-name dir))))
    (cc-butler--with-channel (claude-code-ide))))

;;;###autoload
(defun cc-butler-restore-sessions (&optional force)
  "Resume every recorded session that is not currently running.
Each is relaunched in its working directory with `cc-butler-resume-args'
(default `--continue'), restoring its previous conversation.  The butler
designation is restored too.  With FORCE (a prefix arg), skip the prompt."
  (interactive "P")
  (let* ((records (cc-butler--load-roster))
         (dead (cc-butler--dead-records)))
    (cond
     ((null records) (message "cc-butler: no saved roster at %s" cc-butler-roster-file))
     ((null dead)
      (message "cc-butler: all %d recorded session(s) already running" (length records)))
     ((or force
          (yes-or-no-p (format "Resume %d recorded session(s) with `%s'? "
                               (length dead)
                               (mapconcat #'identity cc-butler-resume-args " "))))
      (dolist (r dead)
        (cc-butler--resume-in (plist-get r :dir))
        (when (plist-get r :butler)
          (setq cc-butler--butler
                (file-name-as-directory (expand-file-name (plist-get r :dir))))))
      (message "cc-butler: resuming %d session(s)…" (length dead))
      (cc-butler)))))

(defun cc-butler--roster-hint (&rest _)
  "Note, on opening the manager, any recorded sessions that are not running."
  (when-let ((dead (cc-butler--dead-records)))
    (message "cc-butler: %d recorded session(s) not running — `R' (cc-butler-restore-sessions) to resume"
             (length dead))))

(advice-add 'cc-butler :after #'cc-butler--roster-hint)

(with-eval-after-load 'cc-butler-session
  (when (boundp 'cc-butler-mode-map)
    (define-key cc-butler-mode-map "R" #'cc-butler-restore-sessions)))

(provide 'cc-butler-persist)
;;; cc-butler-persist.el ends here
