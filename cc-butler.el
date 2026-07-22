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

;;;###autoload
(defun cc-butler-reload ()
  "Cleanly reload all cc-butler modules in dependency order — the hot-load
teardown hygiene: reload WHOLE modules from source (so redefinitions replace
cleanly), not stray defuns that can leave old keymaps/hooks/modes layered
underneath.  Loads by absolute path (not the load-path).  Never restarts Emacs
(the worker sessions are preserved)."
  (interactive)
  (dolist (m cc-butler--modules)
    (load (expand-file-name (concat (symbol-name m) ".el") cc-butler--dir) nil t))
  (message "cc-butler: reloaded %d modules" (length cc-butler--modules)))

(provide 'cc-butler)
;;; cc-butler.el ends here
