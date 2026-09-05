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
;;;; Private permissions on newly-created docs files
;;;; ------------------------------------------------------------------
;;
;; See `cc-butler--state-ensure-dir'/`cc-butler--state-write-file' in
;; cc-butler-session.el.  These exercise the REAL writer functions
;; end-to-end, not the shared helper directly.

(defmacro cc-butler-docs-test--with-butler (&rest body)
  "Run BODY with `cc-butler--butler' pointed at a fresh throwaway directory."
  (declare (indent 0))
  `(let ((cc-butler--butler (make-temp-file "cc-butler-docs-test" t)))
     (unwind-protect (progn ,@body)
       (delete-directory cc-butler--butler t))))

(ert-deftest cc-butler-docs/ensure-index-creates-restricted-dir-and-file ()
  "Given no docs/ dir yet, When `cc-butler-docs--ensure-index' creates the
index, Then docs/ is mode 700 and index.org is mode 600."
  (cc-butler-docs-test--with-butler
    (let ((file (cc-butler-docs--ensure-index)))
      (should (= #o700 (file-modes (cc-butler-docs--docs-dir))))
      (should (= #o600 (file-modes file))))))

(ert-deftest cc-butler-docs/append-log-creates-restricted-dir-and-file ()
  "Given no log/ dir yet, When `cc-butler-docs--append-log' writes the first
entry, Then log/ is mode 700 and today's log file is mode 600."
  (cc-butler-docs-test--with-butler
    (let ((file (cc-butler-docs--append-log "note" "hello")))
      (should (= #o700 (file-modes (cc-butler-docs--log-dir))))
      (should (= #o600 (file-modes file))))))

(ert-deftest cc-butler-docs/write-dashboard-creates-restricted-dir-and-file ()
  "Given no docs/ dir yet, When `cc-butler-docs--write-dashboard' writes the
dashboard, Then docs/ is mode 700 and dashboard.org is mode 600."
  (cc-butler-docs-test--with-butler
    (cl-letf (((symbol-function 'cc-butler--sessions) (lambda () nil)))
      (let ((file (cc-butler-docs--write-dashboard)))
        (should (= #o700 (file-modes (cc-butler-docs--docs-dir))))
        (should (= #o600 (file-modes file)))))))

(provide 'cc-butler-docs-test)
;;; cc-butler-docs-test.el ends here
