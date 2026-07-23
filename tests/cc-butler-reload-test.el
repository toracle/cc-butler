;;; cc-butler-reload-test.el --- tests for the hot-reload path  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jeongsoo Park
;; SPDX-License-Identifier: MIT

;; Run alone:
;;   emacs -Q --batch -L . -l ert -l tests/cc-butler-reload-test.el \
;;         -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'cl-lib)
(require 'cc-butler)

(ert-deftest cc-butler-reload/reloads-this-file-before-using-its-module-list ()
  "REGRESSION (2026-07-23): `cc-butler--modules' is defined in cc-butler.el,
so a reload driven by the OLD in-memory list silently skips a module added
since Emacs started — and still reports success.  cc-butler.el must be
re-read FIRST so the list is current before it is used."
  (let ((loaded nil))
    (cl-letf (((symbol-function 'load)
               (lambda (f &rest _) (push (file-name-nondirectory f) loaded) t))
              ((symbol-function 'cc-butler--stale-elc) (lambda () nil)))
      (cc-butler-reload))
    (setq loaded (nreverse loaded))
    (should (equal (car loaded) "cc-butler.el"))
    ;; and every module still follows, in order
    (should (equal (cdr loaded)
                   (mapcar (lambda (m) (concat (symbol-name m) ".el"))
                           cc-butler--modules)))))

(ert-deftest cc-butler-reload/reports-count-and-directory ()
  "The return value names what was loaded and from where — the directory is
the thing callers most often get wrong."
  (cl-letf (((symbol-function 'load) (lambda (&rest _) t))
            ((symbol-function 'cc-butler--stale-elc) (lambda () nil)))
    (let ((res (cc-butler-reload)))
      (should (equal (plist-get res :count) (length cc-butler--modules)))
      (should (equal (plist-get res :dir) cc-butler--dir)))))

(ert-deftest cc-butler-reload/detects-stale-byte-code ()
  "A .elc newer-than-source wins on the next Emacs start and silently undoes
the reload, so it has to be surfaced rather than discovered later."
  (let* ((dir (file-name-as-directory (make-temp-file "cc-reload" t)))
         (el (expand-file-name "cc-butler-session.el" dir))
         (elc (expand-file-name "cc-butler-session.elc" dir))
         (cc-butler--dir dir))
    ;; .elc older than .el  -> stale
    (write-region "" nil elc)
    (sleep-for 0.02)
    (write-region "" nil el)
    (should (equal (cc-butler--stale-elc) '("cc-butler-session.elc")))
    ;; .elc newer than .el  -> not stale
    (sleep-for 0.02)
    (write-region "" nil elc)
    (should-not (cc-butler--stale-elc))))

(ert-deftest cc-butler-reload/stale-byte-code-is-called-out-in-the-tool-output ()
  "The MCP caller cannot see the filesystem, so a stale .elc must be spelled
out in the response rather than left as a silent trap."
  (cl-letf (((symbol-function 'cc-butler-reload)
             (lambda () (list :count 3 :dir "/x/" :stale '("cc-butler-mail.elc"))))
            ((symbol-function 'shell-command-to-string) (lambda (&rest _) "")))
    (let ((out (cc-butler-tool-reload-code)))
      (should (string-match-p "STALE" out))
      (should (string-match-p "cc-butler-mail.elc" out)))))

(ert-deftest cc-butler-reload/tool-says-it-does-not-fetch ()
  "`reload_butler' loads what is on disk.  Saying so prevents the caller
concluding a merge reached the fleet when nothing was pulled."
  (cl-letf (((symbol-function 'cc-butler-reload)
             (lambda () (list :count 3 :dir "/x/" :stale nil)))
            ((symbol-function 'shell-command-to-string) (lambda (&rest _) "abc123 some commit\n")))
    (let ((out (cc-butler-tool-reload-code)))
      (should (string-match-p "does not fetch" out))
      (should (string-match-p "abc123" out))
      ;; and the tool-list caveat, which is the other recurring wrong conclusion
      (should (string-match-p "/mcp" out)))))

(provide 'cc-butler-reload-test)
;;; cc-butler-reload-test.el ends here
