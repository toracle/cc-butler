;;; cc-butler-session-test.el --- tests for session launch config  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jeongsoo Park
;; SPDX-License-Identifier: MIT

;;   emacs -Q --batch -L . -l ert -l cc-butler-session-test.el \
;;     -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'cc-butler)

(ert-deftest cc-butler-session/configure-installs-refit-hook ()
  "The single session-config path installs a BUFFER-LOCAL window-refit hook, so
any layout change (windmove / C-x o) re-fits the PTY to the largest window (no
20x10 shrink) — the same for every role.  Faithful state assert on the
resulting hook, not on a call."
  (with-temp-buffer
    (cc-butler--configure-session-buffer (current-buffer))
    (should (memq #'cc-butler--session-refit-on-change
                  (buffer-local-value 'window-configuration-change-hook
                                      (current-buffer))))
    (should (local-variable-p 'window-configuration-change-hook))
    ;; idempotent — configuring twice does not double-install
    (cc-butler--configure-session-buffer (current-buffer))
    (should (= 1 (cl-count #'cc-butler--session-refit-on-change
                           (buffer-local-value 'window-configuration-change-hook
                                               (current-buffer)))))))

(ert-deftest cc-butler-session/single-launch-path-exists ()
  "All roles funnel through one launch+config path (global-consistency)."
  (should (fboundp 'cc-butler--launch-session))
  (should (fboundp 'cc-butler--configure-session)))

;;;; ---- ordering (Bug 3b: reordering-on-state-change) ---------------

(ert-deftest cc-butler-session/ordered-workers-fixed-alphabetical ()
  "Workers sort alphabetically by dir and STAY in that order regardless of
waiting-state — no more FIFO-by-wait-timestamp reordering, so a session
flipping to \"waiting\" mid-navigation no longer moves rows out from under
the cursor (regression: `cc-butler--ordered' used to sort waiting workers to
the front as an approval queue)."
  (let ((cc-butler--butler nil) (cc-butler--steward nil)
        (cc-butler--waiting (make-hash-table :test 'equal))
        (sessions (list (list :dir "/c/") (list :dir "/a/") (list :dir "/b/"))))
    (let ((order-1 (mapcar (lambda (s) (plist-get s :dir)) (cc-butler--ordered sessions))))
      (should (equal '("/a/" "/b/" "/c/") order-1))
      (puthash "/a/" (float-time) cc-butler--waiting)   ; "/a/" now waiting
      (let ((order-2 (mapcar (lambda (s) (plist-get s :dir)) (cc-butler--ordered sessions))))
        (should (equal order-1 order-2))))))            ; order unchanged

(ert-deftest cc-butler-session/ordered-pins-butler-and-steward ()
  "Butler and steward stay pinned to the top regardless of alphabetical dir order."
  (let* ((cc-butler--butler "/zzz-butler/") (cc-butler--steward "/steward/")
         (cc-butler--waiting (make-hash-table :test 'equal))
         (sessions (list (list :dir "/a-worker/") (list :dir "/steward/") (list :dir "/zzz-butler/"))))
    (should (equal '("/zzz-butler/" "/steward/" "/a-worker/")
                   (mapcar (lambda (s) (plist-get s :dir)) (cc-butler--ordered sessions))))))

;;;; ---- cursor preservation across redraw (Bug 3a) -------------------

(defvar cc-butler-session-test--sessions nil
  "Fake session-plist list `cc-butler--sessions' is stubbed to return.")

(defun cc-butler-session-test--fake-sessions () cc-butler-session-test--sessions)

(ert-deftest cc-butler-session/render-preserves-cursor-session-across-reorder ()
  "Re-rendering (e.g. the periodic refresh) keeps point on the SAME session by
identity even when a new session shifts row order — it does not reset to
point-min (the top row) just because positions moved (regression: only
`cc-butler--reprint' preserved the cursor, so any other/future direct caller
of `cc-butler--render' silently reset to the top)."
  (let ((cc-butler--butler nil) (cc-butler--steward nil)
        (cc-butler--waiting (make-hash-table :test 'equal))
        (cc-butler-session-test--sessions
         (list (list :dir "/b/" :title "b" :osc "" :status "" :branch "" :forge "")
               (list :dir "/c/" :title "c" :osc "" :status "" :branch "" :forge ""))))
    (cl-letf (((symbol-function 'cc-butler--sessions) #'cc-butler-session-test--fake-sessions))
      (with-temp-buffer
        (cc-butler-mode)
        (cc-butler--render)
        (goto-char (cdr (assoc "/c/" cc-butler--entries)))
        (should (equal "/c/" (cc-butler--dir-at-point)))
        ;; "/a/" arrives, sorting alphabetically BEFORE "/c/" — "/c/" is no
        ;; longer the last row.
        (setq cc-butler-session-test--sessions
              (append (list (list :dir "/a/" :title "a" :osc "" :status "" :branch "" :forge ""))
                      cc-butler-session-test--sessions))
        (cc-butler--reprint)
        (should (equal "/c/" (cc-butler--dir-at-point)))))))

;;;; ---- launch preflight diagnostics (fresh-install gaps) -------------
;;
;; Regression coverage for the fresh-install gap that made a first `B'/`S'
;; press on a newly-installed machine look like "the shortcut doesn't
;; work": `claude-code-ide' defaults to the `vterm' backend, but cc-butler's
;; UI is built on ghostel internals, and the required
;; `(setq claude-code-ide-terminal-backend 'ghostel)' + an absolute
;; `claude-code-ide-cli-path' live only in the user's own Emacs init, never
;; verified by `(require 'cc-butler)' itself. 2026-07-06.

(ert-deftest cc-butler-session/preflight-clean-when-well-configured ()
  "No problems reported when ghostel + an absolute cli-path + a real
executable are all in place."
  (let ((orig-featurep (symbol-function 'featurep)))
    (cl-letf (((symbol-function 'executable-find) (lambda (_) "/usr/bin/claude"))
              ((symbol-function 'featurep)
               (lambda (f) (or (eq f 'ghostel) (funcall orig-featurep f)))))
      (let ((claude-code-ide-terminal-backend 'ghostel)
            (claude-code-ide-cli-path "/usr/bin/claude"))
        (should (null (cc-butler--launch-preflight-diagnostics)))))))

(ert-deftest cc-butler-session/preflight-warns-on-non-ghostel-backend ()
  "A non-ghostel backend is a WARN (cc-butler's UI features degrade), not an
ERROR (the session still launches fine under vterm/eat)."
  (cl-letf (((symbol-function 'executable-find) (lambda (_) "/usr/bin/claude")))
    (let ((claude-code-ide-terminal-backend 'vterm)
          (claude-code-ide-cli-path "/usr/bin/claude"))
      (let ((problems (cc-butler--launch-preflight-diagnostics)))
        (should (= 1 (length problems)))
        (should (eq 'warn (car (car problems))))))))

(ert-deftest cc-butler-session/preflight-errors-when-ghostel-not-installed ()
  "ghostel backend selected but the package itself is not loaded: an ERROR,
since the launch will fail outright."
  (let ((orig-featurep (symbol-function 'featurep)))
    (cl-letf (((symbol-function 'executable-find) (lambda (_) "/usr/bin/claude"))
              ((symbol-function 'featurep)
               (lambda (f) (if (eq f 'ghostel) nil (funcall orig-featurep f)))))
      (let ((claude-code-ide-terminal-backend 'ghostel)
            (claude-code-ide-cli-path "/usr/bin/claude"))
        (should (memq 'error (mapcar #'car (cc-butler--launch-preflight-diagnostics))))))))

(ert-deftest cc-butler-session/preflight-errors-on-unexpanded-tilde-cli-path ()
  "A `~'-prefixed `claude-code-ide-cli-path' under the ghostel backend is a
known-broken combination — ghostel spawns it via execvp with no shell, so
`~' is never expanded and the process dies instantly with a bare \"Invalid
buffer\" error. Must be flagged explicitly, not left to the generic
not-executable check."
  (let ((orig-featurep (symbol-function 'featurep)))
    (cl-letf (((symbol-function 'executable-find) (lambda (_) nil))
              ((symbol-function 'featurep)
               (lambda (f) (or (eq f 'ghostel) (funcall orig-featurep f)))))
      (let* ((claude-code-ide-terminal-backend 'ghostel)
             (claude-code-ide-cli-path "~/.claude/local/claude")
             (problems (cc-butler--launch-preflight-diagnostics)))
        (should (seq-find (lambda (p) (string-match-p "execvp" (cdr p))) problems))))))

(ert-deftest cc-butler-session/preflight-errors-when-cli-not-executable ()
  "No usable `claude' binary at all is an ERROR regardless of backend."
  (cl-letf (((symbol-function 'executable-find) (lambda (_) nil)))
    (let ((claude-code-ide-terminal-backend 'vterm)
          (claude-code-ide-cli-path "claude"))
      (should (memq 'error (mapcar #'car (cc-butler--launch-preflight-diagnostics)))))))

(ert-deftest cc-butler-session/launch-session-refuses-on-preflight-error ()
  "`cc-butler--launch-session' raises a loud `user-error' — and never reaches
`claude-code-ide' — when the preflight reports an ERROR, so a fresh-install
misconfiguration is impossible to miss (regression: it used to fail silently
or with a cryptic downstream error)."
  (cl-letf (((symbol-function 'executable-find) (lambda (_) nil))
            ((symbol-function 'claude-code-ide)
             (lambda (&rest _) (error "claude-code-ide should not have been called"))))
    (let ((claude-code-ide-cli-path "/nonexistent/claude"))
      (should-error (cc-butler--launch-session "/tmp") :type 'user-error))))

;;;; ---- launch readiness (cc-butler#8, 2026-07-21) -------------------

(ert-deftest cc-butler-session/wait-for-ready-returns-once-input-line-appears ()
  "`cc-butler--wait-for-session-ready' returns (no error) as soon as the
session buffer shows a live input row — it does not wait out the full
timeout when the row is already there."
  (let ((term-buf (get-buffer-create " *cc-butler-test-ready-term*")))
    (unwind-protect
        (progn
          (with-current-buffer term-buf
            (insert (make-string 24 cc-butler--border-rule-char))
            (insert "\n❯ \n")
            (insert (make-string 24 cc-butler--border-rule-char)))
          (cl-letf (((symbol-function 'claude-code-ide--get-buffer-name)
                     (lambda (_d) (buffer-name term-buf)))
                    ((symbol-function 'cc-butler--refresh-terminal-text) (lambda (_buf) nil))
                    (cc-butler-launch-ready-timeout 2))
            (should (progn (cc-butler--wait-for-session-ready "/worker/") t))))
      (when (buffer-live-p term-buf) (kill-buffer term-buf)))))

(ert-deftest cc-butler-session/wait-for-ready-errors-on-timeout ()
  "`cc-butler--wait-for-session-ready' signals a loud error — rather than
returning as if launch succeeded — when no input row ever appears within
`cc-butler-launch-ready-timeout'. Silently returning here would hand a
caller a false-ready session (cc-butler#8)."
  (let ((term-buf (get-buffer-create " *cc-butler-test-ready-term-2*")))
    (unwind-protect
        (progn
          (with-current-buffer term-buf (insert "still starting up...\n"))
          (cl-letf (((symbol-function 'claude-code-ide--get-buffer-name)
                     (lambda (_d) (buffer-name term-buf)))
                    ((symbol-function 'cc-butler--refresh-terminal-text) (lambda (_buf) nil))
                    (cc-butler-launch-ready-timeout 0.3))
            (should-error (cc-butler--wait-for-session-ready "/worker/"))))
      (when (buffer-live-p term-buf) (kill-buffer term-buf)))))

(ert-deftest cc-butler-session/launch-session-waits-for-readiness ()
  "`cc-butler--launch-session' calls `cc-butler--wait-for-session-ready'
after spawning and configuring, so a caller can never be handed a
false-ready session into which a `send_to_session' silently vanishes
(cc-butler#8)."
  (let ((orig-featurep (symbol-function 'featurep))
        waited-for)
    (cl-letf (((symbol-function 'executable-find) (lambda (_) "/usr/bin/claude"))
              ((symbol-function 'featurep)
               (lambda (f) (or (eq f 'ghostel) (funcall orig-featurep f))))
              ((symbol-function 'claude-code-ide) (lambda (&rest _) nil))
              ((symbol-function 'cc-butler--configure-session) (lambda (_dir) nil))
              ((symbol-function 'cc-butler--wait-for-session-ready)
               (lambda (dir) (setq waited-for dir))))
      (let ((claude-code-ide-terminal-backend 'ghostel)
            (claude-code-ide-cli-path "/usr/bin/claude"))
        (cc-butler--launch-session "/tmp/some-worker/")))
    (should (equal waited-for (file-name-as-directory (expand-file-name "/tmp/some-worker/"))))))

(provide 'cc-butler-session-test)
;;; cc-butler-session-test.el ends here
