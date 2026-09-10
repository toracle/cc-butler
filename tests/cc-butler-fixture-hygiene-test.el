;;; cc-butler-fixture-hygiene-test.el --- guard against real content leaking into fixtures  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jeongsoo Park
;; SPDX-License-Identifier: MIT

;; Run alone:
;;   emacs -Q --batch -L . -l ert -l tests/cc-butler-fixture-hygiene-test.el \
;;         -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'cl-lib)

(defconst cc-butler-fixture-hygiene-test--dir
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Directory holding this file, i.e. `tests/'. Captured HERE, at top level,
because `load-file-name' is only bound during THIS file's own load -- by
the time an `ert-deftest' body below actually runs (batched, after every
test file has finished loading), it is nil again and `default-directory'
would silently resolve to the repo root instead, making the directory
scan below find nothing and the check pass vacuously. (Caught by running
this file's own positive control before redacting anything: it should
have failed against known-real content and instead passed.) Same pattern
`cc-butler--dir' uses in cc-butler.el, for the same reason.")

(defconst cc-butler-fixture-hygiene-test--confession-words
  '("verbatim" "copied from" "real-shaped" "actually observed")
  "Words a fixture's own docstring uses to self-report that it reproduces
something real (2026-09-10: `tests/cc-butler-decision-test.el' carried two
fixtures literally copied from a real escalation -- real Matrix room id,
event id, and escalation text, sitting in this PUBLIC repo -- and these
exact words were the tell nobody read as a signal; they read as diligence
about fixture fidelity, not as a warning). Any `ert-deftest' block whose
text contains one of these, case-insensitively, gets scanned below for
identifier shapes.

\"actually observed\" is here on purpose, not just the three words that
described the ORIGINAL leak: the fix for those two fixtures keeps noting
that they reproduce a really-observed shape (steward's own instruction --
that provenance note is a good habit, worth keeping) while dropping the
real values. Losing the trigger phrase along with the real values would
have unhooked this check from the very fixtures it exists to keep
watching, forever, silently -- caught by testing that a redacted fixture
mutated back toward a real-looking shape still fails this check, and
finding it did not, because the redaction had also deleted every word
this list originally looked for.")

(defconst cc-butler-fixture-hygiene-test--shape-res
  (list "!\\([A-Za-z0-9_-]+\\):\\([A-Za-z0-9._-]+\\)"    ; Matrix room id
        "\\$[A-Za-z0-9_-]\\{20,\\}"                       ; Matrix event id
        "@[A-Za-z0-9_.-]+:[A-Za-z0-9._-]+"                ; Matrix mxid
        "\\b[A-Za-z0-9+/_]\\{43,\\}\\b")                  ; bare 43+-char base64-ish token
  "Shapes real Matrix identifiers take. A match is a VIOLATION unless it
carries its own \"this is fake\" marker -- see
`cc-butler-fixture-hygiene-test--safe-match-p'. The 4th rule's charset
deliberately excludes `-' (unlike the other three): this codebase's own
Lisp identifiers are long and hyphen-separated (`cc-butler-self-check--
queue-room-thread-activity-one' is 54 chars), and a bare-token rule that
allowed `-' would flag ordinary code, not leaks. Matrix event ids in this
fleet use `_', never `-', so nothing real is lost by excluding it here.")

