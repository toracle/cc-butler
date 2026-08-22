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

(defun cc-butler-governance--memory-index-file ()
  "Absolute path of `MEMORY.md' — the hand-maintained index every session
actually loads.  A note's body can be regenerated perfectly and still never be
recalled if this file has no line pointing at it (cc-butler#36)."
  (expand-file-name "MEMORY.md" cc-butler-governance-memory-dir))

(defun cc-butler-governance--frontmatter-description (path)
  "PATH's frontmatter `description:' value, or nil if unreadable/absent."
  (when (file-readable-p path)
    (with-temp-buffer
      (insert-file-contents path)
      (goto-char (point-min))
      (let ((frontmatter-end (save-excursion
                               (forward-line 1)
                               (and (re-search-forward "^---$" nil t) (point)))))
        (when (and frontmatter-end
                   (re-search-forward "^description: \"\\(.*\\)\"$" frontmatter-end t))
          (match-string 1))))))

(defun cc-butler-governance--index-line (slug)
  "Render the `MEMORY.md' line for SLUG, using the note's own description."
  (let* ((note (expand-file-name (concat "butler-" slug ".md")
                                 cc-butler-governance-memory-dir))
         (desc (or (cc-butler-governance--frontmatter-description note)
                   "(no description in store)")))
    (format "- [%s](butler-%s.md) — %s\n" slug slug desc)))

(defun cc-butler-governance--index-has-slug-p (index slug)
  "Non-nil when INDEX (a file that may not exist yet) already links SLUG's note."
  (and (file-readable-p index)
       (with-temp-buffer
         (insert-file-contents index)
         (goto-char (point-min))
         (search-forward (format "(butler-%s.md)" slug) nil t))))

(defun cc-butler-governance--sync-index (slugs)
  "Add-only merge of SLUGS into `MEMORY.md': append a line for any slug that
has none yet; never touch or remove an existing line.

`MEMORY.md' is hand-maintained and carries entries this store does not own
(steward notes, unrelated links) — overwriting it wholesale, the way note
bodies are overwritten, would be data loss rather than a refresh.  That
asymmetry is deliberate: bodies are fully generated and safe to replace in
full; the index is partly human-authored and is not.  Returns the slugs
actually appended."
  (let* ((index (cc-butler-governance--memory-index-file))
         (missing (seq-remove
                   (lambda (slug) (cc-butler-governance--index-has-slug-p index slug))
                   slugs)))
    (when missing
      (with-temp-buffer
        (when (file-readable-p index) (insert-file-contents index))
        (goto-char (point-max))
        (unless (or (bobp) (bolp)) (insert "\n"))
        (dolist (slug missing) (insert (cc-butler-governance--index-line slug)))
        (write-region (point-min) (point-max) index nil 'quiet)))
    missing))

;;;###autoload
(defun cc-butler-governance-regenerate ()
  "Regenerate the Claude Code memory cache from the neutral store — the store is
the source of truth; the memory is derived.  Also syncs `MEMORY.md's index
against it in both directions: merges in any note missing from the index
(add-only — see `cc-butler-governance--sync-index'), and prunes any index
line whose principle no longer exists in the store (see
`cc-butler-governance--prune-dead-entries').  Returns the count of
principles written."
  (interactive)
  (make-directory cc-butler-governance-memory-dir t)
  (let ((n 0) (slugs nil))
    (dolist (f (cc-butler-governance-principles))
      (copy-file f (expand-file-name (concat "butler-" (file-name-nondirectory f))
                                     cc-butler-governance-memory-dir)
                 t)
      (push (file-name-sans-extension (file-name-nondirectory f)) slugs)
      (setq n (1+ n)))
    (cc-butler-governance--sync-index (nreverse slugs))
    (cc-butler-governance--prune-dead-entries)
    (when (called-interactively-p 'interactive)
      (message "cc-butler: regenerated %d principle(s) from the store" n))
    n))

(defun cc-butler-governance--index-butler-slugs (text)
  "Slugs of every line in TEXT shaped like this store's own generated entry:
`- [S](butler-S.md) — ...'.  Anything hand-authored in a different shape
(a different link target, or a slug that doesn't match on both sides) is
never returned — this is deliberately narrow, so pruning below can never
touch a line this store did not itself write."
  (let (slugs (start 0))
    (while (string-match "^- \\[\\([a-z0-9][a-z0-9-]*\\)\\](butler-\\1\\.md) — "
                         text start)
      (push (match-string 1 text) slugs)
      (setq start (match-end 0)))
    (nreverse slugs)))

(defun cc-butler-governance--dead-index-slugs ()
  "Index slugs (this store's own generated lines only) whose store principle
no longer exists.  This is the index -> store direction: a note that was
deleted or renamed out of the store leaves its `MEMORY.md' line dangling,
and the add-only `--sync-index' merge has no reason to ever look at it
again since it already has a line.  Read-only — see
`cc-butler-governance--prune-dead-entries' for the mutating half."
  (let ((index (cc-butler-governance--memory-index-file)))
    (when (file-readable-p index)
      (let* ((text (with-temp-buffer (insert-file-contents index) (buffer-string)))
             (indexed (cc-butler-governance--index-butler-slugs text))
             (live (cc-butler-governance-names)))
        (seq-remove (lambda (s) (member s live)) indexed)))))

(defun cc-butler-governance--prune-dead-entries ()
  "Remove every `MEMORY.md' line `cc-butler-governance--dead-index-slugs'
currently reports dead.  Only ever removes lines matching this store's own
generated shape (see `cc-butler-governance--index-butler-slugs') — a
hand-authored entry in any other shape is never touched, dead-looking link
or not.  Deletion, not merely reporting, is deliberate here: unlike a
description (which might be hand-curated on purpose, see
`cc-butler-governance--stale-index-entries'), a link to a principle that no
longer exists in the store has no legitimate reading — the store is the
source of truth, so nothing is lost by removing a pointer to nothing.
Returns the removed slugs."
  (let ((dead (cc-butler-governance--dead-index-slugs))
        (index (cc-butler-governance--memory-index-file)))
    (when (and dead (file-readable-p index))
      (with-temp-buffer
        (insert-file-contents index)
        (goto-char (point-min))
        (while (re-search-forward
                "^- \\[\\([a-z0-9][a-z0-9-]*\\)\\](butler-\\1\\.md) — .*\n?" nil t)
          (when (member (match-string 1) dead)
            (delete-region (match-beginning 0) (match-end 0))))
        (write-region (point-min) (point-max) index nil 'quiet)))
    dead))

(defun cc-butler-governance--stale-index-entries ()
  "Slugs (this store's own generated lines only) whose `MEMORY.md'
description no longer matches the store note's CURRENT frontmatter
description.  Read-only and deliberately never auto-corrected: on disk, a
line that drifted because a principle was revised in place (record_principle
updates the store + memory note but `--sync-index' never touches an
existing line, by design) is indistinguishable from a line a human
hand-curated with different wording on purpose — see
`cc-butler-governance/regenerate-does-not-duplicate-an-already-curated-entry'.
So this only surfaces the mismatch for a human or agent to judge; the fix,
if wanted, is to call `record_principle' again or hand-edit the line."
  (let ((index (cc-butler-governance--memory-index-file))
        stale)
    (when (file-readable-p index)
      (with-temp-buffer
        (insert-file-contents index)
        (goto-char (point-min))
        (while (re-search-forward
                "^- \\[\\([a-z0-9][a-z0-9-]*\\)\\](butler-\\1\\.md) — \\(.*\\)$" nil t)
          (let* ((slug (match-string 1))
                 (indexed-desc (match-string 2))
                 (store-file (expand-file-name (concat slug ".md")
                                               (cc-butler-governance-store))))
            (when (file-exists-p store-file)
              (let ((current (cc-butler-governance--frontmatter-description store-file)))
                (when (and current (not (equal current indexed-desc)))
                  (push slug stale))))))))
    (nreverse stale)))

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

(defun cc-butler-governance--unindexed-names ()
  "Store slugs that currently have no `MEMORY.md' line.
Zero here means every store note is actually recallable; non-zero is the
gap this whole file exists to close (cc-butler#36) — safe to call any time,
not only right after a regenerate, so a forgotten sync still shows up."
  (let ((index (cc-butler-governance--memory-index-file)))
    (seq-remove (lambda (slug) (cc-butler-governance--index-has-slug-p index slug))
                (cc-butler-governance-names))))

(defun cc-butler-governance--memory-note (slug)
  "Absolute path of the generated memory note for SLUG."
  (expand-file-name (concat cc-butler-governance--name-prefix slug ".md")
                    cc-butler-governance-memory-dir))

(defun cc-butler-governance--note-count ()
  "How many generated notes (butler-*.md) are in the memory dir right now.
Matches only the `butler-' prefix regenerate writes, not every `.md' file in
the dir — `MEMORY.md' lives there too (cc-butler#36) and is not a note."
  (length (ignore-errors
            (directory-files cc-butler-governance-memory-dir nil "\\`butler-.*\\.md\\'"))))

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

(defun cc-butler-tool-regenerate-governance ()
  "MCP tool: bare-trigger governance regeneration, no arguments.

For the case `record_principle' doesn't cover: a note written straight to
the store with Write/Edit (its frontmatter controlled by hand, not via the
record tool). That write never calls regenerate itself, so the note can sit
in the store, fully valid, and never reach the cache or the MEMORY.md index
until something calls this. Call it once after any such direct write.

Also useful with nothing new to sync: it reports how many store notes are
CURRENTLY un-indexed, so running it any time surfaces a forgotten sync
instead of staying silent — the same silent-gap failure mode this file
exists to close (cc-butler#36).

REGRESSION (2026-08-05): this used to check store -> index only (missing
entries) and reported \"0 un-indexed\" as if the index were fully verified,
when a dangling link (index -> store: the principle was deleted) and a
stale description (content drift after an in-place update) both went
completely unchecked.  A check that reports itself as more thorough than
it is is worse than no check — it ends the search.  The report below now
states plainly what was actually verified, in three directions: store ->
index, index -> store, and description drift."
  (let* ((before (cc-butler-governance--unindexed-names))
         (dead-before (cc-butler-governance--dead-index-slugs))
         (n (cc-butler-governance-regenerate))
         (after (cc-butler-governance--unindexed-names))
         (dead-after (cc-butler-governance--dead-index-slugs))
         (stale (cc-butler-governance--stale-index-entries)))
    (concat
     (format "Regenerated %d principle(s) from the store.\n" n)
     "Checked: store->index (notes missing an index line), index->store (index lines whose principle no longer exists), and description drift (index text vs each note's current frontmatter).\n"
     (if before
         (format "Merged %d previously un-indexed note(s) into MEMORY.md: %s\n"
                 (length before) (string-join before ", "))
       "Nothing was missing from the index before this call.\n")
     (if after
         (format "STILL %d un-indexed after regenerating: %s — these notes are cached but will not be recalled by any session; investigate cc-butler-governance--sync-index.\n"
                 (length after) (string-join after ", "))
       "Store->index: 0 un-indexed notes remain.\n")
     (if dead-before
         (format "Removed %d dangling index link(s) whose principle no longer exists in the store: %s\n"
                 (length dead-before) (string-join dead-before ", "))
       "Index->store: 0 dangling links found.\n")
     (if dead-after
         (format "STILL %d dangling link(s) after pruning: %s — investigate cc-butler-governance--prune-dead-entries.\n"
                 (length dead-after) (string-join dead-after ", "))
       "")
     (if stale
         (format "%d indexed description(s) no longer match the store's current wording (left as-is — this may be deliberate curation rather than staleness, so it is reported, not auto-edited; review and re-run record_principle or hand-edit MEMORY.md if it should change): %s\n"
                 (length stale) (string-join stale ", "))
       "Description drift: all indexed descriptions match the store's current wording.\n"))))

;; Idempotent registration.
(when (fboundp 'claude-code-ide-make-tool)
  (setq claude-code-ide-mcp-server-tools
        (seq-remove
         (lambda (spec)
           (member (plist-get (claude-code-ide--normalize-tool-spec spec) :name)
                   '("record_principle" "regenerate_governance")))
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
            :description "Frontmatter metadata type. Defaults to feedback, which is what every principle in the store currently uses.")))
  (claude-code-ide-make-tool
   :function #'cc-butler-tool-regenerate-governance
   :name "regenerate_governance"
   :description "Bare-trigger governance cache/index regeneration, no arguments. Call this once after writing directly to a governance/*.md store file with Write/Edit (i.e. NOT through record_principle) — that direct write is never followed by a regenerate on its own, so the note can sit in the store and never reach the cache or the MEMORY.md index until this is called. Safe to call any time with nothing new, too: it reports exactly how many store notes are currently un-indexed (0 means fully synced), so it also works as a standalone check for a forgotten sync."
   :args nil))

(provide 'cc-butler-governance)
;;; cc-butler-governance.el ends here
