;;; cc-butler-mail-test.el --- BDD acceptance tests for the message channel  -*- lexical-binding: t; -*-

;; Acceptance oracle for `cc-butler-mail'.  The routing scenarios run against an
;; in-memory MOCK channel (no real Emacs sessions or files needed — ports &
;; adapters), and the transport-level guarantees (atomicity) plus a delivery +
;; return-path smoke run against the real FILE adapter, proving the same
;; behaviour holds end to end.
;;
;;   emacs -Q --batch -L . -l ert -l cc-butler-mail-test.el \
;;     -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'cc-butler-mail)

;;;; ---- mock channel ------------------------------------------------

(defvar cc-butler-mail-test--inboxes nil "Alist agent -> messages (newest first).")
(defvar cc-butler-mail-test--pokes nil   "List of poked agents (newest first).")

(defun cc-butler-mail-test--mock-channel ()
  "An in-memory `cc-butler-channel' recording deliveries and pokes."
  (cc-butler-make-channel
   :deliver (lambda (to msg)
              (let ((id (or (plist-get msg :id) (cc-butler--mail-id))))
                (push (plist-put msg :id id)
                      (alist-get to cc-butler-mail-test--inboxes nil nil #'equal))
                id))
   :drain (lambda (agent)
            (prog1 (reverse (alist-get agent cc-butler-mail-test--inboxes nil nil #'equal))
              (setf (alist-get agent cc-butler-mail-test--inboxes nil t #'equal) nil)))
   :poke (lambda (agent) (push agent cc-butler-mail-test--pokes))))

(defmacro cc-butler-mail-test--with-mock (&rest body)
  "Run BODY with a fresh mock channel and a fixed butler agent id."
  (declare (indent 0))
  `(let ((cc-butler-mail-test--inboxes nil)
         (cc-butler-mail-test--pokes nil)
         (cc-butler--channel (cc-butler-mail-test--mock-channel)))
     (cl-letf (((symbol-function 'cc-butler--mail-butler-agent) (lambda () "butler")))
       ,@body)))

(defun cc-butler-mail-test--only (msgs)
  (should (= 1 (length msgs))) (car msgs))

;;;; ---- routing scenarios (mock channel) ----------------------------

(ert-deftest cc-butler-mail/delivery ()
  "Given a message delivered to an agent, When that agent drains, Then it is received."
  (cc-butler-mail-test--with-mock
    (cc-butler--ch-deliver "worker-a" (list :kind 'note :from "steward" :body "hi"))
    (let ((m (cc-butler-mail-test--only (cc-butler--ch-drain "worker-a"))))
      (should (equal "hi" (plist-get m :body)))
      (should (equal "steward" (plist-get m :from))))
    ;; and draining again yields nothing (messages were consumed)
    (should (null (cc-butler--ch-drain "worker-a")))))

(ert-deftest cc-butler-mail/return-path ()
  "Given the butler asks a worker (reply-to=butler), When the worker replies,
Then the reply lands in the BUTLER's inbox (not the steward's)."
  (cc-butler-mail-test--with-mock
    (let ((id (cc-butler--route-ask "butler" "worker-a" "which auth?")))
      ;; the worker sees the ask with a reply handle back to the butler
      (let* ((ask (cc-butler-mail-test--only (cc-butler--ch-drain "worker-a")))
             (handle (cc-butler--mail-reply-handle ask)))
        (should (eq 'ask (plist-get ask :kind)))
        (should (equal "butler" (plist-get ask :reply-to)))
        (should (equal (format "butler#%s" id) handle))
        ;; the worker replies via the handle
        (cc-butler--route-reply "worker-a" handle "use OAuth"))
      ;; the reply is in the BUTLER's inbox, correlated to the query...
      (let ((r (cc-butler-mail-test--only (cc-butler--ch-drain "butler"))))
        (should (equal "use OAuth" (plist-get r :body)))
        (should (equal id (plist-get r :in-reply-to)))
        (should (equal "worker-a" (plist-get r :from))))
      ;; ...and NOT in the steward's.
      (should (null (cc-butler--ch-drain "steward"))))))

(ert-deftest cc-butler-mail/default-routing-to-steward ()
  "Given a worker's routine report, Then it routes to the steward, not the butler."
  (cc-butler-mail-test--with-mock
    (cc-butler--route-report "worker-a" "done: PR #42" "steward")
    (should (equal "done: PR #42"
                   (plist-get (cc-butler-mail-test--only (cc-butler--ch-drain "steward")) :body)))
    (should (null (cc-butler--ch-drain "butler")))))

(ert-deftest cc-butler-mail/no-input-box-pollution ()
  "Given an agent message, Then the body travels in the inbox and the poke is a
signal only (never the body); and the butler is never poked."
  (cc-butler-mail-test--with-mock
    ;; ask a worker: worker is poked, body is in the inbox not in the poke
    (cc-butler--route-ask "butler" "worker-a" "secret question")
    (should (member "worker-a" cc-butler-mail-test--pokes))
    (should (equal "secret question"
                   (plist-get (car (cc-butler--ch-drain "worker-a")) :body)))
    ;; the poke text is a fixed signal with no body interpolation
    (should-not (string-match-p "secret question" cc-butler-mail-poke-signal))
    ;; a reply whose recipient is the butler must NOT poke the butler
    (setq cc-butler-mail-test--pokes nil)
    (cc-butler--route-reply "worker-a" "butler#abc" "answer")
    (should-not (member "butler" cc-butler-mail-test--pokes))))

;;;; ---- transport guarantees (file adapter) -------------------------

(defmacro cc-butler-mail-test--with-file (&rest body)
  "Run BODY over the real file adapter in a throwaway `cc-butler-mail-dir'."
  (declare (indent 0))
  `(let* ((cc-butler-mail-dir (make-temp-file "cc-butler-mail-test" t))
          (cc-butler--channel nil))          ; nil => file adapter
     (unwind-protect
         (cl-letf (((symbol-function 'cc-butler--mail-butler-agent) (lambda () "butler"))
                   ;; no real sessions in a test => poke is a harmless no-op
                   ((symbol-function 'cc-butler--dir-by-name) (lambda (_n) nil)))
           ,@body)
       (delete-directory cc-butler-mail-dir t))))

(ert-deftest cc-butler-mail/file-atomicity ()
  "Given a half-written message left in tmp/, When an agent drains, Then it is
never read (only complete, renamed messages appear in new/)."
  (cc-butler-mail-test--with-file
    ;; a complete message via the atomic deliver path
    (cc-butler--ch-deliver "worker-a" (list :kind 'note :from "x" :body "complete"))
    ;; a half-written file dropped straight into tmp/ (never renamed into new/)
    (let ((tmp (expand-file-name "tmp/partial.eld" (cc-butler--mail-inbox "worker-a"))))
      (with-temp-file tmp (insert "(:kind note :body \"HALF")) ; truncated garbage
      (let ((got (cc-butler--ch-drain "worker-a")))
        (should (= 1 (length got)))
        (should (equal "complete" (plist-get (car got) :body)))
        ;; the partial file is untouched in tmp/ (not consumed by the drain)
        (should (file-exists-p tmp))))))

(ert-deftest cc-butler-mail/file-return-path-e2e ()
  "The return-path scenario, unchanged, over the real file adapter."
  (cc-butler-mail-test--with-file
    (let ((id (cc-butler--route-ask "butler" "worker-a" "q?")))
      (let* ((ask (car (cc-butler--ch-drain "worker-a")))
             (handle (cc-butler--mail-reply-handle ask)))
        (cc-butler--route-reply "worker-a" handle "a!"))
      (let ((r (car (cc-butler--ch-drain "butler"))))
        (should (equal "a!" (plist-get r :body)))
        (should (equal id (plist-get r :in-reply-to))))
      (should (null (cc-butler--ch-drain "steward"))))))

;;;; ---- B: up-direction transport (report/escalate over the durable inbox) ----

(defmacro cc-butler-mail-test--with-up (&rest body)
  "Mock channel + fixed agent identities for up-direction routing tests."
  (declare (indent 0))
  `(let ((cc-butler-mail-test--inboxes nil)
         (cc-butler-mail-test--pokes nil)
         (cc-butler--channel (cc-butler-mail-test--mock-channel)))
     (cl-letf (((symbol-function 'cc-butler--mail-butler-agent) (lambda () "butler"))
               ((symbol-function 'cc-butler--ops-dir) (lambda () "/steward/"))
               ((symbol-function 'cc-butler--display-name)
                (lambda (d) (pcase d ("/steward/" "steward") ("/worker/" "worker-a")
                              ("/butler/" "butler") (_ d)))))
       ,@body)))

(ert-deftest cc-butler-mail/up-report-to-steward ()
  "Given a worker report over maildir, Then it lands in the steward's inbox
(not the butler's), and nothing is typed anywhere (pull-only)."
  (cc-butler-mail-test--with-up
    (cc-butler-mail-up-report "/worker/" "PR #42 done")
    (let ((m (cc-butler-mail-test--only (cc-butler--ch-drain "steward"))))
      (should (eq 'report (plist-get m :kind)))
      (should (equal "worker-a" (plist-get m :from)))
      (should (equal "PR #42 done" (plist-get m :body))))
    (should (null (cc-butler--ch-drain "butler")))
    (should (null cc-butler-mail-test--pokes))))

(ert-deftest cc-butler-mail/up-escalate-to-butler ()
  "Given an escalation over maildir, Then it lands in the butler's inbox."
  (cc-butler-mail-test--with-up
    (cc-butler-mail-up-decision "/steward/" "use Stripe or Paddle?" "pick one")
    (let ((m (cc-butler-mail-test--only (cc-butler--ch-drain "butler"))))
      (should (eq 'decision (plist-get m :kind)))
      (should (equal "steward" (plist-get m :from)))
      (should (equal "use Stripe or Paddle?" (plist-get m :summary)))
      (should (equal "pick one" (plist-get m :needs))))
    (should (null cc-butler-mail-test--pokes))))

(ert-deftest cc-butler-mail/file-audit-trail ()
  "Given a delivered message, When it is drained, Then it is moved to archive/
(the audit trail) — never deleted."
  (cc-butler-mail-test--with-file
    (cc-butler--ch-deliver "steward" (list :kind 'report :from "w" :body "x"))
    (cc-butler--ch-drain "steward")
    (let* ((in (cc-butler--mail-inbox "steward"))
           (archived (directory-files (expand-file-name "archive/" in) nil "\\.eld\\'"))
           (remaining (directory-files (expand-file-name "new/" in) nil "\\.eld\\'")))
      (should (= 1 (length archived)))
      (should (null remaining)))))

(ert-deftest cc-butler-mail/transport-rollback ()
  "The transport flag switches report_to_butler between the legacy in-memory
queue and the durable maildir inbox — proving rollback."
  (require 'cc-butler-orchestrator)
  (let ((cc-butler-mail-test--inboxes nil)
        (cc-butler-mail-test--pokes nil)
        (cc-butler--channel (cc-butler-mail-test--mock-channel))
        (cc-butler--inbox nil))
    (cl-letf (((symbol-function 'cc-butler--caller-dir) (lambda () "/worker/"))
              ((symbol-function 'cc-butler--mail-butler-agent) (lambda () "butler"))
              ((symbol-function 'cc-butler--ops-dir) (lambda () "/steward/"))
              ((symbol-function 'cc-butler--display-name)
               (lambda (d) (pcase d ("/steward/" "steward") ("/worker/" "worker-a") (_ d))))
              ((symbol-function 'cc-butler--who-dir) (lambda (_d) "worker-a"))
              ((symbol-function 'cc-butler--session-id) (lambda (_d) "id"))
              ((symbol-function 'cc-butler--maybe-refresh) (lambda () nil))
              ((symbol-function 'cc-butler--log) (lambda (&rest _) nil)))
      ;; maildir: report goes to the channel (steward inbox); legacy queue empty
      (let ((cc-butler-message-transport 'maildir))
        (cc-butler-tool-report-to-butler "hello")
        (should (cc-butler--ch-drain "steward"))
        (should (null cc-butler--inbox)))
      ;; in-memory (rollback): report goes to the legacy queue; channel untouched
      (let ((cc-butler-message-transport 'in-memory))
        (cc-butler-tool-report-to-butler "hello2")
        (should cc-butler--inbox)
        (should (null (cc-butler--ch-drain "steward")))))))

(provide 'cc-butler-mail-test)
;;; cc-butler-mail-test.el ends here
