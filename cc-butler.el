;;; cc-butler.el --- Manage & orchestrate multiple Claude Code sessions  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jeongsoo Park
;; SPDX-License-Identifier: MIT

;; Author: Jeongsoo Park <jeongsoo@warmblood.kr>
;; Maintainer: Jeongsoo Park <jeongsoo@warmblood.kr>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (claude-code-ide "0.2.7") (hydra "0.15.0"))
;; Keywords: tools, processes, convenience
;; URL: https://github.com/toracle/cc-butler

;; This file is not part of GNU Emacs.

;;; Commentary:
;;
;; cc-butler is a cmux-like manager and control plane for running many
;; concurrent `claude-code-ide' sessions in one Emacs:
;;
;;   - a sticky left-hand list of live sessions (`M-x cc-butler');
;;   - per-session metadata a running Claude sets about itself over MCP;
;;   - topic workspaces (`cc-butler-new-topic' / `cc-butler-close-topic');
;;   - a butler/worker control plane, where one designated *butler* session
;;     drives the *worker* sessions and aggregates their events;
;;   - a per-session document panel (PRs, issues, CI runs, files) shown as a
;;     tab line beside the session;
;;   - a butler self-document repository (a regenerated dashboard plus an
;;     append-only daily log).
;;
;; This file only wires the modules together; each concern lives in its own
;; `cc-butler-*.el'.  See the README for the full picture.

;;; Code:

(defgroup cc-butler nil
  "Manage and orchestrate multiple Claude Code sessions."
  :group 'tools
  :prefix "cc-butler-")

(require 'cc-butler-session)
(require 'cc-butler-notifications)
(require 'cc-butler-workspace)
(require 'cc-butler-orchestrator)
(require 'cc-butler-mcp-resilience)
(require 'cc-butler-doc-panel)
(require 'cc-butler-docs)
(require 'cc-butler-persist)
(require 'cc-butler-mail)
(require 'cc-butler-decision)
(require 'cc-butler-inbox)
(require 'cc-butler-governance)
(require 'cc-butler-provenance)
(require 'cc-butler-cleanup)
(require 'cc-butler-compact)
(require 'cc-butler-north-star)

(require 'hydra)

;; A discoverable menu of the `*claude-sessions*' buffer's own commands,
;; mirroring the `?' -> hydra pattern already used by
;; `cc-butler-decision-mode-map' (see cc-butler-decision.el).  Lives here
;; (after every module is required) rather than in `cc-butler-session.el'
;; itself, because it references commands owned by other modules
;; (`cc-butler-new-topic', `cc-butler-inbox', `cc-butler-start-butler', the
;; doc-panel commands, ...) that are not yet defined while
;; `cc-butler-session.el' loads.  The individual keys it lists keep working
;; standalone; this only adds a cheat-sheet on `?'.
(defhydra cc-butler-session-hydra (:color blue :hint nil)
  "
 _n_ext  _p_rev  _RET_ open  _SPC_ preview  _g_ refresh  _q_ quit
 _c_ new session   _N_ew topic   _K_ close topic   _h_ doctor   _l_og
 _B_utler   _S_teward   _b_ set butler   _i_nbox   _*_ north star check
 doc panel:  _d_ toggle  _o_pen  _v_ reopen  _D_ remove
"
  ("n" cc-butler-next)
  ("p" cc-butler-prev)
  ("RET" cc-butler-visit)
  ("SPC" cc-butler-preview)
  ("g" cc-butler-refresh)
  ("c" cc-butler-new-session)
  ("N" cc-butler-new-topic)
  ("K" cc-butler-close-topic)
  ("h" cc-butler-doctor)
  ("l" cc-butler-show-log)
  ("B" cc-butler-start-butler)
  ("S" cc-butler-start-steward)
  ("b" cc-butler-set-butler)
  ("i" cc-butler-inbox)
  ("*" cc-butler-north-star-check)
  ("d" cc-butler-doc-toggle)
  ("o" cc-butler-doc-open)
  ("v" cc-butler-doc-reopen)
  ("D" cc-butler-doc-remove)
  ("q" cc-butler-quit)
  ("?" nil "cancel"))

(define-key cc-butler-mode-map "?" #'cc-butler-session-hydra/body)

(defconst cc-butler--modules
  '(cc-butler-session cc-butler-notifications cc-butler-workspace
    cc-butler-orchestrator cc-butler-mcp-resilience
    cc-butler-doc-panel cc-butler-docs cc-butler-persist
    cc-butler-mail cc-butler-decision cc-butler-inbox cc-butler-governance
    cc-butler-provenance cc-butler-cleanup cc-butler-compact
    cc-butler-north-star)
  "cc-butler modules, in dependency order.")

(defconst cc-butler--dir
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Directory holding the cc-butler source files.")

;;;; ------------------------------------------------------------------
;;;; Which copy is this?  One place decides.
;;;;
;;;; cc-butler can exist twice on one machine: the package-installed copy
;;;; most users run, and a development checkout its author edits.  When both
;;;; are on the `load-path' the winner is decided by list order — invisibly,
;;;; and wrongly as often as not.  That went unnoticed here for 19 days, and
;;;; the test runner had already had to fix its own version of it (see the
;;;; load-path comment in tests/run-tests.el, 2026-07-22).  Neither was a
;;;; discipline failure: the state was simply not visible anywhere.
;;;;
;;;; So: keep both copies, make the default reliable, and require a switch
;;;; between them to be deliberate and visible.
;;;; ------------------------------------------------------------------

(declare-function package-get-descriptor "package" (pkg-name))
(declare-function package-desc-dir "package" (cl-x))

(defvar cc-butler--source-override nil
  "Directory to load cc-butler from, or nil to use where it loaded from.
Set this only through `cc-butler-use-checkout' / `cc-butler-use-installed',
which validate the target first.

A `defvar' on purpose.  `cc-butler-reload' re-reads cc-butler.el FIRST, so a
`defconst' — or a top-level `setq' — would reset this midway through a
switch and bounce the source straight back to the copy being switched away
from, while reporting success.  It is also deliberately not a `defcustom':
persisting the choice through Custom is how the last one hid for 19 days.")

(defun cc-butler-source-dir ()
  "The directory cc-butler loads from.
An explicit override if one is set, otherwise wherever this file was loaded
from.  This is the single place that decides which copy is in play, so there
is no second answer to disagree with it."
  (or cc-butler--source-override cc-butler--dir))

(defun cc-butler--installed-dir ()
  "Directory of the package-installed cc-butler, or nil if it is not installed."
  (when (fboundp 'package-get-descriptor)
    (let* ((desc (ignore-errors (package-get-descriptor 'cc-butler)))
           (dir (and desc (package-desc-dir desc))))
      (and (stringp dir) (file-name-as-directory dir)))))

(defun cc-butler--missing-sources (dir)
  "Names of the cc-butler source files DIR does not have.
Nil means DIR can serve as a source.  Anything else names what is actually
wrong, which is usually a module added since that copy was last updated —
more use than a bare \"not a cc-butler directory\"."
  (let (out)
    (dolist (m (cons 'cc-butler cc-butler--modules))
      (let ((f (concat (symbol-name m) ".el")))
        (unless (file-readable-p (expand-file-name f dir))
          (push f out))))
    (nreverse out)))

(defun cc-butler--git (dir &rest args)
  "Run git with ARGS in DIR; return trimmed output, or nil if that failed.
Nil means \"cannot determine\" — not a git checkout, no git, or a git error.
Callers must not read it as \"up to date\"."
  (when (file-directory-p dir)
    (with-temp-buffer
      (let ((default-directory (file-name-as-directory dir)))
        (when (eq 0 (ignore-errors (apply #'process-file "git" nil t nil args)))
          (let ((s (string-trim (buffer-string))))
            (unless (string-empty-p s) s)))))))

(defun cc-butler--file-head-line (file &optional max)
  "First non-blank-trimmed line of FILE (up to MAX bytes, default 512), or nil.
A plain file read — no subprocess, nothing that can block on a lock."
  (when (file-readable-p file)
    (with-temp-buffer
      (insert-file-contents file nil 0 (or max 512))
      (goto-char (point-min))
      (let ((line (string-trim (buffer-substring (point) (line-end-position)))))
        (unless (string-empty-p line) line)))))

(defun cc-butler--git-dir (dir)
  "The git directory serving DIR, or nil.
`.git' is usually a directory, but in a linked worktree or submodule it is a
FILE containing \"gitdir: PATH\" — follow that one hop."
  (let ((dotgit (expand-file-name ".git" dir)))
    (cond
     ((file-directory-p dotgit) dotgit)
     ((file-regular-p dotgit)
      (let ((line (cc-butler--file-head-line dotgit 4096)))
        (when (and line (string-match "\\`gitdir:[ \t]*\\(.+\\)\\'" line))
          (let ((target (expand-file-name (match-string 1 line)
                                          (file-name-as-directory dir))))
            (and (file-directory-p target) target))))))))

(defun cc-butler--git-ref-hash (gitdir ref)
  "Hash REF points to, from GITDIR's loose ref file or packed-refs, or nil.
When GITDIR belongs to a linked worktree, refs live in the COMMON git dir —
named by GITDIR's `commondir' file — not in GITDIR itself."
  (let* ((commondir (expand-file-name "commondir" gitdir))
         (common (or (and (file-regular-p commondir)
                          (let ((rel (cc-butler--file-head-line commondir 4096)))
                            (and rel (expand-file-name rel gitdir))))
                     gitdir))
         (loose (cc-butler--file-head-line (expand-file-name ref common))))
    (if (and loose (string-match "\\`[0-9a-f]\\{40,\\}\\'" loose))
        loose
      (let ((packed (expand-file-name "packed-refs" common)))
        (when (file-readable-p packed)
          (with-temp-buffer
            (insert-file-contents packed)
            (goto-char (point-min))
            (when (re-search-forward
                   (concat "^\\([0-9a-f]\\{40,\\}\\)[ \t]+" (regexp-quote ref) "$")
                   nil t)
              (match-string 1))))))))

(defun cc-butler--git-head (dir)
  "Short description of DIR's git HEAD — \"abc1234 (main)\" — or nil.

Read straight from the repository files (.git/HEAD, the loose ref,
packed-refs) with plain file reads: NO subprocess, ever.  This runs inside a
synchronous MCP tool handler on the daemon's single Lisp thread, where
`shell-command-to-string' blocks in C with no timeout and `with-timeout'
cannot interrupt it (timers cannot fire inside a blocked C call) — so a
wedged .git/index.lock or a stalled filesystem would freeze every fleet
session's terminal and every other MCP call at once.  Reading refs never
takes the index lock and cannot wait on one.

Nil means \"cannot determine\" — not a repo, unreadable, an odd state.
Callers must degrade (drop the line, show nothing), never probe harder."
  (ignore-errors
    (let ((gitdir (cc-butler--git-dir dir)))
      (when gitdir
        (let ((head (cc-butler--file-head-line (expand-file-name "HEAD" gitdir))))
          (cond
           ((null head) nil)
           ;; On a branch: HEAD is a symbolic ref.
           ((string-match "\\`ref:[ \t]*\\(refs/[^ \t]+\\)\\'" head)
            (let* ((ref (match-string 1 head))
                   (hash (cc-butler--git-ref-hash gitdir ref)))
              (when hash
                (format "%s (%s)" (substring hash 0 7)
                        (if (string-prefix-p "refs/heads/" ref)
                            (substring ref (length "refs/heads/"))
                          ref)))))
           ;; Detached: HEAD is the hash itself (40 hex, or 64 under sha256).
           ((string-match "\\`[0-9a-f]\\{40,\\}\\'" head)
            (format "%s (detached)" (substring head 0 7)))))))))

(defun cc-butler--source-revision (dir)
  "One-line description of the commit DIR is on, or nil if not determinable.
The only trustworthy version signal for a source directory: the `Version:'
header is identical in both copies, and a `-pkg.el' `:commit' goes stale
without warning (one was found 32 commits behind its own checkout)."
  (cc-butler--git dir "log" "--oneline" "-1"))

(defun cc-butler--source-behind (dir)
  "How many commits DIR is behind its `origin/main', or nil if not determinable.
Compares against the last-fetched `origin/main' and deliberately does NOT
fetch — this runs on every session launch and must not reach the network.
That makes it under-report when the remote-tracking ref is itself stale,
which is the safe direction: a non-zero answer is always real drift."
  (let ((n (cc-butler--git dir "rev-list" "--count" "HEAD..origin/main")))
    (when (and n (string-match-p "\\`[0-9]+\\'" n))
      (let ((v (string-to-number n)))
        (and (> v 0) v)))))

