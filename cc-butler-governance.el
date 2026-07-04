;;; cc-butler-governance.el --- runtime-neutral operating-principles store  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jeongsoo Park
;; SPDX-License-Identifier: MIT

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

(defcustom cc-butler-governance-user-dir nil
  "A PRIVATE directory of your OWN principle .md files — custom operational
content (private examples, org-specific principles) NOT shipped in the package.
Merged after the built-in generic principles by `cc-butler-governance-principles';
a same-basename file in your dir OVERRIDES the built-in of that name.

This is the governance analog of `cc-butler-define-project-template' for
workspaces: the package ships generic BUILT-IN principles, and you add your
private, user-custom layer here — the two-tier design 정수님 asked for."
  :type '(choice (const :tag "None" nil) directory)
  :group 'cc-butler)

(defcustom cc-butler-governance-memory-dir
  (expand-file-name "~/.claude/projects/-home-toracle--ccsm/memory/")
  "The Claude Code memory dir — a GENERATED cache of the store (never hand-edited)."
  :type 'directory
  :group 'cc-butler)

(defun cc-butler--governance-dir-principles (dir)
  "Principle .md files in DIR (absolute paths), excluding README; nil if no DIR."
  (and dir (file-directory-p dir)
       (seq-remove (lambda (f) (equal (file-name-nondirectory f) "README.md"))
                   (ignore-errors (directory-files dir t "\\`[^.].*\\.md\\'")))))

(defun cc-butler-governance-principles ()
  "The BUILT-IN generic principles, plus your private user layer when
`cc-butler-governance-user-dir' is set.  A user file with the same basename
overrides the built-in of that name, so you can specialize a built-in privately."
  (let ((by-name (make-hash-table :test 'equal)))
    (dolist (f (cc-butler--governance-dir-principles cc-butler-governance-dir))
      (puthash (file-name-nondirectory f) f by-name))
    (dolist (f (cc-butler--governance-dir-principles cc-butler-governance-user-dir))
      (puthash (file-name-nondirectory f) f by-name))  ; user overrides built-in
    (sort (hash-table-values by-name)
          (lambda (a b) (string< (file-name-nondirectory a)
                                 (file-name-nondirectory b))))))

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
