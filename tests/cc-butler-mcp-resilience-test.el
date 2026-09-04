;;; cc-butler-mcp-resilience-test.el --- tests for the MCP registry-wipe fix  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jeongsoo Park
;; SPDX-License-Identifier: MIT

;; Acceptance oracle for cc-butler-mcp-resilience.el, the fix for the
;; 2026-08-14 fleet-wide identity loss: claude-code-ide's shared MCP server
;; wipes `claude-code-ide-mcp-server--sessions' (clrhash in `--stop-server')
;; when its global session counter — which desyncs whenever one session's
;; cleanup is signalled twice — hits zero while other sessions are alive and
;; mid-conversation.  Observed live: 9 of 15 sessions orphaned, with a clean
;; time boundary at the wipe event.
;;
;; These tests run against the REAL claude-code-ide package (run-tests.el
;; puts ~/.emacs.d/elpa on the load-path, and cc-butler-orchestrator already
;; requires it), so the reproduction drives the genuine
;; `session-started'/`session-ended'/`--stop-server' control flow — not a
;; re-implementation of it.  All claude-code-ide state variables are
;; dynamically let-bound to fresh values, so nothing leaks between tests or
;; into the suite.  Only `claude-code-ide-mcp-http-server-stop' is stubbed:
;; without it `--stop-server' would signal void-function and its
;; condition-case would swallow the clrhash, hiding the very defect under
;; test.
;;
;;   emacs -Q --batch -l tests/run-tests.el

