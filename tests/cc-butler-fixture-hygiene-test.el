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
  '("bridge.py"
    "config.sh"
    "test_bridge.py")
  "Files exempt from the scan below. Stay short, and every entry needs a
reason on its own line here -- this is a DELIBERATE allowlist, not a
convenience: it turns off real-identifier detection for that file. Every
entry's justification is machine-checked, not just asserted in this comment
-- see `cc-butler-fixture-hygiene/every-exception-still-contains-a-violation':
if a file listed here ever goes genuinely clean, that test fails and NAMES
it, so an exception cannot quietly outlive the reason it was added for.

`bridge.py', `config.sh', `test_bridge.py': the Python side of the Matrix
bridge, tracked in #239, UNMEASURED -- whether these genuinely need a real
id (a structural constraint in Python-side protocol tests) or just inherited
one by convention has not been checked. Two `bridge.py' files exist:
`~/services/matrix-bridge/bridge.py' (the one actually running, PID
tracked separately, NOT this repo) and this repo's own copy under
`matrix-bridge/'. Only the repo copy is in scope for this scan or any
future redaction; the deployed one is out of scope entirely and must never
be touched by a fixture-hygiene change.

`matrix-bridge.el' and `tests/matrix-bridge-test.el' were exempt here until
2026-09-10, for hardcoded real Matrix identifiers in `matrix-bridge-self-
test' (the OTHER test surface this repo's CLAUDE.md names, \"there are two
test surfaces here\"), in the ERT suite's own fixtures, and in one
defvar's docstring `e.g.' example. Measured, not assumed, before removing
them: `matrix-bridge-attribution' (matrix-bridge.el) compares SENDER
against the `matrix-bridge-human-user-id'/`-self-user-id' *variables*,
then falls back to a plain `string-split' on the localpart -- there is no
lookup table anywhere that only recognizes real fleet ids, and
`@fake-self:example.org'-shaped values were already passing in #238/#240
before this change. So \"cannot be done with a fake id\" was true for the
Python side's unmeasured claim above, but false for the elisp side -- the
elisp identifiers were incidental (copied from a real example when the
tests were written), not structural. Every real literal in both files was
synthesized on that basis and both were removed from this list the same
commit -- see `matrix-bridge-self-test' and the `event-line-*'/`start-
refuses-*'/`deliver-*' tests below it in `tests/matrix-bridge-test.el' for
the synthetic replacements now in place.")

(defconst cc-butler-fixture-hygiene-test--shape-res
  (list (concat "![A-Za-z0-9_-]\\{10,\\}:"
                (regexp-quote cc-butler-fixture-hygiene-test--homeserver)) ; Matrix room id
        "\\$[A-Za-z0-9_-]\\{40,45\\}"                                      ; Matrix event id
        (concat "@[a-z0-9._=-]+:"
                (regexp-quote cc-butler-fixture-hygiene-test--homeserver))) ; Matrix mxid
  "Shapes real Matrix identifiers take in THIS fleet specifically -- the
room-id and mxid shapes require our actual homeserver name (see
`cc-butler-fixture-hygiene-test--homeserver').

The event-id shape is length-bounded to a 40-45 char window, measured
against 800 real event ids on this homeserver (butler-x600 plus two
`butlers' rooms, the most recent 400 from each): all 800 were exactly 43
characters, no other length appeared (min = max = 43). Room v4+ event ids
are `$' followed by a 32-byte SHA-256 digest, unpadded urlsafe-base64
encoded -- that is a FIXED 43-char width by construction, not a
coincidence of this sample. 800/800 identical would normally be reason to
suspect the measuring instrument rather than the thing measured, but here
the uniformity is exactly what the encoding predicts, so it is not a red
flag. The sample is one homeserver, though, so the honest claim is
\"event ids in OUR rooms are 43 chars\", not \"Matrix event ids are 43
chars\" generally -- widening that claim past what was actually measured
would just hand the next reader an unearned premise.

The bound stays 40-45, not tightened to the measured {43}: not because
older room versions need the slack (the homeserver anchor, not the
length, is what would catch those), but because a future spec change is
the actual risk, and the two kinds of error this bound trades off are not
symmetric -- missing a leaked event id defeats the whole point of this
check, silently and unrecoverably, while one false positive costs a
single triage and `$' followed by 40-45 base64-ish characters is already
a rare shape to hit by accident. A match is a VIOLATION unless it carries
its own \"this is fake\" marker -- see
`cc-butler-fixture-hygiene-test--safe-match-p'.")

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

(defun cc-butler-fixture-hygiene-test--exception-files ()
  "Absolute paths of every file in
`cc-butler-fixture-hygiene-test--file-exceptions', resolved against `git
ls-files' the same way `--repo-files' resolves its population -- so a
renamed, typo'd, or duplicated-basename exception entry shows up as a COUNT
mismatch (see `cc-butler-fixture-hygiene/every-exception-still-contains-a-
violation') instead of silently matching zero files and vanishing from both
scans at once."
  (let* ((default-directory cc-butler-fixture-hygiene-test--repo-root)
         (raw (split-string (shell-command-to-string "git ls-files") "\n" t))
         (abs (mapcar #'expand-file-name raw)))
    (seq-filter (lambda (f) (member (file-name-nondirectory f)
                                     cc-butler-fixture-hygiene-test--file-exceptions))
                abs)))

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
Loosening a shape or widening a marker to make this pass is not triage.

SCOPE: this check only sees identifier SHAPES -- a room id, event id, or
mxid matching the patterns above. It does not and cannot see shapeless
internal prose: the `cc-butler-decision.el:903' leak this docstring
names above contained no identifier substring at all, so no population
change here would ever have caught it; only manual redaction did. Do not
try to close that gap by adding word- or phrase-based detection to this
file -- that is exactly the self-defeating confession-word gate this
file's own history (above) already removed once. A prose leak needs a
human reader, not a wider regex."
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

(ert-deftest cc-butler-fixture-hygiene/every-exception-still-contains-a-violation ()
  "Each entry in `cc-butler-fixture-hygiene-test--file-exceptions' turns OFF
identifier scanning for that file -- so an exception that no longer needs to
exist (the file was cleaned up, or the identifier redacted some other way)
would sit there forever as a silent, permanent blind spot with a green light
next to it: the main scan test cannot ever notice, because it excludes
exactly these files from its population by design (2026-09-10: this is the
same shape as `an-upstream-list-walk-is-blind-to-what-is-not-on-the-list' --
a control that cannot fail is not a control).

Disabling is worse than deleting: deleting a check leaves a visible gap
someone can notice; disabling it via a stale exception leaves a green light
nobody looks at twice. So this test inverts the exclusion -- it scans ONLY
the exception files, with the exact same shape+safe-match-p logic the main
check uses -- and requires every one of them to still contain at least one
real violation right now. The moment one goes clean, this fails, NAMING that
file, and the fix is to remove its entry from the list, not to keep the
now-unjustified exception around."
  (let ((files (cc-butler-fixture-hygiene-test--exception-files)))
    ;; A renamed/typo'd/duplicate-basename entry would otherwise resolve to
    ;; fewer files than entries and silently vanish from the scan below.
    (should (equal (length files)
                   (length cc-butler-fixture-hygiene-test--file-exceptions)))
    (let (clean)
      (dolist (file files)
        (unless (cc-butler-fixture-hygiene-test--violation-lines file)
          (push (file-relative-name file cc-butler-fixture-hygiene-test--repo-root)
                clean)))
      (should (equal clean nil)))))

(provide 'cc-butler-fixture-hygiene-test)
;;; cc-butler-fixture-hygiene-test.el ends here