(defun cc-butler-fixture-hygiene-test--safe-match-p (str)
  "Non-nil when STR (an identifier-shaped match) is self-evidently synthetic:
it contains the literal, UPPERCASE marker \"EXAMPLE\", or its domain segment
-- for the room-id/mxid shapes, always everything after the LAST `:' -- is
one of the IANA-reserved example domains (RFC 2606: `example.com'/`.org'/
`.net'/`.invalid') that can never resolve to anything real.

Two things this got wrong before, both caught by mutating a redacted
fixture back into a shape that must NOT read as safe, and confirming this
function still (wrongly) called it safe:

1. The domain check must be anchored to `:example\\.' + end-of-string, not
   a bare substring search -- an earlier version matched \"example.org\"
   as a SUBSTRING of \"notreallyexample.org\", a domain that is not
   reserved at all.
2. `string-match-p' respects `case-fold-search', which defaults to
   non-nil (case-INsensitive) -- an earlier version of the \"EXAMPLE\"
   check therefore matched the ordinary lowercase word \"example\"
   anywhere in STR, not only the deliberate uppercase marker. Both checks
   below bind `case-fold-search' to nil for exactly this reason."
  (let ((case-fold-search nil))
    (or (string-match-p "EXAMPLE" str)
        (string-match-p ":example\\.\\(com\\|org\\|net\\|invalid\\)\\'" str))))

(defun cc-butler-fixture-hygiene-test--violations-in (text)
  "Identifier-shaped substrings of TEXT that are not self-evidently safe.
Returns the actual matched strings -- callers must never surface them
as-is (the test below keeps only a count): this scanner's own assertion
failures must not become a second leak surface in a public repo's CI log."
  (let (hits)
    (dolist (re cc-butler-fixture-hygiene-test--shape-res)
      (let ((start 0))
        (while (string-match re text start)
          (let ((m (match-string 0 text)))
            (unless (cc-butler-fixture-hygiene-test--safe-match-p m)
              (push m hits)))
          (setq start (match-end 0)))))
    (delete-dups hits)))

(defun cc-butler-fixture-hygiene-test--deftest-chunks (file)
  "Alist of (TEST-NAME . TEXT), one entry per top-level `ert-deftest' form in
FILE. TEXT runs from that form's own start to the next top-level
`ert-deftest' (or EOF) -- a plain text split, not a reader; good enough for
a substring-shape scan, and simple enough to trust."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (let (names starts)
      (while (re-search-forward "^(ert-deftest \\([^ \t\n]+\\)" nil t)
        (push (match-string 1) names)
        (push (line-beginning-position) starts))
      (setq names (nreverse names) starts (nreverse starts))
      (let ((ends (append (cdr starts) (list (point-max)))))
        (cl-mapcar (lambda (name start end)
                     (cons name (buffer-substring-no-properties start end)))
                   names starts ends)))))

(ert-deftest cc-butler-fixture-hygiene/self-confessed-fixtures-carry-no-real-identifiers ()
  "REGRESSION GUARD (2026-09-10): a fixture whose OWN docstring says it
reproduces something real (\"verbatim\", \"copied from\", \"real-shaped\") is
the author admitting real material is in there. That admission reads as
diligence about fidelity, not as a warning, so nobody treats it as a
signal -- exactly what happened to two fixtures in
`tests/cc-butler-decision-test.el' that carried a real Matrix room id,
event id, and escalation text in this PUBLIC repo (fixed the same day this
test was added). This promotes the confession itself into a check: any
such fixture may only carry self-evidently-synthetic identifier-shaped
strings (an `EXAMPLE' marker, or a reserved `example.{com,org,net,
invalid}' domain) -- never a real-looking Matrix room id / event id / mxid
/ bare 43+-char token.

Deliberately reports only :file / :test / :shapes-found (a count) on
failure, never the matched strings -- this check's own failure output
must not become a second leak surface."
  (let* ((files (directory-files cc-butler-fixture-hygiene-test--dir t "-test\\.el\\'"))
         (violations nil))
    (dolist (file files)
      (dolist (chunk (cc-butler-fixture-hygiene-test--deftest-chunks file))
        (let* ((name (car chunk))
               (text (cdr chunk))
               (text-lower (downcase text)))
          (when (cl-some (lambda (w) (string-match-p (regexp-quote w) text-lower))
                          cc-butler-fixture-hygiene-test--confession-words)
            (let ((hits (cc-butler-fixture-hygiene-test--violations-in text)))
              (when hits
                (push (list :file (file-name-nondirectory file)
                            :test name
                            :shapes-found (length hits))
                      violations)))))))
    (should (equal violations nil))))

(provide 'cc-butler-fixture-hygiene-test)
;;; cc-butler-fixture-hygiene-test.el ends here
