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

(defcustom cc-butler-governance-max-notes 250
  "Hard cap (250, 정수님's number) on how many principle notes the STORE may
hold — enforced as a RATCHET (butler's design, not 정수님's), not an
on/off switch:

  count >= 250  ->  only a count-INCREASING write is refused (a genuinely
                     new slug). Revising an EXISTING principle in place
                     never counts against this, at any count.
  count < 250   ->  same rule; it just has not started refusing yet.

There is exactly one rule, `count >= max-notes' blocks new slugs — the
\"ratchet\" framing is about why that single rule is correct even while
the store starts out (2026-09-08: 567) far above 250. Turning this on
BEFORE consolidating the existing 567 down to 250 does not deadlock
recording: an update to an EXISTING principle always passes regardless of
count, so the natural response to a rejection — fold the new content into
one of the largest existing notes the rejection message names — both
succeeds immediately and moves the store toward the cap, never away from
it. The count can only ever hold or fall through this gate; it cannot
rise back above where consolidation last left it (m1 함대, 2026-09-08:
correctly flagged that turning the gate on unconditionally would look
like it blocks ALL recording at 567 — it does not block RECORDING, only
GROWTH, and growth is exactly what should stay blocked at any count above
the cap).

정수님, 2026-09-08: \"제약이 좀 있어야 효율화, 추상화가 된다 — 넣으려고
했는데 넘쳐서 못 넣었다, 그러면 기존 것을 정리하고 넣는다.\" 250 is her
number, not a measurement; raise it here only on her instruction — the
intended response to hitting it is to consolidate first, not to widen the
gate."
  :type 'integer
  :group 'cc-butler)

(defcustom cc-butler-governance-max-note-bytes 2048
  "Hard cap on one principle note's BODY length, in bytes.

Checked in the same place `cc-butler-governance-max-notes' is — whatever
function `record_principle' actually calls to write. The two caps push
against EACH OTHER by design: block only length and growth leaks out as
more notes; block only count and growth leaks out as padding existing
notes instead (measured 2026-09-08: the store's single largest note was
already 112 KB). Only blocking both closes the leak down to the one thing
left: actually folding content down.

2048 (2 KB) — 정수님 지정값 (2026-09-08). 개수 250과 한 쌍. This went
through two intermediate values before landing here, in order: 4 KB
(butler's first guess) -> 8 KB (butler, after m1's distribution
measurement) -> 2 KB (정수님's own final call, overriding both). The 8 KB
reasoning is still the right reasoning even though the number changed —
keep it: 8 KB was rejected because m1 함대's distribution showed 68% of
existing notes already fit inside it, so that cap would almost never
actually fire, and a cap that rarely fires gives no reason to fold
anything down. The point here is not to avoid overflow, it is to FORCE
the folding/abstraction 정수님 asked for (\"제약이 좀 있어야 효율화,
추상화가 될 수 있거든요\"). Do not raise this again without new
instruction from 정수님 specifically. Not retroactive —
this bites the next time an existing 2KB+ note is edited, not now."
  :type 'integer
  :group 'cc-butler)

(defcustom cc-butler-governance-max-index-line-bytes 80
  "Hard cap on one principle's `MEMORY.md' index-line length, in bytes —
roughly a name plus a five-or-six-word hook.

This is what actually decides whether a session can even SEE a given
principle: `MEMORY.md' itself is read in full only up to whatever byte
budget the caller reading it applies (measured 2026-09-08, butler: of
598 index lines / 281 KB total, only the first 74 lines / 25 KB actually
load into context — 12%). Shrinking `cc-butler-governance-max-notes' to
250 does not fix this on its own: 250 notes at this store's current
average index-line size (468 bytes, measured the same day) is still
250*468 ~= 117 KB, still roughly 5x that budget. Body length
(`cc-butler-governance-max-note-bytes') is a DIFFERENT variable from
index-line length — capping the body alone does not shrink the index at
all, since `cc-butler-governance--index-line' renders only the
description, not the body.

80 — butler's calculated value (2026-09-08), NOT 정수님's — keep that
distinction visible; 정수님 specified 250 (count) and 2048 (body) directly,
this one is derived: 21504 bytes (a conservative budget) / 250 notes ~=
86, rounded down with a little margin. Adjust independently of the other
two if the actual read-in budget turns out to be measured differently."
  :type 'integer
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

(defcustom cc-butler-governance-memory-dir nil
  "The Claude Code memory dir — a GENERATED cache of the store (never
hand-edited).

Nil — the default — means DERIVE it from `cc-butler-home' the same way
`cc-butler--shared-state-note' computes it, evaluated lazily on every
call (see `cc-butler-governance-memory-store') rather than once at
definition time.  Set it only to point somewhere genuinely different;
an explicit value is always honoured.

REGRESSION (2026-08-31, live 8 days on this fleet): this used to be a
computed `defcustom' default, exactly the bug `cc-butler-governance-dir'
above already replaced once. A `defcustom' default binds once, at the
first definition — if `cc-butler--claude-memory-dir'/`cc-butler-home'
were not yet loaded at that moment (a load-order race, not a
configuration error), it silently froze onto the hardcoded fallback
path below, a stale path from a DIFFERENT fleet machine, and never
self-corrected even after those symbols became available later in the
same session. `regenerate_governance' kept reporting \"0 un-indexed\"
throughout, because it only ever checked its own write against its own
index — see `cc-butler-tool-regenerate-governance''s report, which now
also cross-checks against an independently-derived read path.

Do not restore a computed default here. Ask for the effective path
with `cc-butler-governance-memory-store', never by reading this
variable directly."
  :type '(choice (const :tag "Derive from cc-butler-home" nil) directory)
  :group 'cc-butler)

(defun cc-butler-governance-memory-store ()
  "Absolute path of the Claude Code memory dir actually in effect.
Mirrors `cc-butler-governance-store': the single place this is decided,
re-derived on every call so a reload or a `cc-butler-home' change is
picked up immediately instead of freezing at whatever was true when
this file first loaded."
  (file-name-as-directory
   (or cc-butler-governance-memory-dir
       (and (fboundp 'cc-butler--claude-memory-dir) (boundp 'cc-butler-home)
            (cc-butler--claude-memory-dir cc-butler-home))
       (expand-file-name "~/.claude/projects/-home-toracle--ccsm/memory/"))))

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

(defun cc-butler-governance--store-note-count ()
  "How many principle notes are in the STORE right now (README excluded).

This is the population `cc-butler-governance-max-notes' caps: the store
directory alone (`cc-butler-governance-store'), never the generated
memory-dir cache `cc-butler-governance--note-count' counts. The two can
diverge — a note deleted from the store leaves an orphaned cache file
behind until the next `cc-butler-governance-regenerate', which then
re-discovers it as \"unindexed\" and relinks it — so counting the cache
here would make cleanup fail to lower the count at all."
  (length (cc-butler--governance-dir-principles (cc-butler-governance-store))))

(defun cc-butler-governance--largest-notes (n)
  "The N largest principle notes in the store, as (SLUG . BYTES), biggest
first — what a caller hitting the cap is told to go merge or delete."
  (let ((sized (mapcar (lambda (f)
                          (cons (file-name-sans-extension (file-name-nondirectory f))
                                (or (file-attribute-size (file-attributes f)) 0)))
                        (cc-butler--governance-dir-principles (cc-butler-governance-store)))))
    (seq-take (sort sized (lambda (a b) (> (cdr a) (cdr b)))) n)))

(defun cc-butler-governance--cap-message (slug)
  "Rejection text for `record_principle' hitting `cc-butler-governance-max-notes'.

REGRESSION-SHAPED GAP closed 2026-09-08 (steward-requested real-store
probe, before merge): the first version of this message named the count,
the cap, and the largest notes, and stopped there. Measured against the
REAL 566-note store, that version failed on two counts a unit test with
fake data cannot catch: (1) it stated a fact (\"revising an existing
principle is never blocked\") without ever telling the worker to actually
DO that to get their own content saved NOW; (2) it listed the largest
notes as if size ~= good merge target, but the real #1 result
\(a-true-observation-licenses-only-its-own-scope, 112KB) was, at the same
moment, the exact note warmble-jumble's own folding effort had concluded
needs SPLITTING into 21 notes, not merging into — which would have sent a
worker following this message's implicit ranking to make the count WORSE,
not better. Now: an explicit action line naming update-by-existing-name as
the immediate way through, and the size list re-labeled as location
context rather than a ranked pick list, with the split-vs-merge caveat
spelled out."
  (let ((count (cc-butler-governance--store-note-count))
        (largest (cc-butler-governance--largest-notes 5)))
    (concat
     (format "Refusing to record NEW principle `%s' — the store already holds %d notes, at the cap of %d (`cc-butler-governance-max-notes').\n\n"
             slug count cc-butler-governance-max-notes)
     "TO RECORD THIS NOW: call record_principle again, but pass the NAME of an EXISTING principle whose topic overlaps with what you're recording, instead of a new slug — revising an existing principle is never blocked by this cap, at any count.\n\n"
     "⚠ THIS REPLACES THAT NOTE'S ENTIRE BODY — it is not a merge, record_principle never merges. (1) Read the existing note's full current content first. (2) Fold your new material INTO that content by hand, staying under the body-length cap. (3) Pass that complete folded text as body — not just your new bit, or you delete everything else the note held. A body far smaller than what the note currently holds is refused unless you also pass confirm_shrink as true.\n\n"
     "A note already at/over the body-length cap cannot be edited through record_principle until it is folded under that cap first — sizes are shown below for exactly this reason.\n\n"
     "For reference, where the store's bulk currently concentrates (NOT a ranked merge list — a note's size alone does not mean it is a good target; a very large note may need SPLITTING into several smaller ones rather than absorbing more, so match by topic, never by size):\n"
     (mapconcat (lambda (p) (format "  %7d bytes  %s" (cdr p) (car p))) largest "\n")
     "\n\nNothing existing actually fits the topic? Report to the steward rather than guessing which note to overload.")))

(defun cc-butler-governance--longest-sections (body n)
  "The N longest blank-line-delimited paragraphs in BODY, biggest first, as
\(BYTES . PREVIEW) pairs — what an author hitting the length cap should
look at first to cut or split off."
  (let ((sized (mapcar
                (lambda (p) (cons (string-bytes p)
                                  (truncate-string-to-width
                                   (string-trim (replace-regexp-in-string "\n" " " p))
                                   60 nil nil "…")))
                (split-string body "\n\n+" t))))
    (seq-take (sort sized (lambda (a b) (> (car a) (car b)))) n)))

(defun cc-butler-governance--length-message (slug body)
  "Rejection text for `record_principle' hitting `cc-butler-governance-max-note-bytes'.
Names the byte count, the cap, and BODY's longest sections so the author
can cut on the spot, the same principle as `cc-butler-governance--cap-message'."
  (concat
   (format "Refusing to record `%s' — its body is %d bytes, over the cap of %d (`cc-butler-governance-max-note-bytes').\n"
           slug (string-bytes body) cc-butler-governance-max-note-bytes)
   "Longest sections in this body:\n"
   (mapconcat (lambda (p) (format "  %7d bytes  %s" (car p) (cdr p)))
              (cc-butler-governance--longest-sections body 3) "\n")
   "\n\nTrim to the point, split part of it into a separate principle, or cut one of the sections above, then call record_principle again."))

(defun cc-butler-governance--index-line-message (slug line)
  "Rejection text for `record_principle' hitting
`cc-butler-governance-max-index-line-bytes'. Names the byte count, the
cap, and the offending LINE itself — short enough that showing the whole
thing beats picking excerpts, unlike the other two caps' messages."
  (format "Refusing to record `%s' — its MEMORY.md index line would be %d bytes, over the cap of %d (`cc-butler-governance-max-index-line-bytes').\nLine: %s\nShorten the description to a name plus a five-or-six-word hook, then call record_principle again."
          slug (string-bytes line) cc-butler-governance-max-index-line-bytes
          (string-trim line)))

