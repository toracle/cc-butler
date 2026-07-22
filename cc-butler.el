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
 _B_utler   _S_teward   _b_ set butler   _i_nbox
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
  ("d" cc-butler-doc-toggle)
  ("o" cc-butler-doc-open)
  ("v" cc-butler-doc-reopen)
  ("D" cc-butler-doc-remove)
  ("q" cc-butler-quit)
  ("?" nil "cancel"))

(define-key cc-butler-mode-map "?" #'cc-butler-session-hydra/body)

(defconst cc-butler--modules
  '(cc-butler-session cc-butler-notifications cc-butler-workspace
    cc-butler-orchestrator cc-butler-doc-panel cc-butler-docs cc-butler-persist
    cc-butler-mail cc-butler-decision cc-butler-inbox cc-butler-governance
    cc-butler-provenance cc-butler-cleanup cc-butler-compact)
  "cc-butler modules, in dependency order.")

(defconst cc-butler--dir
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Directory holding the cc-butler source files.")

(defun cc-butler--stale-elc ()
  "Return names of .elc files in `cc-butler--dir' older than their .el source.
`load' prefers a .elc, so a stale one silently wins on the next Emacs start
and quietly undoes whatever a reload just did."
  (let (out)
    (dolist (elc (ignore-errors (directory-files cc-butler--dir t "\\.elc\\'")))
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

Returns a plist describing what happened, for `cc-butler-tool-reload-code'."
  (interactive)
  (let ((self (expand-file-name "cc-butler.el" cc-butler--dir)))
    (when (file-exists-p self) (load self nil t)))
  (dolist (m cc-butler--modules)
    (load (expand-file-name (concat (symbol-name m) ".el") cc-butler--dir) nil t))
  (let ((stale (cc-butler--stale-elc)))
    (when (called-interactively-p 'interactive)
      (message "cc-butler: reloaded %d modules from %s%s"
               (length cc-butler--modules) cc-butler--dir
               (if stale (format " — WARNING: %d stale .elc" (length stale)) "")))
    (list :count (length cc-butler--modules) :dir cc-butler--dir :stale stale)))

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
         (head (string-trim
                (or (ignore-errors
                      (let ((default-directory dir))
                        (shell-command-to-string "git log --oneline -1 2>/dev/null")))
                    ""))))
    (concat
     (format "Reloaded %d cc-butler modules from %s" (plist-get res :count) dir)
     (if (string-empty-p head) "" (format "\nSource is at: %s" head))
     "\n\nThis loads whatever is ON DISK in that directory — it does not fetch. If you expected newer code, `git pull` there first and call this again. Note that directory is the one this Emacs actually loads from, which is not necessarily the checkout you have been editing."
     (if stale
         (format "\n\n⚠ STALE BYTE-CODE: %s are older than their .el source. Emacs prefers .elc on startup, so these will silently undo this reload the next time Emacs restarts. Delete them (or byte-recompile) in %s."
                 (string-join stale ", ") dir)
       "")
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
