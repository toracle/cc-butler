;;; cc-butler-statusline-test.el --- tests for the statusLine helper script  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jeongsoo Park
;; SPDX-License-Identifier: MIT

;; The CTX:<n> marker is the only channel `cc-butler-cleanup-context-for' has
;; onto a session's real token usage, and its own TTL cache is explicitly
;; designed to treat "no reading yet" as "keep the last-known value" rather
;; than as zero (cc-butler-cleanup.el).  That design is defeated if the
;; SCRIPT itself already collapsed "no data" into a literal CTX:0 before the
;; marker ever reaches Emacs — which is exactly what shipped: both the
;; python3 and jq branches used a `// 0'-shaped fallback, so a session with
;; no context_window data at all printed the identical marker as a session
;; genuinely idle at zero tokens.  These tests drive the real script as a
;; subprocess (it is a shell script, not Elisp) and assert the two cases
;; produce DIFFERENT markers.

(require 'ert)

(defconst cc-butler-statusline-test--script
  (expand-file-name "../statusline/cc-butler-statusline.sh"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Path to the statusLine helper under test.")

(defun cc-butler-statusline-test--run (json &optional path)
  "Run the statusline script with JSON on stdin, PATH restricted if given.
Returns stdout as a string.  PATH lets a case force the jq fallback branch by
excluding python3 from the search path."
  (with-temp-buffer
    (let ((process-environment
           (if path
               (cons (concat "PATH=" path) process-environment)
             process-environment)))
      (call-process-region json nil "sh" nil t nil cc-butler-statusline-test--script))
    (buffer-string)))

;; A directory holding ONLY a jq symlink (and /bin, for `sh' itself and
;; coreutils) — homebrew's bin holds both jq AND python3, so merely omitting
;; python3's own directory does not exclude it.
(defconst cc-butler-statusline-test--jq-only-path
  (let* ((jq (executable-find "jq"))
         (dir (and jq (make-temp-file "cc-statusline-jq-only" t))))
    (when jq
      (make-symbolic-link jq (expand-file-name "jq" dir))
      (concat dir ":/bin"))))

(ert-deftest cc-butler-statusline/no-data-is-not-zero--python3 ()
  "No `context_window' at all must print CTX:? — not CTX:0, which is
indistinguishable from a session genuinely idle at zero tokens."
  (skip-unless (executable-find "python3"))
  (let ((out (cc-butler-statusline-test--run "{\"model\":{\"display_name\":\"Sonnet 5\"}}")))
    (should (string-match-p "\\`CTX:?" out))
    (should (string-match-p "CTX:\\?" out))
    (should-not (string-match-p "CTX:0" out))))

(ert-deftest cc-butler-statusline/real-zero-still-reads-as-zero--python3 ()
  "A session that DID report total_input_tokens: 0 must still show CTX:0 —
the fix distinguishes \"no reading\" from \"read a zero\", it must not turn
every real zero into a `?' too."
  (skip-unless (executable-find "python3"))
  (let ((out (cc-butler-statusline-test--run
              "{\"context_window\":{\"total_input_tokens\":0},\"model\":{\"display_name\":\"S\"}}")))
    (should (string-match-p "CTX:0\\(?:[ \t]\\|$\\)" out))))

(ert-deftest cc-butler-statusline/current-usage-fallback-still-works--python3 ()
  "When total_input_tokens is absent but current_usage has real numeric
fields, the fallback sum is still used (this already worked; guards against
the fix accidentally disabling it)."
  (skip-unless (executable-find "python3"))
  (let ((out (cc-butler-statusline-test--run
              "{\"context_window\":{\"current_usage\":{\"input_tokens\":500,\"cache_read_input_tokens\":200}},\"model\":{\"display_name\":\"S\"}}")))
    (should (string-match-p "CTX:700\\(?:[ \t]\\|$\\)" out))))

(ert-deftest cc-butler-statusline/no-data-is-not-zero--jq ()
  "Same guarantee as the python3 test, forced onto the jq fallback branch."
  (skip-unless cc-butler-statusline-test--jq-only-path)
  (let ((out (cc-butler-statusline-test--run
              "{\"model\":{\"display_name\":\"Sonnet 5\"}}"
              cc-butler-statusline-test--jq-only-path)))
    (should (string-match-p "CTX:\\?" out))
    (should-not (string-match-p "CTX:0" out))))

(ert-deftest cc-butler-statusline/real-zero-still-reads-as-zero--jq ()
  "jq branch: a genuine zero reading is not turned into `?' either."
  (skip-unless cc-butler-statusline-test--jq-only-path)
  (let ((out (cc-butler-statusline-test--run
              "{\"context_window\":{\"total_input_tokens\":0},\"model\":{\"display_name\":\"S\"}}"
              cc-butler-statusline-test--jq-only-path)))
    (should (string-match-p "CTX:0\\(?:[ \t]\\|$\\)" out))))

(provide 'cc-butler-statusline-test)
;;; cc-butler-statusline-test.el ends here
