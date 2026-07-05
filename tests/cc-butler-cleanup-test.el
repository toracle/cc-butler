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
         ;; durable store -> a throwaway temp dir, never the real default
         (cc-butler-cleanup-handoff-dir
          (file-name-as-directory (make-temp-file "cc-durable" t)))
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

(ert-deftest cc-butler-cleanup/context-parses-clear-hint-k ()
  "The default parse reads the idle \"/clear to save <N>k tokens\" hint."
  (cl-letf (((symbol-function 'cc-butler--read-output)
             (lambda (&rest _) "  Context left until auto-compact\n\
  /clear to save 152k tokens\n")))
    (should (= 152000 (cc-butler-cleanup--default-context (list :dir "/d"))))))

(ert-deftest cc-butler-cleanup/context-parses-clear-hint-m ()
  "The default parse also handles the M (millions) form of the save hint."
  (cl-letf (((symbol-function 'cc-butler--read-output)
             (lambda (&rest _) "/clear to save 1.2M tokens")))
    (should (= 1200000 (cc-butler-cleanup--default-context (list :dir "/d"))))))

(ert-deftest cc-butler-cleanup/context-parses-percent-used ()
  "The default parse estimates tokens from \"<N>% context used\" against the
configured context window."
  (let ((cc-butler-cleanup-context-window 200000))
    (cl-letf (((symbol-function 'cc-butler--read-output)
               (lambda (&rest _) "45% context used")))
      (should (= 90000 (cc-butler-cleanup--default-context (list :dir "/d")))))))

(ert-deftest cc-butler-cleanup/context-marker-wins-over-tui-hints ()
  "The reliable CTX: marker takes precedence over the default-TUI hints when
both are present in the scrape."
  (cl-letf (((symbol-function 'cc-butler--read-output)
             (lambda (&rest _) "CTX:187342 57%\n/clear to save 152k tokens")))
    (should (= 187342 (cc-butler-cleanup--default-context (list :dir "/d"))))))

;;;; ---- last-known-value persistence (no flicker) -------------------

(ert-deftest cc-butler-cleanup/context-keeps-last-known-on-nil-read ()
  "A fresh read of nil (indicator gone mid-task) must KEEP the last-known size,
so the sessions-list tag persists instead of flickering out; a new real reading
replaces it."
  (let ((cc-butler-cleanup--context-cache (make-hash-table :test 'equal))
        (cc-butler-cleanup-context-ttl 0)   ; force a fresh scrape on every call
        (reading 187342))
    (let ((cc-butler-cleanup-context-function (lambda (_s) reading)))
      ;; first read sees a real value -> cached and shown
      (should (equal "ctx 187k" (cc-butler-cleanup-context-tag "/w/")))
      ;; indicator disappears: read returns nil -> tag STILL shows last-known
      (setq reading nil)
      (should (equal "ctx 187k" (cc-butler-cleanup-context-tag "/w/")))
      (should (= 187342 (cc-butler-cleanup-context-for "/w/")))
      ;; a new real reading replaces the kept value
      (setq reading 150000)
      (should (equal "ctx 150k" (cc-butler-cleanup-context-tag "/w/"))))))

(ert-deftest cc-butler-cleanup/context-nil-with-no-prior-value-is-nil ()
  "With no value ever read, a nil read yields nil (no phantom tag)."
  (let ((cc-butler-cleanup--context-cache (make-hash-table :test 'equal))
        (cc-butler-cleanup-context-ttl 0)
        (cc-butler-cleanup-context-function (lambda (_s) nil)))
    (should (null (cc-butler-cleanup-context-for "/w/")))
    (should (null (cc-butler-cleanup-context-tag "/w/")))))

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
  "Cleaning the butler session is refused outright by the CORE guard."
  (let ((cc-butler--butler "/b/")
        (cc-butler-cleanup--state (make-hash-table :test 'equal)))
    (cl-letf (((symbol-function 'cc-butler--role-rank) (lambda (_d) 0))
              ((symbol-function 'cc-butler--display-name) (lambda (_d) "Butler")))
      (should-error (cc-butler-session-cleanup "/b/" 'clear) :type 'user-error))))

(ert-deftest cc-butler-cleanup/refuses-steward ()
  "Cleaning the steward session is refused outright by the CORE guard."
  (let ((cc-butler--butler nil)
        (cc-butler--steward "/s/")
        (cc-butler-cleanup--state (make-hash-table :test 'equal)))
    (cl-letf (((symbol-function 'cc-butler--role-rank) (lambda (_d) 1))
              ((symbol-function 'cc-butler--display-name) (lambda (_d) "Steward")))
      (should-error (cc-butler-session-cleanup "/s/" 'clear) :type 'user-error))))

;;;; ---- target resolution: butler/steward never targetable ----------

(ert-deftest cc-butler-cleanup/eligible-excludes-butler-steward ()
  "The eligible-worker set (what the picker offers) never includes the butler or
steward, so they can never be confirmed as a target."
  (let ((cc-butler--butler "/b/") (cc-butler--steward "/s/"))
    (cl-letf (((symbol-function 'cc-butler--sessions)
               (lambda () (list (list :dir "/b/") (list :dir "/s/")
                                (list :dir "/w1/") (list :dir "/w2/"))))
              ((symbol-function 'cc-butler--role-rank)
               (lambda (d) (cond ((equal d "/b/") 0) ((equal d "/s/") 1) (t 2)))))
      (let ((dirs (cc-butler-cleanup--eligible-worker-dirs)))
        (should (equal dirs '("/w1/" "/w2/")))
        (should-not (member "/b/" dirs))
        (should-not (member "/s/" dirs))))))

(ert-deftest cc-butler-cleanup/read-target-confirms-by-name ()
  "Target resolution confirms by NAME over eligible workers and returns that dir;
a resolved-at-point BUTLER never leaks through as the target."
  (let ((cc-butler--butler "/b/") (cc-butler--steward nil))
    (cl-letf (((symbol-function 'cc-butler--sessions)
               (lambda () (list (list :dir "/b/") (list :dir "/w1/"))))
              ((symbol-function 'cc-butler--role-rank)
               (lambda (d) (if (equal d "/b/") 0 2)))
              ((symbol-function 'cc-butler--display-name)
               (lambda (d) (file-name-nondirectory (directory-file-name d))))
              ;; point is on the butler, but confirmation must resolve a worker
              ((symbol-function 'cc-butler-cleanup--context-target) (lambda () "/b/"))
              ((symbol-function 'completing-read)
               (lambda (_p coll &rest _)
                 ;; the butler must not even be offered
                 (should-not (member "b" coll))
                 "w1")))
      (should (equal "/w1/" (cc-butler-cleanup--read-target))))))

;;;; ---- durable record lives OUTSIDE the topic dir ------------------

(ert-deftest cc-butler-cleanup/durable-file-is-outside-topic-dir ()
  "The durable record path is in the handoff-dir, never under the topic dir."
  (let ((cc-butler-cleanup-handoff-dir "/var/durable/")
        (session (list :name "proj-x" :topic-dir "/tmp/ws/proj-x/")))
    (let ((durable (cc-butler-cleanup--durable-file session)))
      (should (equal durable "/var/durable/proj-x.md"))
      (should-not (string-prefix-p (expand-file-name "/tmp/ws/proj-x/")
                                   (expand-file-name durable))))))

(ert-deftest cc-butler-cleanup/promote-copies-record-outside ()
  "Promote copies the in-dir re-hydration record to the durable OUTSIDE store."
  (let* ((topic (file-name-as-directory (make-temp-file "cc-topic" t)))
         (durable (file-name-as-directory (make-temp-file "cc-dur" t)))
         (cc-butler-cleanup-handoff-dir durable)
         (session (list :name "sess" :topic-dir topic))
         (body (mapconcat (lambda (i) (format "l%d durable detail" i))
                          (number-sequence 1 20) "\n")))
    (write-region body nil (expand-file-name cc-butler-cleanup-handoff-file topic)
                  nil 'silent)
    (should (eq t (cc-butler-cleanup--default-promote session)))
    (should (file-exists-p (expand-file-name "sess.md" durable)))))

(ert-deftest cc-butler-cleanup/delete-dir-verify-checks-outside-record ()
  "For delete-dir, verify checks the OUTSIDE durable record: it fails when only
the in-dir copy exists, and passes once the record has been promoted outside."
  (let* ((topic (file-name-as-directory (make-temp-file "cc-topic" t)))
         (durable (file-name-as-directory (make-temp-file "cc-dur" t)))
         (cc-butler-cleanup-handoff-dir durable)
         (session (list :name "sess" :topic-dir topic :tier 'delete-dir))
         (body (mapconcat (lambda (i) (format "l%d durable detail" i))
                          (number-sequence 1 20) "\n")))
    (write-region body nil (expand-file-name cc-butler-cleanup-handoff-file topic)
                  nil 'silent)
    ;; in-dir exists but nothing promoted yet -> delete-dir verify fails
    (should (stringp (cc-butler-cleanup--default-verify session)))
    ;; promote outside, then delete-dir verify passes
    (cc-butler-cleanup--default-promote session)
    (should (eq t (cc-butler-cleanup--default-verify session)))))

;;;; ---- context feedback tag formatting -----------------------------

(ert-deftest cc-butler-cleanup/context-tag-formats-k ()
  "The sessions-list context tag renders compactly as \"ctx <n>k\"."
  (let ((cc-butler-cleanup--context-cache (make-hash-table :test 'equal))
        (cc-butler-cleanup-context-function (lambda (_s) 187342)))
    (should (equal "ctx 187k" (cc-butler-cleanup-context-tag "/w/")))))

(ert-deftest cc-butler-cleanup/context-tag-nil-when-unknown ()
  "No CTX marker -> no tag (nil), not \"ctx 0k\"."
  (let ((cc-butler-cleanup--context-cache (make-hash-table :test 'equal))
        (cc-butler-cleanup-context-function (lambda (_s) nil)))
    (should (null (cc-butler-cleanup-context-tag "/w/")))))

(ert-deftest cc-butler-cleanup/context-over-threshold-flag ()
  "The over-threshold flag drives the sessions-list highlight."
  (let ((cc-butler-cleanup--context-cache (make-hash-table :test 'equal))
        (cc-butler-cleanup-context-threshold 200000)
        (cc-butler-cleanup-context-function (lambda (_s) 210000)))
    (should (cc-butler-cleanup-context-over-threshold-p "/w/")))
  (let ((cc-butler-cleanup--context-cache (make-hash-table :test 'equal))
        (cc-butler-cleanup-context-threshold 200000)
        (cc-butler-cleanup-context-function (lambda (_s) 150000)))
    (should-not (cc-butler-cleanup-context-over-threshold-p "/w/"))))

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

;;;; ---- MCP tool: close_topic (the butler's teardown hand) ----------

(ert-deftest cc-butler-cleanup/close-topic-tool-refuses-unknown-name ()
  "close_topic on an unknown session name refuses and touches nothing."
  (let (torn)
    (cl-letf (((symbol-function 'cc-butler--dir-by-name) (lambda (_n) nil))
              ((symbol-function 'cc-butler--teardown-workspace)
               (lambda (&rest _) (setq torn t) '(:deleted t))))
      (let ((out (cc-butler-tool-close-topic "ghost")))
        (should (string-match-p "No session named" out))
        (should-not torn)))))

(ert-deftest cc-butler-cleanup/close-topic-tool-refuses-butler-steward ()
  "close_topic refuses the butler/steward (role-rank 0/1); nothing is torn down."
  (let (torn)
    (cl-letf (((symbol-function 'cc-butler--dir-by-name) (lambda (_n) "/b/"))
              ((symbol-function 'cc-butler--role-rank) (lambda (_d) 0))
              ((symbol-function 'cc-butler--teardown-workspace)
               (lambda (&rest _) (setq torn t) '(:deleted t))))
      (let ((cc-butler--butler "/b/"))
        (let ((out (cc-butler-tool-close-topic "Butler")))
          (should (string-match-p "not a worker" out))
          (should-not torn))))))

(ert-deftest cc-butler-cleanup/close-topic-tool-refuses-unsafe-git ()
  "close_topic refuses a worker with unsafe git state; teardown is never called."
  (let (torn)
    (cl-letf (((symbol-function 'cc-butler--dir-by-name) (lambda (_n) "/w/"))
              ((symbol-function 'cc-butler--role-rank) (lambda (_d) 2))
              ((symbol-function 'cc-butler--close-topic-dir) (lambda (_d) "/w/"))
              ((symbol-function 'cc-butler--close-topic-audit)
               (lambda (_d) '(("repo" "uncommitted changes"))))
              ((symbol-function 'cc-butler--teardown-workspace)
               (lambda (&rest _) (setq torn t) '(:deleted t))))
      (let ((cc-butler--butler nil) (cc-butler--steward nil))
        (let ((out (cc-butler-tool-close-topic "w")))
          (should (string-match-p "unsafe git state" out))
          (should (string-match-p "uncommitted changes" out))
          (should-not torn))))))

(ert-deftest cc-butler-cleanup/close-topic-tool-deletes-clean-worker ()
  "A clean worker: close_topic routes through the shared teardown WITHOUT force
\(so the tail's pre-delete re-check stays live) and reports the deleted dir."
  (let (tear-args)
    (cl-letf (((symbol-function 'cc-butler--dir-by-name) (lambda (_n) "/w/"))
              ((symbol-function 'cc-butler--role-rank) (lambda (_d) 2))
              ((symbol-function 'cc-butler--close-topic-dir) (lambda (_d) "/w/topic/"))
              ((symbol-function 'cc-butler--close-topic-audit) (lambda (_d) nil))
              ((symbol-function 'cc-butler--log) (lambda (&rest _) nil))
              ((symbol-function 'cc-butler--maybe-refresh) (lambda () nil))
              ((symbol-function 'cc-butler--teardown-workspace)
               (lambda (&rest args) (setq tear-args args)
                 '(:killed ("*buf*") :deleted t :note nil))))
      (let ((cc-butler--butler nil) (cc-butler--steward nil))
        (let ((out (cc-butler-tool-close-topic "w")))
          (should (string-match-p "Deleted" out))
          (should (string-match-p "/w/topic/" out))
          ;; called as (dir topic) with NO force argument -> re-check stays on
          (should (equal tear-args '("/w/" "/w/topic/"))))))))

;;;; ---- permission gate: destructive tool kept OUT of auto-allow -----

(ert-deftest cc-butler-cleanup/nondestructive-allow-list-excludes-close-topic ()
  "The carve-out omits every destructive tool and keeps the reversible ones."
  (let ((cc-butler-destructive-tools '("close_topic")))
    (cl-letf (((symbol-function 'claude-code-ide-mcp-server-get-tool-names)
               (lambda (&optional prefix)
                 (mapcar (lambda (n) (concat (or prefix "") n))
                         '("send_to_session" "close_topic" "butler_dashboard")))))
      (let ((allowed (cc-butler--nondestructive-allowed-tools)))
        (should (member "mcp__emacs-tools__send_to_session" allowed))
        (should (member "mcp__emacs-tools__butler_dashboard" allowed))
        (should-not (member "mcp__emacs-tools__close_topic" allowed))))))

(ert-deftest cc-butler-cleanup/install-permissions-carves-out-of-auto ()
  "Installing over the default `auto' replaces it with the reversible-only list
\(so the harness prompts for the destructive tool); a custom value is untouched."
  (cl-letf (((symbol-function 'claude-code-ide-mcp-server-get-tool-names)
             (lambda (&optional prefix)
               (mapcar (lambda (n) (concat (or prefix "") n))
                       '("send_to_session" "close_topic")))))
    ;; default `auto' -> carved-out explicit list, close_topic omitted
    (let ((claude-code-ide-mcp-allowed-tools 'auto)
          (cc-butler-destructive-tools '("close_topic")))
      (cc-butler-install-tool-permissions)
      (should (listp claude-code-ide-mcp-allowed-tools))
      (should-not (member "mcp__emacs-tools__close_topic"
                          claude-code-ide-mcp-allowed-tools)))
    ;; a deliberately-customised value is left exactly as the user set it
    (let ((claude-code-ide-mcp-allowed-tools "mcp__emacs-tools__*"))
      (cc-butler-install-tool-permissions)
      (should (equal "mcp__emacs-tools__*" claude-code-ide-mcp-allowed-tools)))))

;;;; ---- statusLine retrofit: workers only ---------------------------

(ert-deftest cc-butler-cleanup/install-statusline-all-targets-workers-only ()
  "Retrofitting the statusLine installs into every eligible WORKER workspace and
NEVER the butler or steward, returning the dirs actually written."
  (let ((cc-butler--butler "/b/") (cc-butler--steward "/s/")
        (installed nil))
    (cl-letf (((symbol-function 'cc-butler--sessions)
               (lambda () (list (list :dir "/b/") (list :dir "/s/")
                                (list :dir "/w1/") (list :dir "/w2/"))))
              ((symbol-function 'cc-butler--role-rank)
               (lambda (d) (cond ((equal d "/b/") 0) ((equal d "/s/") 1) (t 2))))
              ;; stub the writer: record targets, report a fresh write for each
              ((symbol-function 'cc-butler-cleanup-install-statusline)
               (lambda (dir &optional _template) (push dir installed) dir)))
      (let ((written (cc-butler-cleanup-install-statusline-all)))
        (should (equal '("/w1/" "/w2/") written))
        (should (equal '("/w1/" "/w2/") (sort (copy-sequence installed) #'string<)))
        (should-not (member "/b/" installed))
        (should-not (member "/s/" installed))))))

(ert-deftest cc-butler-cleanup/install-statusline-all-skips-already-configured ()
  "Workers that already have a settings file (writer returns nil) are not counted
as freshly written."
  (let ((cc-butler--butler nil) (cc-butler--steward nil))
    (cl-letf (((symbol-function 'cc-butler--sessions)
               (lambda () (list (list :dir "/w1/") (list :dir "/w2/"))))
              ((symbol-function 'cc-butler--role-rank) (lambda (_d) 2))
              ((symbol-function 'cc-butler-cleanup-install-statusline)
               (lambda (dir &optional _template)
                 ;; /w1 already configured -> nil; /w2 freshly written -> path
                 (unless (equal dir "/w1/") dir))))
      (should (equal '("/w2/") (cc-butler-cleanup-install-statusline-all))))))

(provide 'cc-butler-cleanup-test)
;;; cc-butler-cleanup-test.el ends here
