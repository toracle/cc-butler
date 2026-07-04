;;; cc-butler-governance.el --- runtime-neutral operating-principles store  -*- lexical-binding: t; -*-

;; The butler/steward operating principles live in a repo-owned, runtime-neutral
;; store (governance/, one file per principle) — the single source of truth.
;; Runtime files (Claude Code role CLAUDE.md + memory notes, a future Codex
;; AGENTS.md) are GENERATED caches of it: edit the store + regenerate → every
;; adapter updates.  See docs/cc-butler-governance-store-sdd.md.

(require 'subr-x)

(defcustom cc-butler-governance-dir
  (expand-file-name "governance/"
                    (file-name-directory (or load-file-name buffer-file-name default-directory)))
  "The runtime-neutral operating-principles store (one .md per principle)."
  :type 'directory
  :group 'cc-butler)

(defcustom cc-butler-governance-memory-dir
  (expand-file-name "~/.claude/projects/-home-toracle--ccsm/memory/")
  "The Claude Code memory dir — a GENERATED cache of the store (never hand-edited)."
  :type 'directory
  :group 'cc-butler)

(defun cc-butler-governance-principles ()
  "Return the store's principle files (absolute paths)."
  (ignore-errors
    (directory-files cc-butler-governance-dir t "\\`[^.].*\\.md\\'")))

;;;###autoload
(defun cc-butler-governance-regenerate ()
  "Regenerate the Claude Code memory cache from the neutral store — the store is
the source of truth; the memory is derived.  Returns the count written."
  (interactive)
  (make-directory cc-butler-governance-memory-dir t)
  (let ((n 0))
    (dolist (f (cc-butler-governance-principles))
      (copy-file f (expand-file-name (concat "butler-" (file-name-nondirectory f))
                                     cc-butler-governance-memory-dir)
                 t)
      (setq n (1+ n)))
    (when (called-interactively-p 'interactive)
      (message "cc-butler: regenerated %d principle(s) from the store" n))
    n))

(provide 'cc-butler-governance)
;;; cc-butler-governance.el ends here
