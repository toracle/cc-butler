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
;;;; Single-slug index-line format (2026-09-09, steward: only ~74 of
;;;; ~598 generated lines fit the hook's real read budget) --
;;;; `--render-index-line' writes the slug ONCE, plain-text
;;;; `butler-SLUG.md' kept (no `[]()' brackets) as the ownership marker,
;;;; plus generation-time description truncation via `--truncate-bytes'.
;;;; ------------------------------------------------------------------

(ert-deftest cc-butler-governance/render-index-line-writes-the-slug-once ()
  "The new line shape: `- butler-SLUG.md — DESC', slug written exactly
once, no markdown link brackets around it."
  (let ((line (cc-butler-governance--render-index-line "verify-delivery" "Confirm it landed")))
    (should (equal line "- butler-verify-delivery.md — Confirm it landed\n"))
    ;; the marker appears exactly once, not twice as the old `[S](butler-S.md)' did
    (let ((count 0) (start 0))
      (while (string-match "verify-delivery" line start)
        (setq count (1+ count) start (match-end 0)))
      (should (= count 1)))
    (should-not (string-match-p "\\[" line))))

(ert-deftest cc-butler-governance/truncate-bytes-leaves-a-short-string-alone ()
  "A description already under the budget is returned unchanged -- no
ellipsis added, nothing marked."
  (should (equal (cc-butler-governance--truncate-bytes "short" 48) "short")))

(ert-deftest cc-butler-governance/truncate-bytes-is-byte-exact ()
  "An over-budget ASCII description is cut with an ellipsis appended, and the
RESULT (ellipsis included) fits the byte budget exactly -- not the input."
  (let* ((s (make-string 80 ?x))
         (out (cc-butler-governance--truncate-bytes s 48)))
    (should (<= (string-bytes out) 48))
    (should (string-suffix-p "…" out))
    (should (string-prefix-p (substring out 0 (1- (length out))) s))))

(ert-deftest cc-butler-governance/truncate-bytes-does-not-corrupt-a-korean-character ()
  "This store's real descriptions are almost all Korean, where one character
is 3 UTF-8 bytes -- `string-bytes' != `length'.  A naive byte-substring
would risk slicing a multi-byte character in half.  Cutting by CHARACTER
\(never by byte) guarantees the result is always whole characters plus the
ellipsis, and still fits the budget."
  (let* ((s (make-string 40 ?정))   ; 40 chars * 3 bytes = 120 bytes, well over 48
         (out (cc-butler-governance--truncate-bytes s 48)))
    (should (<= (string-bytes out) 48))
    (should (string-suffix-p "…" out))
    (let ((kept (substring out 0 (1- (length out)))))
      ;; every kept character is a real, unmangled prefix character of S --
      ;; if a byte-slice had cut mid-character this would not hold, or
      ;; `kept' would contain a replacement/garbage character instead.
      (should (string-prefix-p kept s))
      (dotimes (i (length kept))
        (should (= (aref kept i) ?정))))))

(ert-deftest cc-butler-governance/generation-time-truncates-a-long-legacy-description ()
  "`--index-line' (generation-time, reads the note's CURRENT frontmatter off
disk) truncates to 48 bytes even for a description that predates any
length cap -- silently, no refusal, since a legacy note authored before
`cc-butler-governance-max-index-line-bytes' existed must still get a short,
recallable index line on every regenerate with no manual intervention."
  (cc-butler-governance-test--with-store
    (let ((long-desc (make-string 200 ?d)))
      ;; Bypass record_principle's own refusal so an over-length legacy
      ;; description can exist in the store at all, the way a genuinely
      ;; old note (predating the cap) would.
      (with-temp-file (expand-file-name "legacy.md" store)
        (insert (cc-butler-governance--render "legacy" long-desc "body" "feedback")))
      (cc-butler-governance-regenerate)
      (let* ((index (expand-file-name "MEMORY.md" mem))
             (text (with-temp-buffer (insert-file-contents index) (buffer-string))))
        (should (string-match "^- butler-legacy\\.md — \\(.*\\)$" text))
        (should (<= (string-bytes (match-string 1 text)) 48))
        (should (string-suffix-p "…" (match-string 1 text)))))))

(ert-deftest cc-butler-governance/record-time-cap-still-measures-the-full-untruncated-description ()
  "REGRESSION GUARD: generation-time truncation
\(`cc-butler-governance--generated-description-max-bytes', 48) must never
leak into the record-time index-line-length check
\(`cc-butler-governance-max-index-line-bytes', an author-facing gate that
refuses rather than silently truncating).  A description just over 48
bytes but comfortably under a wide record-time cap must be accepted
AS-IS -- not silently shortened -- proving the two code paths
\(`--render-index-line' direct vs `--index-line' off-disk) stay independent."
  (cc-butler-governance-test--with-store
    (let* ((desc (make-string 60 ?d))                    ; over the 48B generation truncation
           (cc-butler-governance-max-index-line-bytes 1000))  ; wide open record-time cap
      (let ((res (cc-butler-governance-record "x" desc "body")))
        (should (plist-get res :verified))
        (let ((text (with-temp-buffer (insert-file-contents (plist-get res :path))
                                      (buffer-string))))
          ;; the STORE note (record-time write) keeps the full description,
          ;; never truncated -- only the GENERATED index line is shortened
          (should (string-match-p (regexp-quote desc) text)))))))

;;;; ------------------------------------------------------------------
;;;; The slug-aware description budget (2026-09-10) -- CONFIRMED BUG: the
;;;; description was truncated to a FIXED 48 bytes regardless of how many
;;;; of the 80-byte line cap the slug's own boilerplate already spent.
;;;; Real slugs run 40-75 bytes, so lines routinely rendered 108-124 bytes
;;;; against the 80-byte `cc-butler-governance-max-index-line-bytes' cap
;;;; even though each description alone fit its own 48-byte sub-limit
;;;; (measured 2026-09-10: 587 real lines averaged 113 bytes). Fix:
;;;; `--index-line' now sizes the description to what is actually left
;;;; after the slug (`--description-budget-bytes'), and
;;;; `--shrink-oversized-index-lines' (wired into `regenerate') re-renders
;;;; any CURRENT-format line still over the cap from before the fix.
;;;; ------------------------------------------------------------------

(ert-deftest cc-butler-governance/regenerate-shrinks-oversized-current-format-index-line ()
  "RED for the real-world bug state: an already-CURRENT-format line
\(`- butler-SLUG.md — DESC') for a long slug, rendered under the OLD flat
48-byte description truncation, is over `max-index-line-bytes' even
though `--normalize-index-format' does not touch it (that pass only
matches the OLD double-slug bracket shape). GREEN after
`cc-butler-governance-regenerate' runs `--shrink-oversized-index-lines':
the line for this slug is re-rendered to fit the cap, and the old
oversized text is gone."
  (cc-butler-governance-test--with-store
    (let* ((slug "an-extremely-long-slug-name-that-mostly-fills-the-budget")
           (desc "This is a genuinely long description text used to verify the old flat truncation overflowed the eighty byte line cap in the legacy rendering path.")
           (index (expand-file-name "MEMORY.md" mem))
           (old-truncated (cc-butler-governance--truncate-bytes
                           desc cc-butler-governance--generated-description-max-bytes))
           (old-line (cc-butler-governance--render-index-line slug old-truncated)))
      ;; Guard the premise: the OLD-scheme line really is over the cap, and
      ;; this slug's own boilerplate alone is NOT (so a fix is possible).
      (should (> (string-bytes old-line) cc-butler-governance-max-index-line-bytes))
      (should (< (cc-butler-governance--description-budget-bytes slug) 48))
      (should (> (cc-butler-governance--description-budget-bytes slug) 0))
      (with-temp-file (expand-file-name (concat slug ".md") store)
        (insert (cc-butler-governance--render slug desc "body" "feedback")))
      ;; Pre-seed MEMORY.md with the already-current-format, already-oversized
      ;; line -- the real bug state `--normalize-index-format' cannot see.
      (with-temp-file index (insert old-line))
      (cc-butler-governance-regenerate)
      (let ((text (with-temp-buffer (insert-file-contents index) (buffer-string))))
        (should-not (string-search old-line text))
        (with-temp-buffer
          (insert text)
          (goto-char (point-min))
          (should (re-search-forward cc-butler-governance--index-line-regexp nil t))
          (let* ((beg (match-beginning 0))
                 (end (min (point-max) (1+ (line-end-position))))
                 (full-line (buffer-substring-no-properties beg end)))
            (should (<= (string-bytes full-line) cc-butler-governance-max-index-line-bytes))))))))

(ert-deftest cc-butler-governance/description-budget-is-zero-when-slug-boilerplate-alone-exceeds-the-cap ()
  "EDGE CASE: a slug long enough that `- butler-SLUG.md — ' plus its
trailing newline alone already meets or exceeds
`cc-butler-governance-max-index-line-bytes' gets a description budget of
0 -- the slug itself is the overflow, not the description, and no
description length can fix that without renaming the note (out of
scope; see `cc-butler-governance--description-budget-bytes'). Must not
error, and `--index-line' must still return normally rather than hang."
  (cc-butler-governance-test--with-store
    (let ((slug "a-fabricated-slug-name-deliberately-long-enough-to-exceed-the-cap-alone"))
      ;; Guard the premise: this slug's boilerplate alone is already over.
      (should (> (string-bytes (format "- butler-%s.md — \n" slug))
                 cc-butler-governance-max-index-line-bytes))
      (should (= 0 (cc-butler-governance--description-budget-bytes slug)))
      ;; `--index-line' reads the note off the MEMORY-DIR copy (the shape
      ;; `cc-butler-governance-regenerate' produces via its `butler-' prefix
      ;; copy step), not the raw store -- write it there directly.
      (with-temp-file (expand-file-name (concat "butler-" slug ".md") mem)
        (insert (cc-butler-governance--render
                 slug "a perfectly ordinary description, irrelevant here" "body" "feedback")))
      ;; No error, no hang -- and the description portion is minimal (the
      ;; ellipsis alone), never the untruncated description.
      (let ((line (cc-butler-governance--index-line slug)))
        (should (stringp line))
        (should-not (string-match-p "perfectly ordinary description" line))))))

;;;; ------------------------------------------------------------------
;;;; The ellipsis floor (2026-09-10): a description budget SMALLER than the
;;;; ellipsis's own byte size (3) still let `--truncate-bytes' emit a lone
;;;; \"…\" -- itself over the requested budget -- and `--render-index-line'
;;;; then kept the ` — ' separator even with nothing after it.  Real slug
;;;; `another-sessions-committed-docs-are-a-corpus-nobody-searches' is one
;;;; of 20 real store slugs whose budget is 1 or 2 bytes, confirmed below.
;;;; ------------------------------------------------------------------

(ert-deftest cc-butler-governance/truncate-bytes-floor-is-empty-not-an-over-budget-ellipsis ()
  "MAX-BYTES below the ellipsis's own 3-byte size has no truncation that
actually fits -- the old code stripped S to nothing and still appended
the ellipsis, returning a 3-byte string that is ITSELF over budget.
Must now return the empty string instead."
  (let ((slug "another-sessions-committed-docs-are-a-corpus-nobody-searches"))
    ;; Guard the premise against this worktree's actual code: this real
    ;; slug's budget really is 1 or 2 bytes, both below the ellipsis's own
    ;; `string-bytes' (3).
    (let ((budget (cc-butler-governance--description-budget-bytes slug)))
      (should (member budget '(1 2)))
      (should (equal (cc-butler-governance--truncate-bytes
                       "a genuinely long description text, irrelevant content" budget)
                     "")))))

(ert-deftest cc-butler-governance/index-line-drops-separator-when-description-is-empty ()
  "A slug whose budget floors the description to empty must render WITHOUT
the ` — ' separator -- `- butler-SLUG.md\\n', not a dangling
`- butler-SLUG.md — \\n' with nothing after it -- and the whole line must
fit the 80-byte cap."
  (cc-butler-governance-test--with-store
    (let ((slug "another-sessions-committed-docs-are-a-corpus-nobody-searches"))
      (with-temp-file (expand-file-name (concat "butler-" slug ".md") mem)
        (insert (cc-butler-governance--render
                 slug "a genuinely long description text, irrelevant content" "body" "feedback")))
      (let ((line (cc-butler-governance--index-line slug)))
        (should (<= (string-bytes line) cc-butler-governance-max-index-line-bytes))
        (should-not (string-match-p " — " line))
        (should (equal line (format "- butler-%s.md\n" slug)))))))

(ert-deftest cc-butler-governance/index-has-slug-p-recognizes-a-bare-no-description-line ()
  "The exact regression risk named in the fix: a slug whose only `MEMORY.md'
line is already in the new bare (no-separator) shape must still be
recognized as indexed, or `--sync-index' would append a duplicate line
for it on every regenerate."
  (cc-butler-governance-test--with-store
    (let* ((slug "another-sessions-committed-docs-are-a-corpus-nobody-searches")
           (index (expand-file-name "MEMORY.md" mem))
           (bare-line (format "- butler-%s.md\n" slug)))
      (with-temp-file index (insert bare-line))
      (should (cc-butler-governance--index-has-slug-p index slug))
      ;; End-to-end: regenerate must not duplicate it.
      (with-temp-file (expand-file-name (concat slug ".md") store)
        (insert (cc-butler-governance--render
                 slug "a genuinely long description text, irrelevant content" "body" "feedback")))
      (cc-butler-governance-regenerate)
      (let* ((text (with-temp-buffer (insert-file-contents index) (buffer-string)))
             (count 0) (start 0))
        (while (string-match (regexp-quote (format "butler-%s.md" slug)) text start)
          (setq count (1+ count) start (match-end 0)))
        (should (= count 1))))))

(ert-deftest cc-butler-governance/regenerate-repairs-an-old-over-budget-ellipsis-line-to-bare-form ()
  "Full round trip on the exact real-world bug state: `MEMORY.md' holds the
OLD buggy line this store actually wrote for a tiny-budget slug -- a lone,
over-budget `…' after the separator (81-82 bytes against the 80-byte
cap). After `cc-butler-governance-regenerate', that slug's line must be
the bare, <=80-byte, separator-free form."
  (cc-butler-governance-test--with-store
    (let* ((slug "another-sessions-committed-docs-are-a-corpus-nobody-searches")
           (index (expand-file-name "MEMORY.md" mem))
           (old-buggy-line (cc-butler-governance--render-index-line slug "…")))
      ;; Guard the premise: this really is the over-budget shape the
      ;; pre-fix code actually wrote for these 20 real slugs.
      (should (> (string-bytes old-buggy-line) cc-butler-governance-max-index-line-bytes))
      (with-temp-file index (insert old-buggy-line))
      (with-temp-file (expand-file-name (concat slug ".md") store)
        (insert (cc-butler-governance--render
                 slug "a genuinely long description text, irrelevant content" "body" "feedback")))
      (cc-butler-governance-regenerate)
      (let ((text (with-temp-buffer (insert-file-contents index) (buffer-string))))
        (should-not (string-search old-buggy-line text))
        (should-not (string-match-p (concat "butler-" (regexp-quote slug) "\\.md — ") text))
        (with-temp-buffer
          (insert text)
          (goto-char (point-min))
          (should (re-search-forward
                   (concat "^- butler-" (regexp-quote slug) "\\.md$") nil t))
          (let* ((beg (match-beginning 0))
                 (end (min (point-max) (1+ (line-end-position))))
                 (full-line (buffer-substring-no-properties beg end)))
            (should (<= (string-bytes full-line) cc-butler-governance-max-index-line-bytes))))))))

;;;; ------------------------------------------------------------------
;;;; Normalizing already-generated legacy (OLD-format) index lines
;;;; (2026-09-09) -- the missing piece: changing the writer alone only
;;;; affects brand-new lines; `--sync-index' is add-only and never
;;;; touches an existing line, so the ~566-598 lines already on disk in
;;;; the OLD `- [S](butler-S.md) — desc' shape need an explicit rewrite
;;;; step, run every `cc-butler-governance-regenerate'.
;;;; ------------------------------------------------------------------

(ert-deftest cc-butler-governance/legacy-line-is-normalized-with-a-fresh-description ()
  "An OLD-format line for a slug whose store note still exists is rewritten
to the NEW format, with the description freshly re-read from the note's
CURRENT frontmatter (and truncated to 48 bytes) -- not the stale text the
old line held."
  (cc-butler-governance-test--with-store
    (let ((index (expand-file-name "MEMORY.md" mem))
          (legacy "- [a-rule](butler-a-rule.md) — an old, stale wording\n"))
      (with-temp-file index (insert legacy))
      (with-temp-file (expand-file-name "a-rule.md" store)
        (insert (cc-butler-governance--render "a-rule" "current frontmatter wording" "body" "feedback")))
      (cc-butler-governance-regenerate)
      (let ((text (with-temp-buffer (insert-file-contents index) (buffer-string))))
        (should-not (string-match-p (regexp-quote legacy) text))
        (should-not (string-match-p "an old, stale wording" text))
        (should (string-match-p "^- butler-a-rule\\.md — current frontmatter wording$" text))))))

(ert-deftest cc-butler-governance/normalize-leaves-a-dead-legacy-slug-untouched ()
  "An OLD-format line whose slug no longer has a matching store note is left
exactly as-is by normalize -- it is neither rewritten (there is nothing
current to re-read) nor deleted (this step never deletes)."
  (cc-butler-governance-test--with-store
    (let ((index (expand-file-name "MEMORY.md" mem))
          (dangling "- [gone](butler-gone.md) — a principle no longer in the store\n"))
      (with-temp-file index (insert dangling))
      (cc-butler-governance--normalize-index-format)
      (should (string-match-p (regexp-quote dangling)
                              (with-temp-buffer (insert-file-contents index) (buffer-string)))))))

(ert-deftest cc-butler-governance/normalize-and-sync-together-never-produce-two-lines ()
  "A slug with a not-yet-normalized OLD-format line must end up with EXACTLY
ONE line after a full regenerate -- never zero (normalize must not drop
it), never two (`--sync-index' must not mistake the not-yet-normalized
line for a missing one and append a second, new-format line beside it)."
  (cc-butler-governance-test--with-store
    (let ((index (expand-file-name "MEMORY.md" mem)))
      (with-temp-file index
        (insert "- [a-rule](butler-a-rule.md) — old wording\n"))
      (with-temp-file (expand-file-name "a-rule.md" store)
        (insert (cc-butler-governance--render "a-rule" "d" "body" "feedback")))
      (cc-butler-governance-regenerate)
      (let ((text (with-temp-buffer (insert-file-contents index) (buffer-string)))
            (count 0) (start 0))
        (while (string-match "butler-a-rule\\.md" text start)
          (setq count (1+ count) start (match-end 0)))
        (should (= count 1))))))

