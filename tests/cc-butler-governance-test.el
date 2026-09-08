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

(ert-deftest cc-butler-governance/memory-dir-is-derived-not-frozen-at-load-order ()
  "REGRESSION (2026-08-31, live 8 days on this fleet): `cc-butler-governance-memory-dir'
used to be a `defcustom' default computed once, at definition time, from
`cc-butler--claude-memory-dir'/`cc-butler-home'.  If either was not yet
loaded at that moment (a load-order race, not misconfiguration) it
silently froze onto a hardcoded fallback path from a DIFFERENT fleet
machine and never self-corrected, even after both symbols became
available later in the same session.  The accessor must re-derive on
every call instead of trusting a value captured once."
  (let ((cc-butler-governance-memory-dir nil))
    (let* ((cc-butler-home "/home-a/butler")
           (a (cc-butler-governance-memory-store)))
      (let* ((cc-butler-home "/home-b/butler")
             (b (cc-butler-governance-memory-store)))
        (should-not (equal a b))))))

;;;; ------------------------------------------------------------------
;;;; Frontmatter description parsing
;;;; ------------------------------------------------------------------

(ert-deftest cc-butler-governance/frontmatter-description-survives-a-leading-blank-line ()
  "REGRESSION (2026-09-01): the parser assumed line 1 is the opening `---'
and skipped it unconditionally with `forward-line 1', then searched for
the NEXT `^---$' as the close. A file with a leading blank line (blank
line 1, `---' on line 2) made that skip land ON the opening delimiter
itself, which the search then matched as its own close, collapsing the
frontmatter range to nothing and silently losing the description. A
real store note (`a-guard-that-cannot-fail-is-theatre') hit exactly
this shape and dropped out of the recallable index."
  (let ((f (make-temp-file "gov-blank-line")))
    (unwind-protect
        (progn
          (with-temp-file f
            (insert "\n---\nname: butler-x\ndescription: \"Hello\"\n---\nbody\n"))
          (should (equal (cc-butler-governance--frontmatter-description f) "Hello")))
      (delete-file f))))

;;;; ------------------------------------------------------------------
;;;; Recording a principle
;;;; ------------------------------------------------------------------

(defmacro cc-butler-governance-test--with-store (&rest body)
  "Run BODY with a throwaway store, memory dir, and (empty) vault root wired
together. The vault-root binding matters even for tests that never look at
citations: without it, `cc-butler-governance-regenerate''s citation-count
grep (see `cc-butler-governance--citation-count-map') falls back to whatever
`cc-butler-governance-vault-root' resolves to for real on the machine
running the suite -- real, slow, and machine-dependent, exactly what these
tests must never quietly depend on."
  (declare (indent 0))
  `(let* ((store (file-name-as-directory (make-temp-file "gov-store" t)))
          (mem (file-name-as-directory (make-temp-file "gov-mem" t)))
          (vault (file-name-as-directory (make-temp-file "gov-vault" t)))
          (cc-butler-governance-dir store)
          (cc-butler-governance-user-dir nil)
          (cc-butler-governance-memory-dir mem)
          (cc-butler-governance-vault-root vault))
     (unwind-protect (progn ,@body)
       (delete-directory store t)
       (delete-directory mem t)
       (delete-directory vault t))))

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

(ert-deftest cc-butler-governance/tool-response-does-not-dump-the-full-roster ()
  "REGRESSION (정수님, 2026-09-08): the MCP tool response used to echo
`:names' -- the FULL slug list `cc-butler-governance-record' returns --
back to the caller on every single call, success or not. Measured against
the real store (563 notes, 2026-09-09): ~28KB of dead weight per call,
98% of the response. Reproduced here against a realistically-sized store
(not a fake 1-2 note one) written directly to disk -- bypassing
`cc-butler-governance-record' for the bulk so the test stays fast, since
that function's duplicate-search and shrink-guard are irrelevant to what
this test is proving -- then exercising the real tool wrapper for the one
call under test. The response must stay small and must not name notes it
never touched."
  (cc-butler-governance-test--with-store
    (dotimes (i 300)
      (let ((slug (format "existing-principle-number-%d" i)))
        (with-temp-file (expand-file-name (concat slug ".md") store)
          (insert (cc-butler-governance--render
                   slug "an existing note" "some body text" nil)))))
    (cc-butler-governance-regenerate)
    ;; Update an EXISTING slug (not a new one) -- with 300 notes already over
    ;; `cc-butler-governance-max-notes' (250), that is the realistic call
    ;; shape anyway: the count-cap ratchet only ever blocks new slugs.
    (let ((out (cc-butler-tool-record-principle
                "existing-principle-number-42" "d" "revised body" nil t)))
      (should (< (string-bytes out) 2000))
      (should-not (string-match-p "existing-principle-number-150" out))
      (should-not (string-match-p "Principles now in the store" out)))))

