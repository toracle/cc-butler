;;; cc-butler-docs-test.el --- tests for the butler self-document repository  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jeongsoo Park
;; SPDX-License-Identifier: MIT

;; Run alone:
;;   emacs -Q --batch -L . -l ert -l tests/cc-butler-docs-test.el \
;;         -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'cl-lib)
(require 'cc-butler)

;;;; ------------------------------------------------------------------
;;;; The dashboard names the source it was rendered from
;;;; ------------------------------------------------------------------
;;
;; Same motivation as `runtime_source' itself (see cc-butler-reload-test.el):
;; whoever reads the dashboard cannot see the filesystem the daemon is
;; actually running from, and the dashboard is exactly the document a human
;; is most likely to be looking at when something looks off.

(ert-deftest cc-butler-docs/dashboard-names-the-running-source ()
  (cl-letf (((symbol-function 'cc-butler-runtime-source-oneline)
             (lambda () "deadbee fix the thing — ⚠ UNMERGED"))
            ((symbol-function 'cc-butler--sessions) (lambda () nil)))
    (let ((out (cc-butler-docs--render-dashboard)))
      (should (string-match-p "Source: deadbee fix the thing — ⚠ UNMERGED" out)))))

(ert-deftest cc-butler-docs/dashboard-omits-source-line-when-not-determinable ()
  "Nil means \"cannot determine\" (see `cc-butler-runtime-source-oneline').
The dashboard must not print a blank or misleading \"Source:\" line for it —
better silence than a line that looks like it means something."
  (cl-letf (((symbol-function 'cc-butler-runtime-source-oneline) (lambda () nil))
            ((symbol-function 'cc-butler--sessions) (lambda () nil)))
    (let ((out (cc-butler-docs--render-dashboard)))
      (should-not (string-match-p "Source:" out)))))

;;;; ------------------------------------------------------------------
;;;; Dashboard refresh must not clobber offline sessions (cc-butler#5)
;;;; ------------------------------------------------------------------

(ert-deftest cc-butler-docs/dashboard-keeps-offline-sessions-in-the-table ()
  "Regenerating the dashboard while only some roster-recorded sessions are
live must not overwrite the table down to just the live set -- cc-butler#5:
`butler_dashboard' called mid-recovery (2/16 live) clobbered the session
table to 2 rows, destroying the record of the other 14, which the recovery
runbook itself points to as a fallback."
  (cl-letf (((symbol-function 'cc-butler--sessions) (lambda () nil))
            ((symbol-function 'cc-butler--dead-records)
             (lambda () (list (list :dir "/offline/" :name "offline-worker"
                                     :title "" :status "waiting on PR" :branch "feature/x"
                                     :butler nil)))))
    (let ((out (cc-butler-docs--render-dashboard)))
      (should (string-match-p "OFFLINE" out))
      (should (string-match-p "offline-worker" out))
      (should (string-match-p "waiting on PR" out)))))

(provide 'cc-butler-docs-test)
;;; cc-butler-docs-test.el ends here
