;;; run-tests.el --- run the cc-butler ERT suite  -*- lexical-binding: t; -*-

;; Usage:  emacs -Q --batch -l tests/run-tests.el
;;
;; Puts the package root (the modules) and this tests/ dir (cross-test helpers)
;; on the load-path, loads every *-test.el, and runs the ERT suite in batch.

(let* ((here (file-name-directory (or load-file-name buffer-file-name default-directory)))
       (root (file-name-directory (directory-file-name here))))
  (add-to-list 'load-path root)
  (add-to-list 'load-path here)
  ;; dev-env dependencies (hydra, etc.); on CI these come from Package-Requires.
  (let ((elpa (expand-file-name "~/.emacs.d/elpa")))
    (when (file-directory-p elpa)
      (dolist (d (directory-files elpa t "\\`[^.]"))
        (when (file-directory-p d) (add-to-list 'load-path d)))))
  (require 'ert)
  ;; `require' (not `load') so a test file already pulled in by a cross-test
  ;; `require' (e.g. the shared mock/helpers) is not loaded — and redefined —
  ;; a second time.
  (dolist (f (sort (directory-files here t "-test\\.el\\'") #'string<))
    (require (intern (file-name-base f)) f))
  (ert-run-tests-batch-and-exit))

;;; run-tests.el ends here
