;;; cc-butler-workspace-test.el --- tests for project templates  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jeongsoo Park
;; SPDX-License-Identifier: MIT

(require 'ert)
(require 'cc-butler-workspace)

(ert-deftest cc-butler-workspace/define-template-registers ()
  "The package ships NO templates; cc-butler-define-project-template registers
one into the registry, retrievable by name (users add their own in private
config — no real repos are hard-coded in the package)."
  (let ((cc-butler-project-templates nil))
    (should (null (cc-butler--template 'anything)))   ; empty by default
    (cc-butler-define-project-template testproj
      :base-dir "~/x" :dir-format "testproj-%s"
      :repos ("git@github.com:me/testproj.git")
      :claude-import ("testproj/CLAUDE.md"))
    (let ((tpl (cc-butler--template 'testproj)))
      (should tpl)
      (should (equal (plist-get tpl :dir-format) "testproj-%s"))
      (should (equal (plist-get tpl :repos) '("git@github.com:me/testproj.git"))))))

(provide 'cc-butler-workspace-test)
;;; cc-butler-workspace-test.el ends here
