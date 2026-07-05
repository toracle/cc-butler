;;; cc-butler-cleanup-test.el --- tests for the session cleaner  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jeongsoo Park
;; SPDX-License-Identifier: MIT

;; Acceptance oracle for `cc-butler-cleanup': the default verifier, the trigger
;; gating, the externalize->verify->teardown state machine, and the safety
;; ordering.  The session-driving primitives (send / read / waiting) are stubbed
;; with `cl-letf', so nothing real is launched, typed, or deleted.
;;
;;   emacs -Q --batch -L . -l ert -l cc-butler-cleanup-test.el \
;;     -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'cl-lib)
(require 'cc-butler-cleanup)

;;;; ---- helpers ------------------------------------------------------

(defmacro cc-butler-cleanup-test--with-session (dir topic &rest body)
  "Run BODY with a fake worker session at DIR whose topic workspace is TOPIC.
Stubs display-name/role/session-id/topic-dir/waiting and the send primitive so
no real terminal is touched.  Sent text is collected in the dynamic var `sent'."
  (declare (indent 2))
  `(let ((sent nil)
         (cc-butler--butler nil)
         (cc-butler-cleanup--inhibit-timers t)
         (cc-butler-cleanup--state (make-hash-table :test 'equal))
         (term-buf (get-buffer-create " *cc-butler-test-term*")))
     (unwind-protect
         (cl-letf (((symbol-function 'cc-butler--display-name)
                    (lambda (d) (file-name-nondirectory (directory-file-name d))))
                   ((symbol-function 'cc-butler--role-rank) (lambda (_d) 2))
                   ((symbol-function 'cc-butler--session-id) (lambda (_d) "sid"))
                   ((symbol-function 'cc-butler--close-topic-dir) (lambda (_d) ,topic))
                   ((symbol-function 'cc-butler--waiting-p) (lambda (_d) (float-time)))
                   ((symbol-function 'cc-butler--send-input)
                    (lambda (_d text &optional _submit) (push text sent) t))
                   ((symbol-function 'cc-butler--log) (lambda (&rest _) nil))
                   ((symbol-function 'cc-butler--maybe-refresh) (lambda () nil))
                   ((symbol-function 'claude-code-ide--get-buffer-name)
                    (lambda (_d) (buffer-name term-buf))))
           (let ((,dir "/tmp/cc-butler-x/ws/"))
             ,@body))
       (when (buffer-live-p term-buf) (kill-buffer term-buf)))))

(defun cc-butler-cleanup-test--write-handoff (topic body)
  "Write BODY as the handoff doc under TOPIC; return its path."
  (make-directory topic t)
  (let ((f (expand-file-name cc-butler-cleanup-handoff-file topic)))
    (write-region body nil f nil 'silent)
    f))

;;;; ---- default verifier: trivial vs sufficient ----------------------

(ert-deftest cc-butler-cleanup/verify-missing-is-reason ()
  "A missing handoff doc fails verification with a reason string."
  (let* ((topic (file-name-as-directory (make-temp-file "cc-ext" t)))
         (res (cc-butler-cleanup--default-verify (list :topic-dir topic))))
    (should (stringp res))
    (should (string-match-p "missing" res))))

(ert-deftest cc-butler-cleanup/verify-trivial-is-reason ()
  "A too-small / too-thin handoff doc fails verification."
  (let* ((topic (file-name-as-directory (make-temp-file "cc-ext" t))))
    (cc-butler-cleanup-test--write-handoff topic "tiny\n")
    (let ((res (cc-butler-cleanup--default-verify (list :topic-dir topic))))
      (should (stringp res))
      (should (string-match-p "too small\\|too thin" res)))))

(ert-deftest cc-butler-cleanup/verify-sufficient-is-t ()
  "A substantial handoff doc passes verification (returns t)."
  (let* ((topic (file-name-as-directory (make-temp-file "cc-ext" t)))
         (body (mapconcat (lambda (i) (format "line %d: durable resume detail" i))
                          (number-sequence 1 20) "\n")))
    (cc-butler-cleanup-test--write-handoff topic body)
    (should (eq t (cc-butler-cleanup--default-verify (list :topic-dir topic))))))

;;;; ---- default context scrape --------------------------------------

(ert-deftest cc-butler-cleanup/context-scrapes-marker ()
  "The default context function reads the CTX:<n> marker off the terminal."
  (cl-letf (((symbol-function 'cc-butler--read-output)
             (lambda (&rest _) "status bar\nCTX:187342 57%\n")))
    (should (= 187342 (cc-butler-cleanup--default-context (list :dir "/d"))))))

(ert-deftest cc-butler-cleanup/context-absent-is-nil ()
  "No marker -> nil context (not an error, not zero)."
  (cl-letf (((symbol-function 'cc-butler--read-output) (lambda (&rest _) "nope")))
    (should (null (cc-butler-cleanup--default-context (list :dir "/d"))))))

;;;; ---- trigger gating ----------------------------------------------

(ert-deftest cc-butler-cleanup/trigger-fires-over-200k ()
  "Crossing the context threshold recommends cleanup."
  (let ((cc-butler-cleanup-context-threshold 200000)
        (cc-butler-cleanup-idle-threshold nil))
    (should (cc-butler-cleanup--default-trigger-p
             (list :context 210000 :waiting (float-time))))
    (should-not (cc-butler-cleanup--default-trigger-p
                 (list :context 190000 :waiting (float-time))))))

(ert-deftest cc-butler-cleanup/trigger-fires-when-idle ()
  "Sitting past the idle threshold recommends cleanup even under context."
  (let ((cc-butler-cleanup-context-threshold 200000)
        (cc-butler-cleanup-idle-threshold 60))
    (should (cc-butler-cleanup--default-trigger-p
             (list :context 10 :waiting (- (float-time) 120))))
    (should-not (cc-butler-cleanup--default-trigger-p
                 (list :context 10 :waiting (- (float-time) 5))))))

(ert-deftest cc-butler-cleanup/safe-candidate-excludes-butler-steward ()
  "The butler and steward are never cleanup candidates; a waiting worker is."
  (let ((cc-butler--butler "/b/") (cc-butler--steward "/s/")
        (cc-butler-cleanup-keep nil))
    (cl-letf (((symbol-function 'cc-butler--waiting-p) (lambda (_d) (float-time)))
              ((symbol-function 'cc-butler--display-name)
               (lambda (d) (file-name-nondirectory (directory-file-name d))))
              ((symbol-function 'cc-butler--role-rank)
               (lambda (d) (cond ((equal d "/b/") 0) ((equal d "/s/") 1) (t 2)))))
      (should-not (cc-butler-cleanup--safe-candidate-p "/b/"))
      (should-not (cc-butler-cleanup--safe-candidate-p "/s/"))
      (should (cc-butler-cleanup--safe-candidate-p "/w/")))))

(ert-deftest cc-butler-cleanup/keep-list-excludes ()
  "A session on the keep list is never a candidate."
  (let ((cc-butler--butler nil)
        (cc-butler-cleanup-keep '("keepme")))
    (cl-letf (((symbol-function 'cc-butler--waiting-p) (lambda (_d) (float-time)))
              ((symbol-function 'cc-butler--display-name)
               (lambda (d) (file-name-nondirectory (directory-file-name d))))
              ((symbol-function 'cc-butler--role-rank) (lambda (_d) 2)))
      (should-not (cc-butler-cleanup--safe-candidate-p "/x/keepme"))
      (should (cc-butler-cleanup--safe-candidate-p "/x/other")))))

;;;; ---- state machine: happy path (clear tier) ----------------------

(ert-deftest cc-butler-cleanup/clear-flow-externalizes-verifies-clears ()
  "clear tier: sends the externalize instruction, waits for the sentinel, verifies,
then types the clear command — in that order.  No delete."
  (cc-butler-cleanup-test--with-session dir "/tmp/cc-butler-x/ws/"
    (let* ((topic "/tmp/cc-butler-x/ws/")
           (body (mapconcat (lambda (i) (format "l%d durable" i))
                            (number-sequence 1 20) "\n"))
           (done nil))
      (cc-butler-cleanup-test--write-handoff topic body)
      (cl-letf (((symbol-function 'cc-butler--read-output)
                 (lambda (&rest _) (if done cc-butler-cleanup-sentinel "working…"))))
        (cc-butler-session-cleanup dir 'clear)
        ;; externalize instruction was sent, mentioning the sentinel
        (should (cc-butler-cleanup--active-p dir))
        (should (cl-some (lambda (s) (string-match-p cc-butler-cleanup-sentinel s))
                         sent))
        ;; not done yet: a poll keeps waiting, no clear typed
        (cc-butler-cleanup--poll dir)
        (should (cc-butler-cleanup--active-p dir))
        (should-not (member cc-butler-cleanup-clear-command sent))
        ;; worker prints the sentinel -> poll advances -> verify -> clear
        (setq done t)
        (cc-butler-cleanup--poll dir)
        (should (member cc-butler-cleanup-clear-command sent))
        (should-not (cc-butler-cleanup--active-p dir))))))

;;;; ---- safety ordering: no teardown before verify ------------------

(ert-deftest cc-butler-cleanup/verify-fail-blocks-teardown ()
  "If verification fails, NO teardown happens: no clear command is sent and the
cleanup ends (session untouched beyond the externalize prompt)."
  (cc-butler-cleanup-test--with-session dir "/tmp/cc-butler-x/ws-bad/"
    ;; no handoff doc written -> default verify returns a reason string
    (cl-letf (((symbol-function 'cc-butler--read-output)
               (lambda (&rest _) cc-butler-cleanup-sentinel)))
      (cc-butler-session-cleanup dir 'clear)
      (cc-butler-cleanup--poll dir)             ; sentinel present -> verify runs
      (should-not (member cc-butler-cleanup-clear-command sent))
      (should-not (cc-butler-cleanup--active-p dir)))))   ; ended, refused

(ert-deftest cc-butler-cleanup/force-skips-verify ()
  "FORCE lets teardown proceed even when verification would fail."
  (cc-butler-cleanup-test--with-session dir "/tmp/cc-butler-x/ws-bad2/"
    (cl-letf (((symbol-function 'cc-butler--read-output)
               (lambda (&rest _) cc-butler-cleanup-sentinel)))
      (cc-butler-session-cleanup dir 'clear t)   ; force = t
      (cc-butler-cleanup--poll dir)
      (should (member cc-butler-cleanup-clear-command sent)))))

;;;; ---- safety: delete-dir refused when git-audit fails --------------

(ert-deftest cc-butler-cleanup/delete-dir-refused-when-unsafe ()
  "delete-dir with a dirty workspace: verification passes but the git-safety
audit refuses; nothing is deleted and the shared teardown is never called."
  (cc-butler-cleanup-test--with-session dir "/tmp/cc-butler-x/ws-del/"
    (let* ((topic "/tmp/cc-butler-x/ws-del/")
           (body (mapconcat (lambda (i) (format "l%d durable" i))
                            (number-sequence 1 20) "\n"))
           (torn nil))
      (cc-butler-cleanup-test--write-handoff topic body)
      (cl-letf (((symbol-function 'cc-butler--read-output)
                 (lambda (&rest _) cc-butler-cleanup-sentinel))
                ;; workspace reports uncommitted work -> unsafe
                ((symbol-function 'cc-butler--close-topic-audit)
                 (lambda (_d) '(("repo" "uncommitted changes"))))
                ((symbol-function 'cc-butler--teardown-workspace)
                 (lambda (&rest _) (setq torn t) '(:deleted t)))
                ((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
        (cc-butler-session-cleanup dir 'delete-dir)
        (cc-butler-cleanup--poll dir)
        (should-not torn)                       ; teardown never reached
        (should-not (cc-butler-cleanup--active-p dir))))))

(ert-deftest cc-butler-cleanup/delete-dir-proceeds-when-clean-and-confirmed ()
  "delete-dir with a clean workspace + confirmation routes through the shared
teardown (which carries the git audit + confirmation)."
  (cc-butler-cleanup-test--with-session dir "/tmp/cc-butler-x/ws-del2/"
    (let* ((topic "/tmp/cc-butler-x/ws-del2/")
           (body (mapconcat (lambda (i) (format "l%d durable" i))
                            (number-sequence 1 20) "\n"))
           (torn nil))
      (cc-butler-cleanup-test--write-handoff topic body)
      (cl-letf (((symbol-function 'cc-butler--read-output)
                 (lambda (&rest _) cc-butler-cleanup-sentinel))
                ((symbol-function 'cc-butler--close-topic-audit) (lambda (_d) nil))
                ((symbol-function 'cc-butler--teardown-workspace)
                 (lambda (&rest _) (setq torn t) '(:deleted t :note nil)))
                ((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
        (cc-butler-session-cleanup dir 'delete-dir)
        (cc-butler-cleanup--poll dir)
        (should torn)
        (should-not (cc-butler-cleanup--active-p dir))))))

;;;; ---- reentrancy + role guards ------------------------------------

(ert-deftest cc-butler-cleanup/refuses-double-cleanup ()
  "A second cleanup of a session already in flight is refused."
  (cc-butler-cleanup-test--with-session dir "/tmp/cc-butler-x/ws-re/"
    (cl-letf (((symbol-function 'cc-butler--read-output) (lambda (&rest _) "…")))
      (cc-butler-session-cleanup dir 'clear)
      (should (cc-butler-cleanup--active-p dir))
      (should-error (cc-butler-session-cleanup dir 'clear) :type 'user-error))))

(ert-deftest cc-butler-cleanup/refuses-butler ()
  "Cleaning the butler session is refused outright."
  (let ((cc-butler--butler "/b/")
        (cc-butler-cleanup--state (make-hash-table :test 'equal)))
    (cl-letf (((symbol-function 'cc-butler--role-rank) (lambda (_d) 0))
              ((symbol-function 'cc-butler--display-name) (lambda (_d) "Butler")))
      (should-error (cc-butler-session-cleanup "/b/" 'clear) :type 'user-error))))

;;;; ---- timeout ------------------------------------------------------

(ert-deftest cc-butler-cleanup/timeout-aborts-untouched ()
  "If the sentinel never appears, the cleanup times out without tearing down."
  (cc-butler-cleanup-test--with-session dir "/tmp/cc-butler-x/ws-to/"
    (let ((cc-butler-cleanup-completion-timeout 0))
      (cl-letf (((symbol-function 'cc-butler--read-output)
                 (lambda (&rest _) "still working, no sentinel")))
        (cc-butler-session-cleanup dir 'clear)
        (cc-butler-cleanup--poll dir)           ; elapsed > 0 -> timeout
        (should-not (member cc-butler-cleanup-clear-command sent))
        (should-not (cc-butler-cleanup--active-p dir))))))

;;;; ---- surfacing ----------------------------------------------------

(ert-deftest cc-butler-cleanup/surface-recommends-once ()
  "Surfacing recommends an over-threshold idle candidate exactly once."
  (let ((cc-butler--butler nil)
        (cc-butler-cleanup-context-threshold 200000)
        (cc-butler-cleanup-idle-threshold nil)
        (cc-butler-cleanup-keep nil)
        (cc-butler-cleanup--state (make-hash-table :test 'equal))
        (cc-butler-cleanup--surfaced (make-hash-table :test 'equal))
        (calls 0))
    (cl-letf (((symbol-function 'cc-butler--sessions)
               (lambda () (list (list :dir "/w/big"))))
              ((symbol-function 'cc-butler--waiting-p) (lambda (_d) (float-time)))
              ((symbol-function 'cc-butler--display-name)
               (lambda (d) (file-name-nondirectory (directory-file-name d))))
              ((symbol-function 'cc-butler--role-rank) (lambda (_d) 2))
              ((symbol-function 'cc-butler--session-id) (lambda (_d) "s"))
              ((symbol-function 'cc-butler--close-topic-dir) (lambda (_d) "/w/big/"))
              ((symbol-function 'cc-butler-cleanup--default-context)
               (lambda (_s) 250000)))
      ;; surface-function is a defcustom (a var), so bind the var, not the fn:
      (let ((cc-butler-cleanup-surface-function
             (lambda (&rest _) (setq calls (1+ calls)))))
        (should (= 1 (cc-butler-cleanup-surface-candidates)))
        (should (= 0 (cc-butler-cleanup-surface-candidates))))  ; already surfaced
      (should (= 1 calls)))))

(provide 'cc-butler-cleanup-test)
;;; cc-butler-cleanup-test.el ends here