(require 'ert)
(require 'cl-lib)
(require 'cc-butler-mcp-resilience)

(defmacro cc-butler-mcp-resilience-test--with-mcp-state (&rest body)
  "Run BODY against fresh, isolated claude-code-ide MCP state.
Rebinds every state table/counter the wipe touches, plus the two
surviving tables recovery reads.  `claude-code-ide-mcp-server--server'
is a non-nil dummy so `--stop-server' proceeds past its guard to the
clrhash.  BODY can use PROCS (push processes to have them cleaned up),
BUFS (likewise for buffers) and LOGGED (list of formatted
`cc-butler--log' lines, newest first)."
  (declare (indent 0))
  `(let ((claude-code-ide-mcp-server--sessions (make-hash-table :test 'equal))
         (claude-code-ide-mcp-server--session-count 0)
         (claude-code-ide-mcp-server--server 'test-server)
         (claude-code-ide-mcp-server--port 65000)
         (claude-code-ide-mcp-server--current-session-id nil)
         (claude-code-ide--session-ids (make-hash-table :test 'equal))
         (claude-code-ide--processes (make-hash-table :test 'equal))
         (procs nil) (bufs nil) (logged nil))
     (ignore procs bufs logged)
     (unwind-protect
         (cl-letf (((symbol-function 'claude-code-ide-mcp-http-server-stop)
                    (lambda (_server) t))
                   ((symbol-function 'cc-butler--log)
                    (lambda (fmt &rest args)
                      (push (apply #'format fmt args) logged))))
           ,@body)
       (dolist (p procs) (ignore-errors (delete-process p)))
       (dolist (b bufs) (ignore-errors (kill-buffer b))))))

(defun cc-butler-mcp-resilience-test--spawn (id dir)
  "Start session ID in DIR the way claude-code-ide does at process creation.
Returns the (live) process.  Mirrors the session-creation slice of
`claude-code-ide' (~line 1069): notify the tools server with
(id dir buffer), record the process, record the session id."
  (let ((proc (start-process (concat "cc-butler-resilience-" id) nil
                             "sleep" "30"))
        (buf (get-buffer-create (claude-code-ide--get-buffer-name dir))))
    (claude-code-ide-mcp-server-session-started id dir buf)
    (puthash dir proc claude-code-ide--processes)
    (puthash dir id claude-code-ide--session-ids)
    proc))

(defun cc-butler-mcp-resilience-test--cleanup (dir)
  "The MCP-relevant slice of `claude-code-ide--cleanup-on-exit', same order.
Called TWICE for one dir this reproduces the real desync: the second
call finds the session id already removed and passes nil to
`session-ended', whose unregister half no-ops but whose decrement half
still fires — one session, two decrements."
  (remhash dir claude-code-ide--processes)
  (let ((session-id (gethash dir claude-code-ide--session-ids)))
    (claude-code-ide-mcp-server-session-ended session-id)
    (when session-id
      (remhash dir claude-code-ide--session-ids))))

(defun cc-butler-mcp-resilience-test--desync-to-zero ()
  "Drive the counter to zero while sessions A and B are alive.
Spawns live sessions A and B, then two short-lived sessions C and D
whose teardown each runs twice (the process sentinel and an explicit
stop both reach `claude-code-ide--cleanup-on-exit' in the real
package).  Counter walk: 4 -> 3 -> 2 -> 1 -> 0; at 0 the real
`session-ended' calls `--stop-server'.  Returns (PROC-A . PROC-B)."
  (let ((pa (cc-butler-mcp-resilience-test--spawn "sess-a" "/tmp/cc-rt-a/"))
        (pb (cc-butler-mcp-resilience-test--spawn "sess-b" "/tmp/cc-rt-b/")))
    (dolist (short '(("sess-c" . "/tmp/cc-rt-c/") ("sess-d" . "/tmp/cc-rt-d/")))
      (let ((p (cc-butler-mcp-resilience-test--spawn (car short) (cdr short))))
        (delete-process p)                          ; the short-lived CLI exits
        (cc-butler-mcp-resilience-test--cleanup (cdr short))   ; sentinel path
        (cc-butler-mcp-resilience-test--cleanup (cdr short)))) ; duplicate path
    (cons pa pb)))

;;;; ---- the historical defect, reproduced red -------------------------

(ert-deftest cc-butler-mcp-resilience/unfixed-counter-desync-wipes-live-sessions ()
  "RED reproduction of the 2026-08-14 defect, advice removed.
Given live sessions A and B and two short-lived sessions each cleaned
up twice, When the desynced counter hits zero, Then `--stop-server'
clrhashes the registry and A and B — alive, mid-conversation — lose
their identity: `get-session-context' returns nil for both.  This is
the behavior the fix exists for; if it stops reproducing, upstream
changed and the advice should be re-examined."
  (cc-butler-mcp-resilience-test--with-mcp-state
    (unwind-protect
        (progn
          (cc-butler-mcp-resilience-uninstall)
          (let ((ab (cc-butler-mcp-resilience-test--desync-to-zero)))
            (push (car ab) procs) (push (cdr ab) procs))
          ;; the wipe happened: server stopped, registry cleared
          (should (null claude-code-ide-mcp-server--server))
          (should (= 0 (hash-table-count claude-code-ide-mcp-server--sessions)))
          ;; A and B are still alive ... and orphaned
          (should (process-live-p (gethash "/tmp/cc-rt-a/" claude-code-ide--processes)))
          (should (null (claude-code-ide-mcp-server-get-session-context "sess-a")))
          (should (null (claude-code-ide-mcp-server-get-session-context "sess-b"))))
      (cc-butler-mcp-resilience-install))))

;;;; ---- layer 1: prevention --------------------------------------------

(ert-deftest cc-butler-mcp-resilience/layer1-averts-wipe-while-sessions-live ()
  "Given the same desync scenario With the advice installed, Then the
stop/clrhash is refused: A and B keep their registrations, the server
is not stopped, the counter is resynced to ground truth (2 live
processes), and the averted wipe is logged."
  (cc-butler-mcp-resilience-test--with-mcp-state
    (let ((ab (cc-butler-mcp-resilience-test--desync-to-zero)))
      (push (car ab) procs) (push (cdr ab) procs))
    (should (eq 'test-server claude-code-ide-mcp-server--server))
    (should (claude-code-ide-mcp-server-get-session-context "sess-a"))
    (should (claude-code-ide-mcp-server-get-session-context "sess-b"))
    (should (equal "/tmp/cc-rt-a/"
                   (plist-get (claude-code-ide-mcp-server-get-session-context "sess-a")
                              :project-dir)))
    (should (= 2 claude-code-ide-mcp-server--session-count))
    (should (cl-some (lambda (l) (string-match-p "averted registry wipe" l))
                     logged))))

(ert-deftest cc-butler-mcp-resilience/layer1-lets-a-genuine-last-exit-stop-the-server ()
  "Given every session genuinely ended (no live processes anywhere),
Then the guard steps aside and the server stops and clears normally."
  (cc-butler-mcp-resilience-test--with-mcp-state
    (let ((p (cc-butler-mcp-resilience-test--spawn "sess-a" "/tmp/cc-rt-a/")))
      (push p procs)
      (delete-process p)
      (cc-butler-mcp-resilience-test--cleanup "/tmp/cc-rt-a/"))
    (should (null claude-code-ide-mcp-server--server))
    (should (= 0 (hash-table-count claude-code-ide-mcp-server--sessions)))
    (should (= 0 claude-code-ide-mcp-server--session-count))))

;;;; ---- layer 2: lazy self-healing --------------------------------------

(ert-deftest cc-butler-mcp-resilience/layer2-heals-orphan-on-lookup-miss ()
  "Given a wiped registry but intact session-ids table and a live
process (the exact post-wipe world), When the orphan's context is
looked up, Then it is re-registered from the server-side tables — dir
and buffer recovered, counter consistent with the registry — and a
second lookup takes the normal path (recovery ran once)."
  (cc-butler-mcp-resilience-test--with-mcp-state
    (let ((proc (start-process "cc-butler-resilience-a" nil "sleep" "30"))
          (buf (get-buffer-create (claude-code-ide--get-buffer-name "/tmp/cc-rt-a/"))))
      (push proc procs) (push buf bufs)
      (puthash "/tmp/cc-rt-a/" proc claude-code-ide--processes)
      (puthash "/tmp/cc-rt-a/" "sess-a" claude-code-ide--session-ids)
      ;; sessions table empty, counter 0: the post-wipe world
      (let ((ctx (claude-code-ide-mcp-server-get-session-context "sess-a")))
        (should ctx)
        (should (equal "/tmp/cc-rt-a/" (plist-get ctx :project-dir)))
        (should (eq buf (plist-get ctx :buffer))))
      (should (gethash "sess-a" claude-code-ide-mcp-server--sessions))
      (should (= 1 claude-code-ide-mcp-server--session-count))
      ;; idempotence: second lookup hits the registry, no second heal
      (should (claude-code-ide-mcp-server-get-session-context "sess-a"))
      (should (= 1 claude-code-ide-mcp-server--session-count))
      (should (= 1 (cl-count-if (lambda (l) (string-match-p "healed orphaned session" l))
                                logged))))))

(ert-deftest cc-butler-mcp-resilience/layer2-heals-via-current-session-id ()
  "Given no explicit argument, When the transport-bound
`--current-session-id' names an orphan, Then healing works through it —
the path every MCP tool call actually takes."
  (cc-butler-mcp-resilience-test--with-mcp-state
    (let ((proc (start-process "cc-butler-resilience-a" nil "sleep" "30")))
      (push proc procs)
      (puthash "/tmp/cc-rt-a/" proc claude-code-ide--processes)
      (puthash "/tmp/cc-rt-a/" "sess-a" claude-code-ide--session-ids)
      (let ((claude-code-ide-mcp-server--current-session-id "sess-a"))
        (should (equal "/tmp/cc-rt-a/"
                       (plist-get (claude-code-ide-mcp-server-get-session-context)
                                  :project-dir)))))))

(ert-deftest cc-butler-mcp-resilience/layer2-unknown-id-returns-nil-registers-nothing ()
  "Given a session id absent from the session-ids table, Then the lookup
returns nil without error and nothing phantom is registered."
  (cc-butler-mcp-resilience-test--with-mcp-state
    (should (null (claude-code-ide-mcp-server-get-session-context "sess-nobody")))
    (should (= 0 (hash-table-count claude-code-ide-mcp-server--sessions)))
    (should (= 0 claude-code-ide-mcp-server--session-count))))

(ert-deftest cc-butler-mcp-resilience/layer2-dead-process-returns-nil-registers-nothing ()
  "Given a session id whose dir is known but whose process is dead,
Then no phantom registration: nil, empty registry, counter untouched."
  (cc-butler-mcp-resilience-test--with-mcp-state
    (let ((proc (start-process "cc-butler-resilience-dead" nil "sleep" "30")))
      (push proc procs)
      (delete-process proc)
      (puthash "/tmp/cc-rt-dead/" proc claude-code-ide--processes)
      (puthash "/tmp/cc-rt-dead/" "sess-dead" claude-code-ide--session-ids)
      (should (null (claude-code-ide-mcp-server-get-session-context "sess-dead")))
      (should (= 0 (hash-table-count claude-code-ide-mcp-server--sessions)))
      (should (= 0 claude-code-ide-mcp-server--session-count)))))

;;;; ---- hot-reload safety ------------------------------------------------

(ert-deftest cc-butler-mcp-resilience/double-install-does-not-stack-advice ()
  "Given `cc-butler-mcp-resilience-install' run twice (a hot reload
re-evaluating the module), Then each function carries the advice
exactly once, and a heal still fixes the counter up once, not twice."
  (unwind-protect
      (progn
        (cc-butler-mcp-resilience-install)
        (cc-butler-mcp-resilience-install)
        (dolist (spec '((claude-code-ide-mcp-server--stop-server
                         . cc-butler--mcp-guard-stop-server)
                        (claude-code-ide-mcp-server-get-session-context
                         . cc-butler--mcp-recover-session-context)))
          (let ((n 0))
            (advice-mapc (lambda (f _props) (when (eq f (cdr spec)) (cl-incf n)))
                         (car spec))
            (should (= 1 n))))
        (cc-butler-mcp-resilience-test--with-mcp-state
          (let ((proc (start-process "cc-butler-resilience-a" nil "sleep" "30")))
            (push proc procs)
            (puthash "/tmp/cc-rt-a/" proc claude-code-ide--processes)
            (puthash "/tmp/cc-rt-a/" "sess-a" claude-code-ide--session-ids)
            (should (claude-code-ide-mcp-server-get-session-context "sess-a"))
            (should (= 1 claude-code-ide-mcp-server--session-count))
            (should (= 1 (cl-count-if
                          (lambda (l) (string-match-p "healed orphaned session" l))
                          logged))))))
    (cc-butler-mcp-resilience-install)))

;;;; ------------------------------------------------------------------
;;;; json-rpc-error catchability
;;;; ------------------------------------------------------------------
;;
;; Regression for the 300s `send_to_session' hang: claude-code-ide signals
;; `json-rpc-error' on a bad MCP request (missing arg, unknown tool, unknown
;; method) but never registers it via `define-error', so no `condition-case'
;; anywhere — including claude-code-ide's own `--handle-post' handler meant
;; to catch exactly this and send a JSON-RPC error response — ever catches
;; it, and the HTTP response is simply never sent.

(ert-deftest cc-butler-mcp-resilience/json-rpc-error-is-defined ()
  "`json-rpc-error' must actually be a registered error symbol (not just a
bare symbol `signal' happens to be called with) — a `condition-case'
handler matches on the `error-conditions' property, which only exists
once `define-error' has been called."
  (should (get 'json-rpc-error 'error-conditions))
  (should (memq 'error (get 'json-rpc-error 'error-conditions))))

(ert-deftest cc-butler-mcp-resilience/json-rpc-error-is-catchable-as-error ()
  "The actual behavior this exists to fix: signaling `json-rpc-error' — the
same way claude-code-ide-mcp-http-server.el does at all three of its call
sites — must be caught by a plain `(error ...)' `condition-case' clause,
not escape uncaught. Without the `define-error' in cc-butler-mcp-resilience,
this test fails with an uncaught \"peculiar error\", exactly reproducing the
300s hang (the HTTP response never gets sent because the handler meant to
send it is never reached)."
  (let ((caught
         (condition-case err
             (progn (signal 'json-rpc-error (list -32602 "Missing required argument: text"))
                    'not-caught)
           (error (error-message-string err)))))
    (should (stringp caught))
    (should (string-match-p "Missing required argument: text" caught))))

(provide 'cc-butler-mcp-resilience-test)
;;; cc-butler-mcp-resilience-test.el ends here
