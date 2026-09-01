;;; cc-butler-self-check-test.el --- tests for cc-butler-self-check.el -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jeongsoo Park
;; SPDX-License-Identifier: MIT

(require 'ert)
(require 'cl-lib)
(require 'cc-butler-self-check)

;;;; ------------------------------------------------------------------
;;;; Check 1: MCP port
;;;; ------------------------------------------------------------------

(ert-deftest cc-butler-self-check/mcp-port-fails-on-mismatch ()
  "A live session connected to a port other than the currently bound one
must fail -- the exact 2026-08-14 failure mode: a session spawned before a
rebind, silently pointed at a dead port."
  (cl-letf (((symbol-function 'cc-butler-self-check--mcp-bound-port) (lambda () 5000))
            ((symbol-function 'cc-butler-self-check--session-ports)
             (lambda () '(("/session-a/" . 5001)))))
    (let ((r (cc-butler-self-check--mcp-port)))
      (should-not (plist-get r :ok))
      (should (string-match-p "5000" (plist-get r :detail)))
      (should (string-match-p "5001" (plist-get r :detail))))))

(ert-deftest cc-butler-self-check/mcp-port-passes-when-matching ()
  "Every live session on the same port as the bound server must pass."
  (cl-letf (((symbol-function 'cc-butler-self-check--mcp-bound-port) (lambda () 5000))
            ((symbol-function 'cc-butler-self-check--session-ports)
             (lambda () '(("/session-a/" . 5000) ("/session-b/" . 5000)))))
    (let ((r (cc-butler-self-check--mcp-port)))
      (should (plist-get r :ok)))))

;;;; ------------------------------------------------------------------
;;;; Check 2: governance memory dir
;;;; ------------------------------------------------------------------

(ert-deftest cc-butler-self-check/governance-memory-dir-fails-on-mismatch ()
  "Write path and read path resolving to different directories must fail --
the 2026-07-23 incident: writer and reader disagreed about the store."
  (cl-letf (((symbol-function 'cc-butler-self-check--governance-write-dir)
             (lambda () "/tmp/write-here/"))
            ((symbol-function 'cc-butler-self-check--governance-read-dir)
             (lambda () "/tmp/read-from-here/")))
    (let ((r (cc-butler-self-check--governance-memory-dir)))
      (should-not (plist-get r :ok)))))

(ert-deftest cc-butler-self-check/governance-memory-dir-passes-when-matching ()
  "Write path and read path resolving to the same directory must pass."
  (cl-letf (((symbol-function 'cc-butler-self-check--governance-write-dir)
             (lambda () "/tmp/same-place/"))
            ((symbol-function 'cc-butler-self-check--governance-read-dir)
             (lambda () "/tmp/same-place")))
    (let ((r (cc-butler-self-check--governance-memory-dir)))
      (should (plist-get r :ok)))))

;;;; ------------------------------------------------------------------
;;;; Check 3: North Star file
;;;; ------------------------------------------------------------------

(ert-deftest cc-butler-self-check/north-star-file-fails-when-missing ()
  "A configured file that does not exist on disk must fail."
  (let ((cc-butler-north-star-file "/tmp/definitely-does-not-exist-north-star.org"))
    (should (not (file-exists-p cc-butler-north-star-file)))
    (let ((r (cc-butler-self-check--north-star-file)))
      (should-not (plist-get r :ok))
      (should (string-match-p "does not exist" (plist-get r :detail))))))

(ert-deftest cc-butler-self-check/north-star-file-fails-when-outside-store ()
  "A file that exists but lives OUTSIDE the currently effective governance
store must fail even though it exists -- the orphaned-by-a-store-move case
that an existence-only check cannot catch."
  (let* ((store-dir (file-name-as-directory (make-temp-file "gov-store" t)))
         (outside-dir (file-name-as-directory (make-temp-file "elsewhere" t)))
         (file (expand-file-name "north-star.org" outside-dir)))
    (unwind-protect
        (progn
          (with-temp-file file (insert "* goal"))
          (cl-letf (((symbol-function 'cc-butler-governance-store) (lambda () store-dir)))
            (let ((cc-butler-north-star-file file))
              (let ((r (cc-butler-self-check--north-star-file)))
                (should-not (plist-get r :ok))
                (should (string-match-p "not inside" (plist-get r :detail)))))))
      (delete-directory store-dir t)
      (delete-directory outside-dir t))))

(ert-deftest cc-butler-self-check/north-star-file-passes-inside-store ()
  "A real file inside the current governance store, with a namespaced
basename (or PR #73's check simply unavailable), must pass."
  (let* ((store-dir (file-name-as-directory (make-temp-file "gov-store" t)))
         (file (expand-file-name "north-star-fleet1.org" store-dir)))
    (unwind-protect
        (progn
          (with-temp-file file (insert "* goal"))
          (cl-letf (((symbol-function 'cc-butler-governance-store) (lambda () store-dir)))
            (let ((cc-butler-north-star-file file))
              (let ((r (cc-butler-self-check--north-star-file)))
                (should (plist-get r :ok))))))
      (delete-directory store-dir t))))

;;;; ------------------------------------------------------------------
;;;; Check 4: module load path (partial implementation)
;;;; ------------------------------------------------------------------

(ert-deftest cc-butler-self-check/module-load-path-fails-when-unmerged ()
  "Once PR #74 lands, an unmerged running commit must fail."
  (cl-letf (((symbol-function 'cc-butler--commit-merged-p) (lambda (&rest _) 'unmerged)))
    (let ((r (cc-butler-self-check--module-load-path)))
      (should-not (plist-get r :ok))
      (should (string-match-p "UNMERGED" (plist-get r :detail))))))

(ert-deftest cc-butler-self-check/module-load-path-passes-when-merged ()
  "Once PR #74 lands, a merged running commit must pass."
  (cl-letf (((symbol-function 'cc-butler--commit-merged-p) (lambda (&rest _) 'merged)))
    (let ((r (cc-butler-self-check--module-load-path)))
      (should (plist-get r :ok))
      (should (string-match-p "reachable from origin/main" (plist-get r :detail))))))

(ert-deftest cc-butler-self-check/module-load-path-calls-commit-merged-p-with-dir-and-sha ()
  "THE BUG: this call site used to pass only `cc-butler-source-dir', one
argument, while `cc-butler--commit-merged-p' requires DIR and SHA -- a
`wrong-number-of-arguments' error every time the periodic self-check
timer fired. This is the guard-invocation check: the real runtime-source
vars PR #74 populates, not just \"does it eventually return a verdict\"."
  (let ((cc-butler--runtime-source-dir "/some/checkout/")
        (cc-butler--runtime-commit-sha "deadbeef")
        captured)
    (cl-letf (((symbol-function 'cc-butler--commit-merged-p)
               (lambda (dir sha) (setq captured (list dir sha)) 'merged)))
      (cc-butler-self-check--module-load-path))
    (should (equal captured '("/some/checkout/" "deadbeef")))))

(ert-deftest cc-butler-self-check/module-load-path-not-checked-when-dependency-missing ()
  "When PR #74's `cc-butler--commit-merged-p' is not loaded (some fleets
run without it), the check must still report :ok t, but its :detail must
say explicitly that it was NOT checked and why -- never a bare pass that
reads identically to a real one. Forces the unbound state directly
(`fmakunbound', restored after) rather than assuming ambient fleet state
-- PR #74 and this module are both merged together on THIS fleet's main,
so `fboundp' is normally true here."
  (let ((was-bound (fboundp 'cc-butler--commit-merged-p))
        (orig (and (fboundp 'cc-butler--commit-merged-p)
                   (symbol-function 'cc-butler--commit-merged-p))))
    (unwind-protect
        (progn
          (fmakunbound 'cc-butler--commit-merged-p)
          (let ((r (cc-butler-self-check--module-load-path)))
            (should (plist-get r :ok))
            (should (string-match-p "not verified" (plist-get r :detail)))
            (should (string-match-p "PR #74\\|cc-butler--commit-merged-p" (plist-get r :detail)))
            ;; The two "pass" detail strings (real pass vs. not-checked) must not
            ;; read identically -- distinguish "reachable from origin/main" (real
            ;; pass) from "not verified" (not checked at all).
            (should-not (string-match-p "reachable from origin/main" (plist-get r :detail)))))
      (when was-bound (fset 'cc-butler--commit-merged-p orig)))))

;;;; ------------------------------------------------------------------
;;;; Check 5: persisted vs. live
;;;; ------------------------------------------------------------------

(ert-deftest cc-butler-self-check/persisted-vs-live-fails-on-live-patch ()
  "A tracked variable that was `setq''d/`let'-bound live (not through
Customize) reads as `changed', not `saved'/`standard' -- must fail."
  (let ((cc-butler-self-check-tracked-variables '(cc-butler-north-star-file))
        (cc-butler-north-star-file "/tmp/live-patched-value.org"))
    (let ((r (cc-butler-self-check--persisted-vs-live)))
      (should-not (plist-get r :ok))
      (should (string-match-p "cc-butler-north-star-file" (plist-get r :detail))))))

(ert-deftest cc-butler-self-check/persisted-vs-live-passes-when-saved ()
  "A tracked variable whose Customize state is `saved' (or `standard') must
pass -- this is the check answering \"is this correct AFTER a restart\"."
  (let ((cc-butler-self-check-tracked-variables '(cc-butler-north-star-file)))
    (cl-letf (((symbol-function 'custom-variable-state) (lambda (&rest _) 'saved)))
      (let ((r (cc-butler-self-check--persisted-vs-live)))
        (should (plist-get r :ok))))))

;;;; ------------------------------------------------------------------
;;;; Check 6: vault path
;;;; ------------------------------------------------------------------

(defmacro cc-butler-self-check-test--with-getenv-stub (value &rest body)
  "Run BODY with `(getenv \"WARMBLE_JUMBLE_PATH\")' stubbed to return VALUE;
every other variable falls through to the real `getenv'."
  (declare (indent 1))
  `(let ((cc-butler-self-check-test--real-getenv (symbol-function 'getenv)))
     (cl-letf (((symbol-function 'getenv)
                (lambda (var)
                  (if (equal var "WARMBLE_JUMBLE_PATH")
                      ,value
                    (funcall cc-butler-self-check-test--real-getenv var)))))
       ,@body)))

(ert-deftest cc-butler-self-check/vault-path-fails-on-mismatch ()
  "Two different, both-real absolute paths must fail."
  (cc-butler-self-check-test--with-getenv-stub "/tmp/stale-vault-clone"
    (cl-letf (((symbol-function 'cc-butler-governance-store)
               (lambda () "/tmp/current-vault-clone/")))
      (let ((r (cc-butler-self-check--vault-path)))
        (should-not (plist-get r :ok))
        (should (string-match-p "!=" (plist-get r :detail)))))))

(ert-deftest cc-butler-self-check/vault-path-passes-when-matching ()
  "The same absolute path (trailing slash aside) must pass."
  (cc-butler-self-check-test--with-getenv-stub "/tmp/same-vault"
    (cl-letf (((symbol-function 'cc-butler-governance-store)
               (lambda () "/tmp/same-vault/")))
      (let ((r (cc-butler-self-check--vault-path)))
        (should (plist-get r :ok))))))

(ert-deftest cc-butler-self-check/vault-path-unset-is-its-own-state ()
  "An UNSET env var is its own distinct, reportable state -- neither a
silent pass masquerading as a match, nor a failure.  Collapsing it into
either of the other two would itself be an existence-only check hiding
inside a consistency check."
  (cc-butler-self-check-test--with-getenv-stub nil
    (let ((r (cc-butler-self-check--vault-path)))
      (should (plist-get r :ok))
      (should (string-match-p "not set" (plist-get r :detail)))
      ;; Must not read like a real match.
      (should-not (string-match-p "matches" (plist-get r :detail))))))

;;;; ------------------------------------------------------------------
;;;; Transition detection: escalate only on ok<->fail flips, both ways
;;;; ------------------------------------------------------------------

(defvar cc-butler-self-check-test--escalations nil)
(defvar cc-butler-self-check-test--logs nil)

(defmacro cc-butler-self-check-test--with-stubs (&rest body)
  "Run BODY with `cc-butler-tool-escalate-to-butler' / `cc-butler-tool-log'
stubbed to record calls instead of touching any real butler state, and
`cc-butler-self-check--previous' reset -- matching this repo's existing
`cl-letf'-on-`symbol-function' stubbing style (see
`cc-butler-north-star-test.el')."
  (declare (indent 0))
  `(let ((cc-butler-self-check-test--escalations nil)
         (cc-butler-self-check-test--logs nil)
         (cc-butler-self-check--previous nil))
     (cl-letf (((symbol-function 'cc-butler-tool-escalate-to-butler)
                (lambda (summary &optional needs options kind)
                  (push (list :summary summary :needs needs :options options :kind kind)
                        cc-butler-self-check-test--escalations)))
               ((symbol-function 'cc-butler-tool-log)
                (lambda (entry &optional kind)
                  (push (list :entry entry :kind kind) cc-butler-self-check-test--logs))))
       ,@body)))

(defun cc-butler-self-check-test--fake-results (ok)
  "A single-check result set, OK controlling the one check's :ok."
  (list (cons "fake-check" (list :ok ok :detail (if ok "all good" "it broke")))))

(ert-deftest cc-butler-self-check/report-logs-every-tick-regardless-of-result ()
  "The quiet per-tick log must fire every time, whether the tick is clean
or failing -- the durable timeline, whether or not anyone is watching."
  (cc-butler-self-check-test--with-stubs
    (cc-butler-self-check--report (cc-butler-self-check-test--fake-results t))
    (should (= 1 (length cc-butler-self-check-test--logs)))
    (cc-butler-self-check--report (cc-butler-self-check-test--fake-results nil))
    (should (= 2 (length cc-butler-self-check-test--logs)))))

(ert-deftest cc-butler-self-check/report-first-observation-does-not-escalate ()
  "With no prior state, the first tick only establishes a baseline -- it
must not itself be treated as a transition."
  (cc-butler-self-check-test--with-stubs
    (cc-butler-self-check--report (cc-butler-self-check-test--fake-results nil))
    (should (null cc-butler-self-check-test--escalations))))

(ert-deftest cc-butler-self-check/report-ok-to-fail-escalates-once-as-notification ()
  "tick 1 ok -> tick 2 fail must fire exactly one escalate call, kind
\"notification\" (never \"decision\" -- a broken check is a fact to read,
not a choice to make)."
  (cc-butler-self-check-test--with-stubs
    (cc-butler-self-check--report (cc-butler-self-check-test--fake-results t))
    (cc-butler-self-check--report (cc-butler-self-check-test--fake-results nil))
    (should (= 1 (length cc-butler-self-check-test--escalations)))
    (should (equal "notification" (plist-get (car cc-butler-self-check-test--escalations) :kind)))))

(ert-deftest cc-butler-self-check/report-fail-to-fail-does-not-re-escalate ()
  "tick 2 fail -> tick 3 fail (still failing, same check) must fire ZERO
additional escalate calls -- only the quiet per-tick log, not a repeat
notification for an unchanged failure."
  (cc-butler-self-check-test--with-stubs
    (cc-butler-self-check--report (cc-butler-self-check-test--fake-results t))
    (cc-butler-self-check--report (cc-butler-self-check-test--fake-results nil))
    (should (= 1 (length cc-butler-self-check-test--escalations)))
    (cc-butler-self-check--report (cc-butler-self-check-test--fake-results nil))
    (should (= 1 (length cc-butler-self-check-test--escalations)))))

(ert-deftest cc-butler-self-check/report-fail-to-ok-escalates-recovery ()
  "tick 3 fail -> tick 4 ok must fire exactly one MORE escalate call (the
recovery notification) -- a human must not carry a stale failure
notification forever once the check actually recovers."
  (cc-butler-self-check-test--with-stubs
    (cc-butler-self-check--report (cc-butler-self-check-test--fake-results t))
    (cc-butler-self-check--report (cc-butler-self-check-test--fake-results nil))
    (cc-butler-self-check--report (cc-butler-self-check-test--fake-results nil))
    (should (= 1 (length cc-butler-self-check-test--escalations)))
    (cc-butler-self-check--report (cc-butler-self-check-test--fake-results t))
    (should (= 2 (length cc-butler-self-check-test--escalations)))
    (should (equal "notification" (plist-get (car cc-butler-self-check-test--escalations) :kind)))
    (should (string-match-p "RECOVERED" (plist-get (car cc-butler-self-check-test--escalations) :summary)))))

(provide 'cc-butler-self-check-test)
;;; cc-butler-self-check-test.el ends here
