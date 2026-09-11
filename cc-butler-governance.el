;;; cc-butler-governance.el --- runtime-neutral operating-principles store  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jeongsoo Park
;; SPDX-License-Identifier: MIT

;; The butler/steward operating principles live in a repo-owned, runtime-neutral
;; store (governance/, one file per principle) — the single source of truth.
;; Runtime files (Claude Code role CLAUDE.md + memory notes, a future Codex
;; AGENTS.md) are GENERATED caches of it: edit the store + regenerate → every
;; adapter updates.  See docs/cc-butler-governance-store-sdd.md.

(require 'subr-x)
;; Needed only for `cc-butler--make-guarded-tool' (cc-butler-session.el),
;; the shared MCP tool error-boundary wrapper every registration below
;; must go through. No cycle: cc-butler-session.el requires only
;; claude-code-ide / claude-code-ide-mcp-server / subr-x / seq / json,
;; none of which requires this file back.
(require 'cc-butler-session)

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

(defvar cc-butler-governance--last-sort-unavailable-reason nil
  "Set by the most recent `cc-butler-governance-regenerate' call: nil when
`MEMORY.md's index was rewritten sorted by git commit-recency; otherwise a
short human-readable string naming why that sort was unavailable (not a
repo, git missing, git log failed) and the fall back to plain insertion
order happened instead. Read by `cc-butler-tool-regenerate-governance' so a
silent fallback can never look like a normal successful run.")

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

(defun cc-butler-governance--oversized-notes ()
  "Store notes (SLUG . BYTES) whose BODY exceeds
`cc-butler-governance-max-note-bytes', biggest first.  Bytes are read via
`cc-butler-governance--body-in-file' — the same body text
`cc-butler-governance-record' measures at write time — so this reports the
identical thing the record-time cap enforces, just applied to whatever is
ALREADY on disk (the direct-Write/Edit path that never goes through
`cc-butler-governance-record' at all, and so never hits that cap)."
  (let (sized)
    (dolist (f (cc-butler--governance-dir-principles (cc-butler-governance-store)))
      (let* ((slug (file-name-sans-extension (file-name-nondirectory f)))
             (body (cc-butler-governance--body-in-file f))
             (bytes (and body (string-bytes body))))
        (when (and bytes (> bytes cc-butler-governance-max-note-bytes))
          (push (cons slug bytes) sized))))
    (sort sized (lambda (a b) (> (cdr a) (cdr b))))))

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
both go through, so the two can never render the line differently.

Format (2026-09-09, steward: only ~74 of ~598 generated lines fit the
hook's real read budget): `- butler-SLUG.md — DESC', SLUG written ONCE.
The prior format wrote SLUG twice -- once as markdown link text, once
inside the link target (`- [SLUG](butler-SLUG.md) — DESC') -- which was
most of the per-line overhead. `butler-SLUG.md' stays PLAIN TEXT (no
`[]()' brackets) rather than being dropped altogether: that literal
substring is the sole marker `--index-has-slug-p',
`--index-butler-slugs', `--prune-dead-entries' and
`--stale-index-entries' use to tell a line this store generated (and may
therefore reformat/prune) from one a human hand-authored in a different
shape (see the `steward-only-note' fixture in the test file, which
deliberately has no `butler-' prefix) -- dropping the marker to save a
few more bytes would make that distinction unrecoverable.

DESCRIPTION may come back empty (`\"\"') from `--truncate-bytes' when a
slug's own boilerplate leaves less than 3 bytes of budget -- see that
function's docstring. In that case the separator is dropped too:
`- butler-SLUG.md\\n', never a dangling `- butler-SLUG.md — \\n' with
nothing after it. The invariant every reader of this shape (
`--index-line-regexp', `--index-has-slug-p', and everything built on
either) now honours: the ` — ' separator is present if and only if a
description follows it, never on its own."
  (if (equal description "")
      (format "- butler-%s.md\n" slug)
    (format "- butler-%s.md — %s\n" slug description)))

(defconst cc-butler-governance--generated-description-max-bytes 48
  "Byte cap `cc-butler-governance--index-line' truncates a note's
frontmatter description to before rendering it into `MEMORY.md'.

Generation-time only -- NEVER applied to
`cc-butler-governance-max-index-line-bytes' (80), the record-time cap
`cc-butler-governance-record' checks against the FULL, untruncated
description and refuses over it (an author-facing gate, not silent
truncation; see `cc-butler-governance/record-refuses-a-description-over-the-index-line-cap').
This is the separate silent-truncation step steward asked for so a
LEGACY note (recorded before that 80-byte cap existed, or simply long)
still renders a short index line on every `cc-butler-governance-regenerate'
with no refusal and no manual edit.")

(defun cc-butler-governance--truncate-bytes (s max-bytes)
  "S truncated to at most MAX-BYTES UTF-8 bytes, byte-safe.

Most descriptions in this store are Korean, where `string-bytes' !=
`length' (one character is 3 bytes) -- a byte-substring would risk
cutting a multi-byte character in half. This drops whole CHARACTERS
\(via `substring', which indexes by character, never by byte) from the
end, one at a time, until what remains plus the ellipsis both fit,
so a cut can never land mid-character.

MAX-BYTES below the ellipsis's own `string-bytes' (3 -- \"…\" is itself a
multi-byte character) has no truncation that actually fits: the loop
below would strip S all the way to the empty string and still append
the ellipsis, handing back a 3-byte result that is ITSELF over
MAX-BYTES. Confirmed on the live store: exactly 20 real slugs whose
`cc-butler-governance--description-budget-bytes' computes to 1 or 2
hit this and rendered a lone `…' that overflowed the 80-byte index-line
cap by 1-2 bytes. Return the empty string instead in that case -- an
honest empty description beats an over-budget ellipsis (see
`cc-butler-governance--render-index-line', which drops the ` — '
separator too when DESCRIPTION comes back empty)."
  (if (< max-bytes (string-bytes "…"))
      ""
    (if (<= (string-bytes s) max-bytes)
        s
      (let ((out s)
            (ellipsis-bytes (string-bytes "…")))
        (while (and (> (length out) 0)
                    (> (+ (string-bytes out) ellipsis-bytes) max-bytes))
          (setq out (substring out 0 (1- (length out)))))
        (concat out "…")))))

(defun cc-butler-governance--description-budget-bytes (slug)
  "Bytes available for SLUG's index-line description before the line
itself would exceed `cc-butler-governance-max-index-line-bytes' -- the
slug and its fixed boilerplate (`- butler-', `.md — ', trailing
newline) are subtracted from the line cap first, then clamped to never
exceed `cc-butler-governance--generated-description-max-bytes' (so a
short slug does not grow into a summary just because it has room --
the index line is a hook, not a summary).

A slug whose own boilerplate already meets or exceeds the line cap
gets a budget of 0 -- the rendered line still exceeds the cap in that
case (the slug itself is the overflow, not the description), and no
description length can fix that without renaming the note, which is
out of scope here: note bodies (including their `name:' frontmatter,
the slug's source) are never touched by this file's index-rendering
code."
  (let ((boilerplate-bytes (string-bytes (format "- butler-%s.md — \n" slug))))
    (max 0 (min cc-butler-governance--generated-description-max-bytes
                (- cc-butler-governance-max-index-line-bytes boilerplate-bytes)))))

(defun cc-butler-governance--index-line (slug)
  "Render the `MEMORY.md' line for SLUG, using the note's own description,
truncated to fit `cc-butler-governance-max-index-line-bytes' once SLUG's
own boilerplate is accounted for (see
`cc-butler-governance--description-budget-bytes') -- NOT a flat
`cc-butler-governance--generated-description-max-bytes' regardless of
slug length, which is what let real lines run 108-124 bytes against an
80-byte cap despite each description alone fitting its own sub-limit."
  (let* ((note (expand-file-name (concat "butler-" slug ".md")
                                 (cc-butler-governance-memory-store)))
         (desc (or (cc-butler-governance--frontmatter-description note)
                   "(no description in store)")))
    (cc-butler-governance--render-index-line
     slug (cc-butler-governance--truncate-bytes
           desc (cc-butler-governance--description-budget-bytes slug)))))

(defun cc-butler-governance--index-has-slug-p (index slug)
  "Non-nil when INDEX (a file that may not exist yet) already links SLUG's
note, in the current plain-text `butler-SLUG.md' shape (with OR without a
description -- see `cc-butler-governance--render-index-line') or the
older `[SLUG](butler-SLUG.md)' shape a not-yet-normalized legacy line may
still be in.  Recognizing all of these here is what keeps `--sync-index'
from appending a duplicate NEW-format line for a slug whose only line
hasn't been rewritten yet by `--normalize-index-format' (which
`cc-butler-governance-regenerate' always runs first, but this function is
also called standalone, before any regenerate, by `--unindexed-names'),
or -- the 2026-09-10 addition -- whose only line is already in the bare,
description-less shape."
  (and (file-readable-p index)
       (with-temp-buffer
         (insert-file-contents index)
         (goto-char (point-min))
         (or (search-forward (format "butler-%s.md — " slug) nil t)
             (progn (goto-char (point-min))
                    (re-search-forward
                     (format "butler-%s\\.md$" (regexp-quote slug)) nil t))
             (progn (goto-char (point-min))
                    (search-forward (format "(butler-%s.md)" slug) nil t))))))

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

(defun cc-butler-governance--commit-recency-map ()
  "Cons (MAP . REASON): MAP is a hash table of every git-tracked filename
under `cc-butler-governance-store' (relative to that directory, e.g.
\"a-rule.md\") to its LATEST commit's unix-epoch timestamp, built from ONE
batched `git log' call over the whole store — never one `git log -1' per
file, which was measured too slow to repeat against the real ~564-note
store. REASON is nil on success; otherwise a short human-readable string
naming why the git-based sort is unavailable (not a repo, git missing,
git log failed, or nothing usable came back), for a caller to surface
LOUDLY rather than silently falling back to insertion order."
  (let ((store (cc-butler-governance-store)))
    (cond
     ((not (and store (file-directory-p store)))
      (cons nil "store directory does not exist"))
     ((not (executable-find "git"))
      (cons nil "git executable not found"))
     (t
      (let ((default-directory (file-name-as-directory store)))
        (if (not (zerop (call-process "git" nil nil nil "rev-parse" "--is-inside-work-tree")))
            (cons nil "not a git repository")
          (with-temp-buffer
            (let ((status (call-process "git" nil t nil
                                         "log" "--name-only" "--format=%at"
                                         "--relative" "--" ".")))
              (if (not (zerop status))
                  (cons nil (format "git log failed (exit %s)" status))
                (let ((map (make-hash-table :test 'equal)) (ts nil))
                  (dolist (line (split-string (buffer-string) "\n"))
                    (cond
                     ((string-match-p "\\`[0-9]+\\'" line)
                      (setq ts (string-to-number line)))
                     ((and ts (not (string-empty-p line)) (not (gethash line map)))
                      (puthash line ts map))))
                  (if (zerop (hash-table-count map))
                      (cons nil "git log returned nothing usable")
                    (cons map nil))))))))))))

(defun cc-butler-governance--rewrite-sorted-index (slugs recency-map)
  "Rewrite `MEMORY.md's block of this store's own generated lines (see
`cc-butler-governance--index-line-regexp') so SLUGS appear as one
contiguous run ordered by RECENCY-MAP (store filename -> unix time, from
`cc-butler-governance--commit-recency-map') descending — the
most-recently-committed principle first, so a note that keeps getting
revised (still alive, still load-bearing) surfaces near the top of
`MEMORY.md' instead of wherever it happened to land historically.

Every line NOT in this store's own generated shape — hand-authored content
the store does not own — is left byte-for-byte untouched, and ALL such
lines are hoisted ABOVE the entire sorted block as a group, preserving
their original relative order among each other (2026-09-10, PR #216
fix): reinserting the block at the position of the FIRST store-owned
line instead left any non-store line that originally sat AFTER that
point stranded past the WHOLE block, however large — a real visibility
regression (a legacy/hand-authored line pointing at content that exists
ONLY via that one `MEMORY.md' line, well within the read budget before
the sort, pushed tens of KB past it after — see
`cc-butler-governance/regenerate-orphan-legacy-line-can-fall-out-of-budget-after-sort').
Mechanically this falls out of the existing delete-in-place loop below
for free: it already leaves every non-matching line (banner included)
untouched, in original relative order, as matched lines are deleted out
from around it — the only change needed is inserting the sorted block at
the END of what remains (`point-max') instead of at the first match's
original position.

An already-indexed slug's EXISTING line text is reused verbatim — curated
wording is never overwritten (see
`cc-butler-governance/regenerate-does-not-duplicate-an-already-curated-entry');
only a slug with no line yet gets one freshly rendered. A slug not in SLUGS
(already gone from the store) has its old line dropped here as a side
effect — `cc-butler-governance--prune-dead-entries', called right after
this in `cc-butler-governance-regenerate', is left in place as a
belt-and-suspenders check, and as the ONLY cleanup mechanism left on the
git-unavailable fallback path (plain `cc-butler-governance--sync-index',
which is add-only and prunes nothing itself).

Ownership is decided by `cc-butler-governance--index-line-regexp' — the
SAME shared constant `--shrink-oversized-index-lines' and
`--prune-dead-entries' already use — rather than a private copy of the
shape, precisely to avoid the \"same regex, only one copy updated\"
failure mode that constant's own docstring warns about (a real past
incident, #136/#146). Must run AFTER `cc-butler-governance--shrink-oversized-index-lines'
in `cc-butler-governance-regenerate': this reuses on-disk line text
verbatim rather than re-rendering it, so an oversized line must already be
fixed before it is repositioned — sorting first would just move the
stale, still-oversized text to a new spot."
  (let ((index (cc-butler-governance--memory-index-file)))
    (with-temp-buffer
      (when (file-readable-p index) (insert-file-contents index))
      (let ((existing (make-hash-table :test 'equal)))
        (goto-char (point-min))
        (while (re-search-forward
                (concat cc-butler-governance--index-line-regexp ".*\n?") nil t)
          (puthash (match-string 1) (match-string 0) existing)
          (delete-region (match-beginning 0) (match-end 0))
          (goto-char (match-beginning 0)))
        ;; Every store-owned line is now gone; whatever remains (banner plus
        ;; any non-store lines, in original relative order) is exactly what
        ;; the sorted block must be hoisted ABOVE -- so it always goes at
        ;; the end of what's left, never at the first match's old spot.
        (goto-char (point-max))
        (unless (or (bobp) (bolp)) (insert "\n"))
        (let* ((insert-pos (point))
               (ordered
                (sort (copy-sequence slugs)
                      (lambda (a b)
                        (> (or (gethash (concat a ".md") recency-map) -1)
                           (or (gethash (concat b ".md") recency-map) -1)))))
               (block (mapconcat
                       (lambda (slug)
                         (or (gethash slug existing)
                             (cc-butler-governance--index-line slug)))
                       ordered "")))
          (goto-char insert-pos)
          (insert block))
        (write-region (point-min) (point-max) index nil 'quiet)))))

(defun cc-butler-governance--normalize-index-format ()
  "Rewrite every OLD-format generated `MEMORY.md' line (see
`cc-butler-governance--legacy-index-line-regexp') to the CURRENT format,
for a slug whose store note still exists (`cc-butler-governance-names',
the same source `--dead-index-slugs' uses).

The single mechanism that actually shrinks a real `MEMORY.md': changing
`--render-index-line' alone only affects lines written from here on —
`--sync-index' is deliberately add-only and never touches a line that
already exists, so the ~566-598 lines already on disk in the old,
double-slug shape would otherwise sit there forever.

Calls `cc-butler-governance--index-line' per matched slug — the SAME
formatter `--sync-index' uses for a brand-new line — rather than
re-implementing description-lookup + truncate + render a second time, so
there is exactly one place that decides what a slug's rendered line looks
like.  This also means the description is freshly re-read from the
note's CURRENT frontmatter (truncated to
`cc-butler-governance--generated-description-max-bytes'), not preserved
from whatever text the old line held — the old line is being regenerated,
not merely reshaped.

A slug with no matching store note (a dangling legacy link) is left
untouched here — `--prune-dead-entries' recognizes only the current
format, so such a line will not be auto-pruned either; this is a known,
narrow gap (see the PR description), not a silent one.

Idempotent: a line already in the current format never matches the legacy
regexp, so a second call changes nothing.  Never deletes a line — a
matched legacy line is always replaced by exactly one new-format line for
the same slug, never removed outright.  Returns the slugs rewritten."
  (let ((index (cc-butler-governance--memory-index-file))
        (live (cc-butler-governance-names))
        (rewritten nil))
    (when (file-readable-p index)
      (with-temp-buffer
        (insert-file-contents index)
        (goto-char (point-min))
        (while (re-search-forward cc-butler-governance--legacy-index-line-regexp nil t)
          ;; Match positions captured explicitly and acted on with
          ;; goto-char/delete-region/insert rather than `replace-match' --
          ;; `--index-line' below does its OWN regex search (reading the
          ;; note's frontmatter, in a different buffer), and Emacs's match
          ;; data is a single global stack, not per-buffer: computing the
          ;; new line first and calling `replace-match' after would act on
          ;; already-clobbered match bounds.
          (let ((slug (match-string 1))
                (beg (match-beginning 0))
                (end (match-end 0)))
            (when (member slug live)
              (let ((new-line (cc-butler-governance--index-line slug)))
                (goto-char beg)
                (delete-region beg end)
                (insert new-line)
                (push slug rewritten)))))
        (write-region (point-min) (point-max) index nil 'quiet)))
    (nreverse rewritten)))

(defun cc-butler-governance--shrink-oversized-index-lines ()
  "Re-render every CURRENT-format `MEMORY.md' line whose byte length still
exceeds `cc-butler-governance-max-index-line-bytes' -- the case
`cc-butler-governance--normalize-index-format' does not cover, since that
function only matches the OLD double-slug shape and treats any line
already in the current shape as done regardless of length.

This exists because the description budget used to be a flat
`cc-butler-governance--generated-description-max-bytes' (48) with no
regard for how many of the 80 bytes the slug itself already spent --
most real slugs run 40-75 bytes, so nearly every generated line
exceeded the cap despite each description alone being within its own
limit (measured 2026-09-10: 587 real lines averaged 113 bytes against
an 80-byte cap). Re-renders via `cc-butler-governance--index-line' (now
slug-aware, see `cc-butler-governance--description-budget-bytes'), the
SAME formatter every other pass uses, so this can never diverge from
what a fresh line for that slug would look like.

Only ever rewrites a line it can PROVE is stale mechanical output, never
one that shows any sign of independent hand-authored wording -- the same
caution `--sync-index' and `--normalize-index-format' already take about
never clobbering a human's own text.  \"Provably mechanical\" here means
EITHER of two independent fingerprints:

  - the on-disk description, re-truncated to the OLD flat
    `cc-butler-governance--generated-description-max-bytes' (48) budget,
    byte-for-byte matches what `cc-butler-governance--truncate-bytes'
    would produce from the note's CURRENT frontmatter description at
    that SAME old 48-byte budget -- the identical comparison
    `cc-butler-governance--stale-index-entries' already uses to tell
    drifted or curated text apart from text that is still exactly what
    the old generator would write; or
  - (2026-09-10, the ellipsis-floor fix) the on-disk description is the
    bare ellipsis `\"…\"' AND this slug's
    `cc-butler-governance--description-budget-bytes' is below the
    ellipsis's own byte size (3) -- CONTENT-INDEPENDENT proof: the
    pre-fix `--truncate-bytes' deterministically produced exactly `\"…\"'
    at any such budget, regardless of what the description actually
    said, so a lone on-disk `\"…\"' at a sub-3-byte budget could only
    ever be that bug's output, never a human's.  (The first fingerprint
    above cannot recognize this case on its own: it compares against the
    48-byte budget, not the slug-aware one, and no real description
    truncates to a bare `\"…\"' at 48 bytes.)

A match on either means nothing about this line has diverged from
mechanical generation, so it is safe to re-render at the correct
slug-aware budget (which, for the second fingerprint, now correctly
renders the bare no-separator shape -- see
`cc-butler-governance--render-index-line').  A mismatch on BOTH -- on-disk
text neither generator would have produced from the current description
-- is left COMPLETELY untouched, oversized or not: it may be a line a
human curated with different wording on purpose (see
`cc-butler-governance/regenerate-does-not-duplicate-an-already-curated-entry'),
and this function has no way to tell that apart from real drift, so
neither is safe to overwrite here.  A note whose current description is
itself short enough to need no truncation at either budget trivially
matches and \"shrinks\" as a no-op -- expected, not a false positive,
since old-render and new-render are then identical anyway.

A slug whose boilerplate alone already meets or exceeds the cap will
still render over-length after this -- expected, not a bug (see
`cc-butler-governance--description-budget-bytes'); this function's job
is only to remove the WASTED bytes the old flat 48-byte budget left in
the description, not to guarantee every single line fits.

Idempotent: once a line is re-rendered at its minimum length for that
slug, a second call finds the same rendering and makes no further
change. Safe on lines this store did not generate:
`cc-butler-governance--index-line-regexp' only matches the current
generated shape, and any slug no longer present in the store (checked
against `cc-butler-governance-names') is skipped, matching the same
dead-link caution `--normalize-index-format' documents. Returns the
slugs rewritten."
  (let ((index (cc-butler-governance--memory-index-file))
        (live (cc-butler-governance-names))
        (rewritten nil))
    (when (file-readable-p index)
      (with-temp-buffer
        (insert-file-contents index)
        (goto-char (point-min))
        (while (re-search-forward
                (concat cc-butler-governance--index-line-regexp "\\(.*\\)$") nil t)
          (let* ((slug (match-string 1))
                 (indexed-desc (match-string 2))
                 (beg (match-beginning 0))
                 (end (min (point-max) (1+ (line-end-position)))))
            (if (and (member slug live)
                     (> (string-bytes (buffer-substring-no-properties beg end))
                        cc-butler-governance-max-index-line-bytes)
                     (or
                      ;; Fingerprint 1: on-disk text must equal the OLD
                      ;; 48-byte-budget rendering of the note's CURRENT
                      ;; description (same comparison `--stale-index-entries'
                      ;; uses, positive sense), or this is curated/drifted
                      ;; text, not mechanical output.
                      (let* ((note (expand-file-name (concat "butler-" slug ".md")
                                                      (cc-butler-governance-memory-store)))
                             (current (or (cc-butler-governance--frontmatter-description note)
                                          "(no description in store)")))
                        (equal (cc-butler-governance--truncate-bytes
                                current cc-butler-governance--generated-description-max-bytes)
                               indexed-desc))
                      ;; Fingerprint 2 (2026-09-10, ellipsis-floor fix):
                      ;; on-disk description is the bare ellipsis at a
                      ;; sub-3-byte slug-aware budget -- content-independent
                      ;; proof of the pre-fix `--truncate-bytes' bug, since
                      ;; that budget deterministically produced exactly "…"
                      ;; regardless of what the description said. This
                      ;; fingerprint's lifetime is the bug's lifetime: fixed
                      ;; `--truncate-bytes' returns "" (not "…") for any
                      ;; sub-3-byte budget, so no line generated AFTER this
                      ;; commit can ever match it again -- it exists only to
                      ;; repair lines a PRE-fix regenerate already wrote to
                      ;; disk, and stays dead code once those are gone. Safe
                      ;; to delete once no store's `MEMORY.md' can still hold
                      ;; a leftover pre-fix line (i.e. once every fleet
                      ;; member's `MEMORY.md' has been regenerated at least
                      ;; once on this commit or later).
                      (and (equal indexed-desc "…")
                           (< (cc-butler-governance--description-budget-bytes slug)
                              (string-bytes "…")))))
                (let ((new-line (cc-butler-governance--index-line slug)))
                  (goto-char beg)
                  (delete-region beg end)
                  (insert new-line)
                  (push slug rewritten))
              (goto-char end))))
        (write-region (point-min) (point-max) index nil 'quiet)))
    (nreverse rewritten)))

(defun cc-butler-governance--dedupe-bare-target-lines ()
  "Resolve every THIRD, even OLDER `MEMORY.md' line shape (see
`cc-butler-governance--bare-legacy-index-line-regexp') -- a bracket link
whose TARGET carries no `butler-' prefix at all, predating even the
prefix convention `--legacy-index-line-regexp' already assumes.  Real
store measured 2026-09-09: 20 such lines, ALL with a TARGET that already
has a canonical `- butler-TARGET.md — ' line elsewhere in the file --
true duplicates, not merely un-normalized ones, so unlike
`--normalize-index-format' this does not always rewrite in place:

  - TARGET already indexed elsewhere (the common real case) -> DELETE
    this line outright; rewriting it too would leave the slug indexed
    twice, which is exactly the bug this closes.
  - TARGET has no canonical line yet, but IS a live store slug -> REWRITE
    to the canonical form (same renderer `--normalize-index-format'
    uses), so the slug ends up indexed once, not zero times.
  - TARGET names no live store note at all -> leave the line completely
    untouched, the same as a dangling `--legacy-index-line-regexp' match.

The slug identity used throughout is the link TARGET (group 1 of the
regexp below), never the bracket DISPLAY text -- a real line found
2026-09-09 has display text truncated relative to its own target
\(`[steward-externalize-is-survival-insurance]
(steward-externalize-is-survival-insurance-not-just-compaction-hygiene.md)'\),
and only the target actually names a real store note.  This also doubles
as the safety gate against a line this store never generated at all: a
hand-authored personal-memory entry in the SAME bracket shape (real
examples found in the same file: `- [Daily standup process]
(daily-standup-process.md) — ...`) is excluded on TWO independent
grounds -- its display text fails the lowercase-kebab-slug character
class the regexp below requires, and even if it somehow matched
syntactically, its target names nothing in `cc-butler-governance-names',
so it falls into the untouched branch above, same as any other
non-store target.

Run AFTER `cc-butler-governance--normalize-index-format' (so an
un-normalized OLD-format, `butler-'-prefixed line has already become the
canonical shape and cannot be mistaken here for a duplicate TARGET) and
BEFORE `--sync-index' (so a slug this rewrites in place is not ALSO
appended as a second, brand-new line).  Returns a plist :removed
:rewritten of the TARGET slugs affected."
  (let* ((index (cc-butler-governance--memory-index-file))
         (live (cc-butler-governance-names))
         removed rewritten)
    (when (file-readable-p index)
      (with-temp-buffer
        (insert-file-contents index)
        (let ((canonical (cc-butler-governance--index-butler-slugs (buffer-string))))
          (goto-char (point-min))
          (while (re-search-forward
                  cc-butler-governance--bare-legacy-index-line-regexp nil t)
            (let ((target (match-string 1))
                  (beg (match-beginning 0))
                  (end (match-end 0)))
              (cond
               ((member target canonical)
                (delete-region beg end)
                (push target removed))
               ((member target live)
                (let ((new-line (cc-butler-governance--index-line target)))
                  (goto-char beg)
                  (delete-region beg end)
                  (insert new-line))
                (push target canonical)
                (push target rewritten))
               (t nil)))))
        (write-region (point-min) (point-max) index nil 'quiet)))
    (list :removed (nreverse removed) :rewritten (nreverse rewritten))))

;;;###autoload
(defun cc-butler-governance-regenerate ()
  "Regenerate the Claude Code memory cache from the neutral store — the store is
the source of truth; the memory is derived.  Also syncs `MEMORY.md's index
against it in six ways: rewrites any OLD-format generated line to the
current, shorter format (see `cc-butler-governance--normalize-index-format'
— run FIRST, so nothing below ever mistakes a not-yet-normalized legacy
line for a genuinely missing one), removes/rewrites any even-OLDER
bare-target-link duplicate (see
`cc-butler-governance--dedupe-bare-target-lines' — run SECOND, same
reason), shrinks any CURRENT-format line still over the byte cap (see
`cc-butler-governance--shrink-oversized-index-lines' — run THIRD, after
both format-migration passes so it only ever sees current-shape lines and
BEFORE the sort below, which reuses on-disk line text verbatim and would
otherwise reposition a still-oversized line instead of a fixed one), then
either re-sorts the store-owned entries by each principle's latest git
commit time, descending — so a note that keeps getting revised surfaces
near the top instead of wherever it happened to land historically (see
`cc-butler-governance--rewrite-sorted-index') — or, when the store is not
a git repo (or git itself is unavailable), falls back to the previous
add-only, insertion-order merge (`cc-butler-governance--sync-index');
either way `cc-butler-governance--last-sort-unavailable-reason' records
which happened, non-nil only on the fallback, for a caller to report
loudly rather than let a silent fallback pass as a normal run.  Finally
prunes any index line whose principle no longer exists in the store (see
`cc-butler-governance--prune-dead-entries' — the sort's own reinsertion
already drops a now-dead slug as a side effect, but this stays in place
as belt-and-suspenders, and is the ONLY cleanup on the fallback path,
since `--sync-index' never prunes) and refreshes the banner (see
`cc-butler-governance--refresh-banner') with the real, current
entries-in-budget figures computed against the final, post-sort content.
Returns the count of principles written."
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
      (setq slugs (nreverse slugs))
      (cc-butler-governance--normalize-index-format)
      (cc-butler-governance--dedupe-bare-target-lines)
      (cc-butler-governance--shrink-oversized-index-lines)
      (let ((recency (cc-butler-governance--commit-recency-map)))
        (setq cc-butler-governance--last-sort-unavailable-reason (cdr recency))
        (if (car recency)
            (cc-butler-governance--rewrite-sorted-index slugs (car recency))
          (cc-butler-governance--sync-index slugs)))
      (cc-butler-governance--prune-dead-entries)
      (cc-butler-governance--refresh-banner)
      (when (called-interactively-p 'interactive)
        (message "cc-butler: regenerated %d principle(s) from the store%s" n
                  (if cc-butler-governance--last-sort-unavailable-reason
                      (format " (git-based sort unavailable (%s): falling back to insertion order)"
                              cc-butler-governance--last-sort-unavailable-reason)
                    " (index sorted by git commit-recency)")))
      n)))

(defconst cc-butler-governance--index-line-regexp
  "^- butler-\\([a-z0-9][a-z0-9-]*\\)\\.md\\(?: — \\)?"
  "The one shape this store's CURRENT generated `MEMORY.md' lines are
recognized by (2026-09-09 single-slug format): `- butler-SLUG.md — DESC',
group 1 = SLUG.  Shared by `--index-butler-slugs', `--prune-dead-entries'
and `--stale-index-entries' (each appends its own tail on top of this
prefix) so a future format change is made in exactly one place — this
exact regex used to be duplicated 2-3x with matching risk, the same
\"same regex, only one copy updated\" shape this repo's CLAUDE.md warns
about from a real incident (#136/#146).  Anything hand-authored in a
different shape (no `butler-' marker, or a mismatched slug) never matches
— deliberately narrow, so nothing here can touch a line this store did
not itself generate.  See `cc-butler-governance--legacy-index-line-regexp'
for the OLD (pre-2026-09-09) shape, recognized only by
`--normalize-index-format'.

The ` — ' separator (2026-09-10, the ellipsis-floor fix) is OPTIONAL --
`\\(?: — \\)?', a non-capturing group -- because `--render-index-line' now
omits it entirely for a slug whose description truncated to empty (see
`cc-butler-governance--truncate-bytes'): the bare shape is
`- butler-SLUG.md\\n', with nothing between `.md' and the newline.  Group
1 is unaffected either way, and this still matches the OLD with-separator
shape identically -- the optional group happily consumes ` — ' when it is
there.

Deliberately still has NO anchor on the right edge (no `$', no length
requirement after the optional separator) -- it never did, even before
this change: this constant is always used as a shared PREFIX, and every
caller appends its own tail (`.*\\n?', `\\(.*\\)$', etc.) to consume
whatever comes after, exactly the shared-regex discipline documented
above.  So a hypothetical malformed line like `- butler-slug.mdxyz' (no
separator, and NOT immediately followed by a newline) would technically
still match this prefix (`- butler-slug.md', with `xyz' left over for
whatever tail pattern a caller appends) -- but this is not a new risk
introduced by making the separator optional, nor a realistic one: the
prefix's right edge was never anchored to begin with (a pre-existing
`- butler-slug.md — DESC-running-on-forever' line matched exactly the
same unanchored prefix), and the only producer of lines in this shape at
all is `--render-index-line' in this same file, which only ever emits
`.md — DESC\\n' or bare `.md\\n' -- never `.mdxyz'.  A hand-authored line
would also need the exact `butler-' marker and a well-formed lowercase-
kebab slug to match this far in the first place, which is precisely the
narrow-match property the rest of this docstring already relies on.")

(defconst cc-butler-governance--legacy-index-line-regexp
  "^- \\[\\([a-z0-9][a-z0-9-]*\\)\\](butler-\\1\\.md) — .*\n?"
  "The OLD (pre-2026-09-09) shape of a generated `MEMORY.md' line —
`- [SLUG](butler-SLUG.md) — DESC', SLUG written twice.  Recognized ONLY by
`--normalize-index-format', the one-time-per-line migration step that
rewrites each such line (for a slug whose store note still exists) to the
current shape via `--index-line'.  No other function in this file should
ever need this regex again once a store's `MEMORY.md' has been through one
`cc-butler-governance-regenerate' under the new format.")

(defconst cc-butler-governance--bare-legacy-index-line-regexp
  "^- \\[[a-z0-9][a-z0-9-]*\\](\\([a-z0-9][a-z0-9-]*\\)\\.md) — .*\n?"
  "A THIRD, even OLDER generated `MEMORY.md' line shape, predating even
the `butler-' filename-prefix convention `--legacy-index-line-regexp'
already assumes: `- [DISPLAY](TARGET.md) — DESC' with NO `butler-' prefix
on the link target at all.  Group 1 is the link TARGET -- deliberately
NOT the bracket display text, which `--dedupe-bare-target-lines' treats
as untrustworthy (a real line found 2026-09-09 has display text that is a
truncated, mismatched copy of its own target).

Recognized ONLY by `--dedupe-bare-target-lines'.  The lowercase-kebab
character class on BOTH the display and target halves is what keeps this
from ever matching a genuinely hand-authored personal-memory entry in the
same bracket shape (real examples in the same file: `- [Daily standup
process](daily-standup-process.md) — ...` -- capitalized, spaced display
text fails this class outright); `--dedupe-bare-target-lines' also never
trusts shape alone; it additionally requires the extracted TARGET to
appear in the real store's slug list before touching anything.")

(defun cc-butler-governance--index-butler-slugs (text)
  "Slugs of every line in TEXT shaped like this store's own generated entry
\(current format only — see `cc-butler-governance--index-line-regexp')."
  (let (slugs (start 0))
    (while (string-match cc-butler-governance--index-line-regexp text start)
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
                (concat cc-butler-governance--index-line-regexp ".*\n?") nil t)
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
                (concat cc-butler-governance--index-line-regexp "\\(.*\\)$") nil t)
          (let* ((slug (match-string 1))
                 (indexed-desc (match-string 2))
                 ;; Resolve the note the SAME way `cc-butler-governance-principles'
                 ;; does: a user-layer file with this basename OVERRIDES the
                 ;; store's, and the index line was generated from the RESOLVED
                 ;; copy.  Reading the store copy unconditionally reports every
                 ;; overridden note as drifted.  Measured 2026-09-10: after the
                 ;; byte-cap fix the store reported exactly one remaining drift,
                 ;; `haiku-summarization-delegation' -- and that is the one note
                 ;; whose basename exists in both layers.  It was not a drift;
                 ;; it was this bug.  True drift count was 0.
                 (user-file (and cc-butler-governance-user-dir
                                 (expand-file-name (concat slug ".md")
                                                   cc-butler-governance-user-dir)))
                 (store-file (if (and user-file (file-exists-p user-file))
                                 user-file
                               (expand-file-name (concat slug ".md")
                                                 (cc-butler-governance-store)))))
            (when (file-exists-p store-file)
              (let ((current (cc-butler-governance--frontmatter-description store-file)))
                ;; Compare like with like.  The index line holds a
                ;; BYTE-TRUNCATED copy of the description (`--index-line'
                ;; truncates to `--generated-description-max-bytes'), so
                ;; comparing it against the store's FULL description marks
                ;; every note whose description exceeds the cap as drifted
                ;; forever -- measured 2026-09-10: 569 of 569 notes with a
                ;; description, i.e. the check's signal was exactly zero and
                ;; it could never report a real drift.  Truncate the same way
                ;; before comparing.
                (when (and current
                           (not (equal (cc-butler-governance--truncate-bytes
                                        current
                                        cc-butler-governance--generated-description-max-bytes)
                                       indexed-desc)))
                  (push slug stale))))))))
    (nreverse stale)))

(defun cc-butler-governance--duplicate-index-slugs ()
  "Slugs that appear more than once in `MEMORY.md', counted across the
UNION of every generated-line shape this file currently recognizes: the
CURRENT format (`cc-butler-governance--index-line-regexp' /
`--index-butler-slugs'), the OLD prefixed-bracket format
\(`--legacy-index-line-regexp'), and the OLDEST bare-target bracket format
\(`--bare-legacy-index-line-regexp').  This is the THIRD axis, alongside
store->index (`--unindexed-names') and index->store (`--dead-index-slugs'),
neither of which can ever catch this: a duplicated slug satisfies both of
those perfectly (the note IS indexed, at least once; every index line DOES
point at a real note).

Counting only CURRENT-format lines (`--index-butler-slugs' alone, per its
own docstring) would miss the real-world case this check exists for: one
current-format line for a slug PLUS a leftover legacy-shaped line for the
SAME slug -- two different shapes, one duplicated slug, invisible to a
same-shape-only scan because it literally cannot see a line in a shape it
does not look for.  `--dedupe-bare-target-lines' only runs at regenerate
time, so a `MEMORY.md' that has not been regenerated since carries exactly
this cross-format duplication right now -- a check that can't see the
thing it exists to catch is worse than no check.  Widening the COUNTING
side here is safe (read-only, can only report) even though the ACTING
side (`--dedupe-bare-target-lines') deliberately stays narrow -- widening
that would risk rewriting/deleting a hand-authored line in the same
bracket shape, a risk pure counting never carries.

Slug identity is always the link TARGET, never bracket display text (see
`--dedupe-bare-target-lines' on why display text is untrustworthy) -- which
is why group 1 of all three regexps can be used directly with no
prefix/format massaging: the current format's only group IS the slug;
`--legacy-index-line-regexp' forces display=target via a `\\1' backreference
so its group 1 is the slug either way; `--bare-legacy-index-line-regexp's
group 1 is explicitly documented as the target.  Reuses the existing
`defconst's and `--index-butler-slugs' rather than re-deriving the
patterns.

`--bare-legacy-index-line-regexp' is a strict textual superset of
`--legacy-index-line-regexp' (same `- [DISPLAY](TARGET.md) — ' shape, just
without the backreference pinning TARGET to \"butler-DISPLAY\"), so an
un-normalized legacy line matches both -- real ones exist in the live
store right now.  A bare-legacy match whose captured target still starts
with \"butler-\" is therefore skipped: it is a `--legacy-index-line-regexp'
line the pipeline has not normalized yet, not a genuine bare-target line,
and counting it under that bogus \"butler-<slug>\" key would name a slug
that exists nowhere.  `--dedupe-bare-target-lines' never needs this guard
because it always runs AFTER `--normalize-index-format' has already
rewritten every `--legacy-index-line-regexp' line away; this read-only
counter has no such ordering guarantee, since the whole point of it is to
inspect a file that may not have been normalized yet.

Read-only, unlike `--dedupe-bare-target-lines': there is no single correct
way to collapse an arbitrary duplicate automatically (which wording wins?),
so this only surfaces the slug for a human or agent to resolve.  Returns
each duplicated slug once, sorted, not once per extra occurrence."
  (let ((index (cc-butler-governance--memory-index-file)))
    (when (file-readable-p index)
      (let* ((text (with-temp-buffer (insert-file-contents index) (buffer-string)))
             (counts (make-hash-table :test 'equal))
             dups)
        (dolist (slug (cc-butler-governance--index-butler-slugs text))
          (puthash slug (1+ (gethash slug counts 0)) counts))
        (let ((start 0))
          (while (string-match cc-butler-governance--legacy-index-line-regexp text start)
            (let ((slug (match-string 1 text)))
              (puthash slug (1+ (gethash slug counts 0)) counts))
            (setq start (match-end 0))))
        ;; `--bare-legacy-index-line-regexp' is a strict textual superset of
        ;; `--legacy-index-line-regexp' -- same `- [DISPLAY](TARGET.md) — '
        ;; shape, just without the backreference pinning TARGET to
        ;; "butler-DISPLAY".  An un-normalized legacy line (real ones exist
        ;; in the live store right now) therefore matches BOTH regexps, and
        ;; without this guard would double-count under a bogus
        ;; "butler-<slug>" key that names no real store slug -- the two
        ;; regexes are only mutually exclusive downstream, in
        ;; `--dedupe-bare-target-lines', because it always runs AFTER
        ;; `--normalize-index-format' has already rewritten every
        ;; `--legacy-index-line-regexp' line away; this read-only counter has
        ;; no such ordering guarantee, since it exists precisely to inspect a
        ;; file that may not have been normalized yet.
        (let ((start 0))
          (while (string-match cc-butler-governance--bare-legacy-index-line-regexp text start)
            (let ((slug (match-string 1 text)))
              (unless (string-prefix-p "butler-" slug)
                (puthash slug (1+ (gethash slug counts 0)) counts)))
            (setq start (match-end 0))))
        (maphash (lambda (slug n) (when (> n 1) (push slug dups))) counts)
        (sort dups #'string<)))))

;;;; ------------------------------------------------------------------
;;;; The banner (the first ~N lines of MEMORY.md every session reads first)
;;;; ------------------------------------------------------------------

(defconst cc-butler-governance--memory-read-budget-bytes 24712
  "The Claude Code memory-load hook's real cumulative read-in budget for
`MEMORY.md', in bytes -- measured directly against the hook's own
behavior (2026-09-09, the same real-store measurement PR #209 relied on
by hand), NOT derived from anything this file generates.  Treat this as
an externally observed constant and re-measure it against the hook
itself if it ever needs updating -- recomputing it from the banner's own
old text would be exactly the self-referential-budget mistake the
#207/#209 chain already made once.")

(defun cc-butler-governance--entries-within-budget (text)
  "How many of TEXT's current-format index lines (see
`cc-butler-governance--index-line-regexp') are still fully inside
`cc-butler-governance--memory-read-budget-bytes' cumulative bytes counted
from the very start of TEXT -- banner included, since the read-in hook
has no way to skip past it.  The same cumulative-byte-budget technique
PR #209 used by hand to measure the hook's real behavior, now run by the
generator itself so a banner claim built from this never goes stale
between regenerates the way a hand-typed one silently did."
  (let ((n 0) (bytes 0))
    (with-temp-buffer
      (insert text)
      (goto-char (point-min))
      (while (not (eobp))
        (let* ((eol (min (point-max) (1+ (line-end-position))))
               (line (buffer-substring-no-properties (line-beginning-position) eol)))
          (setq bytes (+ bytes (string-bytes line)))
          (when (and (<= bytes cc-butler-governance--memory-read-budget-bytes)
                     (string-match-p cc-butler-governance--index-line-regexp line))
            (setq n (1+ n))))
        (forward-line 1)))
    n))

(defun cc-butler-governance--strip-banner (text)
  "TEXT with any leading banner block -- every line at the very start that
begins with `> ', plus any blank line right after it -- removed.  Applies
regardless of whether that banner is one `--generate-banner' itself wrote
on a prior regenerate or a hand-typed one predating this mechanism; either
way `--refresh-banner' replaces it wholesale, so what mattered was only
finding where it ends, not what it said."
  (with-temp-buffer
    (insert text)
    (goto-char (point-min))
    (while (and (not (eobp)) (looking-at-p "^>"))
      (forward-line 1))
    (while (and (not (eobp)) (looking-at-p "^$"))
      (forward-line 1))
    (buffer-substring-no-properties (point) (point-max))))

(defun cc-butler-governance--generate-banner (n total)
  "The banner text for `MEMORY.md', stating the real N-of-TOTAL
entries-in-budget figures.  Fully generator-owned from here on, like a
single index line: `--refresh-banner' replaces this in full on every
`cc-butler-governance-regenerate', so a hand edit here survives only
until the next call -- the same rule already applied to a single index
line, now applied to this whole block instead of leaving it to drift
\(the block this replaces stated a fixed \"73 of 577\" that only ever grew
more wrong; see the PR that closed this gap)."
  (format
   "> **READ THIS FIRST — %d of %d entries (%d%%) reach your context; the rest sit below a byte budget and will not fire.**
> Grep the store directly before concluding \"no principle covers this\": `~/obsidian/warmble-jumble/3-resources/cc-butler-governance/`
> Recording a new principle does NOT make it fire immediately — new entries append at the bottom, past the cut, until the store is re-triaged.

"
   n total (round (* 100 (/ (float n) (float (max total 1)))))))

(defun cc-butler-governance--refresh-banner ()
  "Rewrite `MEMORY.md's leading banner block with the real, current
N-of-TOTAL entries-in-budget figures (see `cc-butler-governance--generate-banner'),
replacing whatever banner -- generated or hand-edited -- currently sits
there.  Run LAST in `cc-butler-governance-regenerate', after every other
index mutation, so the entries counted are the final ones a session will
actually see.

The N used here is computed against a banner already carrying its own
real TOTAL (only N starts as a 0-byte placeholder for the one pass this
takes to measure) -- close enough that the 1-2 byte difference between a
placeholder and the real N's digit count could only ever matter if a line
sits exactly on the budget boundary, the same tolerance PR #209's own
by-hand measurement already accepted."
  (let ((index (cc-butler-governance--memory-index-file)))
    (when (file-readable-p index)
      (let* ((text (with-temp-buffer (insert-file-contents index) (buffer-string)))
             (entries (cc-butler-governance--strip-banner text))
             (total (length (cc-butler-governance--index-butler-slugs entries)))
             (n (cc-butler-governance--entries-within-budget
                 (concat (cc-butler-governance--generate-banner 0 total) entries))))
        (write-region (concat (cc-butler-governance--generate-banner n total) entries)
                       nil index nil 'quiet)))))

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

(defun cc-butler-governance--strip-stamps (body expected)
  "BODY with a trailing copy of EXPECTED removed, if BODY ends with exactly
that line.

EXPECTED is the note's actual existing stamp (nil for a brand-new note that
has none).  Root-cause fix for issue #140's write-side half: the old version
stripped ANY line merely shaped like a stamp, so an author's own genuine last
line — coincidentally shaped that way, on a brand-new note where no real
stamp can possibly exist yet — was silently deleted as if it were a
caller-pasted duplicate.  Comparing against the specific stamp this call
already knows to be real, rather than against the generic shape, means a
line only gets removed when it truly IS a copy of something the tool itself
already wrote — never merely because it resembles one."
  (let* ((body (string-trim-right (or body ""))))
    (string-trim
     (if (and expected
              (>= (length body) (length expected))
              (equal (substring body (- (length body) (length expected))) expected))
         (substring body 0 (- (length body) (length expected)))
       body))))

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

(defun cc-butler-governance--render (slug description body type &optional stamp existing)
  "The full file text for a principle, frontmatter included.
Written here rather than by the caller so the schema cannot be got wrong —
`name:' matching the generated note, the quoting of DESCRIPTION, and the
`metadata:' block are all things a caller would have to know and would
eventually get subtly wrong.

EXISTING is the note's real prior stamp (nil if it has none), passed through
to `cc-butler-governance--strip-stamps' so only a genuine duplicate of it is
ever removed from BODY — never a line that merely looks like a stamp."
  (concat "---\n"
          "name: " cc-butler-governance--name-prefix slug "\n"
          "description: \""
          (cc-butler-governance--clean-description description) "\"\n"
          "metadata:\n"
          "  node_type: memory\n"
          "  type: " (or type "feedback") "\n"
          "---\n\n"
          (cc-butler-governance--strip-stamps body existing)
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
          ;; This reads the note's OWN file back -- a trailing stamp-shaped
          ;; line here, unlike a freshly-submitted BODY, cannot be a pasted
          ;; foreign copy: it is by definition whatever this note's real
          ;; stamp already is, so shape-matching it is exactly the "expected"
          ;; value (never a false strip of genuine content).
          (let ((text (buffer-substring-no-properties (point) (point-max))))
            (cc-butler-governance--strip-stamps
             text (cc-butler-governance--stamp-line text))))))))

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
         (before (cc-butler-governance--note-count))
         ;; Computed once, here, and reused by every cap/guard check below
         ;; AND by `--render' at write time -- so "what counts as this
         ;; note's real existing stamp" can never disagree between the size
         ;; checks and the actual write (issue #140 write-side fix).
         (prior (and existed (cc-butler-governance--existing-stamp path))))
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
             (new-bytes (string-bytes (cc-butler-governance--strip-stamps body prior))))
        (when (and old-bytes (> old-bytes 0)
                   (< new-bytes (* old-bytes cc-butler-governance-shrink-guard-fraction)))
          (user-error "%s" (cc-butler-governance--shrink-guard-message
                            slug old-bytes new-bytes)))))
    ;; Checked on every call, not only new ones — an update that pads an
    ;; existing note past the cap is the append-instead-of-add workaround
    ;; the count cap alone opens up (정수님, 2026-09-08).
    (when (> (string-bytes (cc-butler-governance--strip-stamps body prior))
             cc-butler-governance-max-note-bytes)
      (user-error "%s" (cc-butler-governance--length-message
                        slug (cc-butler-governance--strip-stamps body prior))))
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
               (if existed prior (cc-butler-governance--mint-stamp))
               prior)))
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
     (format "\nStore file : %s\nMemory note: %s\n             (internal cache copy, NOT a link target — link to this note as [[%s]], never as [[%s%s]])\nNotes       : %d -> %d\nVerified    : %s\n"
             (plist-get res :path)
             (plist-get res :note)
             (plist-get res :slug)
             cc-butler-governance--name-prefix (plist-get res :slug)
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

(defun cc-butler-governance--cap-report-line ()
  "Unconditional one-line report of the store's cap state — count against
`cc-butler-governance-max-notes', and any note whose body is over
`cc-butler-governance-max-note-bytes' — independent of whatever else this
regenerate call finds to fix.

THE GAP THIS CLOSES (2026-09-08): a note edited directly with Write/Edit
never goes through `cc-butler-governance-record', so it never hits either
cap — see `cc-butler-tool-regenerate-governance''s own HONEST GAP note.
`regenerate_governance' was called 4 times the night this was written while
the store sat at 566/250 notes and one note's body sat at 16.4KB/2KB; every
call reported plain success, because nothing in this report ever looked at
the caps again once a note had bypassed them.

Report-only, on purpose: refusing to regenerate because the store is
over-cap would leave the cache/index stale ON TOP of the store already
being over, which is strictly worse — this function never blocks anything.
And it always prints, over-cap or not: a line that only speaks up when
something is wrong is indistinguishable, from outside, from a check that
never ran at all — which is exactly the ambiguity 4 straight silent
successes exploited.

The printed line names its own population and byte basis (top-level .md
only, README/roles//user-layer excluded, bytes measured on note body) so
it can never be misread as a store-wide max — this docstring does not
duplicate that count independently, so it can't drift from what the line
actually says."
  (let* ((count (cc-butler-governance--store-note-count))
         (max cc-butler-governance-max-notes)
         (oversized (cc-butler-governance--oversized-notes))
         (n-over (length oversized)))
    (format "창고 %d / 상한 %d — %s. 2K 초과 노트 %d개%s [범위: 최상위 .md · README·roles/·사용자층 제외 · 바이트는 body 기준]\n"
            count max
            (if (> count max)
                (format "%.1f배 초과" (/ (float count) max))
              "이내")
            n-over
            (if oversized
                (format " (최대 %.1fK: %s)"
                        (/ (cdar oversized) 1024.0) (caar oversized))
              "."))))

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
it is is worse than no check — it ends the search.  A FOURTH axis closed
2026-09-09: store->index and index->store both report clean when a slug
is indexed TWICE (the note IS indexed, at least once; every line DOES
point at a real note), so neither ever catches a real duplication —
`cc-butler-governance--duplicate-index-slugs' is the check that does.
The report below now states plainly what was actually verified, in four
directions: store -> index, index -> store, description drift, and
duplicate slugs."
  (let* ((before (cc-butler-governance--unindexed-names))
         (dead-before (cc-butler-governance--dead-index-slugs))
         (n (cc-butler-governance-regenerate))
         (after (cc-butler-governance--unindexed-names))
         (dead-after (cc-butler-governance--dead-index-slugs))
         (stale (cc-butler-governance--stale-index-entries))
         (dup (cc-butler-governance--duplicate-index-slugs)))
    (concat
     (cc-butler-governance--cap-report-line)
     (format "Regenerated %d principle(s) from the store.\n" n)
     (if cc-butler-governance--last-sort-unavailable-reason
         (format "Index sort: git-based sort unavailable (%s): falling back to insertion order.\n"
                 cc-butler-governance--last-sort-unavailable-reason)
       "Index sort: entries ordered by git commit-recency, most recently committed first.\n")
     "Checked: store->index (notes missing an index line), index->store (index lines whose principle no longer exists), description drift (index text vs each note's current frontmatter), and duplicate slugs (any slug indexed more than once).\n"
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
     (if dup
         (format "Index self-check: %d slug(s) indexed more than once: %s — store->index and index->store both report clean on a duplicate, so this is the only check that catches it; investigate cc-butler-governance--duplicate-index-slugs.\n"
                 (length dup) (string-join dup ", "))
       "Index self-check: 0 slug(s) indexed more than once.\n")
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
  (cc-butler--make-guarded-tool
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
  (cc-butler--make-guarded-tool
   :function #'cc-butler-tool-regenerate-governance
   :name "regenerate_governance"
   :description "Bare-trigger governance cache/index regeneration, no arguments. Call this once after writing directly to a governance/*.md store file with Write/Edit (i.e. NOT through record_principle) — that direct write is never followed by a regenerate on its own, so the note can sit in the store and never reach the cache or the MEMORY.md index until this is called. Safe to call any time with nothing new, too: it reports exactly how many store notes are currently un-indexed (0 means fully synced), so it also works as a standalone check for a forgotten sync."
   :args nil))

(provide 'cc-butler-governance)
;;; cc-butler-governance.el ends here
