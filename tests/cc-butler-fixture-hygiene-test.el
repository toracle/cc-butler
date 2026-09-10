;;; cc-butler-fixture-hygiene-test.el --- guard against real content leaking into the repo  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jeongsoo Park
;; SPDX-License-Identifier: MIT

;; Run alone:
;;   emacs -Q --batch -L . -l ert -l tests/cc-butler-fixture-hygiene-test.el \
;;         -f ert-run-tests-batch-and-exit

;; Scans every git-tracked file in the repo, unconditionally, for real-looking
;; Matrix identifiers -- NOT gated on a fixture's docstring admitting it
;; reproduces something real ("verbatim", "copied from", "actually observed").
;; An earlier version of this file WAS gated that way, and gating on words
;; broke twice on the same axis before this version existed:
;;
;;   1. redacting a fixture's docstring can delete the trigger words along
;;      with the real values, silently unhooking the check from the very
;;      fixture it exists to keep watching (2026-09-10, caught by mutation);
;;   2. the real leak this file exists to catch a second instance of
;;      (cc-butler-decision.el:903, a genuine internal-process quote) was not
;;      even inside an `ert-deftest' block -- the population this file
;;      scanned was too narrow no matter what gated entry into it.
;;
;; Authors should still note in a docstring when a fixture reproduces an
;; actually-observed real shape -- that habit is worth keeping as a hint for
;; the next human reader -- but this file no longer depends on that note to
;; decide what to scan. It scans everything, always.

(require 'ert)
(require 'seq)

(defconst cc-butler-fixture-hygiene-test--dir
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Directory holding this file, i.e. `tests/'. Captured HERE, at top level,
because `load-file-name' is only bound during THIS file's own load -- by
the time an `ert-deftest' body below actually runs (batched, after every
test file has finished loading), it is nil again and `default-directory'
would silently resolve to the repo root instead, making a directory scan
find nothing and the check pass vacuously. (Caught by running this file's
own positive control before redacting anything: it should have failed
against known-real content and instead passed.) Same pattern `cc-butler--
dir' uses in cc-butler.el, for the same reason.")

(defconst cc-butler-fixture-hygiene-test--repo-root
  (file-name-directory (directory-file-name cc-butler-fixture-hygiene-test--dir))
  "The repo root, one level up from `tests/'.")

(defconst cc-butler-fixture-hygiene-test--homeserver "warmblood-lounge"
  "This fleet's real Matrix homeserver name. Required as the domain segment
of the room-id and mxid shapes below, on purpose: an unqualified `!...:...'
or `@...:...' pattern with no real homeserver behind it also matches an
unrelated SSH URL (`git@github.com:...') or an unrelated public repo's own
placeholder room id -- both measured as actual false positives (2026-09-10,
steward's own shape scan across 63 public repos) before this constant was
added. Requiring OUR homeserver name turns a generic shape into a specific
one, at the cost of missing a leak that used some OTHER homeserver -- the
tradeoff steward's measurement showed is worth it.")

(defconst cc-butler-fixture-hygiene-test--file-exceptions
  '("matrix-bridge.el"
    "matrix-bridge-test.el"
    "bridge.py"
    "config.sh"
    "test_bridge.py")
  "Files exempt from the scan below. Stay short, and every entry needs a
reason on its own line here -- this is a DELIBERATE allowlist, not a
convenience: it turns off real-identifier detection for that file.

All five entries are the SAME already-known, already out-of-scope issue:
the Matrix bridge's own human/fleet identifiers
(`matrix-bridge-human-user-id', `matrix-bridge-self-user-id', and their
`warmblood-lounge'-homeserver values) are deliberately hardcoded, in both
the bridge's production defaults and its own protocol-level tests, because
the bridge cannot identify \"the human\" or \"itself\" on Matrix without
them. Fixing THAT is a separate, already-scoped, already-coordinated-with-
the-butler change (it touches the live human-facing channel, so it cannot
be done as a side effect of a fixture-hygiene PR). This file's job is to
catch a NEW leak riding along with something else, not to re-flag a known,
tracked one every time the suite runs.")

(defconst cc-butler-fixture-hygiene-test--shape-res
  (list (concat "![A-Za-z0-9_-]\\{10,\\}:"
                (regexp-quote cc-butler-fixture-hygiene-test--homeserver)) ; Matrix room id
        "\\$[A-Za-z0-9_-]\\{40,45\\}"                                      ; Matrix event id
        (concat "@[a-z0-9._=-]+:"
                (regexp-quote cc-butler-fixture-hygiene-test--homeserver))) ; Matrix mxid
  "Shapes real Matrix identifiers take in THIS fleet specifically -- the
room-id and mxid shapes require our actual homeserver name (see
`cc-butler-fixture-hygiene-test--homeserver'); the event-id shape is
length-bounded to the 40-45 char window real Matrix event ids in this
fleet actually fall in, not an open-ended \"20 or more\" (an earlier,
looser version of these shapes was never actually run against real event
ids to check the bound was tight; steward's own measurement supplied
40-45). A match is a VIOLATION unless it carries its own \"this is fake\"
marker -- see `cc-butler-fixture-hygiene-test--safe-match-p'.")

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

(defun cc-butler-fixture-hygiene-test--repo-files ()
  "Every git-tracked file in the repo, as absolute paths, minus this file's
own exceptions list. Uses `git ls-files' rather than a hand-maintained
extension list or directory walk on purpose: a list of \"which file types
to scan\" is exactly the same shape of blind spot this fleet already hit
today in a different check (`cc-butler--modules', a hand-maintained module
list a real file sat outside of for weeks) -- the git index IS the census,
not a copy of it that can drift."
  (let* ((default-directory cc-butler-fixture-hygiene-test--repo-root)
         (raw (split-string (shell-command-to-string "git ls-files") "\n" t)))
    (seq-remove (lambda (f) (member (file-name-nondirectory f)
                                     cc-butler-fixture-hygiene-test--file-exceptions))
                (mapcar #'expand-file-name raw))))

(defun cc-butler-fixture-hygiene-test--binary-p (file)
  "Non-nil when FILE looks binary (contains a NUL byte in its first 4KB) --
skipped rather than scanned, since a shape match inside a PNG is noise, not
signal, and `insert-file-contents' on a large binary is wasted work."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file nil 0 4096)
    (string-match-p "\0" (buffer-string))))

