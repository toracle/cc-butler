;;; cc-butler-governance.el --- runtime-neutral operating-principles store  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jeongsoo Park
;; SPDX-License-Identifier: MIT

;; The butler/steward operating principles live in a repo-owned, runtime-neutral
;; store (governance/, one file per principle) — the single source of truth.
;; Runtime files (Claude Code role CLAUDE.md + memory notes, a future Codex
;; AGENTS.md) are GENERATED caches of it: edit the store + regenerate → every
;; adapter updates.  See docs/cc-butler-governance-store-sdd.md.

(require 'subr-x)

(defconst cc-butler-governance--load-dir
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Directory of the `cc-butler-governance.el' that is CURRENTLY loaded.

`defconst' is the point: it re-evaluates on every load, so a hot reload from
a different checkout carries this with the code.  A `defcustom' default does
NOT — it binds once, at the first definition, and then survives every
subsequent reload.  That is how the store came to point at a stale
installation while the code itself ran from somewhere else: principles were
written to one checkout and read from another, and on 2026-07-23 three
regenerations in a row reported success while landing nothing.")

(defcustom cc-butler-governance-dir nil
  "The runtime-neutral operating-principles store (one .md per principle).

Nil — the default — means DERIVE it from wherever the loaded
`cc-butler-governance.el' lives, so the store always follows the code
through a reload or a move between checkouts.  Set it only to point the
store somewhere genuinely different from the source tree; an explicit value
is always honoured.

Do not restore a computed default here.  A default that captures a path at
definition time is exactly the bug this replaced — read
`cc-butler-governance--load-dir'.  Ask for the effective path with
`cc-butler-governance-store', never by reading this variable directly."
  :type '(choice (const :tag "Beside the loaded code" nil) directory)
  :group 'cc-butler)

(defun cc-butler-governance-store ()
  "Absolute path of the operating-principles store actually in effect.
The single place the store location is decided, so a writer and a reader
cannot disagree about where it is."
  (file-name-as-directory
   (or cc-butler-governance-dir
       (expand-file-name "governance/" cc-butler-governance--load-dir))))

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
  (or (and (fboundp 'cc-butler--claude-memory-dir) (boundp 'cc-butler-home)
           (cc-butler--claude-memory-dir cc-butler-home))
      (expand-file-name "~/.claude/projects/-home-toracle--ccsm/memory/"))
  "The Claude Code memory dir — a GENERATED cache of the store (never
hand-edited). Derived from the butler home the same way
`cc-butler--shared-state-note' computes it, so it tracks
`cc-butler-home' instead of drifting to a stale hardcoded path if the
home ever moves; falls back to the historical ~/.ccsm path only if
`cc-butler--claude-memory-dir'/`cc-butler-home' aren't loaded yet."
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
    (dolist (f (cc-butler--governance-dir-principles (cc-butler-governance-store)))
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

;;;; ------------------------------------------------------------------
;;;; Recording a principle
;;;; ------------------------------------------------------------------

;; The store is written through here rather than by hand.  On 2026-07-23 the
;; butler hand-wrote principle files into one checkout and regenerated from
;; another; `cc-butler-governance-regenerate' answered "regenerated" three
;; times and not one of those principles reached the generated memory.  Two
;; things went wrong and only the second one is really dangerous: the writer
;; and the reader disagreed about where the store was, and the failure
;; reported itself as a success.  So: one function decides the path for both
;; sides (`cc-butler-governance-store'), and nothing here returns success
;; without first reading the generated note back off disk.

(defconst cc-butler-governance--name-prefix "butler-"
  "Prefix the store's frontmatter `name:' and the generated note both carry.")

(defun cc-butler-governance--slug (name)
  "Return the store basename for NAME, or signal if it is unusable.
Accepts a name with or without the `butler-' prefix, since the frontmatter
carries the prefix and the filename does not — a distinction no caller
should have to remember."
  (let* ((s (string-trim (or name "")))
         (s (replace-regexp-in-string "\\.md\\'" "" s))
         (s (replace-regexp-in-string
             (concat "\\`" (regexp-quote cc-butler-governance--name-prefix)) "" s))
         (s (downcase (replace-regexp-in-string "[ _]+" "-" s))))
    (unless (string-match-p "\\`[a-z0-9][a-z0-9-]*\\'" s)
      (user-error "Bad principle name %S: use a kebab-case slug like `verify-delivery'" name))
    s))

(defun cc-butler-governance-names ()
  "Slugs of the principles currently in the store, sorted."
  (mapcar (lambda (f) (file-name-sans-extension (file-name-nondirectory f)))
          (cc-butler-governance-principles)))

(defun cc-butler-governance--memory-note (slug)
  "Absolute path of the generated memory note for SLUG."
  (expand-file-name (concat cc-butler-governance--name-prefix slug ".md")
                    cc-butler-governance-memory-dir))

(defun cc-butler-governance--note-count ()
  "How many generated notes are in the memory dir right now."
  (length (ignore-errors
            (directory-files cc-butler-governance-memory-dir nil "\\`[^.].*\\.md\\'"))))

