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
            ((symbol-function 'cc-butler--git-head) (lambda (_) nil)))
    (let ((out (cc-butler-tool-reload-code)))
      (should (string-match-p "STALE" out))
      (should (string-match-p "cc-butler-mail.elc" out)))))

(ert-deftest cc-butler-reload/tool-says-it-does-not-fetch ()
  "`reload_butler' loads what is on disk.  Saying so prevents the caller
concluding a merge reached the fleet when nothing was pulled."
  (cl-letf (((symbol-function 'cc-butler-reload)
             (lambda () (list :count 3 :dir "/x/" :stale nil)))
            ((symbol-function 'cc-butler--git-head) (lambda (_) "abc123f (main)")))
    (let ((out (cc-butler-tool-reload-code)))
      (should (string-match-p "does not fetch" out))
      (should (string-match-p "abc123f" out))
      ;; and the tool-list caveat, which is the other recurring wrong conclusion
      (should (string-match-p "/mcp" out)))))

;;;; ------------------------------------------------------------------
;;;; Reading git HEAD without a subprocess — the daemon must never block
;;;; ------------------------------------------------------------------
;;
;; The reload report's HEAD line used to come from `shell-command-to-string',
;; which blocks in C with no timeout — and `with-timeout' cannot interrupt a
;; blocked C call, so a wedged .git/index.lock or a stalled filesystem would
;; freeze the single Lisp thread: every fleet session's terminal, every MCP
;; call.  The fix reads .git/HEAD (and the ref files) directly; these tests
;; pin that reader.  `call-process' below is fine — batch tests, not the
;; daemon.

(defun cc-butler-test--git (dir &rest args)
  "Run git ARGS in DIR for fixture setup; error if git fails."
  (let ((default-directory dir))
    (unless (eq 0 (apply #'call-process "git" nil nil nil args))
      (error "fixture git %s failed in %s" args dir))))

(defun cc-butler-test--make-git-repo ()
  "Create a one-commit fixture repo on branch main; return (DIR . FULL-HASH)."
  (let ((dir (file-name-as-directory (make-temp-file "cc-git-head" t))))
    (cc-butler-test--git dir "init" "-q")
    (cc-butler-test--git dir "symbolic-ref" "HEAD" "refs/heads/main")
    (cc-butler-test--git dir "config" "user.email" "test@test")
    (cc-butler-test--git dir "config" "user.name" "test")
    (cc-butler-test--git dir "commit" "-q" "--allow-empty" "-m" "initial")
    (cons dir
          (let ((default-directory dir))
            (with-temp-buffer
              (call-process "git" nil t nil "rev-parse" "HEAD")
              (string-trim (buffer-string)))))))

(ert-deftest cc-butler-git-head/reads-branch-head-from-files ()
  "Normal repo on a branch: short hash and branch name, from file reads alone."
  (skip-unless (executable-find "git"))
  (let* ((fix (cc-butler-test--make-git-repo))
         (dir (car fix)) (hash (cdr fix)))
    (should (equal (cc-butler--git-head dir)
                   (format "%s (main)" (substring hash 0 7))))))

(ert-deftest cc-butler-git-head/detached-head-still-yields-the-hash ()
  "Detached HEAD is a hash in .git/HEAD, not a ref — report it, don't error."
  (skip-unless (executable-find "git"))
  (let* ((fix (cc-butler-test--make-git-repo))
         (dir (car fix)) (hash (cdr fix)))
    (cc-butler-test--git dir "checkout" "-q" "--detach")
    (should (equal (cc-butler--git-head dir)
                   (format "%s (detached)" (substring hash 0 7))))))

(ert-deftest cc-butler-git-head/resolves-a-packed-ref ()
  "After `git pack-refs' the loose ref file is gone and the hash lives in
packed-refs — the state every gc'd repo ends up in."
  (skip-unless (executable-find "git"))
  (let* ((fix (cc-butler-test--make-git-repo))
         (dir (car fix)) (hash (cdr fix)))
    (cc-butler-test--git dir "pack-refs" "--all")
    (should-not (file-exists-p (expand-file-name ".git/refs/heads/main" dir)))
    (should (equal (cc-butler--git-head dir)
                   (format "%s (main)" (substring hash 0 7))))))

(ert-deftest cc-butler-git-head/follows-a-dotgit-file-into-a-worktree ()
  "In a linked worktree `.git' is a FILE naming the real gitdir, and the refs
live in the common dir.  cc-butler's own fleet loads from worktrees, so this
is not an edge case here."
  (skip-unless (executable-find "git"))
  (let* ((fix (cc-butler-test--make-git-repo))
         (dir (car fix)) (hash (cdr fix))
         (wt (expand-file-name "wt" (make-temp-file "cc-git-wt" t))))
    (cc-butler-test--git dir "worktree" "add" "-q" "-b" "side" wt)
    (should (equal (cc-butler--git-head wt)
                   (format "%s (side)" (substring hash 0 7))))))

(ert-deftest cc-butler-git-head/not-a-repo-degrades-to-nil-not-an-error ()
  "Nil means \"cannot determine\"; the reload report drops the line and goes
on.  Blocking or erroring while trying harder is the failure this replaced."
  (let ((dir (file-name-as-directory (make-temp-file "cc-no-repo" t))))
    (should-not (cc-butler--git-head dir))
    (should-not (cc-butler--git-head (expand-file-name "absent" dir)))))

(ert-deftest cc-butler-git-head/tool-report-omits-the-line-when-unknown ()
  "The report must still work with no HEAD available — placeholder behavior,
never a probe that can hang the daemon."
  (cl-letf (((symbol-function 'cc-butler-reload)
             (lambda () (list :count 3 :dir "/x/" :stale nil)))
            ((symbol-function 'cc-butler--git-head) (lambda (_) nil)))
    (let ((out (cc-butler-tool-reload-code)))
      (should (string-match-p "Reloaded 3 cc-butler modules" out))
      (should-not (string-match-p "Source is at:" out)))))

;;;; ------------------------------------------------------------------
;;;; Which source directory loads — one place decides
;;;; ------------------------------------------------------------------

(ert-deftest cc-butler-source/override-wins-over-the-load-location ()
  "One function answers \"which copy is this\".  Everything that needs the
answer must go through it, so there is no second place to disagree."
  (let ((cc-butler--source-override nil))
    (should (equal (cc-butler-source-dir) cc-butler--dir)))
  (let ((cc-butler--source-override "/elsewhere/"))
    (should (equal (cc-butler-source-dir) "/elsewhere/"))))

(ert-deftest cc-butler-source/override-survives-loading-cc-butler-el-again ()
  "`cc-butler-reload' re-reads cc-butler.el FIRST.  If the override were a
`defconst' — or a top-level `setq' — that self-load would reset it and a
switch would bounce straight back to the copy it was switching away from,
reporting success.  This test loads the real file, so it fails if the
declaration form is ever changed to one that re-initialises.

Deliberately does NOT `let'-bind the override: a dynamic `let' restores the
old value on exit, so a reset by the load would be undone before the
assertion could see it and the test would pass under `defconst' too."
  (let ((saved cc-butler--source-override))
    (unwind-protect
        (progn
          (setq cc-butler--source-override "/elsewhere/")
          (load (expand-file-name "cc-butler.el" cc-butler--dir) nil t)
          (should (equal cc-butler--source-override "/elsewhere/")))
      (setq cc-butler--source-override saved))))

(ert-deftest cc-butler-source/reload-loads-from-the-override ()
  "The switch is only real if `cc-butler-reload' follows it — otherwise the
override is a label on a box whose contents never moved."
  (let ((cc-butler--source-override "/elsewhere/")
        (loaded nil))
    (cl-letf (((symbol-function 'load)
               (lambda (f &rest _) (push f loaded) t))
              ((symbol-function 'file-exists-p) (lambda (&rest _) t))
              ((symbol-function 'cc-butler--stale-elc) (lambda () nil)))
      (let ((res (cc-butler-reload)))
        (should (equal (plist-get res :dir) "/elsewhere/"))))
    (should loaded)
    (should (cl-every (lambda (f) (string-prefix-p "/elsewhere/" f)) loaded))))

(ert-deftest cc-butler-source/refuses-a-directory-that-is-not-cc-butler ()
  "Validate BEFORE mutating.  A switch that fails halfway leaves the override
pointing somewhere unloadable, and the next reload takes the whole control
plane down with it."
  (let ((dir (file-name-as-directory (make-temp-file "cc-not-butler" t)))
        (cc-butler--source-override nil))
    (should-error (cc-butler-use-checkout dir) :type 'user-error)
    (should-not cc-butler--source-override)))

(ert-deftest cc-butler-source/names-the-files-a-directory-is-missing ()
  "\"Not a cc-butler checkout\" sends the caller looking; the missing file
names say what is actually wrong — usually a module added since they cloned."
  (let ((dir (file-name-as-directory (make-temp-file "cc-partial" t))))
    (dolist (f (cons 'cc-butler cc-butler--modules))
      (write-region "" nil (expand-file-name (concat (symbol-name f) ".el") dir)))
    (should-not (cc-butler--missing-sources dir))
    (delete-file (expand-file-name "cc-butler-compact.el" dir))
    (should (equal (cc-butler--missing-sources dir) '("cc-butler-compact.el")))))

(ert-deftest cc-butler-source/refusal-distinguishes-wrong-place-from-stale-clone ()
  "Two different mistakes deserve two different messages.  A directory that
is not cc-butler at all listing every one of its 15 absent modules is a wall
to scroll past; a clone missing exactly the module added last week is the one
case where naming the file is the whole answer."
  (let ((elsewhere (file-name-as-directory (make-temp-file "cc-elsewhere" t)))
        (stale (file-name-as-directory (make-temp-file "cc-stale-clone" t))))
    (dolist (f (cons 'cc-butler cc-butler--modules))
      (write-region "" nil (expand-file-name (concat (symbol-name f) ".el") stale)))
    (delete-file (expand-file-name "cc-butler-compact.el" stale))
    (let ((wrong (should-error (cc-butler-use-checkout elsewhere) :type 'user-error))
          (clone (should-error (cc-butler-use-checkout stale) :type 'user-error)))
      (should (string-match-p "not a cc-butler" (error-message-string wrong)))
      (should-not (string-match-p "cc-butler-compact.el" (error-message-string wrong)))
      (should (string-match-p "cc-butler-compact.el" (error-message-string clone))))))

(ert-deftest cc-butler-reload/tool-surfaces-the-source-state ()
  "The MCP caller cannot see the filesystem — the same reason a stale .elc is
spelled out here.  Which copy just got reloaded, and whether it is behind, is
the thing that caller is least able to find out for itself."
  (cl-letf (((symbol-function 'cc-butler-reload)
             (lambda () (list :count 3 :dir "/x/" :stale nil)))
            ((symbol-function 'cc-butler--git-head) (lambda (_) nil))
            ((symbol-function 'cc-butler--source-diagnostics)
             (lambda () '((warn . "SOURCE-STATE-MARKER")))))
    (should (string-match-p "SOURCE-STATE-MARKER" (cc-butler-tool-reload-code)))))

(ert-deftest cc-butler-source/switches-to-a-complete-checkout ()
  (let* ((dir (file-name-as-directory (make-temp-file "cc-checkout" t)))
         (cc-butler--source-override nil)
         (reloaded nil))
    (dolist (f (cons 'cc-butler cc-butler--modules))
      (write-region "" nil (expand-file-name (concat (symbol-name f) ".el") dir)))
    (cl-letf (((symbol-function 'cc-butler-reload)
               (lambda () (setq reloaded t) (list :count 1 :dir dir :stale nil))))
      (cc-butler-use-checkout dir))
    (should reloaded)
    (should (equal cc-butler--source-override dir))))

(ert-deftest cc-butler-source/use-installed-refuses-when-nothing-is-installed ()
  "Refusing leaves the caller where they were.  Silently clearing the override
would drop them onto whichever copy happened to load, which is the accident
this whole mechanism exists to make impossible."
  (cl-letf (((symbol-function 'cc-butler--installed-dir) (lambda () nil)))
    (let ((cc-butler--source-override "/elsewhere/"))
      (should-error (cc-butler-use-installed) :type 'user-error)
      (should (equal cc-butler--source-override "/elsewhere/")))))

;;;; ------------------------------------------------------------------
;;;; Making the source state visible, and drift mechanical
;;;; ------------------------------------------------------------------

(ert-deftest cc-butler-source/diagnostics-stay-quiet-on-the-installed-copy ()
  "The ordinary case has to stay silent.  A warning that fires every launch
is one people learn to scroll past, which costs the warning that matters."
  (cl-letf (((symbol-function 'cc-butler--installed-dir) (lambda () "/elpa/cc-butler/"))
            ((symbol-function 'cc-butler-source-dir) (lambda () "/elpa/cc-butler/"))
            ((symbol-function 'cc-butler--source-behind) (lambda (_) nil)))
    (should-not (cc-butler--source-diagnostics))))

(ert-deftest cc-butler-source/diagnostics-name-a-checkout-that-is-not-installed ()
  "This is the 19-day defect stated back: a development checkout winning the
`load-path' with nothing, anywhere, saying so.  The path and the revision go
in the message because \"you are on a checkout\" alone still leaves the
reader to find out which one."
  (cl-letf (((symbol-function 'cc-butler--installed-dir) (lambda () "/elpa/cc-butler/"))
            ((symbol-function 'cc-butler-source-dir) (lambda () "/home/dev/cc-butler/"))
            ((symbol-function 'cc-butler--source-revision) (lambda (_) "abc1234 a commit"))
            ((symbol-function 'cc-butler--source-behind) (lambda (_) nil)))
    (let ((out (cc-butler--source-diagnostics)))
      (should out)
      (should (cl-every (lambda (p) (eq (car p) 'warn)) out))
      (let ((text (mapconcat #'cdr out "\n")))
        (should (string-match-p "/home/dev/cc-butler/" text))
        (should (string-match-p "abc1234" text))))))

(ert-deftest cc-butler-source/diagnostics-count-the-drift ()
  "Drift as a mechanical check, not a line in a document: what hid the last
one was not missing discipline but missing visibility, and a document cannot
supply visibility."
  (cl-letf (((symbol-function 'cc-butler--installed-dir) (lambda () "/elpa/cc-butler/"))
            ((symbol-function 'cc-butler-source-dir) (lambda () "/elpa/cc-butler/"))
            ((symbol-function 'cc-butler--source-revision) (lambda (_) "abc1234 a commit"))
            ((symbol-function 'cc-butler--source-behind) (lambda (_) 7)))
    (let ((text (mapconcat #'cdr (cc-butler--source-diagnostics) "\n")))
      (should (string-match-p "7 commits behind" text)))))

(ert-deftest cc-butler-source/unknown-drift-is-never-reported-as-up-to-date ()
  "Nil from the git probe means \"cannot determine\".  Rendering that as
\"up to date\" would be the check quietly asserting the very thing it failed
to establish."
  (dolist (answer '(nil "" "fatal: bad revision 'origin/main'"))
    (cl-letf (((symbol-function 'cc-butler--git) (lambda (&rest _) answer)))
      (should-not (cc-butler--source-behind "/x/"))))
  ;; zero commits behind is "not drifted", which is also not a report
  (cl-letf (((symbol-function 'cc-butler--git) (lambda (&rest _) "0")))
    (should-not (cc-butler--source-behind "/x/")))
  (cl-letf (((symbol-function 'cc-butler--git) (lambda (&rest _) "3")))
    (should (equal (cc-butler--source-behind "/x/") 3))))

(ert-deftest cc-butler-source/preflight-carries-the-source-diagnostics ()
  "`cc-butler-doctor' and every session launch both already read the preflight
list, so landing it there surfaces the state in both — no second call site to
keep in step, and no way to see one without the other."
  (cl-letf (((symbol-function 'cc-butler--source-diagnostics)
             (lambda () '((warn . "SOURCE-STATE-MARKER")))))
    (let ((text (mapconcat #'cdr (cc-butler--launch-preflight-diagnostics) "\n")))
      (should (string-match-p "SOURCE-STATE-MARKER" text)))))

;;;; ------------------------------------------------------------------
;;;; What commit is the live daemon actually running, right now?
;;;; ------------------------------------------------------------------

(ert-deftest cc-butler-runtime-source/exit-code-tells-ancestor-from-non-ancestor-from-error ()
  "`merge-base --is-ancestor' answers 0/1/other, and 1 (\"no\") is a real,
meaningful answer, not an error — `cc-butler--commit-merged-p' must not
collapse it into the same bucket as \"could not check\"."
  (cl-letf (((symbol-function 'cc-butler--git-exit-code) (lambda (&rest _) 0)))
    (should (eq (cc-butler--commit-merged-p "/x/" "abc") 'merged)))
  (cl-letf (((symbol-function 'cc-butler--git-exit-code) (lambda (&rest _) 1)))
    (should (eq (cc-butler--commit-merged-p "/x/" "abc") 'unmerged)))
  (cl-letf (((symbol-function 'cc-butler--git-exit-code) (lambda (&rest _) 128)))
    (should (eq (cc-butler--commit-merged-p "/x/" "abc") 'unknown)))
  (cl-letf (((symbol-function 'cc-butler--git-exit-code) (lambda (&rest _) nil)))
    (should (eq (cc-butler--commit-merged-p "/x/" "abc") 'unknown)))
  ;; missing dir/sha never reaches git at all
  (should-not (cc-butler--commit-merged-p nil "abc"))
  (should-not (cc-butler--commit-merged-p "/x/" nil)))

(ert-deftest cc-butler-runtime-source/exit-code-against-a-real-git-repo ()
  "End-to-end against a real repo, not a mock — the thing a mocked exit code
cannot catch is a wrong argument order or a wrong flag to `git' itself.
SHA1 is set up as the locally-known `origin/main'; SHA2 is a later commit
built on top of it that was never pushed anywhere."
  (skip-unless (executable-find "git"))
  (let* ((dir (file-name-as-directory (make-temp-file "cc-runtime-source" t)))
         (git (lambda (&rest args)
                (let ((default-directory dir))
                  (apply #'call-process "git" nil nil nil args)))))
    (funcall git "init" "-q")
    (funcall git "config" "user.email" "test@example.com")
    (funcall git "config" "user.name" "Test")
    (write-region "a" nil (expand-file-name "f" dir))
    (funcall git "add" "f")
    (funcall git "commit" "-q" "-m" "first")
    (let ((sha1 (cc-butler--git dir "rev-parse" "HEAD")))
      ;; No real remote is needed: `merge-base --is-ancestor' only reads
      ;; refs, and a remote-tracking ref is just a ref.
      (funcall git "update-ref" "refs/remotes/origin/main" sha1)
      (write-region "b" nil (expand-file-name "f" dir))
      (funcall git "add" "f")
      (funcall git "commit" "-q" "-m" "second")
      (let ((sha2 (cc-butler--git dir "rev-parse" "HEAD")))
        ;; sha1 IS origin/main -> trivially an ancestor of itself.
        (should (eq (cc-butler--commit-merged-p dir sha1) 'merged))
        ;; sha2 is a child of origin/main, never merged back into it.
        (should (eq (cc-butler--commit-merged-p dir sha2) 'unmerged))))))

(ert-deftest cc-butler-runtime-source/capture-snapshots-source-dir-and-commit ()
  "The snapshot reads `cc-butler-source-dir' (not the raw load location), so
a deliberate `cc-butler-use-checkout' switch is reflected too."
  (let (cc-butler--runtime-source-dir
        cc-butler--runtime-commit-sha
        cc-butler--runtime-commit-line)
    (cl-letf (((symbol-function 'cc-butler-source-dir) (lambda () "/some/dir/"))
              ((symbol-function 'cc-butler--git)
               (lambda (dir &rest args)
                 (should (equal dir "/some/dir/"))
                 (when (equal args '("rev-parse" "HEAD")) "deadbeef")))
              ((symbol-function 'cc-butler--source-revision)
               (lambda (dir) (should (equal dir "/some/dir/")) "deadbee fix the thing")))
      (cc-butler--capture-runtime-source)
      (should (equal cc-butler--runtime-source-dir "/some/dir/"))
      (should (equal cc-butler--runtime-commit-sha "deadbeef"))
      (should (equal cc-butler--runtime-commit-line "deadbee fix the thing")))))

(ert-deftest cc-butler-runtime-source/capture-leaves-vars-nil-when-not-a-checkout ()
  "A directory that is not a git checkout (or has no git) must not leave a
stale answer sitting around looking current."
  (let (cc-butler--runtime-source-dir
        cc-butler--runtime-commit-sha
        cc-butler--runtime-commit-line)
    (cl-letf (((symbol-function 'cc-butler-source-dir) (lambda () "/nope/"))
              ((symbol-function 'cc-butler--git) (lambda (&rest _) nil))
              ((symbol-function 'cc-butler--source-revision) (lambda (_) nil)))
      (cc-butler--capture-runtime-source)
      (should-not cc-butler--runtime-commit-sha)
      (should-not cc-butler--runtime-commit-line))))

(ert-deftest cc-butler-runtime-source/tool-reports-merged-plainly ()
  (let ((cc-butler--runtime-source-dir "/src/")
        (cc-butler--runtime-commit-sha "deadbeef")
        (cc-butler--runtime-commit-line "deadbee fix the thing"))
    (cl-letf (((symbol-function 'cc-butler--commit-merged-p) (lambda (&rest _) 'merged)))
      (let ((out (cc-butler-tool-runtime-source)))
        (should (string-match-p "/src/" out))
        (should (string-match-p "deadbee fix the thing" out))
        (should (string-match-p "merged" out))
        (should-not (string-match-p "UNMERGED" out))))))

(ert-deftest cc-butler-runtime-source/tool-flags-unmerged-loudly ()
  "This is the exact incident this tool exists for: code that was only ever
hot-loaded from a branch, never merged.  It must not be easy to miss."
  (let ((cc-butler--runtime-source-dir "/src/")
        (cc-butler--runtime-commit-sha "deadbeef")
        (cc-butler--runtime-commit-line "deadbee add kind param"))
    (cl-letf (((symbol-function 'cc-butler--commit-merged-p) (lambda (&rest _) 'unmerged)))
      (let ((out (cc-butler-tool-runtime-source)))
        (should (string-match-p "⚠ UNMERGED" out))
        (should (string-match-p "not reachable from origin/main" out))))))

(ert-deftest cc-butler-runtime-source/tool-distinguishes-unknown-from-merged ()
  "A `git' error or a missing local `origin/main' ref must read as \"could
not check\", never as a silent pass."
  (let ((cc-butler--runtime-source-dir "/src/")
        (cc-butler--runtime-commit-sha "deadbeef")
        (cc-butler--runtime-commit-line "deadbee x"))
    (cl-letf (((symbol-function 'cc-butler--commit-merged-p) (lambda (&rest _) 'unknown)))
      (let ((out (cc-butler-tool-runtime-source)))
        (should (string-match-p "unknown" out))
        (should-not (string-match-p "⚠ UNMERGED" out))
        (should-not (string-match-p "Status: merged" out))))))

(ert-deftest cc-butler-runtime-source/tool-says-so-when-the-commit-is-not-determinable ()
  (let (cc-butler--runtime-source-dir
        cc-butler--runtime-commit-sha
        cc-butler--runtime-commit-line)
    (let ((out (cc-butler-tool-runtime-source)))
      (should (string-match-p "Cannot determine" out)))))

(ert-deftest cc-butler-runtime-source/oneline-is-nil-when-not-determinable ()
  (let (cc-butler--runtime-source-dir
        cc-butler--runtime-commit-sha
        cc-butler--runtime-commit-line)
    (should-not (cc-butler-runtime-source-oneline))))

(ert-deftest cc-butler-runtime-source/oneline-names-the-commit-and-status ()
  (let ((cc-butler--runtime-source-dir "/src/")
        (cc-butler--runtime-commit-sha "deadbeef")
        (cc-butler--runtime-commit-line "deadbee fix the thing"))
    (cl-letf (((symbol-function 'cc-butler--commit-merged-p) (lambda (&rest _) 'unmerged)))
      (let ((line (cc-butler-runtime-source-oneline)))
        (should (string-match-p "deadbee fix the thing" line))
        (should (string-match-p "UNMERGED" line))))))

(ert-deftest cc-butler-runtime-source/tool-is-registered-with-no-arguments ()
  "Matches the pattern other read-only status tools (`pending_decisions',
`list_claude_sessions') follow: no caller-supplied argument, because there
is nothing here for a caller to legitimately choose — it always reports the
one thing that is actually running."
  (let ((spec (seq-find (lambda (s)
                          (equal (plist-get (claude-code-ide--normalize-tool-spec s) :name)
                                 "runtime_source"))
                        (bound-and-true-p claude-code-ide-mcp-server-tools))))
    (when spec   ; only when claude-code-ide is present to register against
      (let ((norm (claude-code-ide--normalize-tool-spec spec)))
        (should (eq (plist-get norm :function) #'cc-butler-tool-runtime-source))
        (should-not (plist-get norm :args))))))

(provide 'cc-butler-reload-test)
;;; cc-butler-reload-test.el ends here