(defun cc-butler-fixture-hygiene-test--violation-lines (file)
  "Line numbers in FILE containing an identifier-shaped match that is not
self-evidently safe. Returns line numbers, never the matched text -- this
scanner's own assertion failures must not become a second leak surface in
a public repo's CI log."
  (with-temp-buffer
    (insert-file-contents file)
    (let (lines)
      (dolist (re cc-butler-fixture-hygiene-test--shape-res)
        (goto-char (point-min))
        (while (re-search-forward re nil t)
          (unless (cc-butler-fixture-hygiene-test--safe-match-p (match-string 0))
            (push (line-number-at-pos (match-beginning 0)) lines))))
      (delete-dups (sort lines #'<)))))

(ert-deftest cc-butler-fixture-hygiene/no-real-matrix-identifiers-in-repo-tree ()
  "REGRESSION GUARD (2026-09-10): a real Matrix room id, event id, and
escalation text sat in `tests/cc-butler-decision-test.el' for a day, in
this PUBLIC repo, self-reported by its own docstring ('copied verbatim
from ...') -- an admission nobody read as a signal because it read as
diligence about fixture fidelity. A second, independent real leak (the
same internal-process line, quoted as a boilerplate example in
`cc-butler-decision.el's own production docstring) sat OUTSIDE any
`ert-deftest' block entirely, in the very same review.

Both gaps are closed the same way: this check has no gate and no
population narrower than the whole repo. It does not look for a
docstring admitting a fixture is real, and it does not confine itself to
test files or to `ert-deftest' bodies -- it scans every git-tracked file
unconditionally for identifier shapes that require this fleet's actual
homeserver name (or, for event ids, this fleet's actual id-length
window), and treats a match as a violation unless it is self-evidently
synthetic (see `cc-butler-fixture-hygiene-test--safe-match-p').

Widening the population WILL surface new hits over time as the repo
grows -- that is not this check being noisy, it is things becoming
visible that a narrower check could never have seen. Triage each one:
redact a genuine leak to a synthetic value, or add a reasoned, anchored
entry to `cc-butler-fixture-hygiene-test--file-exceptions' /
`cc-butler-fixture-hygiene-test--safe-match-p' for something legitimate.
Loosening a shape or widening a marker to make this pass is not triage."
  (let ((files (cc-butler-fixture-hygiene-test--repo-files)))
    ;; Sanity guard: if `git ls-files' ever failed or returned nothing (wrong
    ;; cwd, git missing, a shallow/detached checkout), the scan below would
    ;; run against an empty file list and pass vacuously -- exactly the kind
    ;; of silent, undetectable absence this whole file exists to avoid
    ;; elsewhere. A known-always-present file proves the population is real.
    (should (member (expand-file-name "cc-butler.el" cc-butler-fixture-hygiene-test--repo-root)
                     files))
    (let (violations)
      (dolist (file files)
        (unless (cc-butler-fixture-hygiene-test--binary-p file)
          (let ((lines (cc-butler-fixture-hygiene-test--violation-lines file)))
            (when lines
              (push (list :file (file-relative-name file cc-butler-fixture-hygiene-test--repo-root)
                          :lines lines)
                    violations)))))
      (should (equal violations nil)))))

(provide 'cc-butler-fixture-hygiene-test)
;;; cc-butler-fixture-hygiene-test.el ends here