(defun cc-butler-governance--render (slug description body type)
  "The full file text for a principle, frontmatter included.
Written here rather than by the caller so the schema cannot be got wrong —
`name:' matching the generated note, the quoting of DESCRIPTION, and the
`metadata:' block are all things a caller would have to know and would
eventually get subtly wrong."
  (concat "---\n"
          "name: " cc-butler-governance--name-prefix slug "\n"
          "description: \""
          (replace-regexp-in-string "\"" "'" (string-trim (or description ""))) "\"\n"
          "metadata:\n"
          "  node_type: memory\n"
          "  type: " (or type "feedback") "\n"
          "---\n\n"
          (string-trim (or body "")) "\n"))

;;;###autoload
(defun cc-butler-governance-record (name description body &optional type)
  "Write a principle into the store, regenerate, and PROVE it landed.

Returns a plist: :slug :path :existed :before :after :verified :names.
:verified is non-nil only when the generated note was read back off disk and
actually names this principle — the check whose absence let three silent
failures pass for successes.

An existing NAME is overwritten in place.  Correcting a principle is the
normal case; a near-duplicate under a new name is how a store stops being a
source of truth."
  (let* ((slug (cc-butler-governance--slug name))
         (store (cc-butler-governance-store))
         (path (expand-file-name (concat slug ".md") store))
         (existed (file-exists-p path))
         (before (cc-butler-governance--note-count)))
    (when (string-empty-p (string-trim (or body "")))
      (user-error "Refusing to record an empty principle: %s" slug))
    (make-directory store t)
    (with-temp-file path
      (insert (cc-butler-governance--render slug description body type)))
    (cc-butler-governance-regenerate)
    (let* ((note (cc-butler-governance--memory-note slug))
           (verified (and (file-readable-p note)
                          (with-temp-buffer
                            (insert-file-contents note)
                            (goto-char (point-min))
                            (search-forward
                             (concat "name: " cc-butler-governance--name-prefix slug)
                             nil t))
                          note)))
      (list :slug slug :path path :existed existed
            :before before :after (cc-butler-governance--note-count)
            :verified verified :note note :store store
            :names (cc-butler-governance-names)))))

(defun cc-butler-tool-record-principle (name description body &optional type)
  "MCP tool: record an operating principle and report where it landed."
  (let* ((res (cc-butler-governance-record name description body type))
         (verified (plist-get res :verified)))
    (concat
     (if verified
         (format "Recorded principle `%s` (%s).\n"
                 (plist-get res :slug)
                 (if (plist-get res :existed) "updated in place" "new"))
       (format "FAILED to record `%s` — the principle was written but does NOT appear in the generated memory.\n"
               (plist-get res :slug)))
     (format "\nStore file : %s\nMemory note: %s\nNotes       : %d -> %d\nVerified    : %s\n"
             (plist-get res :path)
             (plist-get res :note)
             (plist-get res :before) (plist-get res :after)
             (if verified "yes — read back off disk and it names this principle"
               "NO — the note is missing or does not name this principle"))
     (if verified
         ""
       (format "\nDo not treat this as recorded. The store being written (%s) and the memory being generated (%s) are the two paths to compare — a write landing in a store nobody regenerates from is what this check exists to catch.\n"
               (plist-get res :store) cc-butler-governance-memory-dir))
     (format "\nPrinciples now in the store (%d): %s\n"
             (length (plist-get res :names))
             (string-join (plist-get res :names) ", "))
     "\nTo revise one of these, call this again with that same name — it is overwritten in place.")))

;; Idempotent registration.
(when (fboundp 'claude-code-ide-make-tool)
  (setq claude-code-ide-mcp-server-tools
        (seq-remove
         (lambda (spec)
           (member (plist-get (claude-code-ide--normalize-tool-spec spec) :name)
                   '("record_principle")))
         claude-code-ide-mcp-server-tools))
  (claude-code-ide-make-tool
   :function #'cc-butler-tool-record-principle
   :name "record_principle"
   :description "Record a butler/steward operating principle into the governance store and regenerate the Claude Code memory from it. Writes the frontmatter for you (name/description/metadata) so the schema cannot be got wrong, and takes NO path argument — it writes to exactly the store the regenerator reads, which is the whole point. Calling it with the name of an existing principle UPDATES that principle in place; revise rather than accumulating near-duplicates. Returns the absolute file written, the note count before and after, and whether the generated note was read back off disk and confirmed to name this principle — if that verification fails it reports failure, because a regeneration reporting success while landing nothing is a real thing that has happened here."
   :args '((:name "name" :type "string" :required t
            :description "Kebab-case slug for the principle, e.g. verify-delivery. Naming an existing principle updates it in place. The butler- prefix is added for you.")
           (:name "description" :type "string" :required t
            :description "One-line summary, used to decide relevance during recall. Write it so a reader can tell whether this principle applies without opening it.")
           (:name "body" :type "string" :required t
            :description "The principle itself, in Markdown. Follow the store's shape: what the rule is, then **Why:** with the concrete incident that motivated it, then **How to apply:**.")
           (:name "type" :type "string" :required nil
            :description "Frontmatter metadata type. Defaults to feedback, which is what every principle in the store currently uses."))))

(provide 'cc-butler-governance)
;;; cc-butler-governance.el ends here