(defun cc-butler--source-diagnostics ()
  "Report the loaded source when it is not the plain installed copy, and any
drift, as a `cc-butler--launch-preflight-diagnostics' list.

Returns nil in the ordinary case — running the installed package, up to date
— because a warning that fires on every launch is one people stop reading.

Both entries carry the path and the revision.  \"You are on a checkout\" on
its own still leaves the reader to work out which checkout, and that lookup
is exactly the step nobody takes."
  (let* ((dir (cc-butler-source-dir))
         (installed (cc-butler--installed-dir))
         (rev (cc-butler--source-revision dir))
         (behind (cc-butler--source-behind dir))
         (where (format "%s%s" dir (if rev (format " (%s)" rev) "")))
         problems)
    (cond
     (cc-butler--source-override
      (push (cons 'warn
                  (format "cc-butler was deliberately switched to %s. This is not the installed package; `cc-butler-use-installed' switches back, and it resets on Emacs restart."
                          where))
            problems))
     ((and installed (not (equal dir installed)))
      (push (cons 'warn
                  (format "cc-butler is loading from %s, NOT the installed package at %s. Nothing chose this — it is whichever copy the `load-path' reached first, so the code running is not necessarily the code you installed. Make it deliberate with `cc-butler-use-checkout' / `cc-butler-use-installed'."
                          where installed))
            problems)))
    (when behind
      (push (cons 'warn
                  (format "cc-butler's source at %s is %d commits behind origin/main. Compared against the last-fetched ref without fetching, so the real gap can be larger — never smaller. `git pull` there, then `cc-butler-reload'."
                          where behind))
            problems))
    (nreverse problems)))

