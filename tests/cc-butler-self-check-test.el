;;; cc-butler-self-check-test.el --- tests for cc-butler-self-check.el -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jeongsoo Park
;; SPDX-License-Identifier: MIT

(require 'ert)
(require 'cl-lib)
(require 'cc-butler-self-check)
;; Reuses the synthetic-git-repo fixture helpers this repo already built for
;; testing the drift machinery (`cc-butler-test--git',
;; `cc-butler-test--make-multi-commit-git-repo',
;; `cc-butler-test--write-fixture-module') — never a parallel copy.
(require 'cc-butler-reload-test)

;;;; ------------------------------------------------------------------
;;;; Registry reload mechanism (defvar vs defconst)
;;;; ------------------------------------------------------------------

(ert-deftest cc-butler-self-check/registry-defvar-does-not-resync-on-reload ()
  "SYNTHETIC, mechanism-only -- not tied to the real
`cc-butler-self-check--checks' symbol.  `defvar' with a value only sets the
symbol IF IT IS CURRENTLY UNBOUND, so reloading the SAME file path with a
changed value leaves an already-bound `defvar' stuck at the OLD value.
This is the general Elisp gap that let check 7 (added by PR #225) exist in
source but never actually run on a fleet that had already loaded the older
6-entry `cc-butler-self-check--checks' alist before #225 merged."
  (let* ((dir (file-name-as-directory (make-temp-file "cc-check-registry-reload" t)))
         (file (cc-butler-test--write-fixture-module
                dir "(defvar cc-butler-test-registry-reload '((\"a\" . 1)))\n")))
    (unwind-protect
        (progn
          (load file nil t)
          (write-region "(defvar cc-butler-test-registry-reload '((\"a\" . 1) (\"b\" . 2)))\n"
                        nil file)
          (load file nil t)
          (should (equal (mapcar #'car cc-butler-test-registry-reload) '("a"))))
      (makunbound 'cc-butler-test-registry-reload)
      (delete-directory dir t))))

(ert-deftest cc-butler-self-check/registry-defconst-resyncs-on-reload ()
  "Mirror image, `defconst': unconditionally reassigns on every top-level
evaluation regardless of prior binding, so the same overwrite-and-reload
DOES pick up the new entry.  No code change is under test here -- this
just documents/locks in the mechanism the `defconst' fix to
`cc-butler-self-check--checks' (below) relies on."
  (let* ((dir (file-name-as-directory (make-temp-file "cc-check-registry-reload" t)))
         (file (cc-butler-test--write-fixture-module
                dir "(defconst cc-butler-test-registry-reload-const '((\"a\" . 1)))\n")))
    (unwind-protect
        (progn
          (load file nil t)
          (write-region "(defconst cc-butler-test-registry-reload-const '((\"a\" . 1) (\"b\" . 2)))\n"
                        nil file)
          (load file nil t)
          (should (equal (mapcar #'car cc-butler-test-registry-reload-const) '("a" "b"))))
      (makunbound 'cc-butler-test-registry-reload-const)
      (delete-directory dir t))))

(ert-deftest cc-butler-self-check/run-covers-every-registered-check ()
  "Every name in the registry must actually appear in `cc-butler-self-check-run's
result -- a check function can exist and be correct in isolation while never
being reachable through the dispatcher if it was never added to the alist (or,
2026-09-10 live: was added to the alist in SOURCE but the reload never applied
it to the already-bound symbol -- see the defconst fix above). The existing
per-check tests only ever call each check FUNCTION directly and would not have
caught either failure mode."
  (let ((names (mapcar #'car (cc-butler-self-check-run))))
    (dolist (c cc-butler-self-check--checks)
      (should (member (car c) names)))))

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
Customize), reads as `changed', genuinely differs from its code-default,
AND is labeled a likely stuck reload must fail."
  (let ((cc-butler-self-check-tracked-variables '(cc-butler-north-star-file))
        (cc-butler-north-star-file "/tmp/live-patched-value.org"))
    (cl-letf (((symbol-function 'cc-butler--defcustom-drift-all)
               (lambda (&optional _dir)
                 (list (list 'cc-butler-north-star-file "/tmp/live-patched-value.org" "/tmp/code-default.org"))))
              ((symbol-function 'cc-butler--defcustom-file-for-symbol) (lambda (&rest _) "/fake/file.el"))
              ((symbol-function 'cc-butler--defcustom-drift-label)
               (lambda (&rest _) "(likely stuck reload) this value matches a past shipped default")))
      (let ((r (cc-butler-self-check--persisted-vs-live)))
        (should-not (plist-get r :ok))
        (should (string-match-p "cc-butler-north-star-file" (plist-get r :detail)))))))

(ert-deftest cc-butler-self-check/persisted-vs-live-passes-when-saved ()
  "A tracked variable whose Customize state is `saved' (or `standard') must
pass -- this is the check answering \"is this correct AFTER a restart\"."
  (let ((cc-butler-self-check-tracked-variables '(cc-butler-north-star-file)))
    (cl-letf (((symbol-function 'custom-variable-state) (lambda (&rest _) 'saved)))
      (let ((r (cc-butler-self-check--persisted-vs-live)))
        (should (plist-get r :ok))))))

(ert-deftest cc-butler-self-check/persisted-vs-live-does-not-flag-unsaved-when-matching-code-default ()
  "REGRESSION GUARD (2026-09-10): steward set `cc-butler-launch-ready-timeout'
live to 8 with `saved-value' nil, deliberately -- a restart gives back that
exact same value anyway, so there is nothing to lose and this must read as
OK, not bad.  An unsaved variable whose live value already equals the
current code-default (i.e. absent from `cc-butler--defcustom-drift-all')
must NOT be flagged."
  (let ((cc-butler-self-check-tracked-variables '(cc-butler-test-check5-matching)))
    (defvar cc-butler-test-check5-matching)
    (setq cc-butler-test-check5-matching 8)
    (unwind-protect
        (cl-letf (((symbol-function 'custom-variable-state) (lambda (&rest _) 'changed))
                  ((symbol-function 'cc-butler--defcustom-drift-all) (lambda (&optional _dir) nil))
                  ((symbol-function 'cc-butler--defcustom-symbols-all) (lambda (&optional _dir) nil)))
          (let ((r (cc-butler-self-check--persisted-vs-live)))
            (should (plist-get r :ok))))
      (makunbound 'cc-butler-test-check5-matching))))

(ert-deftest cc-butler-self-check/persisted-vs-live-still-flags-unsaved-when-differing-from-code-default ()
  "The real-risk case must still fail: unsaved, the live value differs from
the code-default (present in `cc-butler--defcustom-drift-all'), AND the
drift is labeled a likely stuck reload -- a restart would silently revert
this to something wrong."
  (let ((cc-butler-self-check-tracked-variables '(cc-butler-test-check5-differing)))
    (defvar cc-butler-test-check5-differing)
    (setq cc-butler-test-check5-differing 5)
    (unwind-protect
        (cl-letf (((symbol-function 'custom-variable-state) (lambda (&rest _) 'changed))
                  ((symbol-function 'cc-butler--defcustom-drift-all)
                   (lambda (&optional _dir) (list (list 'cc-butler-test-check5-differing 5 8))))
                  ((symbol-function 'cc-butler--defcustom-symbols-all) (lambda (&optional _dir) nil))
                  ((symbol-function 'cc-butler--defcustom-file-for-symbol) (lambda (&rest _) "/fake/file.el"))
                  ((symbol-function 'cc-butler--defcustom-drift-label)
                   (lambda (&rest _) "(likely stuck reload) this value matches a past shipped default")))
          (let ((r (cc-butler-self-check--persisted-vs-live)))
            (should-not (plist-get r :ok))
            (should (string-match-p "cc-butler-test-check5-differing" (plist-get r :detail)))))
      (makunbound 'cc-butler-test-check5-differing))))

(ert-deftest cc-butler-self-check/persisted-vs-live-does-not-flag-deliberate-customization ()
  "REGRESSION GUARD (2026-09-10, live): after check 5's population widened
(PR #225), it flagged 8 symbols, 7 of which were legitimate live
customizations -- never saved to custom.el, but deliberately differing
from the code-default -- pure noise. A symbol that is unsaved AND
genuinely differs from its code-default (present in
`cc-butler--defcustom-drift-all') but whose
`cc-butler--defcustom-drift-label' comes back \"(likely deliberate
customization)\", not \"(likely stuck reload)\", must NOT be flagged --
exactly the case that was wrongly flagging 7 of 8 symbols live."
  (let ((cc-butler-self-check-tracked-variables '(cc-butler-test-check5-deliberate)))
    (defvar cc-butler-test-check5-deliberate)
    (setq cc-butler-test-check5-deliberate 999)
    (unwind-protect
        (cl-letf (((symbol-function 'custom-variable-state) (lambda (&rest _) 'changed))
                  ((symbol-function 'cc-butler--defcustom-drift-all)
                   (lambda (&optional _dir) (list (list 'cc-butler-test-check5-deliberate 999 8))))
                  ((symbol-function 'cc-butler--defcustom-symbols-all) (lambda (&optional _dir) nil))
                  ((symbol-function 'cc-butler--defcustom-file-for-symbol) (lambda (&rest _) "/fake/file.el"))
                  ((symbol-function 'cc-butler--defcustom-drift-label)
                   (lambda (&rest _) "(likely deliberate customization) this value never appears in this line's git history")))
          (let ((r (cc-butler-self-check--persisted-vs-live)))
            (should (plist-get r :ok))))
      (makunbound 'cc-butler-test-check5-deliberate))))

(ert-deftest cc-butler-self-check/persisted-vs-live-population-includes-auto-scanned-symbol ()
  "The auto-scanned population must genuinely widen coverage beyond
`cc-butler-self-check-tracked-variables' -- 2026-09-10: the hand list
tracked 2 of ~8 variables that actually mattered that day.  A symbol
returned only by `cc-butler--defcustom-symbols-all', absent from the
(here empty) tracked-variables list, must still be checked."
  (let ((cc-butler-self-check-tracked-variables nil)
        checked)
    (defvar cc-butler-test-check5-autoscanned)
    (setq cc-butler-test-check5-autoscanned 1)
    (unwind-protect
        (cl-letf (((symbol-function 'cc-butler--defcustom-symbols-all)
                   (lambda (&optional _dir) (list 'cc-butler-test-check5-autoscanned)))
                  ((symbol-function 'cc-butler--defcustom-drift-all) (lambda (&optional _dir) nil))
                  ((symbol-function 'custom-variable-state)
                   (lambda (sym &rest _) (push sym checked) 'saved)))
          (cc-butler-self-check--persisted-vs-live)
          (should (memq 'cc-butler-test-check5-autoscanned checked)))
      (makunbound 'cc-butler-test-check5-autoscanned))))

(ert-deftest cc-butler-self-check/tracked-variables-default-includes-external-mcp-port ()
  "REGRESSION GUARD (2026-09-10, live): PR #225 dropped the default to nil,
reasoning `cc-butler-north-star-file' was redundant with the auto-scan
\(`cc-butler--defcustom-symbols-all') -- true for that symbol, but wrong to
also drop `claude-code-ide-mcp-server-port': it belongs to a third-party
package, not to cc-butler.el or any module in `cc-butler--modules', so the
auto-scan structurally cannot ever see it (confirmed live:
`(memq 'claude-code-ide-mcp-server-port (cc-butler--defcustom-symbols-all))'
is nil). Compares against the defcustom's own `standard-value' rather than
hardcoding a literal default, matching `cc-butler-ops-log-dir's own
default-value test (tests/cc-butler-session-test.el)."
  (should (equal (eval (car (get 'cc-butler-self-check-tracked-variables 'standard-value)) t)
                 '(claude-code-ide-mcp-server-port))))

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
;;;; Check 7: code-vs-live defcustom (the stuck-reload shape, live)
;;;; ------------------------------------------------------------------

(ert-deftest cc-butler-self-check/code-vs-live-defcustom-flags-stuck-reload ()
  "The exact live regression this check exists for (2026-09-05:
`cc-butler-launch-ready-timeout' raised 5->8 in source, stayed live at 5
through a reload, for 5 days, because nothing periodic ever asked).  A
live value matching a PAST shipped default, not the current one, must
fail with a \"likely stuck reload\" label."
  (skip-unless (executable-find "git"))
  (cl-destructuring-bind (_dir file _shas)
      (cc-butler-test--make-multi-commit-git-repo "cc-butler-test-check7-stuck" '(3 5 8))
    (cl-letf (((symbol-function 'cc-butler--defcustom-drift-all)
               (lambda (&optional _dir) (list (list 'cc-butler-test-check7-stuck 3 8))))
              ((symbol-function 'cc-butler--defcustom-file-for-symbol)
               (lambda (_dir sym) (should (eq sym 'cc-butler-test-check7-stuck)) file)))
      (let ((r (cc-butler-self-check--code-vs-live-defcustom)))
        (should-not (plist-get r :ok))
        (should (string-match-p "cc-butler-test-check7-stuck" (plist-get r :detail)))
        (should (string-match-p "likely stuck reload" (plist-get r :detail)))))))

(ert-deftest cc-butler-self-check/code-vs-live-defcustom-does-not-flag-deliberate-customization ()
  "A live value that never appeared in the file's git history is ordinary
customization, not a stuck reload -- must pass, never page anyone."
  (skip-unless (executable-find "git"))
  (cl-destructuring-bind (_dir file _shas)
      (cc-butler-test--make-multi-commit-git-repo "cc-butler-test-check7-deliberate" '(3 5 8))
    (cl-letf (((symbol-function 'cc-butler--defcustom-drift-all)
               (lambda (&optional _dir) (list (list 'cc-butler-test-check7-deliberate 999 8))))
              ((symbol-function 'cc-butler--defcustom-file-for-symbol)
               (lambda (_dir _sym) file)))
      (let ((r (cc-butler-self-check--code-vs-live-defcustom)))
        (should (plist-get r :ok))))))

(ert-deftest cc-butler-self-check/code-vs-live-defcustom-does-not-flag-unlabelable-drift ()
  "A default that has NEVER changed in history (no git history to walk at
all -- the `cc-butler-decision-workflow' shape) cannot even be classified
as a stuck-reload match.  Unlabelable drift must pass, not fail-open."
  (let* ((dir (file-name-as-directory (make-temp-file "cc-check7-nogit" t)))
         (file (cc-butler-test--write-fixture-module
                dir "(defcustom cc-butler-test-check7-nogit 8 \"doc\")\n")))
    (cl-letf (((symbol-function 'cc-butler--defcustom-drift-all)
               (lambda (&optional _dir) (list (list 'cc-butler-test-check7-nogit 5 8))))
              ((symbol-function 'cc-butler--defcustom-file-for-symbol)
               (lambda (_dir _sym) file)))
      (let ((r (cc-butler-self-check--code-vs-live-defcustom)))
        (should (plist-get r :ok))))))

(ert-deftest cc-butler-self-check/code-vs-live-defcustom-passes-quietly-with-no-drift ()
  "No drift at all (the ordinary case) must pass, with a detail string that
names how many drifted symbols were checked -- distinct from a real pass
that found drift but no stuck-reload label among it."
  (cl-letf (((symbol-function 'cc-butler--defcustom-drift-all) (lambda (&optional _dir) nil)))
    (let ((r (cc-butler-self-check--code-vs-live-defcustom)))
      (should (plist-get r :ok))
      (should (string-match-p "0 drifted" (plist-get r :detail))))))

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
