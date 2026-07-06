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

(provide 'cc-butler-session-test)
;;; cc-butler-session-test.el ends here
