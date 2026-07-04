;;; cc-butler-provenance-test.el --- tests for the provenance layer  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jeongsoo Park
;; SPDX-License-Identifier: MIT

(require 'ert)
(require 'cc-butler-provenance)

(ert-deftest cc-butler-provenance/enrich-inline-when-short ()
  "A short verbatim is attached INLINE (progressive disclosure, no re-summarize)."
  (let* ((cc-butler-provenance-inline-max 100)
         (s (cc-butler-provenance-enrich "do X" "d1" "use Stripe")))
    (should (string-match-p "ref=d1" s))
    (should (string-match-p "verbatim" s))
    (should (string-match-p "use Stripe" s))))

(ert-deftest cc-butler-provenance/enrich-link-when-long ()
  "A long verbatim becomes a RESOLVABLE link, not re-summarized into the digest."
  (let* ((cc-butler-provenance-inline-max 5)
         (s (cc-butler-provenance-enrich "do X" "d1" "this is a very long verbatim answer")))
    (should (string-match-p "resolve_reference(d1)" s))
    (should-not (string-match-p "this is a very long" s))))

(ert-deftest cc-butler-provenance/resolve-returns-verbatim ()
  "Resolving a reference returns the VERBATIM original document (worker-open);
an unknown ref returns nil / a clear not-found."
  (let ((cc-butler-decision-dir (make-temp-file "cc-prov" t)))
    (unwind-protect
        (progn
          (let ((f (expand-file-name "d1.org" (cc-butler--decision-done-dir))))
            (with-temp-file f (insert "#+TITLE: Decision\n정수님 verbatim: use Stripe, sandbox first.\n")))
          (let ((v (cc-butler-provenance-resolve "d1")))
            (should v)
            (should (string-match-p "use Stripe, sandbox first" v)))
          (should-not (cc-butler-provenance-resolve "nope"))
          (should (string-match-p "No verbatim" (cc-butler-tool-resolve-reference "nope"))))
      (delete-directory cc-butler-decision-dir t))))

(provide 'cc-butler-provenance-test)
;;; cc-butler-provenance-test.el ends here
