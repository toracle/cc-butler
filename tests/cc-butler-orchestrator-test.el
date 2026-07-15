;;; cc-butler-orchestrator-test.el --- tests for the turn-start nudge hooks  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jeongsoo Park
;; SPDX-License-Identifier: MIT

;; Acceptance oracle for the structural nudges added 2026-07-09: the fleet
;; stale-waiting scan, and the payload combinators the butler/steward
;; UserPromptSubmit hooks inject as context (check_inbox + decisions/events +
;; fleet check). These are pure combining logic over stubbed lower-level
;; calls — the lower-level calls themselves (drain mechanics, session
;; listing) are covered in cc-butler-mail-test.el / cc-butler-session-test.el.
;;
;;   emacs -Q --batch -L . -l ert -l cc-butler-orchestrator-test.el \
;;     -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'cc-butler-orchestrator)

;;;; ---- fleet stale-waiting summary -----------------------------------

(ert-deftest cc-butler-orchestrator/fleet-stale-waiting-flags-old-waiters ()
  "Given a worker waiting well past the threshold, Then it is flagged;
given one waiting only briefly, Then it is not; and the butler/steward
themselves are never flagged even if waiting a long time."
  (let* ((cc-butler-fleet-stale-waiting-seconds 60)
         (cc-butler--butler "/butler/")
         (cc-butler--steward "/steward/")
         (now (float-time))
         (cc-butler--waiting (make-hash-table :test 'equal)))
    (puthash "/worker-stale/" (- now 300) cc-butler--waiting)   ; long stale
    (puthash "/worker-fresh/" (- now 5) cc-butler--waiting)     ; just started
    (puthash "/butler/" (- now 300) cc-butler--waiting)         ; excluded role
    (puthash "/steward/" (- now 300) cc-butler--waiting)        ; excluded role
    (cl-letf (((symbol-function 'cc-butler--sessions)
               (lambda () (list (list :dir "/worker-stale/") (list :dir "/worker-fresh/")
                                 (list :dir "/butler/") (list :dir "/steward/"))))
              ((symbol-function 'cc-butler--display-name)
               (lambda (d) (pcase d ("/worker-stale/" "worker-stale")
                             ("/worker-fresh/" "worker-fresh")
                             ("/butler/" "butler") ("/steward/" "steward") (_ d)))))
      (let ((summary (cc-butler--fleet-stale-waiting-summary)))
        (should (string-match-p "worker-stale" summary))
        (should-not (string-match-p "worker-fresh" summary))
        (should-not (string-match-p "butler" summary))
        (should-not (string-match-p "steward" summary))))))

(ert-deftest cc-butler-orchestrator/fleet-stale-waiting-nil-when-none-stale ()
  "Given no session waiting past the threshold, Then the summary is nil."
  (let* ((cc-butler-fleet-stale-waiting-seconds 60)
         (cc-butler--butler "/butler/") (cc-butler--steward "/steward/")
         (cc-butler--waiting (make-hash-table :test 'equal)))
    (cl-letf (((symbol-function 'cc-butler--sessions) (lambda () (list (list :dir "/worker/")))))
      (should (null (cc-butler--fleet-stale-waiting-summary))))))

;;;; ---- hook payload combinators ---------------------------------------

(defmacro cc-butler-orchestrator-test--with-payload-stubs (inbox-block decisions events stale &rest body)
  "Stub the four payload ingredients and run BODY.
INBOX-BLOCK/STALE are the pre-formatted string-or-nil `cc-butler--inbox-urgent-block'
/`cc-butler--fleet-stale-waiting-summary' would return; DECISIONS/EVENTS
are the raw strings `cc-butler-tool-pending-decisions'/`cc-butler-tool-inbox'
would return (including their own \"No pending ...\" empty sentinels)."
  (declare (indent 4))
  `(cl-letf (((symbol-function 'cc-butler--inbox-urgent-block) (lambda (_agent) ,inbox-block))
             ((symbol-function 'cc-butler-tool-pending-decisions) (lambda () ,decisions))
             ((symbol-function 'cc-butler-tool-inbox) (lambda () ,events))
             ((symbol-function 'cc-butler--fleet-stale-waiting-summary) (lambda () ,stale)))
     ,@body))

(ert-deftest cc-butler-orchestrator/pending-decisions-payload-empty-is-empty-string ()
  "Given no inbox messages and no decisions, Then the payload is \"\"."
  (cc-butler-orchestrator-test--with-payload-stubs nil "No pending decisions." "No pending worker events." nil
    (should (equal "" (cc-butler--pending-decisions-hook-payload)))))

(ert-deftest cc-butler-orchestrator/pending-decisions-payload-combines-inbox-and-decisions ()
  "Given both an urgent inbox block and a decision, Then both appear,
inbox first."
  (cc-butler-orchestrator-test--with-payload-stubs
      "📥 1 unread inbox message(s) — handle before anything else this turn:\n- from x asks foo"
      "- [12:00] billing worker: use Stripe or Paddle?"
      "No pending worker events." nil
    (let ((payload (cc-butler--pending-decisions-hook-payload)))
      (should (string-match-p "\\`📥" payload))
      (should (string-match-p "unread inbox" payload))
      (should (string-match-p "Stripe or Paddle" payload))
      ;; inbox block precedes the decisions block
      (should (< (string-match "unread inbox" payload) (string-match "Stripe or Paddle" payload))))))

(ert-deftest cc-butler-orchestrator/pending-events-payload-combines-all-three ()
  "Given an inbox block, events, and a fleet-stale nudge, Then all three
appear in order: inbox, events, fleet check."
  (cc-butler-orchestrator-test--with-payload-stubs
      "📥 1 unread inbox message(s) — handle before anything else this turn:\n- from x asks foo"
      "No pending decisions." ; unused by the events payload
      "- [12:00] worker-a: done: PR #42"
      "🔍 Fleet check: 1 worker(s) waiting a while with no report — could be a stuck dialog (e.g. AskUserQuestion) rather than routine idle; read_session_output to check:\n- worker-b (waiting 300s)"
    (let ((payload (cc-butler--pending-events-hook-payload)))
      (should (string-match-p "unread inbox" payload))
      (should (string-match-p "PR #42" payload))
      (should (string-match-p "Fleet check" payload))
      (should (< (string-match "unread inbox" payload) (string-match "PR #42" payload)))
      (should (< (string-match "PR #42" payload) (string-match "Fleet check" payload))))))

(ert-deftest cc-butler-orchestrator/pending-events-payload-events-only ()
  "Given only events (no inbox, no stale workers), Then the payload is
exactly the events text, with no stray separators."
  (cc-butler-orchestrator-test--with-payload-stubs nil "No pending decisions."
      "- [12:00] worker-a: done: PR #42" nil
    (should (equal "- [12:00] worker-a: done: PR #42" (cc-butler--pending-events-hook-payload)))))

;;;; ---- session I/O timeout guard ---------------------------------------
;;;; 2026-07-15: a stuck ghostel redraw or wedged terminal write used to hang
;;;; the calling MCP request for the full 300s client-side timeout, with no
;;;; Emacs-side bound at all — and since `cc-butler--read-output' is also the
;;;; fallback path for every session-list row's model/context tag on a cache
;;;; miss, ONE wedged session could freeze `cc-butler--maybe-refresh' and
;;;; with it every tool that triggers a refresh, not just direct
;;;; read_session_output/send_to_session calls. `cc-butler-session-io-timeout'
;;;; bounds both primitives.

(ert-deftest cc-butler-orchestrator/read-output-times-out-on-stuck-redraw ()
  "Given a session whose terminal redraw hangs, Then `cc-butler--read-output'
gives up after `cc-butler-session-io-timeout' instead of blocking forever."
  (let ((cc-butler-session-io-timeout 0.2)
        (term-buf (get-buffer-create " *cc-butler-test-term*")))
    (unwind-protect
        (cl-letf (((symbol-function 'claude-code-ide--get-buffer-name)
                   (lambda (_d) (buffer-name term-buf)))
                  ((symbol-function 'cc-butler--display-name) (lambda (d) d))
                  ((symbol-function 'cc-butler--refresh-terminal-text)
                   (lambda (_buf) (sleep-for 5))))
          (let ((start (float-time)))
            (should-error (cc-butler--read-output "/worker/"))
            (should (< (- (float-time) start) 2))))
      (when (buffer-live-p term-buf) (kill-buffer term-buf)))))

(ert-deftest cc-butler-orchestrator/send-input-times-out-on-stuck-terminal ()
  "Given a session whose terminal write hangs, Then `cc-butler--send-input'
gives up after `cc-butler-session-io-timeout' instead of blocking forever."
  (let ((cc-butler-session-io-timeout 0.2)
        (term-buf (get-buffer-create " *cc-butler-test-term*")))
    (unwind-protect
        (cl-letf (((symbol-function 'claude-code-ide--get-buffer-name)
                   (lambda (_d) (buffer-name term-buf)))
                  ((symbol-function 'cc-butler--display-name) (lambda (d) d))
                  ((symbol-function 'claude-code-ide--terminal-send-string)
                   (lambda (_s) (sleep-for 5))))
          (let ((start (float-time)))
            (should-error (cc-butler--send-input "/worker/" "hi"))
            (should (< (- (float-time) start) 2))))
      (when (buffer-live-p term-buf) (kill-buffer term-buf)))))

(ert-deftest cc-butler-orchestrator/read-output-still-works-within-timeout ()
  "Given a session that responds promptly, Then `cc-butler--read-output'
returns its content normally — the timeout guard must not disturb the
non-hung path."
  (let ((cc-butler-session-io-timeout 5)
        (term-buf (get-buffer-create " *cc-butler-test-term*")))
    (unwind-protect
        (progn
          (with-current-buffer term-buf (insert "hello from the terminal\n"))
          (cl-letf (((symbol-function 'claude-code-ide--get-buffer-name)
                     (lambda (_d) (buffer-name term-buf)))
                    ((symbol-function 'cc-butler--refresh-terminal-text) (lambda (_buf) nil)))
            (should (equal "hello from the terminal" (cc-butler--read-output "/worker/")))))
      (when (buffer-live-p term-buf) (kill-buffer term-buf)))))

(provide 'cc-butler-orchestrator-test)
;;; cc-butler-orchestrator-test.el ends here