(ert-deftest cc-butler-governance/normalize-is-idempotent-on-a-mixed-old-new-hand-authored-file ()
  "Running `cc-butler-governance-regenerate' a second time on a file already
containing an OLD-format line (now normalized), a NEW-format line, and a
hand-authored line must produce a BYTE-IDENTICAL `MEMORY.md' to the first
run -- no re-rewriting an already-current line, no re-adding, no drift."
  (cc-butler-governance-test--with-store
    (let ((index (expand-file-name "MEMORY.md" mem)))
      (with-temp-file index
        (insert "- [old-rule](butler-old-rule.md) — stale text\n"
                "- [steward-only-note](steward-only-note.md) — hand-authored, no matching store file\n"))
      (with-temp-file (expand-file-name "old-rule.md" store)
        (insert (cc-butler-governance--render "old-rule" "fresh description" "body" "feedback")))
      (with-temp-file (expand-file-name "new-rule.md" store)
        (insert (cc-butler-governance--render "new-rule" "already new" "body" "feedback")))
      (cc-butler-governance-regenerate)
      (let ((after-first (with-temp-buffer (insert-file-contents index) (buffer-string))))
        (cc-butler-governance-regenerate)
        (let ((after-second (with-temp-buffer (insert-file-contents index) (buffer-string))))
          (should (equal after-first after-second))
          ;; and nothing was lost along the way: all three slugs still present
          (should (string-match-p "old-rule" after-second))
          (should (string-match-p "new-rule" after-second))
          (should (string-match-p "steward-only-note" after-second)))))))

;;;; ------------------------------------------------------------------
;;;; The THIRD, even older bare-target bracket-link shape (2026-09-09
;;;; follow-up): `- [slug](slug.md) — desc', no `butler-' prefix at all.
;;;; ------------------------------------------------------------------

(ert-deftest cc-butler-governance/bare-target-duplicate-is-removed-not-just-normalized ()
  "RED for this bug: a bare-target bracket line (no `butler-' prefix on the
link target) for a slug that ALREADY has a canonical current-format line
elsewhere is a true duplicate, not merely an un-normalized one.
`--normalize-index-format' alone does not recognize this shape at all
\(it only rewrites a target already carrying `butler-'\), so before this
fix the duplicate survives a regenerate untouched.  After the fix,
regenerate must leave the slug indexed EXACTLY once."
  (cc-butler-governance-test--with-store
    (let ((index (expand-file-name "MEMORY.md" mem)))
      (with-temp-file index
        (insert "- butler-a-rule.md — current frontmatter wording\n"
                "- [a-rule](a-rule.md) — stale, pre-butler-prefix duplicate\n"))
      (with-temp-file (expand-file-name "a-rule.md" store)
        (insert (cc-butler-governance--render "a-rule" "current frontmatter wording" "body" "feedback")))
      (cc-butler-governance-regenerate)
      (let* ((text (with-temp-buffer (insert-file-contents index) (buffer-string)))
             (count 0) (start 0))
        (while (string-match "a-rule\\.md" text start)
          (setq count (1+ count) start (match-end 0)))
        (should (= count 1))
        (should-not (string-match-p "stale, pre-butler-prefix duplicate" text))))))

