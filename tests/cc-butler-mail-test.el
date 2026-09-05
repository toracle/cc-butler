;;; cc-butler-mail-test.el --- BDD acceptance tests for the message channel  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jeongsoo Park
;; SPDX-License-Identifier: MIT

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

(ert-deftest cc-butler-mail/check-inbox-drain-as-static-identity ()
  "Given messages waiting for a KNOWN agent name, When drained via
`cc-butler--check-inbox-drain-as' (no MCP caller context, as a
UserPromptSubmit hook would call it), Then the count and formatted text
match, and an empty inbox yields (0 . nil)."
  (cc-butler-mail-test--with-mock
    (should (equal '(0 . nil) (cc-butler--check-inbox-drain-as "steward")))
    (cc-butler--ch-deliver "steward" (list :kind 'note :from "worker-a" :body "done: PR #42"))
    (cc-butler--ch-deliver "steward" (list :kind 'note :from "worker-b" :body "blocked"))
    (pcase-let ((`(,n . ,formatted) (cc-butler--check-inbox-drain-as "steward")))
      (should (= 2 n))
      (should (string-match-p "worker-a" formatted))
      (should (string-match-p "worker-b" formatted)))
    ;; drained — a second call sees nothing left
    (should (equal '(0 . nil) (cc-butler--check-inbox-drain-as "steward")))))

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

;;;; ---- private permissions on newly-created inbox files -------------
;;
;; This maildir tree holds real PII (message bodies, tenant email
;; addresses) — see `cc-butler--state-ensure-dir'/`cc-butler--state-write-file'
;; in cc-butler-session.el.  These exercise the REAL call sites end-to-end
;; (not the shared helper directly), so a future rewiring away from the
;; helper would be caught here.

(ert-deftest cc-butler-mail/file-adapter-creates-restricted-dirs-and-files ()
  "Given a fresh `cc-butler-mail-dir', When a message is delivered through the
real file adapter, Then every freshly-created inbox subdirectory (tmp/, new/,
archive/) is mode 700 and the delivered .eld file is mode 600."
  (cc-butler-mail-test--with-file
    (let* ((id (cc-butler--ch-deliver "worker-a" (list :kind 'note :from "x" :body "hi")))
           (in (cc-butler--mail-inbox "worker-a")))
      (dolist (sub '("tmp/" "new/" "archive/"))
        (should (= #o700 (file-modes (expand-file-name sub in)))))
      (should (= #o600 (file-modes (expand-file-name (format "new/%s.eld" id) in)))))))

(ert-deftest cc-butler-mail/journal-dir-and-file-are-created-restricted ()
  "Given a fresh mail-dir, When the channel journal writes its first entry,
Then <mail-dir>/log/ is mode 700 and today's journal file is mode 600."
  (cc-butler-mail-test--with-file
    (cl-letf (((symbol-function 'cc-butler--display-name) (lambda (d) d)))
      (cc-butler-mail-journal-send "steward" "worker-a" "hi"))
    (should (= #o700 (file-modes (cc-butler--mail-log-dir))))
    (should (= #o600 (file-modes (expand-file-name (format-time-string "%Y-%m-%d.eld")
                                                   (cc-butler--mail-log-dir)))))))

(ert-deftest cc-butler-mail/rename-file-preserves-mode-new-to-archive ()
  "The file this fix creates at 600 is later moved new/ -> archive/ by
`cc-butler--mail-file-drain' via `rename-file', which preserves whatever
mode the file had at creation — true only because creation now forces 600
in the first place.  Guards that invariant against a future change to the
creation site silently widening it with no test noticing."
  (cc-butler-mail-test--with-file
    (let* ((id (cc-butler--ch-deliver "worker-a" (list :kind 'note :from "x" :body "hi")))
           (in (cc-butler--mail-inbox "worker-a")))
      (cc-butler--ch-drain "worker-a")     ; the real move: new/ -> archive/
      (should (= #o600 (file-modes (expand-file-name (format "archive/%s.eld" id) in)))))))

;;;; ---- unified channel journal (audit log over BOTH channels) -------
;;
;; Two channels, two consumption patterns: "messenger" (send_to_session —
;; immediate, typed into the terminal, consumed on the spot) and "email"
;; (maildir — pull-based, held until drained).  BOTH are audit-logged in ONE
;; append-only journal under <mail-dir>/log/YYYY-MM-DD.eld, one printed plist
;; per line.  The journal is an audit layer only: it never touches any
;; maildir, and a journal failure must never break a delivery or a send.

(defun cc-butler-mail-test--journal-entries ()
  "Read back every entry in today's journal file (oldest first)."
  (let ((file (expand-file-name (format-time-string "%Y-%m-%d.eld")
                                (expand-file-name "log/" cc-butler-mail-dir)))
        entries)
    (when (file-exists-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (while (progn (skip-chars-forward " \t\n") (not (eobp)))
          (push (read (current-buffer)) entries))))
    (nreverse entries)))

(ert-deftest cc-butler-mail/journal-terminal-send-without-touching-mail ()
  "Given a terminal (messenger) send journaled via `cc-butler-mail-journal-send',
Then today's journal gains one parseable entry (:channel terminal, :kind send,
from/to/body), and the receiver's maildir stays EMPTY — new/ and archive/
both — so a drain returns nothing (audit records and real mail never mix)."
  (cc-butler-mail-test--with-file
    (cl-letf (((symbol-function 'cc-butler--display-name)
               (lambda (d) (if (equal d "/steward/") "steward" d))))
      (cc-butler-mail-journal-send "/steward/" "worker-a" "please rebase")
      (let ((entry (car (cc-butler-mail-test--journal-entries))))
        (should entry)
        (should (eq 'terminal (plist-get entry :channel)))
        (should (eq 'send (plist-get entry :kind)))
        (should (equal "steward" (plist-get entry :from)))
        (should (equal "worker-a" (plist-get entry :to)))
        (should (equal "please rebase" (plist-get entry :body)))
        (should (plist-get entry :id))
        (should (plist-get entry :time)))
      ;; the journal is not mail: nothing lands in the receiver's maildir
      (let ((in (cc-butler--mail-inbox "worker-a")))
        (dolist (sub '("new/" "archive/"))
          (let ((d (expand-file-name sub in)))
            (should (null (and (file-directory-p d)
                               (directory-files d nil "\\.eld\\'")))))))
      (should (null (cc-butler--ch-drain "worker-a"))))))

(ert-deftest cc-butler-mail/journal-mail-delivery-same-id ()
  "Given a maildir (email) delivery, Then the inbox file lands in new/ AND the
journal gains an entry with the SAME id (:channel mail, the message's own kind),
so every routed delivery is traceable to its inbox file."
  (cc-butler-mail-test--with-file
    (let* ((id (cc-butler--ch-deliver "bob" (list :kind 'note :from "alice" :body "hi")))
           (new (expand-file-name (format "new/%s.eld" id) (cc-butler--mail-inbox "bob")))
           (entry (car (cc-butler-mail-test--journal-entries))))
      (should (file-exists-p new))
      (should entry)
      (should (eq 'mail (plist-get entry :channel)))
      (should (eq 'note (plist-get entry :kind)))
      (should (equal id (plist-get entry :id)))
      (should (equal "alice" (plist-get entry :from)))
      (should (equal "bob" (plist-get entry :to)))
      (should (equal "hi" (plist-get entry :body))))))

(ert-deftest cc-butler-mail/journal-appends-to-same-day-file ()
  "Given two consecutive journal writes, Then today's file holds BOTH entries
in order (append semantics — the second never clobbers the first)."
  (cc-butler-mail-test--with-file
    (cl-letf (((symbol-function 'cc-butler--display-name) (lambda (d) d)))
      (cc-butler-mail-journal-send "steward" "worker-a" "first")
      (cc-butler-mail-journal-send "steward" "worker-a" "second")
      (let ((entries (cc-butler-mail-test--journal-entries)))
        (should (= 2 (length entries)))
        (should (equal "first" (plist-get (nth 0 entries) :body)))
        (should (equal "second" (plist-get (nth 1 entries) :body)))))))

(ert-deftest cc-butler-mail/journal-failure-never-breaks-delivery ()
  "Given a journal that CANNOT be written (its dir path is blocked by a plain
file), When a message is delivered, Then delivery still succeeds and returns
the id — logging is subordinate to delivery."
  (cc-butler-mail-test--with-file
    (let ((blocker (expand-file-name "blocker" cc-butler-mail-dir)))
      (with-temp-file blocker (insert "x"))   ; a FILE where the log dir must go
      (cl-letf (((symbol-function 'cc-butler--mail-log-dir)
                 (lambda () (expand-file-name "log/" blocker))))
        (let ((id (cc-butler--ch-deliver "bob" (list :kind 'note :from "a" :body "hi"))))
          (should id)
          (let ((got (cc-butler--ch-drain "bob")))
            (should (= 1 (length got)))
            (should (equal "hi" (plist-get (car got) :body)))
            (should (equal id (plist-get (car got) :id)))))))))

(ert-deftest cc-butler-mail/transport-rollback ()
  "The transport flag switches report_to_steward between the legacy in-memory
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
        (cc-butler-tool-report-to-steward "hello")
        (should (cc-butler--ch-drain "steward"))
        (should (null cc-butler--inbox)))
      ;; in-memory (rollback): report goes to the legacy queue; channel untouched
      (let ((cc-butler-message-transport 'in-memory))
        (cc-butler-tool-report-to-steward "hello2")
        (should cc-butler--inbox)
        (should (null (cc-butler--ch-drain "steward")))))))

(ert-deftest cc-butler-mail/report-to-steward-logs-under-maildir-transport ()
  "Given maildir transport (where `cc-butler--inbox-push' — and its
auto-log advice — is never called), Then `report_to_steward' still logs
directly, so \"report -> logged\" holds under either transport, not just
the in-memory default it used to silently depend on."
  (require 'cc-butler-orchestrator)
  (let ((cc-butler-message-transport 'maildir)
        (cc-butler--channel (cc-butler-mail-test--mock-channel))
        (logged nil))
    (cl-letf (((symbol-function 'cc-butler--caller-dir) (lambda () "/worker/"))
              ((symbol-function 'cc-butler--ops-dir) (lambda () "/steward/"))
              ((symbol-function 'cc-butler--display-name)
               (lambda (d) (pcase d ("/steward/" "steward") ("/worker/" "worker-a") (_ d))))
              ((symbol-function 'cc-butler--who-dir) (lambda (_d) "worker-a"))
              ((symbol-function 'cc-butler--maybe-refresh) (lambda () nil))
              ((symbol-function 'cc-butler-docs--auto-log)
               (lambda (dir body) (push (cons dir body) logged))))
      (should (fboundp 'cc-butler-docs--auto-log)) ; the report path only logs when this is bound
      (cc-butler-tool-report-to-steward "hello")
      (should (= 1 (length logged)))
      (should (equal "/worker/" (car (car logged))))
      (should (string-match-p "hello" (cdr (car logged)))))))

(ert-deftest cc-butler-mail/dismiss-mcp-all-targets ()
  "cc-butler-dismiss-mcp-all sends ESC to WORKER sessions, skipping the butler
(rank 0) and steward (rank 1).  Faithful: assert which dirs actually got ESC."
  (let ((escaped '()))
    (cl-letf (((symbol-function 'cc-butler--sessions)
               (lambda () '((:dir "butler") (:dir "steward") (:dir "worker-a") (:dir "worker-b"))))
              ((symbol-function 'cc-butler--send-escape)
               (lambda (dir) (push dir escaped) t))
              ((symbol-function 'cc-butler--role-rank)
               (lambda (dir) (cond ((equal dir "butler") 0) ((equal dir "steward") 1) (t 9)))))
      (cc-butler-dismiss-mcp-all)
      (should (equal (sort (copy-sequence escaped) #'string<) '("worker-a" "worker-b"))))))

(ert-deftest cc-butler-mail/rearm-is-disabled ()
  "Re-arm via /mcp is guarded off after the 2026-07-04 incident: cc-butler--rearm
signals a user-error rather than typing /mcp reconnect (which parks the session).
This neutralizes every caller (rearm-session, the MCP tool, any bulk re-arm)."
  (should-error (cc-butler--rearm "worker-a") :type 'user-error))

(provide 'cc-butler-mail-test)
;;; cc-butler-mail-test.el ends here
