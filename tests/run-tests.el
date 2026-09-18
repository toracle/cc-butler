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
  ;; Isolate `cc-butler-ops-log-dir' from the real, live one for this whole
  ;; batch run — its default is the developer's actual log dir, and
  ;; ordinary code this suite exercises writes to it along the way.
  ;;
  ;; The `defvar' must come first: this file is `lexical-binding: t' and
  ;; the defcustom hasn't loaded yet, so without declaring the symbol
  ;; special here, the `let' below would create a plain lexical binding —
  ;; invisible to the dynamically-scoped code that logs to it — and the
  ;; later `defcustom' would then error trying to redeclare a
  ;; still-in-scope lexical variable as dynamic.
  ;; Same reasoning, same trap, for `cc-butler-inbox-queue-file': its default
  ;; is the real on-disk inbox-queue mirror, and `cc-butler--inbox-push' is
  ;; advised to write it on every call -- ordinary inbox tests would else
  ;; clobber the live queue file.
  (defvar cc-butler-ops-log-dir)
  (defvar cc-butler-inbox-queue-file)
  (let ((cc-butler-ops-log-dir
         (file-name-as-directory (make-temp-file "cc-butler-test-ops-log-" t)))
        (cc-butler-inbox-queue-file
         (make-temp-file "cc-butler-test-inbox-queue-" nil ".eld")))
    (add-hook 'kill-emacs-hook
              (lambda ()
                (ignore-errors (delete-directory cc-butler-ops-log-dir t))
                (ignore-errors (delete-file cc-butler-inbox-queue-file))))
    ;; `require' (not `load') so a test file already pulled in by a cross-test
    ;; `require' (e.g. the shared mock/helpers) is not loaded — and
    ;; redefined — a second time.
    (dolist (f (sort (directory-files here t "-test\\.el\\'") #'string<))
      (require (intern (file-name-base f)) f))
    (ert-run-tests-batch-and-exit)))

;;; run-tests.el ends here
