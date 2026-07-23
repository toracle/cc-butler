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

(provide 'cc-butler-governance-test)
;;; cc-butler-governance-test.el ends here
