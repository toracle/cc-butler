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
  ;; batch run (cc-butler#137-class fix, 2026-09-04). Its default
  ;; (`cc-butler-session.el') resolves to the developer's actual
  ;; ~/.local/state/cc-butler/log/, and `cc-butler--log'/`cc-butler--log-message'
  ;; are called from deep inside ordinary code paths this suite exercises
  ;; (forward/backstop, inbox drain, escalate, ...) — so running the suite on
  ;; a dev machine, outside a from-scratch CI container, wrote real ERT
  ;; fixture lines (buffer names like *cc-butler-test-term*, placeholder dirs
  ;; like /worker/, fixture bodies like "ship it?") straight into the live
  ;; ops/msg logs. Measured before this fix: one full suite run added 29 ops
  ;; lines + 14 msg lines to that day's real log files, all attributable to
  ;; test fixtures. A handful of tests already redirect this var locally for
  ;; their own log-file assertions (cc-butler-session-test.el,
  ;; cc-butler-orchestrator-test.el, cc-butler-compact-test.el) — this `let'
  ;; sits outside all of them and does not change their behavior; a `let'
  ;; closer to point of use always wins over this one.
  ;;
  ;; `let', not `setq': the binding must be in place before any test file
  ;; below is `require'd, and must last exactly as long as this process,
  ;; which `ert-run-tests-batch-and-exit' terminates itself (via
  ;; `kill-emacs') — a plain `setq' would need a matching restore that this
  ;; function never returns to run.
  ;;
  ;; This file is `lexical-binding: t', and `cc-butler-session.el' (which
  ;; `defcustom's this variable) has not loaded yet at this point — without
  ;; declaring it special first, the `let' below would create a plain
  ;; LEXICAL binding invisible to `cc-butler--log'/`cc-butler--log-message'
  ;; (which reference it as a free, dynamically-scoped variable), and the
  ;; later `defcustom' would then error trying to redeclare a
  ;; still-in-scope lexical variable as dynamic ("Defining as dynamic an
  ;; already lexical var"). The empty `defvar' marks it special with no
  ;; value of its own, so the `let' dynamically binds it and the later
  ;; `defcustom' — which never overrides an already-bound special variable
  ;; — leaves this binding alone.
  (defvar cc-butler-ops-log-dir)
  (let ((cc-butler-ops-log-dir
         (file-name-as-directory (make-temp-file "cc-butler-test-ops-log-" t))))
    (add-hook 'kill-emacs-hook
              (lambda () (ignore-errors (delete-directory cc-butler-ops-log-dir t))))
    ;; `require' (not `load') so a test file already pulled in by a cross-test
    ;; `require' (e.g. the shared mock/helpers) is not loaded — and
    ;; redefined — a second time.
    (dolist (f (sort (directory-files here t "-test\\.el\\'") #'string<))
      (require (intern (file-name-base f)) f))
    (ert-run-tests-batch-and-exit)))

;;; run-tests.el ends here