(defun cc-butler-governance--memory-index-file ()
  "Absolute path of `MEMORY.md' — the hand-maintained index every session
actually loads.  A note's body can be regenerated perfectly and still never be
recalled if this file has no line pointing at it (cc-butler#36)."
  (expand-file-name "MEMORY.md" (cc-butler-governance-memory-store)))

(defun cc-butler-governance--frontmatter-description (path)
  "PATH's frontmatter `description:' value, or nil if unreadable/absent.

REGRESSION (2026-09-01): this used to assume line 1 is the opening `---',
skipping it unconditionally with `forward-line 1' and searching for the
NEXT `^---$' as the close. A note with a leading blank line (line 1
blank, `---' on line 2) made that skip land ON the opening delimiter
itself, which the search then matched as its own close — collapsing the
frontmatter range to nothing and silently losing the description. Now
finds the opening `---' explicitly and searches for the close only
after it, so a leading blank line no longer matters."
  (when (file-readable-p path)
    (with-temp-buffer
      (insert-file-contents path)
      (goto-char (point-min))
      (let* ((frontmatter-start (and (re-search-forward "^---$" nil t) (point)))
             (frontmatter-end (and frontmatter-start
                                    (re-search-forward "^---$" nil t) (point))))
        (when frontmatter-end
          (goto-char frontmatter-start)
          (when (re-search-forward "^description: \"\\(.*\\)\"$" frontmatter-end t)
            (match-string 1)))))))

(defun cc-butler-governance--render-index-line (slug description)
  "The literal `MEMORY.md' line text for SLUG with DESCRIPTION already in
hand — the one formatter `cc-butler-governance--index-line' (reads
DESCRIPTION off disk, after the note exists) and the record-time length
check (has DESCRIPTION in the call already, before anything is written)
both go through, so the two can never render the line differently."
  (format "- [%s](butler-%s.md) — %s\n" slug slug description))

(defun cc-butler-governance--index-line (slug)
  "Render the `MEMORY.md' line for SLUG, using the note's own description."
  (let* ((note (expand-file-name (concat "butler-" slug ".md")
                                 (cc-butler-governance-memory-store)))
         (desc (or (cc-butler-governance--frontmatter-description note)
                   "(no description in store)")))
    (cc-butler-governance--render-index-line slug desc)))

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
  (let ((memory-dir (cc-butler-governance-memory-store)))
    (make-directory memory-dir t)
    (let ((n 0) (slugs nil))
      (dolist (f (cc-butler-governance-principles))
        (copy-file f (expand-file-name (concat "butler-" (file-name-nondirectory f))
                                       memory-dir)
                   t)
        (push (file-name-sans-extension (file-name-nondirectory f)) slugs)
        (setq n (1+ n)))
      (cc-butler-governance--sync-index (nreverse slugs))
      (cc-butler-governance--prune-dead-entries)
      (when (called-interactively-p 'interactive)
        (message "cc-butler: regenerated %d principle(s) from the store" n))
      n)))

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
                    (cc-butler-governance-memory-store)))