(defun cc-butler--switch-source (dir label)
  "Point cc-butler at DIR, reload, and say where it now loads from.
Validation happens BEFORE the override moves: a rejected switch leaves a
working control plane, rather than one whose next reload cannot find its own
modules."
  (let* ((dir (file-name-as-directory (expand-file-name dir)))
         (missing (cc-butler--missing-sources dir)))
    (when missing
      ;; No cc-butler.el means the caller named the wrong place; listing all
      ;; fifteen absent modules would bury that. Missing modules WITH a
      ;; cc-butler.el present means a real but outdated clone, and there the
      ;; file names are the entire diagnosis.
      (if (member "cc-butler.el" missing)
          (user-error "%s is not a cc-butler source tree (no cc-butler.el)" dir)
        (user-error "Incomplete cc-butler source tree: %s has no %s — most likely a clone predating those modules; `git pull' there first"
                    dir (string-join missing ", "))))
    (setq cc-butler--source-override dir)
    (let ((res (cc-butler-reload))
          (rev (cc-butler--source-revision dir)))
      (message "cc-butler: now loading from the %s at %s (%d modules)%s"
               label dir (plist-get res :count)
               (if rev (format " — %s" rev) ""))
      res)))

;;;###autoload
(defun cc-butler-use-checkout (dir)
  "Load cc-butler from the development checkout DIR from now on, and reload.
Deliberate and per-session: this does not persist, so a restarted Emacs is
back on whatever it installs — a development copy can never become the
default by forgetting.  `cc-butler-use-installed' switches back."
  (interactive "DLoad cc-butler from checkout: ")
  (cc-butler--switch-source dir "checkout"))

;;;###autoload
(defun cc-butler-use-installed ()
  "Load cc-butler from the package-installed copy from now on, and reload.
The way back from `cc-butler-use-checkout'."
  (interactive)
  (let ((dir (cc-butler--installed-dir)))
    (unless dir
      (user-error "cc-butler is not installed as a package — nothing to switch to; name a directory with `cc-butler-use-checkout' instead"))
    (cc-butler--switch-source dir "installed package")))

