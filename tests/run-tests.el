;;; run-tests.el --- run the cc-butler ERT suite  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jeongsoo Park
;; SPDX-License-Identifier: MIT

;; Usage:  emacs -Q --batch -l tests/run-tests.el
;;
;; Puts the package root (the modules) and this tests/ dir (cross-test helpers)
;; on the load-path, loads every *-test.el, and runs the ERT suite in batch.

(let* ((here (file-name-directory (or load-file-name buffer-file-name default-directory)))
       (root (file-name-directory (directory-file-name here))))
  ;; dev-env dependencies (hydra, transient, etc.); on CI these come from
  ;; Package-Requires.  These must be PREPENDED — several of them (transient in
  ;; particular) shadow an older copy built into Emacs itself, and appending
  ;; would let the stale built-in win.
  (let ((elpa (expand-file-name "~/.emacs.d/elpa")))
    (when (file-directory-p elpa)
      (dolist (d (directory-files elpa t "\\`[^.]"))
        (when (file-directory-p d) (add-to-list 'load-path d)))))
  ;; ROOT and HERE go on LAST so they sit at the very front, ahead of the elpa
  ;; entries added above.  Order is load-bearing, not cosmetic: one of those
  ;; entries is ~/.emacs.d/elpa/cc-butler, an installed copy of this very
  ;; package.  While it sat ahead of ROOT the suite silently tested the
  ;; INSTALLED build instead of the working tree, so every test covering code
  ;; newer than the last install failed against stale definitions — 24 of them
  ;; on 2026-07-22, all of which pass against the tree.  An installed copy must
  ;; never shadow the checkout under test.
  (add-to-list 'load-path here)
  (add-to-list 'load-path root)
  (require 'ert)
  ;; `require' (not `load') so a test file already pulled in by a cross-test
  ;; `require' (e.g. the shared mock/helpers) is not loaded — and redefined —
  ;; a second time.
  (dolist (f (sort (directory-files here t "-test\\.el\\'") #'string<))
    (require (intern (file-name-base f)) f))
  (ert-run-tests-batch-and-exit))

;;; run-tests.el ends here