(defun cc-butler-governance--note-count ()
  "How many generated notes (butler-*.md) are in the memory dir right now.
Matches only the `butler-' prefix regenerate writes, not every `.md' file in
the dir — `MEMORY.md' lives there too (cc-butler#36) and is not a note."
  (length (ignore-errors
            (directory-files (cc-butler-governance-memory-store) nil "\\`butler-.*\\.md\\'"))))

(defconst cc-butler-governance--stamp-regexp "\\`(최초 기록: .+)\\'"
  "A whole line that is a creation stamp.  Anchored to the WHOLE string, so it
is applied to one line at a time and a line that merely quotes the shape
mid-sentence cannot match it.")

(defun cc-butler-governance--stamp-line (text)
  "The creation stamp TEXT ends with, or nil.
Only the LAST non-empty line can be a stamp.  A stamp-shaped line anywhere
else is body text — someone quoting a stamp while writing ABOUT stamping —
and treating it as this tool's own mark would promote a quotation into an
attribution, which is the false attribution the whole design exists to
avoid.  (Measured 2026-09-04: zero of the vault's 507 governance notes
contain a line of this shape today, so this is a boundary being closed
before it is crossed, not one already crossed.)"
  (let ((last (car (last (split-string (string-trim-right (or text "")) "\n")))))
    (when (and last (string-match-p cc-butler-governance--stamp-regexp last))
      last)))

(defun cc-butler-governance--existing-stamp (path)
  "The creation stamp already in the note at PATH, or nil if it has none.
The notes written before stamping existed have none, and must not gain one:
whoever edits a legacy note today is not its first recorder."
  (when (file-readable-p path)
    (cc-butler-governance--stamp-line
     (with-temp-buffer (insert-file-contents path) (buffer-string)))))

(defun cc-butler-governance--strip-stamps (body)
  "BODY with a trailing creation stamp removed, if it has one.
Only a trailing stamp is removed, for the same reason only a trailing one is
recognised: a stamp-shaped line elsewhere in BODY is the author's text and
deleting it would be silent data loss."
  (let* ((body (string-trim-right (or body "")))
         (stamp (cc-butler-governance--stamp-line body)))
    (string-trim
     (if stamp (substring body 0 (- (length body) (length stamp))) body))))

(defun cc-butler-governance--mint-stamp ()
  "A creation stamp naming the calling session, or nil if it cannot be known.
Written by the CODE from the MCP request's own session context, never by the
calling model — the same reason `cc-butler--relay-attribution' is: asking a
session to label itself is asking it to remember, and this cannot be
forgotten.  The date comes from the machine clock, not from a model's belief
about today, which is the one date in the vault that cannot drift.

Deliberately weak and therefore always true: it claims only who STARTED the
note, not who wrote any given sentence.  Per-change attribution would need a
diff, and a line diff cannot tell a new block from a rewrite of someone
else's paragraph — measured at 39.3% of authored edits, so it would misattribute
about four edits in ten.  Nil when the session is unknown: no stamp beats a
stamp that says `?'."
  (let ((dir (and (fboundp 'cc-butler--caller-dir)
                  (ignore-errors (cc-butler--caller-dir)))))
    (when (and dir (fboundp 'cc-butler--who-dir))
      (let ((who (ignore-errors (cc-butler--who-dir dir))))
        (when (and (stringp who) (not (string-empty-p who)) (not (equal who "?")))
          (format "(최초 기록: %s, %s)" who (format-time-string "%m-%d")))))))

(defun cc-butler-governance--clean-description (description)
  "DESCRIPTION exactly as it ends up on disk — trimmed, `\"' swapped to `''
so it cannot break the frontmatter's quoted value. The single place this
cleanup happens, so `cc-butler-governance--render' (what gets written) and
the record-time index-line length check (what gets measured before
anything is written) can never disagree about what the text actually is."
  (replace-regexp-in-string "\"" "'" (string-trim (or description ""))))

(defun cc-butler-governance--render (slug description body type &optional stamp)
  "The full file text for a principle, frontmatter included.
Written here rather than by the caller so the schema cannot be got wrong —
`name:' matching the generated note, the quoting of DESCRIPTION, and the
`metadata:' block are all things a caller would have to know and would
eventually get subtly wrong."
  (concat "---\n"
          "name: " cc-butler-governance--name-prefix slug "\n"
          "description: \""
          (cc-butler-governance--clean-description description) "\"\n"
          "metadata:\n"
          "  node_type: memory\n"
          "  type: " (or type "feedback") "\n"
          "---\n\n"
          (cc-butler-governance--strip-stamps body)
          "\n"
          (if stamp (concat "\n" stamp "\n") "")))

(defcustom cc-butler-governance-shrink-guard-fraction 0.5
  "Below this fraction of an EXISTING note's current body size, updating it
via `record_principle' is refused unless the call also confirms the
shrink (see `cc-butler-governance-record''s CONFIRM-SHRINK argument).

REGRESSION-SHAPED DANGER closed 2026-09-08 (steward, reading the code
directly): `record_principle' OVERWRITES a note's entire file via
`with-temp-file' — never merges, never appends. The count-cap rejection
message told a worker to \"call record_principle again ... your text
merges into that note in place\", which is FALSE, and following it
literally on any real (large) note would silently delete almost all of
it. This guard is the structural stop that a truthful message alone
cannot be, since a message not read is not a safeguard.

0.5 is butler's judgment call, not a measurement: deliberate folding
(cramming a 45KB note down to under the 2KB body cap) legitimately looks
identical, byte-count-wise, to an accidental partial overwrite -- there
is no size threshold that tells them apart. So this is not a hard block;
it is a REQUIRED CONFIRMATION, the same shape the 4/4-real-store-probe
discipline already established for this file: default to refusing,
require an explicit opt-in for the case that looks the same as the
danger it exists to catch."
  :type 'number
  :group 'cc-butler)

(defun cc-butler-governance--truthy-p (v)
  "Non-nil when V is a truthy CONFIRM-SHRINK argument.
An MCP boolean argument's exact Lisp representation across JSON
true/false is not something this file controls or wants to guess at
narrowly -- nil, `:false', the empty string, and the literal string
\"false\" are all treated as \"not confirmed\"; anything else (t, a
non-empty string, `:true') is treated as confirmed. Erring toward
treating an ambiguous value as NOT confirmed is the safe direction for a
guard that exists to prevent data loss."
  (not (or (null v) (eq v :false) (equal v "") (equal v "false"))))

(defun cc-butler-governance--body-in-file (path)
  "PATH's body text -- everything after the frontmatter's closing `---'
line, with any trailing creation stamp stripped, matching exactly what
`cc-butler-governance--render' put there. Nil if PATH is unreadable or
has no frontmatter close. The one place \"what does this note currently
say\" is read back off disk, so the shrink guard and any future reader of
the same question cannot disagree."
  (when (file-readable-p path)
    (with-temp-buffer
      (insert-file-contents path)
      (goto-char (point-min))
      (let* ((start (and (re-search-forward "^---$" nil t) (point)))
             (end (and start (re-search-forward "^---$" nil t) (point))))
        (when end
          (goto-char end)
          (forward-line 1)
          (cc-butler-governance--strip-stamps
           (buffer-substring-no-properties (point) (point-max))))))))

(defun cc-butler-governance--shrink-guard-message (slug old-bytes new-bytes)
  "Rejection text for `record_principle' hitting the shrink guard.
Names both sizes plainly, then gives the two different next steps for the
two different reasons this fires: accidental (go read + fold + resubmit
the WHOLE text) or deliberate (resubmit with confirm-shrink)."
  (format "Refusing to update `%s' without confirmation — its current body is %d bytes, and the body in this call is only %d bytes (%d%% smaller). record_principle OVERWRITES THE ENTIRE FILE, never merges, so this call would delete most of what the note currently holds.

If this is accidental: you likely called record_principle with only your NEW material, not the note's existing content folded in. Read the note's current body first, merge your addition into the complete text by hand, then call record_principle again with that whole result as body.

If this is deliberate — you actually condensed this note on purpose (e.g. folding it under the body-length cap) — call record_principle again with the same body, and pass confirm_shrink as true this time.
"
          slug old-bytes new-bytes
          (round (* 100 (- 1 (/ (float new-bytes) old-bytes))))))

(defcustom cc-butler-governance-duplicate-search-min-shared-keywords 3
  "Minimum shared significant keywords for an existing principle to count
as a possible duplicate of a NEW one being recorded (see
`cc-butler-governance--duplicate-candidates'). Below this, overlap is
treated as ordinary shared vocabulary, not evidence of the same lesson.

butler's judgment call (2026-09-08), not measured against real
duplicate/non-duplicate pairs — there was no time to build that dataset
under this dispatch's own urgency. Tune down if real near-duplicates keep
slipping through with too few shared keywords; tune up if unrelated new
principles keep getting flagged."
  :type 'integer
  :group 'cc-butler)

(defconst cc-butler-governance--stopwords
  '("the" "a" "an" "and" "or" "but" "of" "in" "on" "at" "to" "for" "is"
    "are" "was" "were" "be" "been" "being" "this" "that" "these" "those"
    "it" "its" "as" "by" "with" "from" "not" "no" "so" "if" "then" "than"
    "do" "does" "did" "has" "have" "had" "will" "would" "should" "could"
    "can" "must" "never" "always" "only" "just" "also" "when" "while"
    "into" "onto" "out" "over" "under" "again" "own" "same" "note" "notes"
    "principle" "principles" "store" "record")
  "Common English function words (plus a few domain words so common in
this store's own vocabulary they carry no discriminating signal) excluded
from `cc-butler-governance--keywords'. This store's slugs and descriptions
are written in English kebab-case/prose by convention (measured
2026-09-08: 566 of 566 real slugs are ASCII) -- Korean body text is not
tokenized meaningfully by this word-splitter, so the duplicate search
below is English-vocabulary-only by construction, not by oversight.")

(defun cc-butler-governance--keywords (text)
  "Significant lowercase word tokens in TEXT: alphanumeric runs of length
>= 4, lowercased, deduplicated, stopwords removed. The one tokenizer both
the submitted query and every candidate's description go through in
`cc-butler-governance--duplicate-candidates', so the two extractions can
never silently disagree about what counts as a keyword."
  (let (out)
    (dolist (w (split-string (downcase (or text "")) "[^a-z0-9]+" t))
      (when (and (>= (length w) 4) (not (member w cc-butler-governance--stopwords)))
        (push w out)))
    (delete-dups (nreverse out))))

(defun cc-butler-governance--duplicate-candidates (name description body)
  "Store principles that may already say what NAME/DESCRIPTION/BODY is
about to record, as (SLUG SHARED-COUNT DESCRIPTION) triples, highest
shared-keyword-count first, top 5. Only principles meeting
`cc-butler-governance-duplicate-search-min-shared-keywords' are returned
at all — weaker overlap is not treated as evidence.

REGRESSION this closes (steward, 2026-09-08): this fleet already has TWO
recall mechanisms telling agents to search the store before recording
\(a role-file section, a vault hook that fired nearly every turn on the
actual duplicate in question\), and a real duplicate was still
re-recorded under a new slug, costing hours to rediscover. Human/agent
search stacked in layers still failed; this makes the tool itself
search, at the one moment — right before a NEW slug is created — where
it can still be caught before it happens again."
  (let* ((query (cc-butler-governance--keywords
                 (mapconcat #'identity (list name description body) " ")))
         (scored
          (mapcar
           (lambda (f)
             (let* ((slug (file-name-sans-extension (file-name-nondirectory f)))
                    (desc (or (cc-butler-governance--frontmatter-description f) ""))
                    (shared (seq-intersection query (cc-butler-governance--keywords desc))))
               (list slug (length shared) desc)))
           (cc-butler--governance-dir-principles (cc-butler-governance-store)))))
    (seq-take
     (sort (seq-filter (lambda (r) (>= (nth 1 r)
                                       cc-butler-governance-duplicate-search-min-shared-keywords))
                       scored)
           (lambda (a b) (> (nth 1 a) (nth 1 b))))
     5)))

(defun cc-butler-governance--duplicate-message (slug candidates)
  "Rejection text for `record_principle' hitting `cc-butler-governance--duplicate-candidates'.
Names each candidate's slug, shared-keyword count, current size, and — the
structural gap steward asked this be designed around, not hidden behind a
dead end — whether it is already over the body-length cap and therefore
cannot be folded into via a normal-sized update at all."
  (concat
   (format "Refusing to record NEW principle `%s' — this looks like it may already exist in the store. Before creating a new slug, check these:\n\n"
           slug)
   (mapconcat
    (lambda (c)
      (let* ((cand-slug (nth 0 c)) (shared (nth 1 c)) (desc (nth 2 c))
             (path (expand-file-name (concat cand-slug ".md") (cc-butler-governance-store)))
             (bytes (or (and (file-exists-p path) (file-attribute-size (file-attributes path))) 0)))
        (format "  %s — %d shared keyword(s), %d bytes%s\n    %s"
                cand-slug shared bytes
                (if (> bytes cc-butler-governance-max-note-bytes)
                    (format " — OVER the %dB body cap: cannot be folded into with a normal update until IT is condensed under the cap first"
                            cc-butler-governance-max-note-bytes)
                  "")
                desc)))
    candidates "\n\n")
   "\n\nIf one of these is genuinely the same lesson: call record_principle again with THAT name. Read its current content first, fold your new material into the complete text by hand, and submit that whole result — record_principle REPLACES the file, it never merges, and a drastic shrink needs confirm_shrink.\n\nIf none of these are actually the same thing — this is shared wording, not a real duplicate — call record_principle again with the same new name and pass skip_duplicate_check as true."))

;;;###autoload
(defun cc-butler-governance-record (name description body &optional type confirm-shrink skip-duplicate-check)
  "Write a principle into the store, regenerate, and PROVE it landed.

Returns a plist: :slug :path :existed :before :after :verified :names.
:verified is non-nil only when the generated note was read back off disk and
actually names this principle — the check whose absence let three silent
failures pass for successes.

An existing NAME is OVERWRITTEN — the whole file is replaced with BODY,
never merged or appended to.  Correcting a principle is the normal case
for that (a near-duplicate under a new name is how a store stops being a
source of truth), so calling this with an existing name is expected and
fine — AS LONG AS BODY is the complete, already-folded text you want the
note to hold, not just the new material.  A BODY far smaller than what
the note currently holds is refused unless CONFIRM-SHRINK is non-nil (see
`cc-butler-governance-shrink-guard-fraction') — the guard against exactly
the mistake of passing only the new bit and losing the rest.

A genuinely NEW NAME is checked against the store for a possible existing
duplicate first (see `cc-butler-governance--duplicate-candidates') unless
SKIP-DUPLICATE-CHECK is non-nil — before anything else, since \"does this
even need to be a new principle at all\" is upstream of every other
question this function asks."
  (let* ((slug (cc-butler-governance--slug name))
         (store (cc-butler-governance-store))
         (path (expand-file-name (concat slug ".md") store))
         (existed (file-exists-p path))
         (before (cc-butler-governance--note-count)))
    (when (string-empty-p (string-trim (or body "")))
      (user-error "Refusing to record an empty principle: %s" slug))
    ;; "Does this already exist?" is asked before anything else -- a
    ;; question nobody was asking mechanically until now (steward,
    ;; 2026-09-08: two existing human/agent-facing recall mechanisms both
    ;; fired on the real duplicate in question and it was still missed).
    (when (and (not existed) (not (cc-butler-governance--truthy-p skip-duplicate-check)))
      (let ((candidates (cc-butler-governance--duplicate-candidates name description body)))
        (when candidates
          (user-error "%s" (cc-butler-governance--duplicate-message slug candidates)))))
    ;; Data-loss guard, checked next: this call is about to OVERWRITE
    ;; (not merge) an existing file. Ordered ahead of the caps below
    ;; because it is the one check whose failure is irreversible; those
    ;; are merely refused writes (steward, 2026-09-08: "노트가 사라집니다").
    (when (and existed (not (cc-butler-governance--truthy-p confirm-shrink)))
      (let* ((old-body (cc-butler-governance--body-in-file path))
             (old-bytes (and old-body (string-bytes old-body)))
             (new-bytes (string-bytes (cc-butler-governance--strip-stamps body))))
        (when (and old-bytes (> old-bytes 0)
                   (< new-bytes (* old-bytes cc-butler-governance-shrink-guard-fraction)))
          (user-error "%s" (cc-butler-governance--shrink-guard-message
                            slug old-bytes new-bytes)))))
    ;; Checked on every call, not only new ones — an update that pads an
    ;; existing note past the cap is the append-instead-of-add workaround
    ;; the count cap alone opens up (정수님, 2026-09-08).
    (when (> (string-bytes (cc-butler-governance--strip-stamps body))
             cc-butler-governance-max-note-bytes)
      (user-error "%s" (cc-butler-governance--length-message
                        slug (cc-butler-governance--strip-stamps body))))
    ;; Also checked on every call, same reason: a DESCRIPTION that only
    ;; grows the index line, never the body, would otherwise dodge the
    ;; body-length cap entirely while still blowing the index-read budget
    ;; the index-line cap exists for (butler, 2026-09-08).
    (let ((line (cc-butler-governance--render-index-line
                 slug (cc-butler-governance--clean-description description))))
      (when (> (string-bytes line) cc-butler-governance-max-index-line-bytes)
        (user-error "%s" (cc-butler-governance--index-line-message slug line))))
    (when (and (not existed)
               (>= (cc-butler-governance--store-note-count) cc-butler-governance-max-notes))
      (user-error "%s" (cc-butler-governance--cap-message slug)))
    (make-directory store t)
    (with-temp-file path
      (insert (cc-butler-governance--render
               slug description body type
               ;; Minted only when the note is NEW.  `with-temp-file' truncates
               ;; and the caller resubmits the whole body without ever having
               ;; seen the stamp, so an update must read the old one back off
               ;; disk or it is silently erased on the first edit.
               (if existed
                   (cc-butler-governance--existing-stamp path)
                 (cc-butler-governance--mint-stamp)))))
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

(defun cc-butler-tool-record-principle (name description body &optional type confirm-shrink skip-duplicate-check)
  "MCP tool: record an operating principle and report where it landed.

Reports the note COUNT (`:before'/`:after' on the plist `cc-butler-governance-record'
returns), never the full roster of slugs — `:names' holds all of them (563 in
the real store as of 2026-09-08) and every one of those went out on every
single call, success or not, at ~28 KB of dead weight per response (measured
against the real store, 2026-09-09: 27567 bytes old vs 565 new — a 98%
reduction). Nothing here ever consumed the list: `cc-butler-governance-record'
returns it for a caller who wants \"is X already recorded\" for free, and the
duplicate check (`skip_duplicate_check') does its own targeted search instead
of scanning this string. Revising an existing note needs its own name and
current body — read via the store or memory path already in this response —
not a directory of 562 unrelated slugs."
  (let* ((res (cc-butler-governance-record name description body type confirm-shrink skip-duplicate-check))
         (verified (plist-get res :verified)))
    (concat
     (if verified
         (format "Recorded principle `%s` (%s).\n"
                 (plist-get res :slug)
                 (if (plist-get res :existed) "OVERWROTE the existing file" "new"))
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
               (plist-get res :store) (cc-butler-governance-memory-store)))
     "\nTo revise an existing principle, call this again with that same name — BODY REPLACES THE WHOLE FILE, it is never merged. Read the note first, fold your change into its complete text by hand, then pass that whole result as body.")))

(defun cc-butler-governance--memory-dir-drift-detail ()
  "Nil if the write path (`cc-butler-governance-memory-store') agrees with
an independently-derived path (`cc-butler--claude-memory-dir' via
`cc-butler-home', computed fresh here rather than read back off the same
accessor); a detail string describing the mismatch otherwise.

REGRESSION (2026-08-31): `cc-butler-tool-regenerate-governance' checked
its own write against its own index and always reported \"0 un-indexed\",
even the entire 8 days `cc-butler-governance-memory-dir' was frozen onto
a stale path from a different fleet machine — because every check in
that report resolves through the SAME variable that was wrong. This
check is deliberately the odd one out: it recomputes the expected path
from scratch instead of trusting the accessor, so a future variant of
the same bug (the accessor itself derives wrong) cannot hide from it the
way it hid from every store->index/index->store check that shares its
one source of truth."
  (when (and (fboundp 'cc-butler--claude-memory-dir) (boundp 'cc-butler-home))
    (let* ((write (file-name-as-directory (expand-file-name (cc-butler-governance-memory-store))))
           (read (file-name-as-directory
                  (expand-file-name (cc-butler--claude-memory-dir cc-butler-home)))))
      (unless (equal write read)
        (format "write path (%s) != independently-derived read path (%s)" write read)))))

(defun cc-butler-tool-regenerate-governance ()
  "MCP tool: bare-trigger governance regeneration, no arguments.

For the case `record_principle' doesn't cover: a note written straight to
the store with Write/Edit (its frontmatter controlled by hand, not via the
record tool). That write never calls regenerate itself, so the note can sit
in the store, fully valid, and never reach the cache or the MEMORY.md index
until something calls this. Call it once after any such direct write.

⚠ HONEST GAP (2026-09-08): that same direct-write path also skips all
THREE record-time caps entirely — `cc-butler-governance-max-notes',
`cc-butler-governance-max-note-bytes', and
`cc-butler-governance-max-index-line-bytes' are checked inside
`cc-butler-governance-record', which a direct Write/Edit never calls.
This function does not check any of them either. As long as writing
straight to the store stays possible, all three caps are a gate on the
one path that goes through `record_principle', not an enforced limit on
the store overall. Not closed by this change; not hidden either —
recorded here so the next person doesn't discover it the hard way.

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
       "Description drift: all indexed descriptions match the store's current wording.\n")
     (let ((drift (cc-butler-governance--memory-dir-drift-detail)))
       (if drift
           (format "MEMORY-DIR MISMATCH: %s — this regenerate wrote somewhere a session may not actually read from; see the governance principle one-path-for-write-and-read.\n" drift)
         "Memory dir: write path matches the independently-derived read path.\n")))))

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
   :description "Record a butler/steward operating principle into the governance store and regenerate the Claude Code memory from it. Writes the frontmatter for you (name/description/metadata) so the schema cannot be got wrong, and takes NO path argument — it writes to exactly the store the regenerator reads, which is the whole point. A genuinely NEW name is first checked against the store for a possible existing duplicate (shared-keyword search over every principle's description) — if one looks similar enough, this refuses and names the candidate(s) instead of creating a near-duplicate; pass skip_duplicate_check if you've checked and it's a false positive. Calling it with the name of an EXISTING principle REPLACES that principle's entire file with whatever you pass as body — this OVERWRITES, it never merges or appends. To revise one: read its current content first, fold your change into the complete text by hand, then pass that whole result as body; passing only your new material deletes the rest. A body far smaller than the note's current size is refused unless confirm_shrink is also passed as true, so an accidental partial-overwrite cannot silently destroy most of a note. Returns the absolute file written, the note count before and after, and whether the generated note was read back off disk and confirmed to name this principle — if that verification fails it reports failure, because a regeneration reporting success while landing nothing is a real thing that has happened here."
   :args '((:name "name" :type "string" :required t
            :description "Kebab-case slug for the principle, e.g. verify-delivery. Naming an EXISTING principle REPLACES its entire file (never merges) — read it first if you mean to revise it. The butler- prefix is added for you.")
           (:name "description" :type "string" :required t
            :description "One-line summary, used to decide relevance during recall. Write it so a reader can tell whether this principle applies without opening it. Also used, together with name and body, to search the store for a possible existing duplicate before a NEW principle is created.")
           (:name "body" :type "string" :required t
            :description "The principle itself, in Markdown, as the COMPLETE text the note should hold — this replaces the whole file when the name already exists, it is never merged with what's there. Follow the store's shape: what the rule is, then **Why:** with the concrete incident that motivated it, then **How to apply:**.")
           (:name "type" :type "string" :required nil
            :description "Frontmatter metadata type. Defaults to feedback, which is what every principle in the store currently uses.")
           (:name "confirm_shrink" :type "boolean" :required nil
            :description "Required (true) when revising an existing principle to less than half its current body size — otherwise refused, to catch an accidental partial-overwrite that would delete most of the note. Pass true only when the shrink is deliberate (e.g. you already folded the note down under the body-length cap).")
           (:name "skip_duplicate_check" :type "boolean" :required nil
            :description "Required (true) to create a NEW principle that the store's duplicate search flagged as similar to an existing one. Pass true only after checking the named candidate(s) and confirming this is genuinely a different lesson, not the same one under a new name.")))
  (claude-code-ide-make-tool
   :function #'cc-butler-tool-regenerate-governance
   :name "regenerate_governance"
   :description "Bare-trigger governance cache/index regeneration, no arguments. Call this once after writing directly to a governance/*.md store file with Write/Edit (i.e. NOT through record_principle) — that direct write is never followed by a regenerate on its own, so the note can sit in the store and never reach the cache or the MEMORY.md index until this is called. Safe to call any time with nothing new, too: it reports exactly how many store notes are currently un-indexed (0 means fully synced), so it also works as a standalone check for a forgotten sync."
   :args nil))

(provide 'cc-butler-governance)
;;; cc-butler-governance.el ends here
