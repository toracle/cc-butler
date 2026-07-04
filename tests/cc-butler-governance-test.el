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

(provide 'cc-butler-governance-test)
;;; cc-butler-governance-test.el ends here