(ert-deftest cc-butler-governance/tool-response-memory-note-path-is-not-a-bare-link-target ()
  "REGRESSION (multiple sessions, 2026-08-21 through 2026-09-07): the
response's `Memory note: .../butler-<slug>.md' line sits right next to the
correct `Store file: .../<slug>.md' line, and was repeatedly misread as
this note's link identifier -- linked elsewhere in the vault as
`[[butler-<slug>]]', which nothing downstream ever resolves (the
regenerator, the `MEMORY.md' index, and shared-state-note recall are all
bare-slug-driven; the `butler-' prefix is filename/frontmatter-only, never
read back for linking). Fix: the response now says, right at the line
that caused the confusion, both what NOT to link and what to link
instead -- so a session reading quickly hits the correction at the exact
point it would otherwise misread, not somewhere else that needs
cross-referencing."
  (cc-butler-governance-test--with-store
    (let ((out (cc-butler-tool-record-principle "verify-delivery" "d" "body")))
      (should (string-match-p "NOT a link target" out))
      (should (string-match-p (regexp-quote "[[verify-delivery]]") out))
      (should (string-match-p (regexp-quote "[[butler-verify-delivery]]") out)))))

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
;;;; The shrink guard (2026-09-08, steward: reading the code directly
;;;; found record_principle OVERWRITES via with-temp-file -- it never
;;;; merges -- while the count-cap rejection message told a worker
;;;; "your text merges into that note in place". Following that message
;;;; literally on any real note would have silently deleted almost all
;;;; of it. This section proves BOTH halves: the danger is real (RED,
;;;; against a realistic ~45KB copy, never the live store), and the
;;;; guard actually stops it.
;;;; ------------------------------------------------------------------

(ert-deftest cc-butler-governance/shrink-guard-blocks-a-drastic-accidental-overwrite ()
  "RED-shaped reproduction of the real incident: updating a large existing
note (sized like the real ~45KB notes steward was about to fold) with only
a small new body must be refused, and — the actual proof, not just that an
error was raised — the OLD content must still be on disk afterward,
completely intact."
  (cc-butler-governance-test--with-store
    (let* ((big-body (make-string 45000 ?x))
           (path (expand-file-name "big-note.md" store)))
      ;; Written DIRECTLY, bypassing record_principle's own 2KB body cap --
      ;; the real 45KB/31KB notes this reproduces predate that cap and are
      ;; exactly the ones a worker cannot create through record_principle
      ;; today, only encounter already sitting in the store.
      (with-temp-file path
        (insert (cc-butler-governance--render "big-note" "d" big-body "feedback")))
      (should-error (cc-butler-governance-record "big-note" "d" "tiny new fact")
                    :type 'user-error)
      (let ((text (with-temp-buffer (insert-file-contents path) (buffer-string))))
        ;; string-match-p on a regexp-quoted 45000-char needle overflows
        ;; Emacs's regexp engine ("Regular expression too big") -- a plain
        ;; substring search has no such limit.
        (should (string-search big-body text))
        (should-not (string-match-p "tiny new fact" text))))))

(ert-deftest cc-butler-governance/shrink-guard-message-names-both-sizes ()
  "The rejection text must be actionable: both sizes and both possible next
steps (accidental -> read+fold+resubmit whole; deliberate -> confirm_shrink)."
  (cc-butler-governance-test--with-store
    (cc-butler-governance-record "big-note" "d" (make-string 1000 ?x))
    (let ((msg (condition-case err
                   (progn (cc-butler-governance-record "big-note" "d" "small") nil)
                 (user-error (cadr err)))))
      (should (string-match-p "1000 bytes" msg))
      (should (string-match-p "OVERWRITES THE ENTIRE FILE" msg))
      (should (string-match-p "confirm_shrink\\|confirm-shrink" msg))
      (should (string-match-p "read.*fold\\|fold.*read\\|Read the note" msg)))))

(ert-deftest cc-butler-governance/shrink-guard-passes-with-confirm-shrink-true ()
  "GREEN: the identical drastic shrink succeeds once CONFIRM-SHRINK is
passed -- proves this is a confirmation gate, not a permanent block, since
deliberate folding looks byte-for-byte identical to the accident."
  (cc-butler-governance-test--with-store
    (let ((path (expand-file-name "big-note.md" store)))
      (with-temp-file path
        (insert (cc-butler-governance--render "big-note" "d" (make-string 45000 ?x) "feedback")))
      (let ((res (cc-butler-governance-record "big-note" "d" "folded down on purpose"
                                              "feedback" t)))
        (should (plist-get res :verified))
        (let ((text (with-temp-buffer (insert-file-contents path) (buffer-string))))
          (should (string-match-p "folded down on purpose" text))
          (should-not (string-match-p "xxxxxxxxxx" text)))))))

(ert-deftest cc-butler-governance/shrink-guard-does-not-block-a-new-note ()
  "A brand-new slug has no old body to lose -- the guard must never fire on
`existed' = nil, no matter how small the first body is."
  (cc-butler-governance-test--with-store
    (let ((res (cc-butler-governance-record "brand-new" "d" "tiny")))
      (should (plist-get res :verified)))))

(ert-deftest cc-butler-governance/shrink-guard-does-not-block-a-modest-revision ()
  "A normal edit -- new body within `cc-butler-governance-shrink-guard-fraction'
of the old size -- must pass without confirm-shrink. The guard exists for
DRASTIC shrinks only, not ordinary tightening of wording."
  (cc-butler-governance-test--with-store
    (cc-butler-governance-record "a-rule" "d" (make-string 1000 ?x))
    (let ((res (cc-butler-governance-record "a-rule" "d" (make-string 700 ?y))))
      (should (plist-get res :verified)))))

(ert-deftest cc-butler-governance/shrink-guard-fraction-boundary ()
  "Exactly AT the fraction is still a pass (only STRICTLY below refuses) --
matches this file's own at/above vs strictly-below convention elsewhere
\(e.g. `cc-butler-governance/record-allows-past-the-cap-once-raised')."
  (cc-butler-governance-test--with-store
    (let ((cc-butler-governance-shrink-guard-fraction 0.5))
      ;; Two independent slugs, each updated exactly ONCE from its own
      ;; fresh 1000-byte original -- a second update to the SAME slug
      ;; would be measured against the FIRST update's already-shrunk
      ;; size, not the original, and silently test the wrong boundary.
      (cc-butler-governance-record "at-half" "d" (make-string 1000 ?x))
      (should (plist-get (cc-butler-governance-record "at-half" "d" (make-string 500 ?y))
                         :verified))
      (cc-butler-governance-record "under-half" "d" (make-string 1000 ?x))
      (should-error (cc-butler-governance-record "under-half" "d" (make-string 499 ?z))
                    :type 'user-error))))

(ert-deftest cc-butler-governance/cap-message-no-longer-claims-a-merge ()
  "REGRESSION (2026-09-08, steward reading the code directly): the count-cap
message used to say \"your text merges into that note in place\", which is
false -- record_principle overwrites. Must never say \"merge\" as if it
were automatic, and must say the update replaces/overwrites the whole
file."
  (cc-butler-governance-test--with-store
    (let ((cc-butler-governance-max-notes 1))
      (cc-butler-governance-record "big-one" "d" "body")
      (let ((msg (condition-case err
                     (progn (cc-butler-governance-record "second" "d" "body") nil)
                   (user-error (cadr err)))))
        (should-not (string-match-p "your text merges into that note in place" msg))
        (should (string-match-p "REPLACES THAT NOTE'S ENTIRE BODY" msg))
        (should (string-match-p "not a merge" msg))))))

;;;; ------------------------------------------------------------------
;;;; Duplicate search (2026-09-08, steward: two existing human/agent
;;;; recall mechanisms both fired on a real duplicate the same day and it
;;;; was still re-recorded under a new slug -- "사람이 하는 검색은 안
;;;; 됩니다. 검색을 도구가 해야 합니다." record_principle now searches
;;;; the store itself before creating a genuinely new slug.
;;;; ------------------------------------------------------------------

(ert-deftest cc-butler-governance/keywords-strips-stopwords-and-short-words ()
  "The tokenizer: lowercased, length>=4, stopwords and short filler words
gone, order-independent (dedup via delete-dups is a set, not a sequence)."
  (let ((kw (cc-butler-governance--keywords
             "The Verify Delivery Test is a Test of the delivery path")))
    (should (member "verify" kw))
    (should (member "delivery" kw))
    (should (member "path" kw))
    (should-not (member "the" kw))
    (should-not (member "is" kw))
    (should-not (member "a" kw))
    (should-not (member "of" kw))
    ;; "test" appears twice in the input; the tokenizer is a set
    (should (= 1 (length (seq-filter (lambda (w) (equal w "test")) kw))))))

(ert-deftest cc-butler-governance/duplicate-candidates-requires-a-minimum-shared-count ()
  "A single incidentally-shared word is not evidence of duplication -- must
stay below `cc-butler-governance-duplicate-search-min-shared-keywords' and
therefore not be returned as a candidate at all."
  (cc-butler-governance-test--with-store
    (let ((cc-butler-governance-duplicate-search-min-shared-keywords 3)
          (cc-butler-governance-max-index-line-bytes 1000))
      (cc-butler-governance-record "verify-delivery" "Confirm delivery landed" "body")
      (should-not (cc-butler-governance--duplicate-candidates
                   "unrelated-topic" "Something about timeouts entirely" "body")))))

(ert-deftest cc-butler-governance/duplicate-search-blocks-a-new-note-that-shares-enough-keywords ()
  "RED-shaped: recording a NEW slug whose name/description/body shares
enough keywords with an existing principle's description must be refused
-- and no file created -- before it ever reaches the count/length caps."
  (cc-butler-governance-test--with-store
    (let ((cc-butler-governance-duplicate-search-min-shared-keywords 3)
          (cc-butler-governance-max-index-line-bytes 1000))
      (cc-butler-governance-record
       "verify-delivery" "Confirm delivery landed before declaring success" "original body")
      (should-error
       (cc-butler-governance-record
        "check-delivery-again" "Please confirm delivery landed before declaring anything done"
        "new body")
       :type 'user-error)
      (should-not (file-exists-p (expand-file-name "check-delivery-again.md" store))))))

(ert-deftest cc-butler-governance/duplicate-search-allows-a-genuinely-new-topic ()
  "An unrelated new principle, sharing no meaningful vocabulary with what's
already in the store, must record normally -- the search must not become
a de facto block on all new principles."
  (cc-butler-governance-test--with-store
    (let ((cc-butler-governance-max-index-line-bytes 1000))
      (cc-butler-governance-record
       "verify-delivery" "Confirm delivery landed before declaring success" "body")
      (let ((res (cc-butler-governance-record
                  "rotate-logs" "Old log files must be compressed weekly" "body")))
        (should (plist-get res :verified))))))

(ert-deftest cc-butler-governance/duplicate-search-skip-flag-bypasses-the-check ()
  "GREEN: the identical call that was just refused succeeds once
skip_duplicate_check is passed -- the false-positive escape hatch."
  (cc-butler-governance-test--with-store
    (let ((cc-butler-governance-duplicate-search-min-shared-keywords 3)
          (cc-butler-governance-max-index-line-bytes 1000))
      (cc-butler-governance-record
       "verify-delivery" "Confirm delivery landed before declaring success" "original body")
      (should-error
       (cc-butler-governance-record
        "check-delivery-again" "Please confirm delivery landed before declaring anything done"
        "new body"))
      (let ((res (cc-butler-governance-record
                  "check-delivery-again" "Please confirm delivery landed before declaring anything done"
                  "new body" "feedback" nil t)))
        (should (plist-get res :verified))))))

(ert-deftest cc-butler-governance/duplicate-search-never-fires-on-an-update ()
  "Revising an EXISTING principle is not \"creating something that might
already exist\" -- the whole point is that it already does. The search
must never fire when `existed' is true, no matter the wording."
  (cc-butler-governance-test--with-store
    (let ((cc-butler-governance-duplicate-search-min-shared-keywords 3)
          (cc-butler-governance-max-index-line-bytes 1000))
      (cc-butler-governance-record
       "verify-delivery" "Confirm delivery landed before declaring success" "body")
      (let ((res (cc-butler-governance-record
                  "verify-delivery" "Confirm delivery landed before declaring success"
                  "revised body, still about delivery confirmation and success")))
        (should (plist-get res :verified))))))

(ert-deftest cc-butler-governance/duplicate-search-message-names-candidate-shared-count-and-size ()
  "The rejection text must be actionable: which existing note, how many
keywords it shares, and its current size -- not just \"looks similar\"."
  (cc-butler-governance-test--with-store
    (let ((cc-butler-governance-duplicate-search-min-shared-keywords 3)
          (cc-butler-governance-max-index-line-bytes 1000))
      (cc-butler-governance-record
       "verify-delivery" "Confirm delivery landed before declaring success" "original body")
      (let ((msg (condition-case err
                     (progn (cc-butler-governance-record
                             "check-delivery-again"
                             "Please confirm delivery landed before declaring anything done"
                             "new body")
                            nil)
                   (user-error (cadr err)))))
        (should (string-match-p "verify-delivery" msg))
        (should (string-match-p "shared keyword" msg))
        (should (string-match-p "bytes" msg))
        (should (string-match-p "skip_duplicate_check" msg))))))

(ert-deftest cc-butler-governance/duplicate-search-flags-a-candidate-already-over-the-body-cap ()
  "The structural gap steward asked this be designed around, not hidden
behind a dead end: a candidate already over the body-length cap cannot be
folded into with a normal update. The message must say so plainly next to
that candidate, not leave the worker to discover it by trying and failing."
  (cc-butler-governance-test--with-store
    (let ((cc-butler-governance-duplicate-search-min-shared-keywords 3)
          (cc-butler-governance-max-note-bytes 100))
      ;; written directly -- bypasses the body cap, matching how a real
      ;; oversized legacy note predates any cap on it
      (with-temp-file (expand-file-name "verify-delivery.md" store)
        (insert (cc-butler-governance--render
                 "verify-delivery" "Confirm delivery landed before declaring success"
                 (make-string 500 ?x) "feedback")))
      (let ((msg (condition-case err
                     (progn (cc-butler-governance-record
                             "check-delivery-again"
                             "Please confirm delivery landed before declaring anything done"
                             "new")
                            nil)
                   (user-error (cadr err)))))
        (should (string-match-p "OVER the.*body cap" msg))
        (should (string-match-p "condensed under the cap first" msg))))))

(ert-deftest cc-butler-governance/duplicate-search-runs-before-the-count-cap ()
  "Meta-requirement (steward, 2026-09-08): a gate placed after another
never gets exercised by a call the earlier gate already refuses -- exactly
how the description/index-line cap went untested against real data behind
the count cap. Prove ordering directly: with BOTH the duplicate condition
and the count cap simultaneously true, the DUPLICATE message -- not the
count-cap message -- is what a caller actually sees."
  (cc-butler-governance-test--with-store
    (let ((cc-butler-governance-duplicate-search-min-shared-keywords 3)
          (cc-butler-governance-max-notes 1)
          (cc-butler-governance-max-index-line-bytes 1000))
      (cc-butler-governance-record
       "verify-delivery" "Confirm delivery landed before declaring success" "body")
      ;; store is now AT the count cap (1) AND a genuine duplicate exists
      (let ((msg (condition-case err
                     (progn (cc-butler-governance-record
                             "check-delivery-again"
                             "Please confirm delivery landed before declaring anything done"
                             "new body")
                            nil)
                   (user-error (cadr err)))))
        (should (string-match-p "may already exist in the store" msg))
        (should-not (string-match-p "at the cap of" msg))))))

;;;; ------------------------------------------------------------------
;;;; The store cap (2026-09-08, 정수님 배차: "제약이 있어야 효율화된다")
;;;; ------------------------------------------------------------------

(ert-deftest cc-butler-governance/record-refuses-a-new-note-at-the-cap ()
  "RED: a NEW slug is refused once the store already holds `max-notes' notes,
and refusing means the file is genuinely never written — not just a
rejection message with the write still landing underneath it."
  (cc-butler-governance-test--with-store
    (let ((cc-butler-governance-max-notes 1))
      (cc-butler-governance-record "first" "d" "body")
      (should-error (cc-butler-governance-record "second" "d" "body")
                    :type 'user-error)
      (should-not (file-exists-p
                   (expand-file-name "second.md" (cc-butler-governance-store))))
      (should (equal (cc-butler-governance-names) '("first"))))))

(ert-deftest cc-butler-governance/record-allows-past-the-cap-once-raised ()
  "GREEN: the identical call just refused succeeds once the cap is raised —
proves this is a live count check, not a one-time snapshot or a permanent
lock."
  (cc-butler-governance-test--with-store
    (let ((cc-butler-governance-max-notes 1))
      (cc-butler-governance-record "first" "d" "body")
      (should-error (cc-butler-governance-record "second" "d" "body")))
    (let* ((cc-butler-governance-max-notes 10)
           (res (cc-butler-governance-record "second" "d" "body")))
      (should (plist-get res :verified))
      (should (file-exists-p (plist-get res :path))))))

(ert-deftest cc-butler-governance/record-cap-never-blocks-revising-an-existing-note ()
  "Updating a principle that already exists must never be blocked — it does
not grow the store, so it is not the growth this cap exists to stop."
  (cc-butler-governance-test--with-store
    (let ((cc-butler-governance-max-notes 1))
      (cc-butler-governance-record "first" "d" "original")
      (let ((res (cc-butler-governance-record "first" "d" "revised")))
        (should (plist-get res :existed))
        (should (plist-get res :verified))
        (should (equal (cc-butler-governance--store-note-count) 1))))))

(ert-deftest cc-butler-governance/cap-message-names-count-cap-and-largest-notes ()
  "The rejection text must be actionable on the spot: current count, the cap,
and which notes are large — not just \"no\"."
  (cc-butler-governance-test--with-store
    (let ((cc-butler-governance-max-notes 1))
      (cc-butler-governance-record "big-one" "d" (make-string 500 ?x))
      (let ((msg (condition-case err
                     (progn (cc-butler-governance-record "second" "d" "body") nil)
                   (user-error (cadr err)))))
        (should (string-match-p "1 notes" msg))
        (should (string-match-p "cap of 1" msg))
        (should (string-match-p "big-one" msg))))))

(ert-deftest cc-butler-governance/cap-message-gives-an-explicit-pass-now-action ()
  "REGRESSION (2026-09-08, real-store probe before merge): the original
message stated \"revising an existing principle is never blocked\" as a
FACT but never told the worker to actually do that to get their own
content saved now. Must contain an imperative the worker can follow
without a follow-up question — naming record_principle and an existing
name, not just describing the rule."
  (cc-butler-governance-test--with-store
    (let ((cc-butler-governance-max-notes 1))
      (cc-butler-governance-record "big-one" "d" "body")
      (let ((msg (condition-case err
                     (progn (cc-butler-governance-record "second" "d" "body") nil)
                   (user-error (cadr err)))))
        (should (string-match-p "TO RECORD THIS NOW" msg))
        (should (string-match-p "call record_principle again" msg))
        (should (string-match-p "NAME of an EXISTING principle" msg))))))

(ert-deftest cc-butler-governance/cap-message-does-not-present-size-as-a-ranked-merge-list ()
  "REGRESSION (2026-09-08, real-store probe before merge): the real
store's single largest note, at the moment this was measured, was the
exact note warmble-jumble's own folding effort had concluded needs
SPLITTING into 21 notes -- not merging into. A worker following
\"largest = best merge target\" would have made the count WORSE. The
message must explicitly warn that size is not a ranking and a large note
may need splitting, not silently imply big-is-mergeable."
  (cc-butler-governance-test--with-store
    (let ((cc-butler-governance-max-notes 1))
      (cc-butler-governance-record "big-one" "d" "body")
      (let ((msg (condition-case err
                     (progn (cc-butler-governance-record "second" "d" "body") nil)
                   (user-error (cadr err)))))
        (should (string-match-p "NOT a ranked merge list" msg))
        (should (string-match-p "SPLITTING" msg))
        (should (string-match-p "match by topic, never by size" msg))))))

(ert-deftest cc-butler-governance/store-note-count-ignores-the-memory-cache ()
  "The cap counts the STORE, never the generated memory-dir cache: the cache
can hold an orphan a store deletion left behind (see cc-butler#36 /
regenerate-governance), and a cap that counted the cache would refuse
writes the store itself has room for, and would never shrink just because
the store was cleaned up."
  (cc-butler-governance-test--with-store
    (cc-butler-governance-record "only-one" "d" "body")
    (with-temp-file (expand-file-name "butler-orphan.md" cc-butler-governance-memory-dir)
      (insert "orphan"))
    (should (equal (cc-butler-governance--store-note-count) 1))
    (should (equal (cc-butler-governance--note-count) 2))))

;;;; ------------------------------------------------------------------
;;;; The body-length cap (2026-09-08, 정수님 증보: "용건만 간단히")
;;;; ------------------------------------------------------------------

(ert-deftest cc-butler-governance/record-refuses-a-body-over-the-length-cap ()
  "RED: a body longer than `max-note-bytes' is refused, and refusing means
the file is genuinely never written."
  (cc-butler-governance-test--with-store
    (let ((cc-butler-governance-max-note-bytes 100))
      (should-error (cc-butler-governance-record "too-long" "d" (make-string 200 ?x))
                    :type 'user-error)
      (should-not (file-exists-p
                   (expand-file-name "too-long.md" (cc-butler-governance-store)))))))

(ert-deftest cc-butler-governance/record-allows-a-long-body-once-the-cap-is-raised ()
  "GREEN: the identical call just refused succeeds once the cap is raised —
a live byte count, not a permanent lock."
  (cc-butler-governance-test--with-store
    (let ((cc-butler-governance-max-note-bytes 100))
      (should-error (cc-butler-governance-record "too-long" "d" (make-string 200 ?x))))
    (let* ((cc-butler-governance-max-note-bytes 1000)
           (res (cc-butler-governance-record "too-long" "d" (make-string 200 ?x))))
      (should (plist-get res :verified))
      (should (file-exists-p (plist-get res :path))))))

(ert-deftest cc-butler-governance/record-length-cap-also-blocks-padding-an-existing-note ()
  "The count cap alone can be dodged by appending to an existing note
instead of creating a new one — 정수님 spotted this leak directly. The
length cap must catch that path too, not just brand-new notes."
  (cc-butler-governance-test--with-store
    (let ((cc-butler-governance-max-note-bytes 100))
      (cc-butler-governance-record "grows" "d" (make-string 50 ?x))
      (should-error (cc-butler-governance-record "grows" "d" (make-string 200 ?x))
                    :type 'user-error)
      ;; refused edit must not have clobbered the original body
      (let ((text (with-temp-buffer
                    (insert-file-contents
                     (expand-file-name "grows.md" (cc-butler-governance-store)))
                    (buffer-string))))
        (should (string-match-p (make-string 50 ?x) text))
        (should-not (string-match-p (make-string 200 ?x) text))))))

(ert-deftest cc-butler-governance/length-cap-counts-bytes-not-characters ()
  "Multi-byte text (Korean, this fleet's working language) must be measured
in bytes, matching what actually lands on disk — counting characters would
let a body several times the intended byte cap through."
  (cc-butler-governance-test--with-store
    (let* ((korean (make-string 40 ?정))          ; 40 chars, 120 bytes in UTF-8
           (cc-butler-governance-max-note-bytes 100))
      (should (> (string-bytes korean) cc-butler-governance-max-note-bytes))
      (should (< (length korean) cc-butler-governance-max-note-bytes))
      (should-error (cc-butler-governance-record "korean-note" "d" korean)
                    :type 'user-error))))

(ert-deftest cc-butler-governance/length-cap-message-names-bytes-cap-and-longest-sections ()
  "The rejection text must be actionable: current bytes, the cap, and which
sections of THIS body are worth cutting — not just \"too long\"."
  (cc-butler-governance-test--with-store
    (let ((cc-butler-governance-max-note-bytes 50))
      (let ((msg (condition-case err
                     (progn (cc-butler-governance-record
                             "too-long" "d"
                             (concat "short bit\n\n" (make-string 80 ?y)))
                            nil)
                   (user-error (cadr err)))))
        (should (string-match-p "cap of 50" msg))
        (should (string-match-p (make-string 20 ?y) msg))   ; the long section, previewed
        (should (string-match-p "Trim to the point" msg))))))

;;;; ------------------------------------------------------------------
;;;; The index-line-length cap (2026-09-08, butler's own design — a
;;;; short body does not guarantee a short MEMORY.md line, and the index
;;;; line is what a session's context-read budget actually pays for)
;;;; ------------------------------------------------------------------

(ert-deftest cc-butler-governance/record-refuses-a-description-over-the-index-line-cap ()
  "RED: a description that renders an index line over
`max-index-line-bytes' is refused, and refusing means the file is
genuinely never written — even though the BODY itself is tiny."
  (cc-butler-governance-test--with-store
    (let ((cc-butler-governance-max-index-line-bytes 40))
      (should-error (cc-butler-governance-record
                     "x" (make-string 60 ?d) "short body")
                    :type 'user-error)
      (should-not (file-exists-p (expand-file-name "x.md" (cc-butler-governance-store)))))))

(ert-deftest cc-butler-governance/record-allows-past-the-index-line-cap-once-raised ()
  "GREEN: the identical call just refused succeeds once the cap is raised —
a live check, not a one-time snapshot."
  (cc-butler-governance-test--with-store
    (let ((cc-butler-governance-max-index-line-bytes 40))
      (should-error (cc-butler-governance-record "x" (make-string 60 ?d) "short body")))
    (let* ((cc-butler-governance-max-index-line-bytes 200)
           (res (cc-butler-governance-record "x" (make-string 60 ?d) "short body")))
      (should (plist-get res :verified))
      (should (file-exists-p (plist-get res :path))))))

(ert-deftest cc-butler-governance/index-line-cap-is-independent-of-the-body-cap ()
  "A tiny body with a long DESCRIPTION must still be refused — the two caps
measure different text, so passing one must never be mistaken for passing
both. This is the actual gap the index-line cap closes: capping the body
alone (`cc-butler-governance-max-note-bytes') does nothing to
`MEMORY.md''s size, since the index line is rendered from the
description, not the body."
  (cc-butler-governance-test--with-store
    (let ((cc-butler-governance-max-note-bytes 100000)   ; body cap wide open
          (cc-butler-governance-max-index-line-bytes 40))
      (should-error (cc-butler-governance-record "x" (make-string 60 ?d) "tiny")
                    :type 'user-error))))

(ert-deftest cc-butler-governance/index-line-cap-also-blocks-padding-an-existing-description ()
  "Revising a principle's description into a longer one must be checked too
-- an update is exactly how an author would otherwise dodge this cap on a
NEW note, the same append-instead-of-add shape the body-length cap closes."
  (cc-butler-governance-test--with-store
    (let ((cc-butler-governance-max-index-line-bytes 40))
      (cc-butler-governance-record "grows" "short" "body")
      (should-error (cc-butler-governance-record "grows" (make-string 60 ?d) "body")
                    :type 'user-error))))

(ert-deftest cc-butler-governance/index-line-cap-message-names-bytes-cap-and-the-line ()
  "The rejection text must be actionable: current bytes, the cap, and the
offending line itself, so the author can shorten it on the spot."
  (cc-butler-governance-test--with-store
    (let ((cc-butler-governance-max-index-line-bytes 40))
      (let ((msg (condition-case err
                     (progn (cc-butler-governance-record
                             "x" "a rather long description that overflows" "body")
                            nil)
                   (user-error (cadr err)))))
        (should (string-match-p "cap of 40" msg))
        (should (string-match-p "a rather long description" msg))
        (should (string-match-p "Shorten the description" msg))))))

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

;;;; ------------------------------------------------------------------
;;;; Creation stamps — who STARTED a note (never who wrote a sentence)
;;;; ------------------------------------------------------------------

(defmacro cc-butler-governance-test--as-session (label &rest body)
  "Run BODY as if MCP session LABEL were the caller."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'cc-butler--caller-dir) (lambda () "/tmp/fake-session"))
             ((symbol-function 'cc-butler--who-dir) (lambda (_dir) ,label)))
     ,@body))

(defun cc-butler-governance-test--text (res)
  (with-temp-buffer (insert-file-contents (plist-get res :path)) (buffer-string)))

(ert-deftest cc-butler-governance/stamps-a-new-note-with-the-calling-session ()
  "P1. A note that did not exist gets a creation stamp naming its caller."
  (cc-butler-governance-test--with-store
    (let ((text (cc-butler-governance-test--as-session "worker-a (sess-1)"
                  (cc-butler-governance-test--text
                   (cc-butler-governance-record "p" "d" "Body.")))))
      (should (string-match-p "^(최초 기록: worker-a (sess-1), [0-9][0-9]-[0-9][0-9])$" text)))))

(ert-deftest cc-butler-governance/an-update-keeps-the-original-creation-stamp ()
  "P2. `with-temp-file' truncates and the caller resubmits a body it has never
seen the stamp in, so an update must carry the ORIGINAL stamp forward — not
mint a second one, and above all not silently erase the first."
  (cc-butler-governance-test--with-store
    (cc-butler-governance-test--as-session "worker-a (sess-1)"
      (cc-butler-governance-record "p" "d" "First body."))
    (let ((text (cc-butler-governance-test--as-session "worker-b (sess-2)"
                  (cc-butler-governance-test--text
                   (cc-butler-governance-record "p" "d" "Rewritten body.")))))
      (should (string-match-p "Rewritten body\\." text))
      (should (string-match-p "최초 기록: worker-a (sess-1)" text))
      (should-not (string-match-p "worker-b" text)))))       ; the editor is not the recorder

(ert-deftest cc-butler-governance/a-legacy-note-never-gains-a-stamp ()
  "P3. The notes written before stamping existed have no first-recorder on
record.  Whoever edits one today is not it — stamping them would be exactly
the false attribution this design exists to avoid."
  (cc-butler-governance-test--with-store
    (let ((path (expand-file-name "p.md" (cc-butler-governance-store))))
      (with-temp-file path (insert "---\nname: butler-p\n---\n\nLegacy body.\n"))
      (let ((text (cc-butler-governance-test--as-session "worker-b (sess-2)"
                    (cc-butler-governance-test--text
                     (cc-butler-governance-record "p" "d" "Edited legacy body.")))))
        (should (string-match-p "Edited legacy body\\." text))
        (should-not (string-match-p "최초 기록" text))))))

(ert-deftest cc-butler-governance/the-stamp-survives-regeneration ()
  "P4. The memory note is a copy of the store file, so a stamp must round-trip."
  (cc-butler-governance-test--with-store
    (let* ((res (cc-butler-governance-test--as-session "worker-a (sess-1)"
                  (cc-butler-governance-record "p" "d" "Body.")))
           (note (plist-get res :verified)))
      (should note)
      (should (string-match-p
               "최초 기록: worker-a (sess-1)"
               (with-temp-buffer (insert-file-contents note) (buffer-string)))))))

(ert-deftest cc-butler-governance/an-unknown-session-gets-no-stamp ()
  "P5. Outside an MCP request there is no caller to name.  No stamp beats a
stamp that says `?' — absence keeps people asking, a wrong answer stops them."
  (cc-butler-governance-test--with-store
    (cl-letf (((symbol-function 'cc-butler--caller-dir) (lambda () nil)))
      (let ((text (cc-butler-governance-test--text
                   (cc-butler-governance-record "p" "d" "Body."))))
        (should (string-match-p "Body\\." text))
        (should-not (string-match-p "최초 기록" text))))))

(ert-deftest cc-butler-governance/a-stamp-pasted-into-the-body-is-not-duplicated ()
  "A caller that copies the stamp back into BODY must not produce two."
  (cc-butler-governance-test--with-store
    (cc-butler-governance-test--as-session "worker-a (sess-1)"
      (cc-butler-governance-record "p" "d" "Body."))
    (let* ((text (cc-butler-governance-test--as-session "worker-b (sess-2)"
                   (cc-butler-governance-test--text
                    (cc-butler-governance-record
                     "p" "d" "Body.\n\n(최초 기록: worker-a (sess-1), 01-01)"))))
           (n 0) (start 0))
      (while (string-match "최초 기록" text start)
        (setq n (1+ n) start (match-end 0)))
      (should (= n 1)))))

(ert-deftest cc-butler-governance/a-quoted-stamp-in-the-body-is-not-promoted ()
  "A note that WRITES ABOUT stamping quotes a stamp line.  Recognising the
stamp anywhere in the file (rather than as the last line) promotes that
quotation into an attribution — a legacy note would inherit a first recorder
it never had, which is exactly the false attribution this design avoids."
  (cc-butler-governance-test--with-store
    (let ((path (expand-file-name "p.md" (cc-butler-governance-store)))
          (quoting "About stamping.\n\n> (최초 기록: someone-else (sess-9), 01-01)\n\nEnd."))
      (with-temp-file path
        (insert "---\nname: butler-p\n---\n\n" quoting "\n"))
      (let ((text (cc-butler-governance-test--as-session "worker-b (sess-2)"
                    (cc-butler-governance-test--text
                     (cc-butler-governance-record "p" "d" quoting)))))
        (should (string-match-p "someone-else" text))          ; the quote survives
        (should (string-match-p "^End\\.$" text))              ; and so does what follows
        (should-not (string-match-p "worker-b" text))          ; no stamp minted for a legacy note
        ;; the quoted line must not have become the note's own stamp
        (should-not (cc-butler-governance--stamp-line text))))))

(ert-deftest cc-butler-governance/a-quoted-stamp-is-never-stripped-from-the-body ()
  "Stripping every stamp-shaped line, rather than only a trailing one, deletes
the author's text silently.  Mutation guard: reverting --strip-stamps to
`remove every matching line' must fail here."
  (cc-butler-governance-test--with-store
    (let* ((body "Intro.\n\n(최초 기록: quoted-example (sess-9), 01-01)\n\nOutro.")
           (text (cc-butler-governance-test--as-session "worker-a (sess-1)"
                   (cc-butler-governance-test--text
                    (cc-butler-governance-record "p" "d" body)))))
      (should (string-match-p "quoted-example" text))
      (should (string-match-p "^Outro\\.$" text))
      ;; and the note still gets its OWN stamp, appended after all of that
      (should (string-match-p "최초 기록: worker-a (sess-1)"
                              (or (cc-butler-governance--stamp-line text) ""))))))

(ert-deftest cc-butler-governance/a-line-merely-containing-the-shape-is-not-a-stamp ()
  "Mutation guard: unanchoring the stamp regexp makes a sentence that mentions
a stamp read as one.  A stamp is a WHOLE line, never a substring."
  (should-not (cc-butler-governance--stamp-line
               "see (최초 기록: w (s), 01-01) above for the format"))
  (should-not (cc-butler-governance--stamp-line
               "prefix (최초 기록: w (s), 01-01)"))
  (should (cc-butler-governance--stamp-line
           "Body.\n\n(최초 기록: w (s), 01-01)")))

;;;; ------------------------------------------------------------------
;;;; Two-band index (2026-09-08) -- commit-recency alone has the SAME
;;;; failure shape as the `mtime' key it replaced: one bulk mechanical
;;;; commit occupies the entire top of the index. Band A (recent commits,
;;;; capped per commit so one bulk commit cannot swallow it) followed by
;;;; Band B (everything else, by inbound-citation count) is the fix.
;;;; ------------------------------------------------------------------

(defun cc-butler-governance-test--git (dir &rest args)
  "Run git ARGS in DIR for fixture setup; error if git fails."
  (let ((default-directory dir))
    (unless (eq 0 (apply #'call-process "git" nil nil nil args))
      (error "fixture git %s failed in %s" args dir))))

(defun cc-butler-governance-test--init-repo (dir)
  "Init a fixture git repo in DIR with a usable identity."
  (cc-butler-governance-test--git dir "init" "-q")
  (cc-butler-governance-test--git dir "config" "user.email" "test@test")
  (cc-butler-governance-test--git dir "config" "user.name" "test"))

(defun cc-butler-governance-test--commit-at (dir epoch message &rest files)
  "Write FILES (relative to DIR, each file's own content is just its name)
and commit them together, with author AND committer date pinned to unix
EPOCH -- so a fixture's commit-recency is deterministic regardless of when
the test actually runs, never relative to wall-clock `now' at test time."
  (dolist (f files)
    (with-temp-file (expand-file-name f dir) (insert f)))
  (let ((default-directory dir)
        (process-environment
         (append (list (format "GIT_AUTHOR_DATE=%d +0000" epoch)
                       (format "GIT_COMMITTER_DATE=%d +0000" epoch))
                 process-environment)))
    (apply #'call-process "git" nil nil nil "add" files)
    (unless (eq 0 (call-process "git" nil nil nil "commit" "-q" "-m" message))
      (error "fixture commit failed"))))

;;;; --- cc-butler-governance--band-order: pure-function unit tests ---

(ert-deftest cc-butler-governance/band-order-caps-a-single-commit-timestamp ()
  "A commit touching more than K notes (K = `cc-butler-governance-band-a-commit-cap')
contributes only its top-K, by citation count, to Band A -- the rest fall to
Band B. This cap is the ONLY thing stopping one bulk commit from swallowing
Band A whole."
  (let* ((cc-butler-governance-band-a-commit-cap 2)
         (cc-butler-governance-band-a-days 7)
         (now 1000000)
         (recency (make-hash-table :test 'equal))
         (citation (make-hash-table :test 'equal)))
    ;; four notes share ONE commit timestamp -- a stand-in bulk commit
    (dolist (s '("bulk-1" "bulk-2" "bulk-3" "bulk-4"))
      (puthash (concat s ".md") (- now 100) recency))
    ;; a fifth note has its own, slightly older but still-recent commit
    (puthash "solo.md" (- now 200) recency)
    (puthash "bulk-2" 50 citation)   ; highest-cited bulk member
    (puthash "bulk-4" 30 citation)   ; second highest
    (puthash "bulk-1" 5 citation)
    (puthash "bulk-3" 1 citation)
    (let ((ordered (cc-butler-governance--band-order
                    '("bulk-1" "bulk-2" "bulk-3" "bulk-4" "solo")
                    recency citation now)))
      ;; only the top-2 by citation from the bulk commit reach Band A, ahead
      ;; of `solo' (an older, but still within-window, commit)
      (should (equal (seq-take ordered 3) '("bulk-2" "bulk-4" "solo")))
      ;; the rest of the bulk commit falls through to Band B, in the tail
      (should (equal (last ordered 2) '("bulk-1" "bulk-3"))))))

(ert-deftest cc-butler-governance/band-order-old-commit-falls-to-band-b ()
  "A commit older than `cc-butler-governance-band-a-days' does not qualify for
Band A no matter how heavily cited -- it is ordered into Band B like
everything else outside the window, behind anything genuinely recent."
  (let* ((cc-butler-governance-band-a-days 7)
         (cc-butler-governance-band-a-commit-cap 5)
         (now 1000000)
         (recency (make-hash-table :test 'equal))
         (citation (make-hash-table :test 'equal)))
    (puthash "fresh.md" (- now 3600) recency)          ; 1 hour ago
    (puthash "stale.md" (- now (* 8 86400)) recency)    ; 8 days ago -- outside
    (puthash "stale" 100 citation)                      ; very cited, still too old
    (puthash "fresh" 1 citation)
    (should (equal (cc-butler-governance--band-order '("fresh" "stale") recency citation now)
                   '("fresh" "stale")))))

(ert-deftest cc-butler-governance/band-order-window-boundary-is-inclusive ()
  "Exactly `cc-butler-governance-band-a-days' days ago still qualifies for
Band A -- the window comparison is <=, not <."
  (let* ((cc-butler-governance-band-a-days 7)
         (cc-butler-governance-band-a-commit-cap 5)
         (now 1000000)
         (recency (make-hash-table :test 'equal))
         (citation (make-hash-table :test 'equal)))
    (puthash "edge.md" (- now (* 7 86400)) recency)
    (should (equal (car (cc-butler-governance--band-order '("other" "edge") recency citation now))
                   "edge"))))

(ert-deftest cc-butler-governance/band-order-band-b-by-citation-then-slug ()
  "Band B (no qualifying recent commit) is ordered by citation count
descending; equal counts break by slug so the order is deterministic run to
run, not an accident of hash-table iteration order."
  (let* ((cc-butler-governance-band-a-days 7)
         (now 1000000)
         (recency (make-hash-table :test 'equal))
         (citation (make-hash-table :test 'equal)))
    (puthash "b" 5 citation)
    (puthash "a" 5 citation)
    (puthash "c" 9 citation)
    (should (equal (cc-butler-governance--band-order '("a" "b" "c") recency citation now)
                   '("c" "a" "b")))))

(ert-deftest cc-butler-governance/band-order-slug-with-no-data-never-errors ()
  "A slug absent from both maps (no git history, no citations) still sorts
in -- as the least-favored Band B member -- rather than signalling an error."
  (let ((recency (make-hash-table :test 'equal))
        (citation (make-hash-table :test 'equal)))
    (should (equal (cc-butler-governance--band-order '("nobody-knows-this-one") recency citation 1000000)
                   '("nobody-knows-this-one")))))

;;;; --- cc-butler-governance--citation-count-map ---

(ert-deftest cc-butler-governance/citation-count-map-counts-across-the-vault ()
  "One recursive grep over the vault, counted per exact `[[wikilink]]' target
text -- `[[a]]' and `[[a|display text]]' both count toward `a'; a distinct
target is a distinct key."
  (let ((vault (file-name-as-directory (make-temp-file "gov-cite-vault" t))))
    (unwind-protect
        (let ((cc-butler-governance-vault-root vault))
          (with-temp-file (expand-file-name "note1.md" vault)
            (insert "See [[a]] and [[a|alias text]] and [[b]].\n"))
          (with-temp-file (expand-file-name "note2.md" vault)
            (insert "Also [[a]].\n"))
          (let ((result (cc-butler-governance--citation-count-map)))
            (should (null (cdr result)))
            (should (equal (gethash "a" (car result)) 3))
            (should (equal (gethash "b" (car result)) 1))
            (should (null (gethash "nobody-links-here" (car result))))))
      (delete-directory vault t))))

(ert-deftest cc-butler-governance/citation-count-map-excludes-docs-and-site-mirrors ()
  "REGRESSION guard (2026-09-08): the real vault publishes an MkDocs build of
itself into `docs/' and `site/', a near-duplicate of the real content
directories. Counting those in ALONGSIDE the source inflates every count by
a rendering artifact, not a second real citation -- measured against the
real vault, it silently doubled every count. `docs/' and `site/' must stay
excluded."
  (let ((vault (file-name-as-directory (make-temp-file "gov-cite-vault2" t))))
    (unwind-protect
        (let ((cc-butler-governance-vault-root vault))
          (make-directory (expand-file-name "docs" vault))
          (make-directory (expand-file-name "site" vault))
          (with-temp-file (expand-file-name "note.md" vault) (insert "[[a]]\n"))
          (with-temp-file (expand-file-name "docs/note.md" vault) (insert "[[a]]\n"))
          (with-temp-file (expand-file-name "site/note.md" vault) (insert "[[a]]\n"))
          (should (equal (gethash "a" (car (cc-butler-governance--citation-count-map))) 1)))
      (delete-directory vault t))))

(ert-deftest cc-butler-governance/citation-count-map-missing-vault-degrades-gracefully ()
  "A vault that does not exist (or is not yet configured) must never break
regeneration -- Band B's ordering is a nice-to-have, not a gate on whether
notes appear in the index at all. Failure reads as an empty map plus a named
reason, not an error."
  (let* ((missing (expand-file-name "does-not-exist" (make-temp-file "gov-cite-missing" t)))
         (cc-butler-governance-vault-root missing))
    (let ((result (cc-butler-governance--citation-count-map)))
      (should (zerop (hash-table-count (car result))))
      (should (stringp (cdr result))))))

;;;; --- integration: cc-butler-governance-regenerate wired end to end ---

(ert-deftest cc-butler-governance/regenerate-two-band-index-real-git ()
  "End to end, with a REAL git repo standing in for the store: a note
committed recently (Band A) leads a note that is only heavily cited but has
no recent commit (Band B), and the reported message names the two-band
shape (not the old single-key wording)."
  (skip-unless (executable-find "git"))
  (cc-butler-governance-test--with-store
    (cc-butler-governance-test--init-repo store)
    (let ((now (floor (float-time))))
      (cc-butler-governance-test--commit-at
       store (- now 3600) "recent" "recent-note.md"))
    ;; `old-note' pre-dates the window entirely -- write it WITHOUT a commit
    ;; touching it inside the last `band-a-days', by committing it long ago
    (cc-butler-governance-test--commit-at
     store (- (floor (float-time)) (* 30 86400)) "old" "old-note.md")
    (with-temp-file (expand-file-name "citing.md" vault)
      (insert "[[old-note]] [[old-note]] [[old-note]]\n"))  ; heavily cited, but stale commit
    (let ((out (cc-butler-tool-regenerate-governance)))
      (should (string-match-p "two bands" out))
      (let* ((index-text (with-temp-buffer
                           (insert-file-contents (expand-file-name "MEMORY.md" mem))
                           (buffer-string)))
             (slugs (cc-butler-governance--index-butler-slugs index-text)))
        ;; Band A (recent commit) leads Band B (citation-only), even though
        ;; `old-note' is the more heavily cited of the two
        (should (equal slugs '("recent-note" "old-note")))))))

(ert-deftest cc-butler-governance/regenerate-still-falls-back-loudly-without-git ()
  "REGRESSION GUARD (carried over from #196, re-confirmed after the two-band
change): a store that is not a git repo must still fall back to plain
insertion order, and say so loudly -- this must not have quietly broken
while wiring the citation map in alongside it."
  (cc-butler-governance-test--with-store
    (with-temp-file (expand-file-name "a-rule.md" store)
      (insert (cc-butler-governance--render "a-rule" "d" "body" "feedback")))
    (let ((out (cc-butler-tool-regenerate-governance)))
      (should (string-match-p "git-based sort unavailable" out))
      (should (string-match-p "not a git repository" out))
      (should (stringp cc-butler-governance--last-sort-unavailable-reason)))))

(ert-deftest cc-butler-governance/regenerate-bulk-commit-does-not-swallow-band-a ()
  "Check 4 (bulk-commit immunity), through the REAL pipeline: a single commit
touching many notes at once (a stand-in for the real 2026-09-08 91-file
wikilink-redirect commit) must not occupy the whole front of the index --
only `cc-butler-governance-band-a-commit-cap' of its members, the most-cited
ones, make Band A; the rest are pushed behind a genuinely-solo recent commit
and are still findable, just in Band B."
  (skip-unless (executable-find "git"))
  (cc-butler-governance-test--with-store
    (let ((cc-butler-governance-band-a-commit-cap 3))
      (cc-butler-governance-test--init-repo store)
      (let* ((now (floor (float-time)))
             (bulk-files (mapcar (lambda (i) (format "bulk-%02d.md" i))
                                  (number-sequence 1 20))))
        (apply #'cc-butler-governance-test--commit-at
               store (- now 1800) "bulk redirect" bulk-files)
        (cc-butler-governance-test--commit-at
         store (- now 3600) "solo" "loved.md"))
      (with-temp-file (expand-file-name "citing.md" vault)
        ;; `loved' and one bulk file (bulk-07) are the only cited notes --
        ;; standing in for the mass of files a mechanical redirect touches
        ;; without any of them individually being popular
        (insert "[[loved]] [[loved]] [[bulk-07]]\n"))
      (cc-butler-tool-regenerate-governance)
      (let* ((index-text (with-temp-buffer
                           (insert-file-contents (expand-file-name "MEMORY.md" mem))
                           (buffer-string)))
             (slugs (cc-butler-governance--index-butler-slugs index-text))
             (bulk-slugs (seq-filter (lambda (s) (string-prefix-p "bulk-" s)) slugs)))
        ;; all 20 bulk notes are still indexed SOMEWHERE -- the cap reorders,
        ;; it never drops a note
        (should (= (length bulk-slugs) 20))
        ;; the cited bulk survivor and the solo recent commit lead
        (should (member "loved" (seq-take slugs 4)))
        (should (member "bulk-07" (seq-take slugs 4)))
        ;; the cap actually bit: strictly fewer than all 20 bulk notes lead
        ;; the index alongside them -- most of the 20 are pushed behind
        (should (< (length (seq-intersection (seq-take slugs 4) bulk-slugs)) 20))
        (should (> (length bulk-slugs) cc-butler-governance-band-a-commit-cap))))))
