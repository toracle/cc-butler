;;; cc-butler-governance-test.el --- tests for the 2-tier store  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jeongsoo Park
;; SPDX-License-Identifier: MIT

(require 'ert)
(require 'cc-butler-governance)

(ert-deftest cc-butler-governance/dualize-merges-user-layer ()
  "Principles = built-in generic + the user's private layer; a same-basename user
file OVERRIDES the built-in of that name; README is excluded; result is sorted."
  (let ((builtin (make-temp-file "gov-b" t))
        (user (make-temp-file "gov-u" t)))
    (unwind-protect
        (let ((cc-butler-governance-dir builtin)
              (cc-butler-governance-user-dir user))
          (with-temp-file (expand-file-name "a.md" builtin) (insert "built-in a"))
          (with-temp-file (expand-file-name "b.md" builtin) (insert "built-in b"))
          (with-temp-file (expand-file-name "README.md" builtin) (insert "readme"))
          (with-temp-file (expand-file-name "b.md" user) (insert "USER b override"))
          (with-temp-file (expand-file-name "c.md" user) (insert "user c"))
          (let* ((ps (cc-butler-governance-principles))
                 (names (mapcar #'file-name-nondirectory ps)))
            (should (equal names '("a.md" "b.md" "c.md")))   ; merged, sorted, no README
            (let ((bfile (seq-find (lambda (f) (equal (file-name-nondirectory f) "b.md")) ps)))
              (should (string-match-p "USER b override"
                                      (with-temp-buffer (insert-file-contents bfile)
                                                        (buffer-string)))))))
      (delete-directory builtin t)
      (delete-directory user t))))

(ert-deftest cc-butler-governance/no-user-dir-is-builtin-only ()
  "With no user dir set, principles are the built-in set only (package default)."
  (let ((builtin (make-temp-file "gov-b2" t)))
    (unwind-protect
        (let ((cc-butler-governance-dir builtin) (cc-butler-governance-user-dir nil))
          (with-temp-file (expand-file-name "a.md" builtin) (insert "a"))
          (should (= 1 (length (cc-butler-governance-principles)))))
      (delete-directory builtin t))))

;;;; ------------------------------------------------------------------
;;;; Where the store is  (the 2026-07-23 silent-failure root cause)
;;;; ------------------------------------------------------------------

(ert-deftest cc-butler-governance/store-follows-the-loaded-code ()
  "REGRESSION (2026-07-23): the store path was a `defcustom' default computed
from `load-file-name'.  A defcustom default binds once and survives every
later reload, so hot-loading the code from another checkout moved the code
and left the store pointing at the old installation.  With no explicit
setting the store must be derived from wherever the loaded code lives."
  (let ((cc-butler-governance-dir nil)
        (cc-butler-governance--load-dir "/tmp/some-checkout/"))
    (should (equal (cc-butler-governance-store) "/tmp/some-checkout/governance/"))))

(ert-deftest cc-butler-governance/explicit-store-setting-wins ()
  "Deriving is the default, not a policy: an explicitly configured store is
still honoured, so pointing it outside the source tree keeps working."
  (let ((cc-butler-governance-dir "/srv/principles")
        (cc-butler-governance--load-dir "/tmp/some-checkout/"))
    (should (equal (cc-butler-governance-store) "/srv/principles/"))))

(ert-deftest cc-butler-governance/store-is-derived-not-frozen-at-definition ()
  "The load directory is a `defconst' precisely so it re-evaluates on reload.
If it ever becomes a `defvar'/`defcustom' default again the original bug is
back, so pin the property itself rather than trusting the declaration."
  (let ((cc-butler-governance-dir nil))
    (let ((cc-butler-governance--load-dir "/checkout-a/"))
      (should (equal (cc-butler-governance-store) "/checkout-a/governance/")))
    (let ((cc-butler-governance--load-dir "/checkout-b/"))
      (should (equal (cc-butler-governance-store) "/checkout-b/governance/")))))

;;;; ------------------------------------------------------------------
;;;; Where the memory cache is  (the 2026-09-01 sibling of the above —
;;;; `cc-butler-governance-memory-dir' had the identical defcustom-default
;;;; shape and was never converted when `cc-butler-governance-dir' was.
;;;; Confirmed live: `cc-butler-orchestrator.el' requires this file before
;;;; it defines `cc-butler-home', so on every normal boot the frozen
;;;; default landed on the hardcoded ~/.ccsm fallback and stayed there —
;;;; every record_principle/regenerate_governance call kept writing to a
;;;; directory no session's startup memory-load ever reads.
;;;;
;;;; NOTE on what these tests actually prove, vs what they don't: what
;;;; follows exercises `cc-butler-governance-memory-store' the same way
;;;; `store-is-derived-not-frozen-at-definition' above exercises its
;;;; sibling — two `let'-bindings of an input in the SAME Emacs process,
;;;; asserting the accessor's output tracks each. That proves "the
;;;; accessor recomputes from its input on every call," not "this variable
;;;; is immune to the original freeze-on-first-load defect" — a real
;;;; cross-process reload can't be simulated inside one `ert-deftest'. THAT
;;;; guarantee is structural, not tested: it comes from `cc-butler-home'
;;;; and `cc-butler--claude-memory-dir' being ordinary `defun'/`defcustom'
;;;; values read fresh inside a function body (never captured into another
;;;; defcustom's default form), the same reasoning
;;;; `cc-butler-governance--load-dir's docstring gives for why a `defconst'
;;;; re-evaluates on reload. Keep both kinds of guarantee — and the
;;;; distinction between them — visible; conflating "tested" with
;;;; "structurally guaranteed" is exactly how the original defect went
;;;; unnoticed this long.
;;;; ------------------------------------------------------------------

(ert-deftest cc-butler-governance/memory-store-follows-cc-butler-home ()
  "With no explicit `cc-butler-governance-memory-dir' override, the memory
path must derive from `cc-butler-home' via `cc-butler--claude-memory-dir' —
never from a value captured once and reused."
  (let ((cc-butler-governance-memory-dir nil)
        (cc-butler-home "/some/butler/home"))
    (should (equal (cc-butler-governance-memory-store)
                   (file-name-as-directory
                    (cc-butler--claude-memory-dir "/some/butler/home"))))))

(ert-deftest cc-butler-governance/memory-store-is-derived-not-frozen-at-definition ()
  "Two different `cc-butler-home' values, read within the SAME process, must
produce two different effective memory paths. See the section comment above
for exactly what this test does and does not prove."
  (let ((cc-butler-governance-memory-dir nil))
    (let ((cc-butler-home "/home-a"))
      (should (equal (cc-butler-governance-memory-store)
                     (file-name-as-directory (cc-butler--claude-memory-dir "/home-a")))))
    (let ((cc-butler-home "/home-b"))
      (should (equal (cc-butler-governance-memory-store)
                     (file-name-as-directory (cc-butler--claude-memory-dir "/home-b")))))
    ;; And the two must actually differ, or the assertions above would both
    ;; pass vacuously against a value that never moved.
    (should-not (equal (let ((cc-butler-home "/home-a")) (cc-butler-governance-memory-store))
                        (let ((cc-butler-home "/home-b")) (cc-butler-governance-memory-store))))))

(ert-deftest cc-butler-governance/memory-store-explicit-setting-wins ()
  "Deriving is the default, not a policy: an explicit override still wins
over whatever `cc-butler-home' says, same as `cc-butler-governance-dir'."
  (let ((cc-butler-governance-memory-dir "/explicit/memory/dir")
        (cc-butler-home "/some/butler/home"))
    (should (equal (cc-butler-governance-memory-store) "/explicit/memory/dir/"))))

;;;; ------------------------------------------------------------------
;;;; Recording a principle
;;;; ------------------------------------------------------------------

(defmacro cc-butler-governance-test--with-store (&rest body)
  "Run BODY with a throwaway store and memory dir wired together."
  (declare (indent 0))
  `(let* ((store (file-name-as-directory (make-temp-file "gov-store" t)))
          (mem (file-name-as-directory (make-temp-file "gov-mem" t)))
          (cc-butler-governance-dir store)
          (cc-butler-governance-user-dir nil)
          (cc-butler-governance-memory-dir mem))
     (unwind-protect (progn ,@body)
       (delete-directory store t)
       (delete-directory mem t))))

(ert-deftest cc-butler-governance/record-writes-the-store-frontmatter ()
  "The tool writes the frontmatter, so a caller cannot get the schema wrong.
Shape must match the files already in the store: a butler- prefixed name, a
quoted description, and the metadata block."
  (cc-butler-governance-test--with-store
    (let* ((res (cc-butler-governance-record
                 "verify-delivery" "Confirm it landed" "Body of the rule."))
           (text (with-temp-buffer (insert-file-contents (plist-get res :path))
                                   (buffer-string))))
      (should (equal (plist-get res :slug) "verify-delivery"))
      (should (string-match-p "^name: butler-verify-delivery$" text))
      (should (string-match-p "^description: \"Confirm it landed\"$" text))
      (should (string-match-p "^  node_type: memory$" text))
      (should (string-match-p "^  type: feedback$" text))
      (should (string-match-p "Body of the rule\\." text)))))

(ert-deftest cc-butler-governance/record-verifies-the-note-landed ()
  "The whole point: success is claimed only after the generated note is read
back off disk and found to name this principle."
  (cc-butler-governance-test--with-store
    (let ((res (cc-butler-governance-record "a-rule" "d" "body")))
      (should (plist-get res :verified))
      (should (equal (plist-get res :before) 0))
      (should (equal (plist-get res :after) 1))
      (should (file-exists-p (plist-get res :note))))))

(ert-deftest cc-butler-governance/record-reports-failure-when-nothing-lands ()
  "REGRESSION (2026-07-23): `regenerate' answered \"regenerated\" three times
while landing nothing, because it read a different store than the one being
written.  A regeneration that copies nothing must come back as a FAILURE,
never as a success with an encouraging count."
  (cc-butler-governance-test--with-store
    (cl-letf (((symbol-function 'cc-butler-governance-regenerate) (lambda () 0)))
      (let* ((res (cc-butler-governance-record "lost-rule" "d" "body"))
             (out (cc-butler-tool-record-principle "lost-rule" "d" "body")))
        (should-not (plist-get res :verified))
        ;; The store file was still written — it is the memory that is missing.
        (should (file-exists-p (plist-get res :path)))
        (should (string-match-p "FAILED" out))
        (should-not (string-match-p "Recorded principle" out))
        ;; and it names both paths, which are the two things to compare
        (should (string-match-p (regexp-quote cc-butler-governance-memory-dir) out))))))

(ert-deftest cc-butler-governance/record-updates-an-existing-principle-in-place ()
  "Revising a principle is the normal case; a near-duplicate under a new name
is how a store stops being a source of truth.  Same name overwrites, and the
store does not grow."
  (cc-butler-governance-test--with-store
    (cc-butler-governance-record "a-rule" "first" "original body")
    (let ((res (cc-butler-governance-record "a-rule" "second" "revised body")))
      (should (plist-get res :existed))
      (should (equal (plist-get res :names) '("a-rule")))
      (should (equal (plist-get res :after) 1))
      (let ((text (with-temp-buffer (insert-file-contents (plist-get res :path))
                                    (buffer-string))))
        (should (string-match-p "revised body" text))
        (should-not (string-match-p "original body" text))))))

(ert-deftest cc-butler-governance/record-returns-the-existing-names ()
  "The caller gets the current roster back for free, which is what makes
`update the right one' the easy move rather than a lookup they must ask for."
  (cc-butler-governance-test--with-store
    (cc-butler-governance-record "b-rule" "d" "body")
    (let ((res (cc-butler-governance-record "a-rule" "d" "body")))
      (should (equal (plist-get res :names) '("a-rule" "b-rule"))))))

(ert-deftest cc-butler-governance/record-normalises-the-name ()
  "The frontmatter carries the butler- prefix and the filename does not — a
distinction no caller should have to remember."
  (cc-butler-governance-test--with-store
    (should (equal (plist-get (cc-butler-governance-record
                               "butler-prefixed" "d" "body") :slug)
                   "prefixed"))
    (should (equal (plist-get (cc-butler-governance-record
                               "Spaced Name.md" "d" "body") :slug)
                   "spaced-name"))))

(ert-deftest cc-butler-governance/record-refuses-junk ()
  "A bad name or an empty body fails loudly rather than quietly creating an
unusable principle in the store."
  (cc-butler-governance-test--with-store
    (should-error (cc-butler-governance-record "../escape" "d" "body"))
    (should-error (cc-butler-governance-record "ok-name" "d" "   "))))

(ert-deftest cc-butler-governance/record-takes-no-path-argument ()
  "The tool must not let a caller choose where to write: writer and reader
disagreeing about the store location is the original defect, and a path
argument would reintroduce it one call at a time."
  (let ((spec (seq-find (lambda (s)
                          (equal (plist-get (claude-code-ide--normalize-tool-spec s) :name)
                                 "record_principle"))
                        (bound-and-true-p claude-code-ide-mcp-server-tools))))
    (when spec   ; only when claude-code-ide is present to register against
      (let ((args (plist-get (claude-code-ide--normalize-tool-spec spec) :args)))
        (should-not (seq-find (lambda (a)
                                (string-match-p "dir\\|path\\|store"
                                                (plist-get a :name)))
                              args))))))

;;;; ------------------------------------------------------------------
;;;; Syncing the MEMORY.md index (cc-butler#36 gap b)
;;;; ------------------------------------------------------------------

(ert-deftest cc-butler-governance/regenerate-adds-missing-notes-to-the-index ()
  "The whole point of this fix: a note that lands in the cache but never gets
an index line is invisible to every future session — regenerate must add one,
pulling the hook text from the note's own frontmatter description."
  (cc-butler-governance-test--with-store
    (with-temp-file (expand-file-name "verify-delivery.md" store)
      (insert (cc-butler-governance--render
               "verify-delivery" "Confirm it landed" "Body." "feedback")))
    (cc-butler-governance-regenerate)
    (let ((index (expand-file-name "MEMORY.md" mem)))
      (should (file-exists-p index))
      (let ((text (with-temp-buffer (insert-file-contents index) (buffer-string))))
        (should (string-match-p "\\[verify-delivery\\](butler-verify-delivery\\.md)" text))
        (should (string-match-p "Confirm it landed" text))))))

(ert-deftest cc-butler-governance/regenerate-index-merge-preserves-hand-written-lines ()
  "MEMORY.md is hand-maintained and carries entries this store doesn't own
(steward notes, unrelated links). Regenerate must merge additively — never
overwrite or drop a line it didn't add."
  (cc-butler-governance-test--with-store
    (let ((index (expand-file-name "MEMORY.md" mem))
          (hand-written "- [steward-only-note](steward-only-note.md) — hand-authored, no matching store file\n"))
      (with-temp-file index (insert hand-written))
      (with-temp-file (expand-file-name "a-rule.md" store)
        (insert (cc-butler-governance--render "a-rule" "d" "body" "feedback")))
      (cc-butler-governance-regenerate)
      (let ((text (with-temp-buffer (insert-file-contents index) (buffer-string))))
        (should (string-match-p (regexp-quote hand-written) text))
        (should (string-match-p "\\[a-rule\\](butler-a-rule\\.md)" text))))))

(ert-deftest cc-butler-governance/regenerate-index-merge-is-idempotent ()
  "Running regenerate twice must not duplicate an already-indexed note's line."
  (cc-butler-governance-test--with-store
    (with-temp-file (expand-file-name "a-rule.md" store)
      (insert (cc-butler-governance--render "a-rule" "d" "body" "feedback")))
    (cc-butler-governance-regenerate)
    (cc-butler-governance-regenerate)
    (let* ((index (expand-file-name "MEMORY.md" mem))
           (text (with-temp-buffer (insert-file-contents index) (buffer-string)))
           (count 0) (start 0))
      (while (string-match "\\[a-rule\\](butler-a-rule\\.md)" text start)
        (setq count (1+ count) start (match-end 0)))
      (should (= count 1)))))

(ert-deftest cc-butler-governance/regenerate-does-not-duplicate-an-already-curated-entry ()
  "If a slug already has a hand-curated line (worded differently from the
frontmatter description), regenerate must not add a second, auto-generated
line for the same note — that would produce two competing entries for one slug."
  (cc-butler-governance-test--with-store
    (let ((index (expand-file-name "MEMORY.md" mem))
          (curated "- [a-rule](butler-a-rule.md) — a human's own curated wording, not the frontmatter description\n"))
      (with-temp-file index (insert curated))
      (with-temp-file (expand-file-name "a-rule.md" store)
        (insert (cc-butler-governance--render
                 "a-rule" "totally different auto description" "body" "feedback")))
      (cc-butler-governance-regenerate)
      (let ((text (with-temp-buffer (insert-file-contents index) (buffer-string))))
        (should (string-match-p (regexp-quote curated) text))
        (should-not (string-match-p "totally different auto description" text))))))

(ert-deftest cc-butler-governance/regenerate-index-falls-back-when-no-description ()
  "A store note somehow missing/malformed frontmatter still gets indexed, with
a placeholder hook instead of crashing the whole regenerate call."
  (cc-butler-governance-test--with-store
    (with-temp-file (expand-file-name "raw-rule.md" store) (insert "no frontmatter here"))
    (cc-butler-governance-regenerate)
    (let* ((index (expand-file-name "MEMORY.md" mem))
           (text (with-temp-buffer (insert-file-contents index) (buffer-string))))
      (should (string-match-p "\\[raw-rule\\](butler-raw-rule\\.md)" text)))))

;;;; ------------------------------------------------------------------
;;;; Bare-trigger regeneration for direct writes (cc-butler#36 gap a)
;;;; ------------------------------------------------------------------

(ert-deftest cc-butler-governance/regenerate-tool-syncs-a-directly-written-note ()
  "A note written straight to the store (Write/Edit, bypassing
record_principle) never calls regenerate itself. This tool is the bare
trigger an agent calls after that write — it must land the note in BOTH
the cache and the MEMORY.md index, and say so in its report."
  (cc-butler-governance-test--with-store
    (with-temp-file (expand-file-name "direct-write-rule.md" store)
      (insert (cc-butler-governance--render
               "direct-write-rule" "written directly, not via record_principle"
               "body" "feedback")))
    (let ((out (cc-butler-tool-regenerate-governance)))
      (should (file-exists-p (expand-file-name "butler-direct-write-rule.md" mem)))
      (let ((index-text (with-temp-buffer
                          (insert-file-contents (expand-file-name "MEMORY.md" mem))
                          (buffer-string))))
        (should (string-match-p "\\[direct-write-rule\\](butler-direct-write-rule\\.md)"
                                index-text)))
      (should (string-match-p "direct-write-rule" out)))))

(ert-deftest cc-butler-governance/regenerate-tool-reports-zero-gap-when-current ()
  "Calling the tool with nothing new to sync must say so plainly (0 remaining),
not just silently succeed — that visibility is the point: if a caller forgets
to invoke this after a direct write, running it later still surfaces whether
a gap exists right now."
  (cc-butler-governance-test--with-store
    (with-temp-file (expand-file-name "a-rule.md" store)
      (insert (cc-butler-governance--render "a-rule" "d" "body" "feedback")))
    (cc-butler-tool-regenerate-governance)
    (let ((out (cc-butler-tool-regenerate-governance)))
      (should (string-match-p "0 .*un-indexed" out)))))

;;;; ------------------------------------------------------------------
;;;; Bidirectional index validation (2026-08-05, steward-reported)
;;;;
;;;; regenerate_governance checked store -> index only (missing entries).
;;;; Reproduced live: recording a principle, merging it into a duplicate,
;;;; then deleting the original's store file + memory note left a dangling
;;;; MEMORY.md line behind, and separately an in-place description update
;;;; left the OLD wording sitting in the index -- in both cases the tool
;;;; reported "0 un-indexed" / "Nothing was missing from the index".
;;;; ------------------------------------------------------------------

(ert-deftest cc-butler-governance/regenerate-prunes-a-dangling-index-link ()
  "REGRESSION (2026-08-05): a principle recorded, then merged into a
duplicate and deleted by hand (store file AND memory note both removed),
left its MEMORY.md line behind. Index -> store was never checked, so the
dangling line survived every regenerate. A line whose slug no longer names
a store principle must be pruned."
  (cc-butler-governance-test--with-store
    (with-temp-file (expand-file-name "a-rule.md" store)
      (insert (cc-butler-governance--render "a-rule" "d" "body" "feedback")))
    (cc-butler-governance-regenerate)
    (let ((index (expand-file-name "MEMORY.md" mem)))
      (should (string-match-p "\\[a-rule\\](butler-a-rule\\.md)"
                              (with-temp-buffer (insert-file-contents index) (buffer-string))))
      ;; Simulate the hand-cleanup: the principle is gone from the store
      ;; and its generated note is gone from memory, but nobody touched
      ;; MEMORY.md.
      (delete-file (expand-file-name "a-rule.md" store))
      (delete-file (expand-file-name "butler-a-rule.md" mem))
      (cc-butler-governance-regenerate)
      (should-not (string-match-p "\\[a-rule\\](butler-a-rule\\.md)"
                                  (with-temp-buffer (insert-file-contents index) (buffer-string)))))))

(ert-deftest cc-butler-governance/prune-never-touches-a-non-generated-line ()
  "Pruning must only ever remove lines shaped exactly like this store's own
generated entries (`- [slug](butler-slug.md) -- ...'). A hand-written entry
in any other shape -- even one pointing at a file that does not exist -- is
none of this store's business and must survive untouched."
  (cc-butler-governance-test--with-store
    (let ((index (expand-file-name "MEMORY.md" mem))
          (hand-written "- [steward-only-note](steward-only-note.md) — points at nothing, on purpose\n"))
      (with-temp-file index (insert hand-written))
      (cc-butler-governance-regenerate)
      (should (string-match-p (regexp-quote hand-written)
                              (with-temp-buffer (insert-file-contents index) (buffer-string)))))))

(ert-deftest cc-butler-governance/regenerate-tool-reports-pruned-dangling-links ()
  "The tool's report text must say what it actually checked and found -- not
just \"0 un-indexed\", which reads as if index->store were also verified
when it was not."
  (cc-butler-governance-test--with-store
    (with-temp-file (expand-file-name "a-rule.md" store)
      (insert (cc-butler-governance--render "a-rule" "d" "body" "feedback")))
    (cc-butler-tool-regenerate-governance)
    (delete-file (expand-file-name "a-rule.md" store))
    (delete-file (expand-file-name "butler-a-rule.md" mem))
    (let ((out (cc-butler-tool-regenerate-governance)))
      (should (string-match-p "dangling" out))
      (should (string-match-p "a-rule" out)))))

(ert-deftest cc-butler-governance/regenerate-tool-reports-stale-descriptions ()
  "REGRESSION (2026-08-05): a principle's description was updated in place
\(as `record_principle' does\) -- the store note and generated memory note
both got the new wording, but the MEMORY.md index line, never touched by
the add-only sync, kept the OLD description. `regenerate_governance' must
surface this drift instead of reporting a clean index. The line itself is
NOT rewritten automatically: on disk, drift from an update is
indistinguishable from a human's deliberate curation of that line (see
`cc-butler-governance/regenerate-does-not-duplicate-an-already-curated-entry'),
so this is report-only, never an auto-edit."
  (cc-butler-governance-test--with-store
    (with-temp-file (expand-file-name "a-rule.md" store)
      (insert (cc-butler-governance--render "a-rule" "original description" "body" "feedback")))
    (cc-butler-governance-regenerate)
    (with-temp-file (expand-file-name "a-rule.md" store)
      (insert (cc-butler-governance--render "a-rule" "revised description" "body" "feedback")))
    (let ((out (cc-butler-tool-regenerate-governance)))
      (should (string-match-p "a-rule" out))
      (should (string-match-p "no longer match\\|stale\\|drift" out))
      (should (string-match-p "original description"
                              (with-temp-buffer
                                (insert-file-contents (expand-file-name "MEMORY.md" mem))
                                (buffer-string)))))))

(provide 'cc-butler-governance-test)
;;; cc-butler-governance-test.el ends here
