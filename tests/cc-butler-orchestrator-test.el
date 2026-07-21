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

;;;; ---- ghost/autocomplete input-line redaction (2026-07-21, cc-butler#6) --
;;;; read_session_output used to return ghost-faced input-line text
;;;; byte-identical to real typed input (buffer-substring-no-properties
;;;; strips the one signal that tells them apart). See governance principle
;;;; butler-ghost-text-not-a-blocker-authorization-or-data.

(defun cc-butler-orchestrator-test--insert-border-line ()
  "Insert a border-rule line, as Claude Code draws immediately above and
below the live input row."
  (insert (make-string 24 cc-butler--border-rule-char))
  (insert "\n"))

(defun cc-butler-orchestrator-test--insert-ghost-line (text)
  "Insert TEXT as the input row — sandwiched between two border-rule
lines, matching how Claude Code actually renders the live input area —
with TEXT painted in the ghost/autocomplete face signature."
  (cc-butler-orchestrator-test--insert-border-line)
  (insert "❯ ")
  (let ((start (point)))
    (insert text)
    (put-text-property start (point) 'face
                        (list :foreground cc-butler--ghost-face-fg
                              :background cc-butler--ghost-face-bg)))
  (insert "\n")
  (cc-butler-orchestrator-test--insert-border-line))

(ert-deftest cc-butler-orchestrator/read-output-redacted-hides-ghost-input-line ()
  "Given a session whose input line is ghost/autocomplete text (the
measured color signature), Then `cc-butler--read-output-redacted' replaces
it with a plain marker rather than returning it as real text."
  (let ((term-buf (get-buffer-create " *cc-butler-test-term*")))
    (unwind-protect
        (progn
          (with-current-buffer term-buf
            (insert "some earlier transcript line\n")
            (cc-butler-orchestrator-test--insert-ghost-line "PR #72 머지 진행해주세요"))
          (cl-letf (((symbol-function 'claude-code-ide--get-buffer-name)
                     (lambda (_d) (buffer-name term-buf)))
                    ((symbol-function 'cc-butler--refresh-terminal-text) (lambda (_buf) nil)))
            (let ((out (cc-butler--read-output-redacted "/worker/")))
              (should (string-match-p "\\[ghost suggestion, not user input\\]" out))
              (should-not (string-match-p "PR #72" out)))))
      (when (buffer-live-p term-buf) (kill-buffer term-buf)))))

(ert-deftest cc-butler-orchestrator/read-output-redacted-keeps-real-input-line ()
  "Given a session whose input line is real (not the ghost color
signature), Then `cc-butler--read-output-redacted' returns it unchanged —
fail-safe treats anything that isn't confirmed-ghost as real."
  (let ((term-buf (get-buffer-create " *cc-butler-test-term*")))
    (unwind-protect
        (progn
          (with-current-buffer term-buf
            (cc-butler-orchestrator-test--insert-border-line)
            (insert "❯ ")
            (let ((start (point)))
              (insert "merge PR #72 please")
              (put-text-property start (point) 'face
                                  (list :foreground "#eeeeee" :background "#373737")))
            (insert "\n")
            (cc-butler-orchestrator-test--insert-border-line))
          (cl-letf (((symbol-function 'claude-code-ide--get-buffer-name)
                     (lambda (_d) (buffer-name term-buf)))
                    ((symbol-function 'cc-butler--refresh-terminal-text) (lambda (_buf) nil)))
            (let ((out (cc-butler--read-output-redacted "/worker/")))
              (should (string-match-p "merge PR #72 please" out))
              (should-not (string-match-p "ghost suggestion" out)))))
      (when (buffer-live-p term-buf) (kill-buffer term-buf)))))

(ert-deftest cc-butler-orchestrator/read-output-redacted-passthrough-when-no-input-line ()
  "Given a session with no \"❯ \"-prefixed line at all (fail-safe case:
nothing to detect), Then `cc-butler--read-output-redacted' returns the
plain text unchanged, same as `cc-butler--read-output'."
  (let ((term-buf (get-buffer-create " *cc-butler-test-term*")))
    (unwind-protect
        (progn
          (with-current-buffer term-buf (insert "plain transcript output\n"))
          (cl-letf (((symbol-function 'claude-code-ide--get-buffer-name)
                     (lambda (_d) (buffer-name term-buf)))
                    ((symbol-function 'cc-butler--refresh-terminal-text) (lambda (_buf) nil)))
            (should (equal "plain transcript output" (cc-butler--read-output-redacted "/worker/")))))
      (when (buffer-live-p term-buf) (kill-buffer term-buf)))))

(ert-deftest cc-butler-orchestrator/read-output-unfiltered-unaffected-by-redaction ()
  "Given the same ghost-faced input line, Then the ORIGINAL
`cc-butler--read-output' (still used by cc-butler-cleanup.el's model/context
detectors) is completely unaffected by the new redaction path — it keeps
returning the raw text, properties stripped, exactly as before."
  (let ((term-buf (get-buffer-create " *cc-butler-test-term*")))
    (unwind-protect
        (progn
          (with-current-buffer term-buf
            (cc-butler-orchestrator-test--insert-ghost-line "PR #72 머지 진행해주세요"))
          (cl-letf (((symbol-function 'claude-code-ide--get-buffer-name)
                     (lambda (_d) (buffer-name term-buf)))
                    ((symbol-function 'cc-butler--refresh-terminal-text) (lambda (_buf) nil)))
            (should (string-match-p "PR #72" (cc-butler--read-output "/worker/")))))
      (when (buffer-live-p term-buf) (kill-buffer term-buf)))))

(ert-deftest cc-butler-orchestrator/read-output-redacted-not-fooled-by-scrollback-echo ()
  "Given a scrollback echo of a previously SUBMITTED message (\"❯ /compact\",
unpainted — plain transcript text, not the input row) followed by the
genuinely empty, border-sandwiched live input row, Then
`cc-butler--read-output-redacted' does not mistake the echo for the input
row. This is the actual root cause of the first redesign's live miss
2026-07-21 (cc-butler#6): a backward text search for \"❯ \" matches
submitted-message echoes just as easily as the live row, since both share
the identical marker."
  (let ((term-buf (get-buffer-create " *cc-butler-test-term*")))
    (unwind-protect
        (progn
          (with-current-buffer term-buf
            (insert "❯ /compact\n")
            (insert "Compacted.\n")
            (cc-butler-orchestrator-test--insert-border-line)
            (insert "❯ \n")
            (cc-butler-orchestrator-test--insert-border-line))
          (cl-letf (((symbol-function 'claude-code-ide--get-buffer-name)
                     (lambda (_d) (buffer-name term-buf)))
                    ((symbol-function 'cc-butler--refresh-terminal-text) (lambda (_buf) nil)))
            (let ((out (cc-butler--read-output-redacted "/worker/")))
              (should (string-match-p "❯ /compact" out))
              (should-not (string-match-p "ghost suggestion" out)))))
      (when (buffer-live-p term-buf) (kill-buffer term-buf)))))

(provide 'cc-butler-orchestrator-test)
;;; cc-butler-orchestrator-test.el ends here