(defun cc-butler--stale-elc ()
  "Return names of .elc files in `cc-butler--dir' older than their .el source.
`load' prefers a .elc, so a stale one silently wins on the next Emacs start
and quietly undoes whatever a reload just did."
  (let (out)
    (dolist (elc (ignore-errors (directory-files (cc-butler-source-dir) t "\\.elc\\'")))
      (let ((el (concat (file-name-sans-extension elc) ".el")))
        (when (and (file-exists-p el) (file-newer-than-file-p el elc))
          (push (file-name-nondirectory elc) out))))
    (nreverse out)))

;;;###autoload
(defun cc-butler-reload ()
  "Cleanly reload all cc-butler modules in dependency order — the hot-load
teardown hygiene: reload WHOLE modules from source (so redefinitions replace
cleanly), not stray defuns that can leave old keymaps/hooks/modes layered
underneath.  Loads by absolute path (not the load-path).  Never restarts Emacs
\(the worker sessions are preserved).

Reloads THIS file first.  `cc-butler--modules' and `cc-butler--dir' are
defined here, so a reload driven by the old values cannot pick up a module
that was added since this Emacs started — it would silently skip the new
file and report success.  That happened on 2026-07-23 with
`cc-butler-compact'.  Re-reading this file first makes the module list
current before it is used.

Loads from `cc-butler-source-dir' — where this file came from, unless
`cc-butler-use-checkout' / `cc-butler-use-installed' deliberately pointed it
elsewhere.

Returns a plist describing what happened, for `cc-butler-tool-reload-code'."
  (interactive)
  (let ((self (expand-file-name "cc-butler.el" (cc-butler-source-dir))))
    (when (file-exists-p self) (load self nil t)))
  ;; Re-read the source directory AFTER the self-load: that load is what makes
  ;; `cc-butler--modules' and `cc-butler--dir' current, and an override set by
  ;; `cc-butler--switch-source' has to be the thing the modules follow.
  (dolist (m cc-butler--modules)
    (load (expand-file-name (concat (symbol-name m) ".el") (cc-butler-source-dir)) nil t))
  (let ((stale (cc-butler--stale-elc))
        (dir (cc-butler-source-dir)))
    (when (called-interactively-p 'interactive)
      (message "cc-butler: reloaded %d modules from %s%s"
               (length cc-butler--modules) dir
               (if stale (format " — WARNING: %d stale .elc" (length stale)) "")))
    (list :count (length cc-butler--modules) :dir dir :stale stale)))

;;;; ------------------------------------------------------------------
;;;; MCP tool: hot-reload the control plane from disk
;;;; ------------------------------------------------------------------

(defun cc-butler-tool-reload-code ()
  "MCP tool: reload cc-butler from disk, and report what was actually loaded.

Reloading swaps CODE in a live Emacs.  It does not touch any session's
conversation, and a 514k-token session is still 514k afterwards — that is
the whole point of preserving sessions.  Reload and compaction are
orthogonal: `cc-butler-compact-session' is the only thing here that reduces
a context, and nothing in this path is a substitute for it."
  (let* ((res (cc-butler-reload))
         (dir (plist-get res :dir))
         (stale (plist-get res :stale))
         ;; File reads only — `shell-command-to-string' here once put the
         ;; whole daemon one wedged .git/index.lock away from a total freeze
         ;; (single Lisp thread, no timeout, `with-timeout' can't interrupt
         ;; a blocked C call).  See `cc-butler--git-head'.
         (head (ignore-errors (cc-butler--git-head dir))))
    (concat
     (format "Reloaded %d cc-butler modules from %s" (plist-get res :count) dir)
     (if head (format "\nSource is at: %s" head) "")
     "\n\nThis loads whatever is ON DISK in that directory — it does not fetch. If you expected newer code, `git pull` there first and call this again. Note that directory is the one this Emacs actually loads from, which is not necessarily the checkout you have been editing."
     (if stale
         (format "\n\n⚠ STALE BYTE-CODE: %s are older than their .el source. Emacs prefers .elc on startup, so these will silently undo this reload the next time Emacs restarts. Delete them (or byte-recompile) in %s."
                 (string-join stale ", ") dir)
       "")
     ;; Same reason the stale .elc is spelled out: this caller cannot look at
     ;; the filesystem, and "which copy did I just reload, and is it behind"
     ;; is the question it is least able to answer for itself.
     (let ((src (ignore-errors (cc-butler--source-diagnostics))))
       (if src
           (concat "\n\n⚠ SOURCE: "
                   (mapconcat #'cdr src "\n\n⚠ SOURCE: "))
         ""))
     "\n\nAlready-running sessions keep the MCP tool list they fetched at connect time; a human reconnecting from that session's /mcp panel picks up newly registered tools without a restart.")))

;; Idempotent registration.
(when (fboundp 'claude-code-ide-make-tool)
  (setq claude-code-ide-mcp-server-tools
        (seq-remove
         (lambda (spec)
           (member (plist-get (claude-code-ide--normalize-tool-spec spec) :name)
                   '("reload_butler_code")))
         claude-code-ide-mcp-server-tools))
  (claude-code-ide-make-tool
   :function #'cc-butler-tool-reload-code
   :name "reload_butler_code"
   :description "Hot-reload the cc-butler control plane from disk after its SOURCE CODE changed — new tools, fixes, new modules — without restarting Emacs and without losing any session. Reloads every module in dependency order, including this file first so a newly added module is not skipped. It loads what is on disk and does NOT git pull, so pull first if you want newer code; it reports the source directory and its git HEAD so you can tell what you actually got. This changes CODE ONLY and has no effect whatsoever on any session's context size — it is not a way to shrink a large session and is unrelated to compaction; use compact_session for that."
   :args nil))

(provide 'cc-butler)
;;; cc-butler.el ends here
