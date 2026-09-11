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
;; Reuses `cc-butler-mail-test--with-file' — a throwaway `cc-butler-mail-dir'
;; over the real file adapter — rather than inventing a second temp-maildir
;; fixture for check 8's tests below.
(require 'cc-butler-mail-test)

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
must NOT be flagged.  (`standard-value' is set explicitly here to match
the live value, so this exercises the real \"matches\" comparison rather
than the separate no-`standard-value' failure case.)"
  (let ((cc-butler-self-check-tracked-variables '(cc-butler-test-check5-matching)))
    (defvar cc-butler-test-check5-matching)
    (setq cc-butler-test-check5-matching 8)
    (put 'cc-butler-test-check5-matching 'standard-value '(8))
    (unwind-protect
        (cl-letf (((symbol-function 'custom-variable-state) (lambda (&rest _) 'changed))
                  ((symbol-function 'cc-butler--defcustom-drift-all) (lambda (&optional _dir) nil))
                  ((symbol-function 'cc-butler--defcustom-symbols-all) (lambda (&optional _dir) nil)))
          (let ((r (cc-butler-self-check--persisted-vs-live)))
            (should (plist-get r :ok))))
      (makunbound 'cc-butler-test-check5-matching)
      (put 'cc-butler-test-check5-matching 'standard-value nil))))

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

(ert-deftest cc-butler-self-check/persisted-vs-live-flags-extra-list-symbol-not-found-by-scanner ()
  "THE BUG (2026-09-10): a symbol reaching check 5 ONLY via the EXTRA list
`cc-butler-self-check-tracked-variables' -- not found by
`cc-butler--defcustom-symbols-all', matching the real shape of
`claude-code-ide-mcp-server-port', which belongs to a third-party package
and so is structurally invisible to the in-repo scan -- is ALSO invisible
to `cc-butler--defcustom-drift-all': that function only walks
`cc-butler--modules', cc-butler's own source.  So `(assq sym drift)' is
always nil for such a symbol, the `(when triple ...)' body guarding the
label check never runs, and the symbol can NEVER be flagged no matter how
far its live value has drifted from its own default.  This must fail
against the CURRENT (unfixed) code -- the EXTRA list is currently useless
for the exact case it exists to catch."
  (let ((cc-butler-self-check-tracked-variables '(cc-butler-test-check5-external)))
    (defvar cc-butler-test-check5-external)
    (put 'cc-butler-test-check5-external 'standard-value '(1))
    (setq cc-butler-test-check5-external 2)
    (unwind-protect
        (cl-letf (((symbol-function 'custom-variable-state) (lambda (&rest _) 'set))
                  ((symbol-function 'cc-butler--defcustom-symbols-all) (lambda (&optional _dir) nil))
                  ((symbol-function 'cc-butler--defcustom-drift-all) (lambda (&optional _dir) nil)))
          (let ((r (cc-butler-self-check--persisted-vs-live)))
            (should-not (plist-get r :ok))
            (should (string-match-p "cc-butler-test-check5-external" (plist-get r :detail)))))
      (makunbound 'cc-butler-test-check5-external)
      (put 'cc-butler-test-check5-external 'standard-value nil))))

(ert-deftest cc-butler-self-check/persisted-vs-live-flags-extra-list-symbol-without-standard-value ()
  "THE BUG (2026-09-10): `cc-butler-self-check-tracked-variables' has no
entry requirement beyond \"the automatic scan can't see it\" -- nothing
stops a plain `defvar' (not a `defcustom') from being added to it.  Such a
symbol has no `standard-value' property at all (only `defcustom'/
`custom-declare-variable' populate that), so the EXTRA-list-only branch's
`(when (get sym \\='standard-value) ...)' guard is simply falsy: no flag,
no note, no error -- the symbol was accepted onto the list but check 5
silently cannot monitor it, and nothing in the report says so.  Against
CURRENT (unfixed) code this reads as plain :ok t with no mention of the
symbol anywhere -- indistinguishable from \"all clear\".  Must instead
surface as a distinctly-worded check failure naming the symbol."
  (let ((cc-butler-self-check-tracked-variables '(cc-butler-test-check5-no-standard-value)))
    (defvar cc-butler-test-check5-no-standard-value)
    (setq cc-butler-test-check5-no-standard-value 42)
    (unwind-protect
        (cl-letf (((symbol-function 'custom-variable-state) (lambda (&rest _) 'set))
                  ((symbol-function 'cc-butler--defcustom-symbols-all) (lambda (&optional _dir) nil))
                  ((symbol-function 'cc-butler--defcustom-drift-all) (lambda (&optional _dir) nil)))
          (let ((r (cc-butler-self-check--persisted-vs-live)))
            (should-not (plist-get r :ok))
            (should (string-match-p "cc-butler-test-check5-no-standard-value" (plist-get r :detail)))
            (should (string-match-p "no standard-value\\|not a defcustom" (plist-get r :detail)))))
      (makunbound 'cc-butler-test-check5-no-standard-value))))

(ert-deftest cc-butler-self-check/persisted-vs-live-does-not-flag-non-drifted-in-repo-defvar-without-standard-value ()
  "The `:no-standard-value' fallback above must fire ONLY for a symbol that
reached this check EXCLUSIVELY via `cc-butler-self-check-tracked-variables'
-- never for a genuine in-repo symbol the automatic scan
(`cc-butler--defcustom-symbols-all') already returns.  cc-butler's own
codebase has real public (non `--', non hook/keymap) top-level `defvar'
forms with a literal value (e.g. `cc-butler-project-templates') --
`custom-variable-state' reports `rogue' (not `saved'/`standard') for ANY
plain `defvar', drifted or not, since Customize never tracks a `standard'
state for a variable it didn't declare.  Such a symbol, when its live
value still matches its own source-text default (so it is NOT present in
`cc-butler--defcustom-drift-all'), must fall through as \"nothing to
report\" -- flagging it `:no-standard-value' would be a live false
positive on an ordinary, entirely healthy in-repo variable, wrongly
telling a reader it \"is not a defcustom, cannot be monitored\" when in
fact `cc-butler--defcustom-drift-all' COULD monitor it (via its own
code-default), it simply has nothing to report right now."
  (let ((cc-butler-self-check-tracked-variables nil))
    (defvar cc-butler-test-check5-inrepo-defvar)
    (setq cc-butler-test-check5-inrepo-defvar 7)
    (unwind-protect
        (cl-letf (((symbol-function 'custom-variable-state) (lambda (&rest _) 'rogue))
                  ((symbol-function 'cc-butler--defcustom-symbols-all)
                   (lambda (&optional _dir) (list 'cc-butler-test-check5-inrepo-defvar)))
                  ((symbol-function 'cc-butler--defcustom-drift-all) (lambda (&optional _dir) nil)))
          (let ((r (cc-butler-self-check--persisted-vs-live)))
            (should (plist-get r :ok))
            (should-not (string-match-p "cc-butler-test-check5-inrepo-defvar" (plist-get r :detail)))))
      (makunbound 'cc-butler-test-check5-inrepo-defvar))))

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
;;;; Check 8: orphaned inboxes -- unread mail nobody will ever read
;;;; ------------------------------------------------------------------
;;
;; All fixture slugs below are synthetic ("old-session", "worker-a",
;; "restarted-worker", "test-agent") -- never a real person or session id.

(defun cc-butler-self-check-test--drop-message (slug filename age-seconds)
  "Create <`cc-butler-mail-dir'>/SLUG/new/FILENAME with mtime AGE-SECONDS
in the past.  Uses the real maildir plumbing (`cc-butler--mail-ensure'/
`cc-butler--mail-inbox') so the fixture matches real delivery layout."
  (cc-butler--mail-ensure slug)
  (let ((f (expand-file-name (concat "new/" filename) (cc-butler--mail-inbox slug))))
    (with-temp-file f (insert "(:kind note :from \"x\" :body \"hi\")\n"))
    (set-file-times f (time-subtract (current-time) age-seconds))
    f))

(defmacro cc-butler-self-check-test--with-live-slugs (slugs &rest body)
  "Run BODY with `cc-butler-self-check--live-inbox-slugs' stubbed to
return exactly SLUGS (a list of strings) as the live set."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'cc-butler-self-check--live-inbox-slugs)
              (lambda ()
                (let ((h (make-hash-table :test 'equal)))
                  (dolist (s ,slugs) (puthash s t h))
                  h))))
     ,@body))

(ert-deftest cc-butler-self-check/orphaned-inboxes-flags-not-live-old-inbox ()
  "(a) A not-live slug's inbox holding a message at/over the age threshold
must be flagged, with the slug, pending count, and age all visible in
:detail."
  (cc-butler-mail-test--with-file
    (cc-butler-self-check-test--drop-message "old-session" "1.eld" (* 8 24 60 60))
    (cc-butler-self-check-test--with-live-slugs nil
      (let ((r (cc-butler-self-check--orphaned-inboxes)))
        (should-not (plist-get r :ok))
        (should (string-match-p "old-session" (plist-get r :detail)))
        (should (string-match-p "1 pending" (plist-get r :detail)))
        (should (string-match-p "8d" (plist-get r :detail)))))))

(ert-deftest cc-butler-self-check/orphaned-inboxes-never-flags-live-session ()
  "(b) A currently live agent's own unread backlog must never be flagged,
no matter how old the messages are -- an active worker with unread mail
is busy, not orphaned. Liveness gates the whole check."
  (cc-butler-mail-test--with-file
    (cc-butler-self-check-test--drop-message "worker-a" "1.eld" (* 30 24 60 60))
    (cc-butler-self-check-test--with-live-slugs '("worker-a")
      (let ((r (cc-butler-self-check--orphaned-inboxes)))
        (should (plist-get r :ok))
        (should-not (string-match-p "worker-a" (plist-get r :detail)))))))

(ert-deftest cc-butler-self-check/orphaned-inboxes-does-not-flag-recent-mail ()
  "(c) A not-live slug whose only unread mail is recent (under the
threshold) must NOT be flagged -- guards against flagging a worker that
merely restarted minutes/hours ago."
  (cc-butler-mail-test--with-file
    (cc-butler-self-check-test--drop-message "restarted-worker" "1.eld" 300)
    (cc-butler-self-check-test--with-live-slugs nil
      (let ((r (cc-butler-self-check--orphaned-inboxes)))
        (should (plist-get r :ok))
        (should-not (string-match-p "restarted-worker" (plist-get r :detail)))))))

(ert-deftest cc-butler-self-check/orphaned-inboxes-does-not-flag-empty-new ()
  "(d) An inbox that exists but has nothing under new/ at all is not
orphaned -- an inbox with nothing pending is not orphaned."
  (cc-butler-mail-test--with-file
    (cc-butler--mail-ensure "test-agent")
    (cc-butler-self-check-test--with-live-slugs nil
      (let ((r (cc-butler-self-check--orphaned-inboxes)))
        (should (plist-get r :ok))
        (should-not (string-match-p "test-agent" (plist-get r :detail)))))))

(ert-deftest cc-butler-self-check/inbox-dirs-excludes-log-dir ()
  "(e), mechanism-level: `cc-butler-self-check--inbox-dirs' must never
return the channel journal directory (`cc-butler--mail-log-dir') as a
candidate inbox, even though it sits alongside real per-agent inboxes
under the same `cc-butler-mail-dir' root."
  (cc-butler-mail-test--with-file
    (cc-butler--mail-ensure "old-session")
    (make-directory (cc-butler--mail-log-dir) t)
    (let ((dirs (cc-butler-self-check--inbox-dirs)))
      (should (member "old-session" dirs))
      (should-not (member "log" dirs)))))

(ert-deftest cc-butler-self-check/orphaned-inboxes-never-flags-log-dir-even-with-new-subdir ()
  "(e), end-to-end: even in the adversarial case where the channel journal
directory happens to hold a `new/' subdirectory with an old file inside
it, the orphaned-inboxes check must never treat `log' itself as a
candidate inbox slug."
  (cc-butler-mail-test--with-file
    (let* ((log-dir (cc-butler--mail-log-dir))
           (new-dir (expand-file-name "new/" log-dir))
           (bogus (expand-file-name "bogus.eld" new-dir)))
      (make-directory new-dir t)
      (with-temp-file bogus (insert "()\n"))
      (set-file-times bogus (time-subtract (current-time) (* 30 24 60 60))))
    (cc-butler-self-check-test--with-live-slugs nil
      (let ((r (cc-butler-self-check--orphaned-inboxes)))
        (should (plist-get r :ok))
        (should-not (string-match-p "log" (plist-get r :detail)))))))

;;;; ------------------------------------------------------------------
;;;; Check 8: orphan-inbox acknowledgment -- deliberate non-fix must not
;;;; keep the check permanently red once someone has looked at it
;;;; ------------------------------------------------------------------

(defun cc-butler-self-check-test--touch-ack (slug age-seconds)
  "Create/touch SLUG's `.orphan-ack' marker via the real acknowledge
function (with a harmless synthetic reason -- never a real one, this
repo is public), then pin its mtime to AGE-SECONDS in the past with
`set-file-times' -- avoids relying on wall-clock ordering between
fixture steps that run faster than clock resolution."
  (cc-butler-self-check-acknowledge-orphan-inbox slug "kept pending separate disposal")
  (set-file-times (cc-butler-self-check--orphan-ack-file slug)
                   (time-subtract (current-time) age-seconds)))

(ert-deftest cc-butler-self-check/orphaned-inboxes-acknowledged-does-not-fail-ok-but-stays-in-detail ()
  "An orphan candidate whose `.orphan-ack' marker is newer than its
newest pending message must not make `:ok' fail -- but its slug must
still appear in `:detail', distinguishably, never silently dropped."
  (cc-butler-mail-test--with-file
    (cc-butler-self-check-test--drop-message "old-session" "1.eld" (* 8 24 60 60))
    (cc-butler-self-check-test--touch-ack "old-session" (* 1 24 60 60))
    (cc-butler-self-check-test--with-live-slugs nil
      (let ((r (cc-butler-self-check--orphaned-inboxes)))
        (should (plist-get r :ok))
        (should (string-match-p "old-session" (plist-get r :detail)))
        (should (string-match-p "acknowledged" (plist-get r :detail)))))))

(ert-deftest cc-butler-self-check/orphaned-inboxes-newer-message-after-ack-retriggers ()
  "Acknowledging silences only the mail that existed at ack time: once a
message newer than the ack marker is delivered, `:ok' fails again with
no further action -- acknowledgment is not permanent silence."
  (cc-butler-mail-test--with-file
    (cc-butler-self-check-test--drop-message "old-session" "1.eld" (* 8 24 60 60))
    (cc-butler-self-check-test--touch-ack "old-session" (* 1 24 60 60))
    (cc-butler-self-check-test--with-live-slugs nil
      (should (plist-get (cc-butler-self-check--orphaned-inboxes) :ok))
      ;; A newer message arrives after acknowledgment -- newer than the ack
      ;; marker, though still not itself past the age threshold (the
      ;; candidacy gate below still fires off the original 8-day-old
      ;; message, which remains the oldest).
      (cc-butler-self-check-test--drop-message "old-session" "2.eld" 60)
      (let ((r (cc-butler-self-check--orphaned-inboxes)))
        (should-not (plist-get r :ok))
        (should (string-match-p "old-session" (plist-get r :detail)))))))

(ert-deftest cc-butler-self-check/acknowledge-orphan-inbox-rejects-unknown-slug ()
  "Acknowledging a slug that names no existing inbox directory under
`cc-butler-mail-dir' must signal the deliberate membership-check error
and create nothing -- never silently create an arbitrary directory.
Asserts on the error's own message text, not merely \"some error was
signaled\" -- `write-region' failing on a missing parent directory
would also satisfy a bare `should-error' here without the explicit
guard actually having run, which would make this test pass whether or
not the guard exists."
  (cc-butler-mail-test--with-file
    (let ((err (should-error (cc-butler-self-check-acknowledge-orphan-inbox
                               "no-such-inbox" "kept pending separate disposal"))))
      (should (string-match-p "not a known mail inbox" (error-message-string err))))
    (should-not (file-directory-p (cc-butler--mail-inbox "no-such-inbox")))))

(ert-deftest cc-butler-self-check/acknowledge-orphan-inbox-never-touches-message-files ()
  "Acknowledging an inbox must touch only the `.orphan-ack' marker --
never modify, move, or delete any file under new/, tmp/, or archive/.
Captures the pending message's mtime and content before and after
acknowledgment and asserts both are byte-identical."
  (cc-butler-mail-test--with-file
    (let* ((f (cc-butler-self-check-test--drop-message "old-session" "1.eld" (* 8 24 60 60)))
           (before-mtime (file-attribute-modification-time (file-attributes f)))
           (before-content (with-temp-buffer (insert-file-contents f) (buffer-string))))
      (cc-butler-self-check-acknowledge-orphan-inbox "old-session" "kept pending separate disposal")
      (should (file-exists-p f))
      (should (equal (file-attribute-modification-time (file-attributes f)) before-mtime))
      (should (equal (with-temp-buffer (insert-file-contents f) (buffer-string))
                      before-content)))))

(ert-deftest cc-butler-self-check/acknowledge-orphan-inbox-records-reason-in-marker ()
  "Acknowledging with a non-blank REASON must persist that reason text in
the marker file's own content -- not just bump its mtime.  A marker
with only a timestamp erases who judged an inbox fine and why, exactly
the erasure this check exists to catch."
  (cc-butler-mail-test--with-file
    (cc-butler-self-check-test--drop-message "old-session" "1.eld" (* 8 24 60 60))
    (cc-butler-self-check-acknowledge-orphan-inbox "old-session" "kept pending separate disposal")
    (let ((content (with-temp-buffer
                      (insert-file-contents (cc-butler-self-check--orphan-ack-file "old-session"))
                      (buffer-string))))
      (should (string-match-p "kept pending separate disposal" content)))))

(ert-deftest cc-butler-self-check/acknowledge-orphan-inbox-rejects-blank-reason-no-prior-marker ()
  "An empty or whitespace-only REASON must signal an error and create NO
marker file at all -- never a timestamp-only marker, which would repeat
the exact erasure (who judged this fine, and why) this check exists to
catch.  Asserts on the error's message text, not a bare `should-error'
-- same discipline as `acknowledge-orphan-inbox-rejects-unknown-slug',
so a downstream failure (e.g. `write-region' erroring some other way)
can never masquerade as this guard having run."
  (cc-butler-mail-test--with-file
    (cc-butler--mail-ensure "old-session")
    (let ((err (should-error (cc-butler-self-check-acknowledge-orphan-inbox "old-session" "   "))))
      (should (string-match-p "non-blank reason" (error-message-string err))))
    (should-not (file-exists-p (cc-butler-self-check--orphan-ack-file "old-session")))))

(ert-deftest cc-butler-self-check/acknowledge-orphan-inbox-rejects-blank-reason-with-existing-marker ()
  "A blank-REASON call on an ALREADY-acknowledged inbox must not touch --
let alone blank out -- the pre-existing marker's content or mtime at
all; a blank reason must never corrupt a prior good acknowledgment."
  (cc-butler-mail-test--with-file
    (cc-butler--mail-ensure "old-session")
    (cc-butler-self-check-acknowledge-orphan-inbox "old-session" "kept pending separate disposal")
    (let* ((ack-file (cc-butler-self-check--orphan-ack-file "old-session"))
           (before-content (with-temp-buffer (insert-file-contents ack-file) (buffer-string)))
           (before-mtime (file-attribute-modification-time (file-attributes ack-file))))
      (let ((err (should-error (cc-butler-self-check-acknowledge-orphan-inbox "old-session" ""))))
        (should (string-match-p "non-blank reason" (error-message-string err))))
      (should (equal (with-temp-buffer (insert-file-contents ack-file) (buffer-string))
                      before-content))
      (should (equal (file-attribute-modification-time (file-attributes ack-file))
                      before-mtime)))))

(ert-deftest cc-butler-self-check/orphaned-inboxes-acknowledged-detail-includes-reason ()
  "An acknowledged-but-still-listed candidate's `:detail' entry must
include the reason it was acknowledged for, not just its slug/count/age
-- otherwise \"someone said this was fine\" with no recorded reason is
exactly the failure check 8 exists to prevent."
  (cc-butler-mail-test--with-file
    (cc-butler-self-check-test--drop-message "old-session" "1.eld" (* 8 24 60 60))
    (cc-butler-self-check-test--touch-ack "old-session" (* 1 24 60 60))
    (cc-butler-self-check-test--with-live-slugs nil
      (let ((r (cc-butler-self-check--orphaned-inboxes)))
        (should (string-match-p "kept pending separate disposal" (plist-get r :detail)))))))

;;;; ------------------------------------------------------------------
;;;; Check 9: queue vs. room -- thread activity surfaced, never judged
;;;; ------------------------------------------------------------------
;;;; All ids below are synthetic (`!fake-room:example.org',
;;;; `$fake-event-N', `@butler-test:example.org', `old-decision') -- never
;;;; a real event id, room id, decision id, or the real self-user-id.
;;;; No test here makes a real network call: `matrix-bridge-thread-replies'
;;;; is always stubbed.

(defmacro cc-butler-self-check-test--with-decision-dir (&rest body)
  "Fresh temp mail + decision dirs (mirrors
`cc-butler-decision-test--with-arrival', not reused directly to avoid a
cross-test-file `require' for one macro)."
  (declare (indent 0))
  `(let* ((cc-butler-mail-dir (make-temp-file "cc-butler-qrr-mail" t))
          (cc-butler-decision-dir (make-temp-file "cc-butler-qrr-dec" t)))
     (unwind-protect (progn ,@body)
       (delete-directory cc-butler-mail-dir t)
       (delete-directory cc-butler-decision-dir t))))

(defun cc-butler-self-check-test--seed-open-decision
    (id-suffix &optional event-id room delivered-room delivered-thread)
  "Write a `Kind: decision' open/ file, optionally with
`:Delivered-to-matrix:'/`:Room:'/`:Delivered-room:'/`:Delivered-thread:'
properties."
  (with-temp-file (expand-file-name
                    (format "%s-991-%s.org" (format-time-string "%Y%m%dT%H%M%S") id-suffix)
                    (cc-butler--decision-open-dir))
    (insert ":PROPERTIES:\n:Kind: decision\n"
            (if event-id (format ":Delivered-to-matrix: %s\n" event-id) "")
            (if room (format ":Room: %s\n" room) "")
            (if delivered-room (format ":Delivered-room: %s\n" delivered-room) "")
            (if delivered-thread (format ":Delivered-thread: %s\n" delivered-thread) "")
            ":END:\n#+TITLE: synthetic\n\n* Decision\nplaceholder\n")))

(defmacro cc-butler-self-check-test--with-matrix-configured (&rest body)
  "Run BODY with Matrix bridging looking configured: a synthetic self-user-id
and an existing (empty) token file."
  (declare (indent 0))
  `(let* ((token-file (make-temp-file "cc-butler-qrr-token"))
          (matrix-bridge-self-user-id "@butler-test:example.org")
          (matrix-bridge-token-file token-file))
     (unwind-protect (progn ,@body)
       (delete-file token-file))))

(defmacro cc-butler-self-check-test--with-thread-replies-stub (fn &rest body)
  "Run BODY with `matrix-bridge-thread-replies' stubbed to FN (a function of
ROOM EVENT-ID).  Binds `cc-butler-self-check-test--thread-replies-calls' to
the number of calls made, visible to BODY."
  (declare (indent 1))
  `(let ((cc-butler-self-check-test--thread-replies-calls 0))
     (cl-letf (((symbol-function 'matrix-bridge-thread-replies)
                (lambda (room event-id)
                  (setq cc-butler-self-check-test--thread-replies-calls
                        (1+ cc-butler-self-check-test--thread-replies-calls))
                  (funcall ,fn room event-id))))
       ,@body)))

(ert-deftest cc-butler-self-check/queue-room-not-configured-self-user-id-nil ()
  "No Matrix identity set on this fleet at all -- a normal, valid state, not
a defect: `:ok t', this check is explicitly skipped, open count named."
  (cc-butler-self-check-test--with-decision-dir
    (let ((matrix-bridge-self-user-id nil))
      (cc-butler-self-check-test--seed-open-decision "a")
      (let ((r (cc-butler-self-check--queue-room-thread-activity)))
        (should (plist-get r :ok))
        (should (string-match-p "skipped" (plist-get r :detail)))
        (should (string-match-p "1 open decision" (plist-get r :detail)))))))

(ert-deftest cc-butler-self-check/queue-room-not-configured-no-token-file ()
  "A self-user-id is set but the token file does not exist on disk -- still
treated as \"not configured\", not a failure."
  (cc-butler-self-check-test--with-decision-dir
    (let ((matrix-bridge-self-user-id "@butler-test:example.org")
          (matrix-bridge-token-file "/nonexistent/cc-butler-qrr-token-missing"))
      (cc-butler-self-check-test--seed-open-decision "a")
      (let ((r (cc-butler-self-check--queue-room-thread-activity)))
        (should (plist-get r :ok))
        (should (string-match-p "skipped" (plist-get r :detail)))))))

(ert-deftest cc-butler-self-check/queue-room-empty-thread-is-genuinely-open ()
  "A successful fetch that finds NOTHING is still a real, meaningful result
-- \"fetched, found nothing\", not \"all clear\": this check makes no
judgment about what an empty thread means, only that the fetch itself
succeeded.  Lands in the open bucket, not unverifiable, not an error."
  (cc-butler-self-check-test--with-decision-dir
    (cc-butler-self-check-test--with-matrix-configured
      (cc-butler-self-check-test--seed-open-decision
       "empty" "$fake-event-3" "!fake-room:example.org")
      (cc-butler-self-check-test--with-thread-replies-stub
          (lambda (_room _event-id) (list :status 'ok :events nil :scanned 0 :truncated nil))
        (let ((r (cc-butler-self-check--queue-room-thread-activity)))
          (should (plist-get r :ok))
          (should (string-match-p "open 1" (plist-get r :detail)))
          (should (string-match-p "1 decision(s) checked, 0 total thread message(s) scanned"
                                   (plist-get r :detail))))))))

(ert-deftest cc-butler-self-check/queue-room-unverifiable-no-room-property ()
  "A real, confirmed-live gap: `:Delivered-to-matrix:' present but no
`:Room:' at all -- structurally unverifiable, must not be guessed at with
any default room.  Stays `:ok t' (unverifiable alone never fails the
check) and is named separately, not folded into `open'."
  (cc-butler-self-check-test--with-decision-dir
    (cc-butler-self-check-test--with-matrix-configured
      (cc-butler-self-check-test--seed-open-decision "noroom" "$fake-event-4" nil)
      (cc-butler-self-check-test--with-thread-replies-stub
          (lambda (_room _event-id) (error "must not be called -- no :Room: to fetch with"))
        (let ((r (cc-butler-self-check--queue-room-thread-activity)))
          (should (plist-get r :ok))
          (should (string-match-p "unverifiable 1" (plist-get r :detail)))
          (should (string-match-p "no :Room:" (plist-get r :detail)))
          (should (= 0 cc-butler-self-check-test--thread-replies-calls)))))))

(ert-deftest cc-butler-self-check/queue-room-only-delivered-room-property-resolves ()
  "The fix must not depend on the `:Room:' backfill -- a file carrying ONLY
`:Delivered-room:' (the newer-convention shape the 4 newest live
escalations actually use) must still resolve to a room and get fetched,
not land in `no-room'."
  (cc-butler-self-check-test--with-decision-dir
    (cc-butler-self-check-test--with-matrix-configured
      (cc-butler-self-check-test--seed-open-decision
       "delroom" "$fake-event-delroom" nil "!fake-room:example.org")
      (cc-butler-self-check-test--with-thread-replies-stub
          (lambda (room _event-id)
            (should (equal room "!fake-room:example.org"))
            (list :status 'ok :events nil :scanned 0 :truncated nil))
        (let ((r (cc-butler-self-check--queue-room-thread-activity)))
          (should (plist-get r :ok))
          (should (string-match-p "open 1" (plist-get r :detail)))
          (should (= 1 cc-butler-self-check-test--thread-replies-calls)))))))

(ert-deftest cc-butler-self-check/queue-room-conflict-between-room-and-delivered-room ()
  "`:Room:' and `:Delivered-room:' present and naming DIFFERENT rooms is its
own unverifiable reason -- must not silently pick either value, and must
never call out to Matrix with a guessed room."
  (cc-butler-self-check-test--with-decision-dir
    (cc-butler-self-check-test--with-matrix-configured
      (cc-butler-self-check-test--seed-open-decision
       "conflict" "$fake-event-conflict" "!fake-room-a:example.org" "!fake-room-b:example.org")
      (cc-butler-self-check-test--with-thread-replies-stub
          (lambda (_room _event-id) (error "must not be called -- room conflict is unverifiable"))
        (let ((r (cc-butler-self-check--queue-room-thread-activity)))
          (should (plist-get r :ok))
          (should (string-match-p "unverifiable 1" (plist-get r :detail)))
          (should (string-match-p "disagree" (plist-get r :detail)))
          (should (= 0 cc-butler-self-check-test--thread-replies-calls)))))))

(ert-deftest cc-butler-self-check/queue-room-fetches-from-thread-root-not-leaf ()
  "The leaf/root hypothesis, confirmed live 2026-09-11: when
`:Delivered-to-matrix:' names a LEAF reply and `:Delivered-thread:' names
the actual root, the fetch must go to the ROOT -- a human answer attaches
there, not to the leaf."
  (cc-butler-self-check-test--with-decision-dir
    (cc-butler-self-check-test--with-matrix-configured
      (cc-butler-self-check-test--seed-open-decision
       "leafroot" "$fake-event-leaf" "!fake-room:example.org" nil "$fake-event-root")
      (cc-butler-self-check-test--with-thread-replies-stub
          (lambda (_room event-id)
            (should (equal event-id "$fake-event-root"))
            (list :status 'ok :events nil :scanned 5 :truncated nil))
        (let ((r (cc-butler-self-check--queue-room-thread-activity)))
          (should (plist-get r :ok))
          (should (string-match-p "5 total thread message" (plist-get r :detail)))
          (should (= 1 cc-butler-self-check-test--thread-replies-calls)))))))

(ert-deftest cc-butler-self-check/queue-room-unverifiable-not-in-room ()
  "The recorded room turns out wrong (M_NOT_FOUND) -- a data problem, kept
distinct in `:detail' from \"never delivered\" or \"fetch failed\"."
  (cc-butler-self-check-test--with-decision-dir
    (cc-butler-self-check-test--with-matrix-configured
      (cc-butler-self-check-test--seed-open-decision
       "wrongroom" "$fake-event-5" "!fake-room:example.org")
      (cc-butler-self-check-test--with-thread-replies-stub
          (lambda (_room _event-id) (list :status 'not-in-room))
        (let ((r (cc-butler-self-check--queue-room-thread-activity)))
          (should (plist-get r :ok))
          (should (string-match-p "unverifiable 1" (plist-get r :detail)))
          (should (string-match-p "M_NOT_FOUND\\|does not contain" (plist-get r :detail))))))))

(ert-deftest cc-butler-self-check/queue-room-unverifiable-fetch-error ()
  "A network/timeout failure fetching the thread is unverifiable too -- kept
distinct from the not-in-room and no-property cases -- and never fails
`:ok' by itself."
  (cc-butler-self-check-test--with-decision-dir
    (cc-butler-self-check-test--with-matrix-configured
      (cc-butler-self-check-test--seed-open-decision
       "fetcherr" "$fake-event-6" "!fake-room:example.org")
      (cc-butler-self-check-test--with-thread-replies-stub
          (lambda (_room _event-id) (list :status 'error :detail "simulated timeout"))
        (let ((r (cc-butler-self-check--queue-room-thread-activity)))
          (should (plist-get r :ok))
          (should (string-match-p "unverifiable 1" (plist-get r :detail)))
          (should (string-match-p "fetch failed\\|error" (plist-get r :detail))))))))

(ert-deftest cc-butler-self-check/queue-room-aggregate-scanned-total-sums-across-candidates ()
  "The aggregate scanned-message total sums across every successful fetch,
and is paired with the checked-decision count so a reader can tell
\"nothing ran\" apart from \"ran and found nothing\"."
  (cc-butler-self-check-test--with-decision-dir
    (cc-butler-self-check-test--with-matrix-configured
      (cc-butler-self-check-test--seed-open-decision
       "one" "$fake-event-7" "!fake-room:example.org")
      (cc-butler-self-check-test--seed-open-decision
       "two" "$fake-event-8" "!fake-room:example.org")
      (cc-butler-self-check-test--with-thread-replies-stub
          (lambda (_room event-id)
            (if (equal event-id "$fake-event-7")
                (list :status 'ok :events nil :scanned 3 :truncated nil)
              (list :status 'ok :events nil :scanned 4 :truncated nil)))
        (let ((r (cc-butler-self-check--queue-room-thread-activity)))
          (should (plist-get r :ok))
          (should (string-match-p "2 decision(s) checked, 7 total thread message(s) scanned"
                                   (plist-get r :detail))))))))

(ert-deftest cc-butler-self-check/queue-room-detail-shows-per-sender-message-counts ()
  "Requirement: `:detail' exposes sender + count as raw material, not a
computed verdict -- multiple senders, each appearing more than once,
formatted distinctly per sender."
  (cc-butler-self-check-test--with-decision-dir
    (cc-butler-self-check-test--with-matrix-configured
      (cc-butler-self-check-test--seed-open-decision
       "multi" "$fake-event-multi" "!fake-room:example.org")
      (cc-butler-self-check-test--with-thread-replies-stub
          (lambda (_room _event-id)
            (list :status 'ok
                  :events (append (make-list 3 '((sender . "@fleet-a:example.org")))
                                  (make-list 4 '((sender . "@fleet-b:example.org"))))
                  :scanned 7 :truncated nil))
        (let ((r (cc-butler-self-check--queue-room-thread-activity)))
          (should (plist-get r :ok))
          (should (string-match-p "@fleet-a:example.org x3" (plist-get r :detail)))
          (should (string-match-p "@fleet-b:example.org x4" (plist-get r :detail)))
          (should (string-match-p "scanned 7" (plist-get r :detail))))))))

;;;; ---- the four PERMANENT negative controls -----------------------

(ert-deftest cc-butler-self-check/queue-room-no-file-means-structurally-invisible ()
  "PERMANENT, DESIGNATED negative control -- coverage axis: a real human-facing
question sent directly to the Matrix room, bypassing the decision queue
entirely, has NO corresponding file under open/ -- and this check only
ever iterates files that exist there, by construction.  It is not merely
untested that this check catches that gap; it CANNOT, structurally,
because there is nothing to iterate.  This is NOT a bug to fix here: a
reverse room->queue scanner was explicitly rejected in this check's design
-- the room has no way to self-label \"this message is a question\", so a
reverse detector would be an unfalsifiable heuristic over an unconstrained
population.  There is no file for the bypassing message, so there is
nothing to assert against except its absence: with zero decision files
present, this check trivially finds zero candidates and never
calls out to Matrix at all."
  (cc-butler-self-check-test--with-decision-dir
    (cc-butler-self-check-test--with-matrix-configured
      (cc-butler-self-check-test--with-thread-replies-stub
          (lambda (_room _event-id) (error "must not be called -- no candidate files exist"))
        (let ((r (cc-butler-self-check--queue-room-thread-activity)))
          (should (plist-get r :ok))
          (should (string-match-p "0 candidate(s)" (plist-get r :detail)))
          (should (string-match-p "0 decision(s) checked, 0 total thread message(s) scanned"
                                   (plist-get r :detail)))
          (should (= 0 cc-butler-self-check-test--thread-replies-calls)))))))

(ert-deftest cc-butler-self-check/queue-room-never-delivered-lands-unverifiable-not-dropped ()
  "PERMANENT, DESIGNATED negative control -- coverage axis: an open decision file
that DOES exist but has no `:Delivered-to-matrix:' property recorded at
all (never delivered, or delivery never got logged) must land in the
unverifiable bucket, still implicitly \"awaiting answer\" -- never silently
dropped from the count entirely."
  (cc-butler-self-check-test--with-decision-dir
    (cc-butler-self-check-test--with-matrix-configured
      (cc-butler-self-check-test--seed-open-decision "old-decision" nil nil)
      (cc-butler-self-check-test--with-thread-replies-stub
          (lambda (_room _event-id) (error "must not be called -- never delivered"))
        (let ((r (cc-butler-self-check--queue-room-thread-activity)))
          (should (plist-get r :ok))
          (should (string-match-p "1 candidate(s)" (plist-get r :detail)))
          (should (string-match-p "unverifiable 1" (plist-get r :detail)))
          (should-not (string-match-p "open 1" (plist-get r :detail)))
          (should (= 0 cc-butler-self-check-test--thread-replies-calls)))))))

(ert-deftest cc-butler-self-check/queue-room-self-reply-alone-is-not-closure ()
  "PERMANENT, DESIGNATED negative control -- precision axis, not coverage: a
thread whose ONLY reply is this fleet's own delivery-body post (the shape
actually found live, mislabeling still-open decisions as closed) must land
in the open bucket, must not fail `:ok', and must carry no word implying
the decision was answered. A self-authored reply is not evidence of an
answer -- this fleet's own 2-step delivery convention (a short header
event, with the decision body posted as a threaded reply to it) means
every delivered decision already has exactly this reply before anyone,
human or fleet, ever responds. A positive control that only asks \"is a
self-reply found\" cannot distinguish this from a real closure -- it is
the false-positive shape itself; this test is the mirror negative control
that shape required."
  (cc-butler-self-check-test--with-decision-dir
    (cc-butler-self-check-test--with-matrix-configured
      (cc-butler-self-check-test--seed-open-decision
       "selfonly" "$fake-event-selfonly" "!fake-room:example.org")
      (cc-butler-self-check-test--with-thread-replies-stub
          (lambda (_room _event-id)
            (list :status 'ok
                  :events '(((sender . "@butler-test:example.org")))
                  :scanned 1 :truncated nil))
        (let ((r (cc-butler-self-check--queue-room-thread-activity)))
          (should (plist-get r :ok))
          (should (string-match-p "open 1" (plist-get r :detail)))
          (should-not (string-match-p "stale\\|closed\\|resolved" (plist-get r :detail)))
          (should (string-match-p "@butler-test:example.org x1" (plist-get r :detail))))))))

(ert-deftest cc-butler-self-check/queue-room-human-hold-or-recheck-is-not-closure ()
  "PERMANENT, DESIGNATED negative control -- precision axis: a thread with a
genuine THIRD-PARTY reply alongside the self-authored delivery reply (e.g.
a human saying \"hold on\" or asking a follow-up, not an answer) must ALSO
land in the open bucket and must not fail `:ok'. This is automatically
satisfied by this check's design -- it has no closure bucket at all, for
any sender -- pinned here as a permanent test rather than left implicit."
  (cc-butler-self-check-test--with-decision-dir
    (cc-butler-self-check-test--with-matrix-configured
      (cc-butler-self-check-test--seed-open-decision
       "holdreply" "$fake-event-hold" "!fake-room:example.org")
      (cc-butler-self-check-test--with-thread-replies-stub
          (lambda (_room _event-id)
            (list :status 'ok
                  :events '(((sender . "@butler-test:example.org"))
                            ((sender . "@a-human:example.org")))
                  :scanned 2 :truncated nil))
        (let ((r (cc-butler-self-check--queue-room-thread-activity)))
          (should (plist-get r :ok))
          (should (string-match-p "open 1" (plist-get r :detail)))
          (should-not (string-match-p "stale\\|closed\\|resolved" (plist-get r :detail)))
          (should (string-match-p "@a-human:example.org x1" (plist-get r :detail))))))))

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
                (lambda (summary &optional needs options kind sender-label)
                  (push (list :summary summary :needs needs :options options :kind kind
                              :sender-label sender-label)
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

(ert-deftest cc-butler-self-check/report-escalates-with-identifiable-sender-label ()
  "The self-check timer path fires from a timer callback with no MCP session
context to derive a sender from at all, so it must pass an explicit,
human-identifiable SENDER-LABEL through to escalate_to_butler -- never
leave the callee to fall back to an unidentifiable sender."
  (cc-butler-self-check-test--with-stubs
    (cc-butler-self-check--report (cc-butler-self-check-test--fake-results t))
    (cc-butler-self-check--report (cc-butler-self-check-test--fake-results nil))
    (should (equal "cc-butler (self-check)"
                   (plist-get (car cc-butler-self-check-test--escalations) :sender-label)))))

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