(ert-deftest cc-butler-governance/bare-target-duplicate-dedupes-by-link-target-not-display-text ()
  "A real store line (2026-09-09) has bracket DISPLAY text that is a
truncated, mismatched copy of its own link TARGET
\(`[steward-externalize-is-survival-insurance]
(steward-externalize-is-survival-insurance-not-just-compaction-hygiene.md)'\).
The slug identity must come from the TARGET, never the display text --
using display text here would fail to recognize this as the duplicate of
the existing `...-not-just-compaction-hygiene' canonical line that it is."
  (cc-butler-governance-test--with-store
    (let ((index (expand-file-name "MEMORY.md" mem)))
      (with-temp-file index
        (insert "- butler-full-slug-name.md — current wording\n"
                "- [short-name](full-slug-name.md) — old, mismatched display text\n"))
      (with-temp-file (expand-file-name "full-slug-name.md" store)
        (insert (cc-butler-governance--render "full-slug-name" "current wording" "body" "feedback")))
      (cc-butler-governance-regenerate)
      (let* ((text (with-temp-buffer (insert-file-contents index) (buffer-string)))
             (count 0) (start 0))
        (while (string-match "full-slug-name\\.md" text start)
          (setq count (1+ count) start (match-end 0)))
        (should (= count 1))
        (should-not (string-match-p "mismatched display text" text))))))

(ert-deftest cc-butler-governance/bare-target-line-rewritten-in-place-when-not-yet-indexed ()
  "A bare-target line for a LIVE store slug that has no canonical line yet
must be REWRITTEN to the canonical form, not deleted -- deleting it with
nothing to replace it would leave the slug indexed zero times until the
next `--sync-index' pass happens to add it back (which it does, but this
proves the dedupe step itself never transiently loses the slug)."
  (cc-butler-governance-test--with-store
    (let ((index (expand-file-name "MEMORY.md" mem)))
      (with-temp-file index
        (insert "- [a-rule](a-rule.md) — old, pre-butler-prefix wording\n"))
      (with-temp-file (expand-file-name "a-rule.md" store)
        (insert (cc-butler-governance--render "a-rule" "fresh frontmatter wording" "body" "feedback")))
      (cc-butler-governance-regenerate)
      (let ((text (with-temp-buffer (insert-file-contents index) (buffer-string))))
        (should (string-match-p "^- butler-a-rule\\.md — fresh frontmatter wording$" text))
        (should-not (string-match-p "\\[a-rule\\](a-rule\\.md)" text))))))

(ert-deftest cc-butler-governance/bare-target-line-left-untouched-when-dangling ()
  "A bare-target line whose slug names no live store note at all is left
completely untouched -- neither deleted (nothing here is this store's
business to remove) nor rewritten (nothing current to re-read).  Same
existing fixture other dangling-link tests in this file use."
  (cc-butler-governance-test--with-store
    (let ((index (expand-file-name "MEMORY.md" mem))
          (hand-written "- [steward-only-note](steward-only-note.md) — hand-authored, no matching store file\n"))
      (with-temp-file index (insert hand-written))
      (cc-butler-governance-regenerate)
      (should (string-match-p (regexp-quote hand-written)
                              (with-temp-buffer (insert-file-contents index) (buffer-string)))))))

(ert-deftest cc-butler-governance/bare-target-shape-never-touches-a-hand-authored-sentence-title-entry ()
  "SAFETY NEGATIVE CONTROL (2026-09-09, steward-caught near-miss): this
fleet's real MEMORY.md also carries genuine hand-authored, non-governance
personal/project memory entries in the EXACT SAME bracket shape a bare-
target legacy duplicate has -- e.g. `- [Daily standup process]
(daily-standup-process.md) — ...'.  These 6 real lines (verbatim from the
live file) must survive completely untouched: dedupe must never rewrite
or remove a link-shaped line whose slug this store does not itself own,
even though the SHAPE alone cannot tell it apart from a real legacy
duplicate.  Two independent gates must both hold: the lowercase-kebab
slug character class (capitalized, spaced display text like \"Daily
standup process\" never matches the regexp at all) AND, even for a line
that somehow did match syntactically, membership in the real store's
slug list (`cc-butler-governance-names') before anything is touched."
  (cc-butler-governance-test--with-store
    (let ((index (expand-file-name "MEMORY.md" mem))
          (real-hand-authored-lines
           (concat
            "- [Daily standup process](daily-standup-process.md) — how the butler runs the daily standup\n"
            "- [User: SPT principle](user-spt-principle.md) — user heavily follows \"simplest thing that could work\"\n"
            "- [Framework reuse vs build principle](framework-reuse-vs-build-principle.md) — can't get the value/don't have it is a weak reason to reject reuse\n"
            "- [Warmblood talent philosophy](warmblood-talent-philosophy.md) — AUTHORITATIVE 인재상\n"
            "- [Operating principles doc](operating-principles-doc.md) — team collaboration/decision principles live in warmble-jumble vault\n"
            "- [Monocle admin panel orphaned](project-monocle-admin-panel-orphaned.md) — Monocle's admin panel screen is unreachable\n")))
      ;; None of these 6 targets exist anywhere in the store -- exactly the
      ;; real-fleet condition (confirmed 2026-09-09: all 6 targets absent
      ;; from the governance store).
      (with-temp-file index (insert real-hand-authored-lines))
      (cc-butler-governance-regenerate)
      (let ((text (with-temp-buffer (insert-file-contents index) (buffer-string))))
        (dolist (fragment '("Daily standup process" "User: SPT principle"
                             "Framework reuse vs build principle"
                             "Warmblood talent philosophy" "Operating principles doc"
                             "Monocle admin panel orphaned"))
          (should (string-match-p (regexp-quote fragment) text)))))))

;;;; ------------------------------------------------------------------
;;;; Direct unit coverage for the 4 reader functions, against
;;;; hand-constructed NEW-format strings (not only via a full
;;;; regenerate roundtrip) -- proves each recognizes the current shape
;;;; on its own.
;;;; ------------------------------------------------------------------

(ert-deftest cc-butler-governance/index-has-slug-p-recognizes-new-format ()
  (cc-butler-governance-test--with-store
    (let ((index (expand-file-name "MEMORY.md" mem)))
      (with-temp-file index (insert "- butler-a-rule.md — some description\n"))
      (should (cc-butler-governance--index-has-slug-p index "a-rule"))
      (should-not (cc-butler-governance--index-has-slug-p index "other-rule")))))

(ert-deftest cc-butler-governance/index-has-slug-p-still-recognizes-old-format ()
  "So `--sync-index' never appends a duplicate for a slug whose only line
hasn't been normalized to the new shape yet."
  (cc-butler-governance-test--with-store
    (let ((index (expand-file-name "MEMORY.md" mem)))
      (with-temp-file index (insert "- [a-rule](butler-a-rule.md) — some description\n"))
      (should (cc-butler-governance--index-has-slug-p index "a-rule")))))

(ert-deftest cc-butler-governance/index-butler-slugs-reads-new-format-only ()
  (let ((slugs (cc-butler-governance--index-butler-slugs
                (concat "- butler-a-rule.md — desc one\n"
                        "- [old-rule](butler-old-rule.md) — desc two\n"   ; old shape, ignored
                        "- steward-only-note.md — hand-authored, no marker\n"
                        "- butler-b-rule.md — desc three\n"))))
    (should (equal slugs '("a-rule" "b-rule")))))

(ert-deftest cc-butler-governance/prune-dead-entries-recognizes-new-format ()
  (cc-butler-governance-test--with-store
    (let ((index (expand-file-name "MEMORY.md" mem)))
      (with-temp-file index
        (insert "- butler-gone.md — a principle no longer in the store\n"
                "- steward-only-note.md — hand-authored, untouched\n"))
      ;; No matching store note for "gone" -- store is empty.
      (cc-butler-governance--prune-dead-entries)
      (let ((text (with-temp-buffer (insert-file-contents index) (buffer-string))))
        (should-not (string-match-p "butler-gone\\.md" text))
        (should (string-match-p "steward-only-note" text))))))

(ert-deftest cc-butler-governance/stale-index-entries-recognizes-new-format ()
  (cc-butler-governance-test--with-store
    (let ((index (expand-file-name "MEMORY.md" mem)))
      (with-temp-file (expand-file-name "a-rule.md" store)
        (insert (cc-butler-governance--render "a-rule" "current wording" "body" "feedback")))
      (with-temp-file index (insert "- butler-a-rule.md — stale old wording\n"))
      (should (equal (cc-butler-governance--stale-index-entries) '("a-rule"))))))

(ert-deftest cc-butler-governance/a-user-layer-override-is-not-reported-drifted ()
  "A user-layer file overrides the store note of the same basename
\(`cc-butler-governance-principles'), and the index line is generated from
the RESOLVED copy.  So the drift check must resolve the same way; reading the
store copy reports every overridden note as drifted.

Measured 2026-09-10 against the live store: after the byte-cap fix, the single
remaining reported drift was `haiku-summarization-delegation' -- the one note
whose basename exists in both the store and the user layer.  It was this bug,
not a drift.  True drift count was 0."
  (cc-butler-governance-test--with-store
    (let* ((userdir (file-name-as-directory (make-temp-file "gov-user" t)))
           (cc-butler-governance-user-dir userdir)
           (index (expand-file-name "MEMORY.md" mem))
           (store-desc "the store's own wording for this rule, long enough to be truncated")
           (user-desc "the USER layer's overriding wording, also long enough to truncate")
           (user-trunc (cc-butler-governance--truncate-bytes
                        user-desc cc-butler-governance--generated-description-max-bytes)))
      (unwind-protect
          (progn
            ;; Guard the premise: the two layers must actually differ, and the
            ;; description must exceed the cap, or this test proves nothing.
            (should-not (equal store-desc user-desc))
            (should (> (string-bytes user-desc)
                       cc-butler-governance--generated-description-max-bytes))
            (with-temp-file (expand-file-name "a-rule.md" store)
              (insert (cc-butler-governance--render "a-rule" store-desc "body" "feedback")))
            (with-temp-file (expand-file-name "a-rule.md" userdir)
              (insert (cc-butler-governance--render "a-rule" user-desc "body" "feedback")))
            ;; The line matches the RESOLVED (user) wording: not drifted.
            (with-temp-file index
              (insert (format "- butler-a-rule.md \u2014 %s\n" user-trunc)))
            (should-not (cc-butler-governance--stale-index-entries))
            ;; Positive control, same test: a third wording matching NEITHER
            ;; layer is still reported, so the assertion above cannot pass by
            ;; the check having gone silent.
            (with-temp-file index
              (insert "- butler-a-rule.md \u2014 neither layer's wording\n"))
            (should (equal (cc-butler-governance--stale-index-entries) '("a-rule"))))
        (delete-directory userdir t)))))

(ert-deftest cc-butler-governance/a-description-over-the-index-cap-is-not-reported-drifted ()
  "The index line holds a BYTE-TRUNCATED description, so the store's
description must be truncated the same way before comparing.  Without
that, every note whose description exceeds
`cc-butler-governance--generated-description-max-bytes' reports as drifted
forever -- measured 2026-09-10 against the live store: 569 of the 569 notes
carrying a description, i.e. the check could never report a real drift and
its signal was exactly zero."
  (cc-butler-governance-test--with-store
    (let* ((index (expand-file-name "MEMORY.md" mem))
           (desc "a description comfortably longer than the forty-eight byte index cap")
           (truncated (cc-butler-governance--truncate-bytes
                       desc cc-butler-governance--generated-description-max-bytes)))
      ;; Guard the premise: this test is vacuous if the description fits.
      (should (> (string-bytes desc)
                 cc-butler-governance--generated-description-max-bytes))
      (with-temp-file (expand-file-name "a-rule.md" store)
        (insert (cc-butler-governance--render "a-rule" desc "body" "feedback")))
      (with-temp-file index
        (insert (format "- butler-a-rule.md — %s\n" truncated)))
      ;; The line holds exactly what the renderer would write: not drifted.
      (should-not (cc-butler-governance--stale-index-entries))
      ;; Positive control, in the same test: a genuinely different wording is
      ;; still reported.  Without this the assertion above would also pass if
      ;; the check were broken into always returning nil.
      (with-temp-file index
        (insert "- butler-a-rule.md — genuinely different wording\n"))
      (should (equal (cc-butler-governance--stale-index-entries) '("a-rule"))))))

;;;; ------------------------------------------------------------------
;;;; The THIRD axis: a slug indexed more than once (2026-09-09 follow-up).
;;;; Neither store->index nor index->store can ever catch this -- a
;;;; duplicate satisfies both perfectly.
;;;; ------------------------------------------------------------------

(ert-deftest cc-butler-governance/duplicate-index-slugs-detects-a-slug-indexed-twice ()
  (let ((slugs (cc-butler-governance--index-butler-slugs
                (concat "- butler-a-rule.md — desc one\n"
                        "- butler-b-rule.md — desc two\n"
                        "- butler-a-rule.md — desc one again, worded differently\n"))))
    ;; Direct unit coverage of the counting logic, independent of file I/O.
    (should (equal slugs '("a-rule" "b-rule" "a-rule")))))

(ert-deftest cc-butler-governance/duplicate-index-slugs-reads-real-memory-md ()
  (cc-butler-governance-test--with-store
    (let ((index (expand-file-name "MEMORY.md" mem)))
      (with-temp-file index
        (insert "- butler-a-rule.md — desc one\n"
                "- butler-b-rule.md — desc two\n"
                "- butler-a-rule.md — desc one, indexed twice\n"))
      (should (equal (cc-butler-governance--duplicate-index-slugs) '("a-rule"))))))

(ert-deftest cc-butler-governance/duplicate-index-slugs-is-nil-when-clean ()
  (cc-butler-governance-test--with-store
    (let ((index (expand-file-name "MEMORY.md" mem)))
      (with-temp-file index
        (insert "- butler-a-rule.md — desc one\n" "- butler-b-rule.md — desc two\n"))
      (should-not (cc-butler-governance--duplicate-index-slugs)))))

(ert-deftest cc-butler-governance/duplicate-index-slugs-detects-cross-format-duplicate ()
  "The gap this whole PR chain exists to fix: a CURRENT-format line for a
slug plus a leftover bare-target LEGACY-format line (no `butler-' prefix)
for the SAME slug -- two different shapes, one duplicated slug.  RED
against the original, current-format-only `--duplicate-index-slugs' (it
walks right past the legacy-shaped line and reports zero duplicates,
since store->index and index->store both report clean too); GREEN once
the check counts across the union of recognized shapes."
  (cc-butler-governance-test--with-store
    (let ((index (expand-file-name "MEMORY.md" mem)))
      (with-temp-file index
        (insert "- butler-a-rule.md — current-format line\n"
                "- [a-rule](a-rule.md) — bare-target legacy-format line, same slug\n"))
      (should (equal (cc-butler-governance--duplicate-index-slugs) '("a-rule"))))))

(ert-deftest cc-butler-governance/duplicate-index-slugs-does-not-double-count-un-normalized-legacy-line ()
  "`--bare-legacy-index-line-regexp' is a strict textual superset of
`--legacy-index-line-regexp' (same bracket shape, no backreference
constraint), so an un-normalized legacy line (real ones exist in the live
store right now) matches BOTH regexps.  Two legacy-format lines for the
SAME slug are a genuine duplicate (correctly reported as \"a-rule\"), but
without the \"butler-\" prefix guard they would ALSO both match
`--bare-legacy-index-line-regexp' with target \"butler-a-rule\", so the
report would additionally, wrongly, include a second, nonexistent slug
literally named \"butler-a-rule\".  Asserts the real slug is reported
exactly once, with no pollutant entry alongside it."
  (cc-butler-governance-test--with-store
    (let ((index (expand-file-name "MEMORY.md" mem)))
      (with-temp-file index
        (insert "- [a-rule](butler-a-rule.md) — first un-normalized legacy line\n"
                "- [a-rule](butler-a-rule.md) — same slug, indexed twice\n"))
      (should (equal (cc-butler-governance--duplicate-index-slugs) '("a-rule"))))))

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
        (should (string-match-p "^- butler-verify-delivery\\.md — " text))
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
        (should (string-match-p "^- butler-a-rule\\.md — " text))))))

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
      (while (string-match "^- butler-a-rule\\.md — " text start)
        (setq count (1+ count) start (match-end 0)))
      (should (= count 1)))))

(ert-deftest cc-butler-governance/regenerate-does-not-duplicate-an-already-curated-entry ()
  "If a slug already has a hand-curated line (worded differently from the
frontmatter description), regenerate must not add a second, auto-generated
line for the same note — that would produce two competing entries for one
slug.  The curated line here is already in the CURRENT format on purpose:
only an OLD-format line is rewritten by `--normalize-index-format' (see
`cc-butler-governance/legacy-line-is-normalized-with-a-fresh-description'
for that case) -- a curated line already in the current shape must survive
completely untouched, wording and all."
  (cc-butler-governance-test--with-store
    (let ((index (expand-file-name "MEMORY.md" mem))
          (curated "- butler-a-rule.md — a human's own curated wording, not the frontmatter description\n"))
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
      (should (string-match-p "^- butler-raw-rule\\.md — " text)))))

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
        (should (string-match-p "^- butler-direct-write-rule\\.md — "
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
      (should (string-match-p "^- butler-a-rule\\.md — "
                              (with-temp-buffer (insert-file-contents index) (buffer-string))))
      ;; Simulate the hand-cleanup: the principle is gone from the store
      ;; and its generated note is gone from memory, but nobody touched
      ;; MEMORY.md.
      (delete-file (expand-file-name "a-rule.md" store))
      (delete-file (expand-file-name "butler-a-rule.md" mem))
      (cc-butler-governance-regenerate)
      (should-not (string-match-p "^- butler-a-rule\\.md — "
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

(ert-deftest cc-butler-governance/regenerate-tool-reports-a-slug-indexed-twice ()
  "RED for this bug: neither `--unindexed-names' nor `--dead-index-slugs'
can ever catch a slug indexed twice -- the note IS indexed (at least
once) and every line DOES point at a real note, so both existing checks
report clean.  Two hand-seeded CURRENT-format lines for the same slug are
not something `cc-butler-governance-regenerate' itself dedupes (that is
`--dedupe-bare-target-lines''s job for the third bracket shape only, not
for two already-canonical lines), so the duplicate must still be sitting
there when the report runs -- and before this fix, nothing in the report
text says so."
  (cc-butler-governance-test--with-store
    (with-temp-file (expand-file-name "a-rule.md" store)
      (insert (cc-butler-governance--render "a-rule" "d" "body" "feedback")))
    (let ((index (expand-file-name "MEMORY.md" mem)))
      (with-temp-file index
        (insert "- butler-a-rule.md — d\n" "- butler-a-rule.md — d, indexed a second time\n"))
      (let ((out (cc-butler-tool-regenerate-governance)))
        (should (string-match-p "a-rule" out))
        (should (string-match-p "1 slug(s) indexed more than once\\|indexed more than once" out))))))

(ert-deftest cc-butler-governance/regenerate-tool-reports-zero-duplicates-explicitly ()
  "Explicit zero, not silence -- matching this file's existing
store->index/index->store report lines, which always state \"0\" plainly
rather than omitting the line when there is nothing to report."
  (cc-butler-governance-test--with-store
    (with-temp-file (expand-file-name "a-rule.md" store)
      (insert (cc-butler-governance--render "a-rule" "d" "body" "feedback")))
    (let ((out (cc-butler-tool-regenerate-governance)))
      (should (string-match-p "0 slug(s) indexed more than once" out)))))

;;;; ------------------------------------------------------------------
;;;; The banner (2026-09-09 follow-up): generator-owned, real N-of-TOTAL
;;;; entries-in-budget figures instead of a hand-typed, ever-staler count.
;;;; ------------------------------------------------------------------

(ert-deftest cc-butler-governance/regenerate-writes-a-banner-with-accurate-counts ()
  "RED for this bug: before this fix, `cc-butler-governance-regenerate'
never writes any banner at all -- MEMORY.md's first line is just whatever
the caller happened to seed (or the first index line, if nothing was
seeded).  After the fix, every regenerate must prepend a banner whose
N-of-TOTAL figures are the real, freshly computed ones -- TOTAL equal to
the number of live store notes actually indexed."
  (cc-butler-governance-test--with-store
    (with-temp-file (expand-file-name "a-rule.md" store)
      (insert (cc-butler-governance--render "a-rule" "d" "body" "feedback")))
    (with-temp-file (expand-file-name "b-rule.md" store)
      (insert (cc-butler-governance--render "b-rule" "d" "body" "feedback")))
    (cc-butler-governance-regenerate)
    (let ((text (with-temp-buffer
                  (insert-file-contents (expand-file-name "MEMORY.md" mem))
                  (buffer-string))))
      (should (string-match-p "READ THIS FIRST" text))
      ;; Both tiny test notes trivially fit any real budget -- N and TOTAL
      ;; must both read 2, not a stale/hardcoded figure.
      (should (string-match-p "2 of 2 entries" text))
      (should (string-match-p "^- butler-a-rule\\.md — " text))
      (should (string-match-p "^- butler-b-rule\\.md — " text)))))

(ert-deftest cc-butler-governance/regenerate-replaces-a-stale-hand-banner ()
  "A previously hand-typed (or previously generated, now-stale) banner must
be replaced wholesale on the next regenerate -- never left standing beside
a fresh one, and never hand-patched in place."
  (cc-butler-governance-test--with-store
    (let ((index (expand-file-name "MEMORY.md" mem))
          (stale-banner "> **READ THIS FIRST — YOU ARE SEEING ~13% OF THIS INDEX.**\n> **73 of 577 entries reach your context.**\n\n"))
      (with-temp-file (expand-file-name "a-rule.md" store)
        (insert (cc-butler-governance--render "a-rule" "d" "body" "feedback")))
      (with-temp-file index
        (insert stale-banner "- butler-a-rule.md — d\n"))
      (cc-butler-governance-regenerate)
      (let ((text (with-temp-buffer (insert-file-contents index) (buffer-string))))
        (should-not (string-match-p "73 of 577" text))
        (should-not (string-match-p "~13%" text))
        (should (string-match-p "1 of 1 entries" text))
        (should (string-match-p "^- butler-a-rule\\.md — " text))))))

;;;; ------------------------------------------------------------------
;;;; Reintegration: sorting MEMORY.md's index by git commit-recency
;;;; (originally `fix/governance-index-sort-by-commit-recency' @ 983d067,
;;;; reintegrated here against the banner/80-byte-cap/curated-line
;;;; invariants that landed on main afterward). These three tests were
;;;; written and confirmed RED before any of that reintegration code
;;;; existed in this worktree.
;;;; ------------------------------------------------------------------

(defun cc-butler-governance-test--git-init (store)
  "Turn STORE into a git repo, discarding init chatter."
  (let ((default-directory store))
    (call-process "git" nil nil nil "init" "-q")))

(defun cc-butler-governance-test--commit-note (store slug content epoch)
  "Write STORE/SLUG.md with CONTENT and commit it at unix EPOCH, so
`cc-butler-governance--commit-recency-map' has a deterministic,
test-controlled timestamp to sort by regardless of wall-clock time or
host git config."
  (with-temp-file (expand-file-name (concat slug ".md") store) (insert content))
  (let* ((default-directory store)
         (process-environment
          (append (list (format "GIT_AUTHOR_DATE=@%d +0000" epoch)
                        (format "GIT_COMMITTER_DATE=@%d +0000" epoch)
                        "GIT_AUTHOR_NAME=cc-butler-test"
                        "GIT_AUTHOR_EMAIL=test@cc-butler.invalid"
                        "GIT_COMMITTER_NAME=cc-butler-test"
                        "GIT_COMMITTER_EMAIL=test@cc-butler.invalid")
                  process-environment)))
    (call-process "git" nil nil nil "add" (concat slug ".md"))
    (call-process "git" nil nil nil "commit" "-q" "-m" (concat "add " slug))))

(ert-deftest cc-butler-governance/regenerate-sorts-index-by-commit-recency-with-fresh-banner ()
  "Banner invariant: after a regenerate that sorts MEMORY.md's index by each
principle's latest git commit (newest first), the banner block must still
be the very first thing in the file, in the correct format, and its stated
N-of-TOTAL must equal `cc-butler-governance--entries-within-budget' run
fresh against the FINAL, post-sort content -- never a stale pre-sort
count. Three notes committed oldest to newest (note-a, note-b, note-c)
must come out newest-first."
  (cc-butler-governance-test--with-store
    (cc-butler-governance-test--git-init store)
    (cc-butler-governance-test--commit-note
     store "note-a" (cc-butler-governance--render "note-a" "d" "body" "feedback") 1000)
    (cc-butler-governance-test--commit-note
     store "note-b" (cc-butler-governance--render "note-b" "d" "body" "feedback") 2000)
    (cc-butler-governance-test--commit-note
     store "note-c" (cc-butler-governance--render "note-c" "d" "body" "feedback") 3000)
    (cc-butler-governance-regenerate)
    (let* ((index (expand-file-name "MEMORY.md" mem))
           (text (with-temp-buffer (insert-file-contents index) (buffer-string))))
      (should (string-match-p "\\`> \\*\\*READ THIS FIRST" text))
      (should (string-match-p "3 of 3 entries" text))
      (should (equal (cc-butler-governance--entries-within-budget text) 3))
      (let ((pos-a (string-match "butler-note-a\\.md" text))
            (pos-b (string-match "butler-note-b\\.md" text))
            (pos-c (string-match "butler-note-c\\.md" text)))
        (should (and pos-a pos-b pos-c))
        (should (< pos-c pos-b pos-a))))))

(ert-deftest cc-butler-governance/regenerate-shrunk-line-is-correctly-positioned-after-sort ()
  "80-byte-cap-survives-a-sort: a line long enough to need shrinking must come
out of `cc-butler-governance-regenerate' BOTH correctly shrunk (<=80
bytes) AND correctly positioned per the recency sort -- proof that
shrink's already-fixed output is what got sorted, not stale oversized
text repositioned unchanged. Seeded with the long-slug's oversized
pre-shrink line SECOND and a normal-length line FIRST, while committing
the long slug LATER (more recent) than the normal one -- so a test that
only checked size, or that coincidentally matched seed order, would not
catch a missing sort."
  (cc-butler-governance-test--with-store
    (let* ((slug "an-extremely-long-slug-name-that-mostly-fills-the-budget")
           (desc "This is a genuinely long description text used to verify the old flat truncation overflowed the eighty byte line cap in the legacy rendering path.")
           (old-truncated (cc-butler-governance--truncate-bytes
                           desc cc-butler-governance--generated-description-max-bytes))
           (old-line (cc-butler-governance--render-index-line slug old-truncated))
           (index (expand-file-name "MEMORY.md" mem)))
      (should (> (string-bytes old-line) cc-butler-governance-max-index-line-bytes))
      (cc-butler-governance-test--git-init store)
      ;; Seed order: short-note first, then the long slug's oversized line --
      ;; the OPPOSITE of the expected post-sort order below.
      (with-temp-file index (insert "- butler-short-note.md — d\n" old-line))
      (cc-butler-governance-test--commit-note
       store "short-note" (cc-butler-governance--render "short-note" "d" "body" "feedback") 1000)
      (cc-butler-governance-test--commit-note
       store slug (cc-butler-governance--render slug desc "body" "feedback") 2000)
      (cc-butler-governance-regenerate)
      (let ((text (with-temp-buffer (insert-file-contents index) (buffer-string))))
        (should-not (string-search old-line text))
        (with-temp-buffer
          (insert text)
          (goto-char (point-min))
          (should (re-search-forward
                   (concat "^- butler-" (regexp-quote slug) "\\.md.*$") nil t))
          (let* ((beg (match-beginning 0))
                 (end (min (point-max) (1+ (line-end-position))))
                 (full-line (buffer-substring-no-properties beg end)))
            (should (<= (string-bytes full-line) cc-butler-governance-max-index-line-bytes))))
        (let ((pos-long (string-match (concat "butler-" (regexp-quote slug) "\\.md") text))
              (pos-short (string-match "butler-short-note\\.md" text)))
          (should (and pos-long pos-short))
          ;; The long slug was committed MORE recently -- it must sort first,
          ;; even though it was seeded second.
          (should (< pos-long pos-short)))))))

(ert-deftest cc-butler-governance/regenerate-preserves-a-hand-curated-line-across-a-sort ()
  "Curated-line preservation invariant, interleaved case: a hand-authored
line the store does not own at all (a different bracket shape, no
`butler-' marker -- the same fixture
`cc-butler-governance/regenerate-index-merge-preserves-hand-written-lines'
already relies on) sits between two real store-generated lines. After a
recency sort, that curated line must survive verbatim -- present exactly
once, text untouched -- and never end up straddled by the sorted block
(the store's own generated lines never sit on both sides of a line the
store does not own, since the sorted block is reinserted as one
contiguous run)."
  (cc-butler-governance-test--with-store
    (let ((index (expand-file-name "MEMORY.md" mem))
          (curated "- [steward-only-note](steward-only-note.md) — hand-authored, no matching store file\n"))
      (cc-butler-governance-test--git-init store)
      (with-temp-file index
        (insert "- butler-note-a.md — d\n" curated "- butler-note-b.md — d\n"))
      (cc-butler-governance-test--commit-note
       store "note-a" (cc-butler-governance--render "note-a" "d" "body" "feedback") 1000)
      (cc-butler-governance-test--commit-note
       store "note-b" (cc-butler-governance--render "note-b" "d" "body" "feedback") 2000)
      (cc-butler-governance-regenerate)
      (let ((text (with-temp-buffer (insert-file-contents index) (buffer-string))))
        ;; present exactly once, byte-for-byte -- not duplicated, not deleted.
        (let ((count 0) (start 0))
          (while (string-match (regexp-quote curated) text start)
            (setq count (1+ count) start (match-end 0)))
          (should (= count 1)))
        ;; recency actually took effect: note-b (newer) now precedes note-a,
        ;; the opposite of how they were seeded.
        (let ((pos-a (string-match "butler-note-a\\.md" text))
              (pos-b (string-match "butler-note-b\\.md" text)))
          (should (and pos-a pos-b))
          (should (< pos-b pos-a)))
        ;; the curated line was never pulled into the sorted block: both
        ;; generated lines end up on the SAME side of it.
        (let ((curated-pos (string-match (regexp-quote curated) text))
              (pos-a (string-match "butler-note-a\\.md" text))
              (pos-b (string-match "butler-note-b\\.md" text)))
          (should (or (and (< pos-a curated-pos) (< pos-b curated-pos))
                      (and (> pos-a curated-pos) (> pos-b curated-pos)))))))))

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
;;;; Unconditional cap report line (2026-09-08 incident)
;;;;
;;;; regenerate_governance was called 4 times the night the store sat at
;;;; 566/250 notes and one note's body sat at 16.4KB/2KB -- every call
;;;; reported plain success. The direct-Write/Edit bypass path skips every
;;;; cap record_principle enforces, so only a report INSIDE regenerate_governance
;;;; itself can ever catch it. This is report-only: regenerate must never
;;;; refuse to run just because the store is over-cap.
;;;; ------------------------------------------------------------------

(ert-deftest cc-butler-governance/regenerate-tool-reports-real-cap-violations ()
  "REGRESSION this closes (2026-09-08): a store that already blew past both
caps (count and per-note body length) must have the OVER-cap facts, in real
numbers, in EVERY regenerate_governance report -- not just a generic success
message. Seeds a store genuinely over both caps."
  (cc-butler-governance-test--with-store
    (let ((cc-butler-governance-max-notes 250)
          (cc-butler-governance-max-note-bytes 2048))
      ;; count cap: 252 tiny notes, well past 250.
      (dotimes (i 252)
        (with-temp-file (expand-file-name (format "note-%d.md" i) store)
          (insert (cc-butler-governance--render
                   (format "note-%d" i) "d" "tiny body" "feedback"))))
      ;; body-length cap: one note with a body well past 2048 bytes.
      (with-temp-file (expand-file-name "the-big-one.md" store)
        (insert (cc-butler-governance--render
                 "the-big-one" "d" (make-string 16793 ?x) "feedback")))
      (let ((out (cc-butler-tool-regenerate-governance)))
        ;; real count, real cap
        (should (string-match-p "253" out))
        (should (string-match-p "250" out))
        ;; the ratio is over 1 and stated as an excess, not silence
        (should (string-match-p "초과" out))
        ;; the oversized-note count and the actual largest offender, named
        (should (string-match-p "1" out))
        (should (string-match-p "the-big-one" out))
        (should (string-match-p "16\\.4K" out))))))

(ert-deftest cc-butler-governance/regenerate-tool-reports-explicit-zero-violations ()
  "Positive control: a store safely under BOTH caps must still print the cap
line, explicitly saying zero violations -- silence here is indistinguishable
from the check never having run, which is exactly the ambiguity that let 4
straight silent successes through on 2026-09-08."
  (cc-butler-governance-test--with-store
    (let ((cc-butler-governance-max-notes 250)
          (cc-butler-governance-max-note-bytes 2048))
      (with-temp-file (expand-file-name "a-rule.md" store)
        (insert (cc-butler-governance--render "a-rule" "d" "small body" "feedback")))
      (let ((out (cc-butler-tool-regenerate-governance)))
        (should (string-match-p "1" out))
        (should (string-match-p "250" out))
        (should (string-match-p "이내" out))
        (should (string-match-p "0개" out))))))

(ert-deftest cc-butler-governance/cap-report-line-discloses-its-own-population ()
  "REGRESSION this closes: the cap report line's \"최대\" only ever scans the
top-level store .md files (README and roles/ excluded, user-layer never
merged in), but said nothing about that -- a reader could mistake it for a
store-wide max. README.md is itself over the body cap and invisible to the
counter; a roles/ file, bigger than the true top-level max, is invisible
too because the scan never recurses. Both must stay excluded (that
population is correct); the line must now say so."
  (cc-butler-governance-test--with-store
    (let ((cc-butler-governance-max-notes 250)
          (cc-butler-governance-max-note-bytes 2048))
      ;; a few small, unremarkable top-level notes.
      (dotimes (i 3)
        (with-temp-file (expand-file-name (format "small-note-%d.md" i) store)
          (insert (cc-butler-governance--render
                   (format "small-note-%d" i) "d" "tiny body" "feedback"))))
      ;; the one note that SHOULD be reported as the max: top-level, in scope.
      (with-temp-file (expand-file-name "top-level-biggest.md" store)
        (insert (cc-butler-governance--render
                 "top-level-biggest" "d" (make-string 3000 ?x) "feedback")))
      ;; README.md: over-cap itself, but excluded by name -- must never be "최대".
      (with-temp-file (expand-file-name "README.md" store)
        (insert (make-string 3000 ?y)))
      ;; roles/: a file bigger than top-level-biggest, but out of scope because
      ;; the scan doesn't recurse -- must never be "최대" either.
      (make-directory (expand-file-name "roles" store))
      (with-temp-file (expand-file-name "roles/steward-role-CLAUDE.md" store)
        (insert (cc-butler-governance--render
                 "steward-role-CLAUDE" "d" (make-string 5000 ?z) "feedback")))
      (let ((out (cc-butler-tool-regenerate-governance)))
        ;; positive control: the true top-level max is named.
        (should (string-match-p "top-level-biggest" out))
        ;; the bigger roles/ file must never be reported as the max -- distinct,
        ;; nameable failure if the population regresses to include roles/.
        (should-not (string-match-p "steward-role-CLAUDE" out))
        ;; the disclosure clause is present verbatim -- distinct, nameable
        ;; failure if only the format string regresses (population untouched).
        (should (string-match-p
                 (regexp-quote "[범위: 최상위 .md · README·roles/·사용자층 제외 · 바이트는 body 기준]")
                 out))))))
