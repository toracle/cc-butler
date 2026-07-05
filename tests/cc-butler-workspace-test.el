;;; cc-butler-workspace-test.el --- tests for project templates  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jeongsoo Park
;; SPDX-License-Identifier: MIT

(require 'ert)
(require 'cl-lib)
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

;;;; ------------------------------------------------------------------
;;;; Teardown safety: never delete a dir cc-butler did not scaffold
;;;; ------------------------------------------------------------------

(defun cc-butler-workspace-test--scaffold-dir ()
  "Make a temp dir shaped like a cc-butler-scaffolded topic and return it.
Wrapper dir with the scaffold marker + generated CLAUDE.md at the root and a
cloned repo living in a SUBDIR (its `.git' is under the subdir, NOT the root)."
  (let* ((base (make-temp-file "cc-scaffold" t))
         ;; Nest one level deeper so the path clears the >=3-component backstop
         ;; (temp dirs live directly under /tmp, which is only two components).
         (topic (file-name-as-directory (expand-file-name "myproject-x" base)))
         (marker (expand-file-name cc-butler-project-marker topic))
         (claude (expand-file-name "CLAUDE.md" topic))
         (repo   (file-name-as-directory (expand-file-name "app" topic))))
    (make-directory topic t)
    (write-region "" nil marker nil 'silent)
    (write-region "# topic workspace\n" nil claude nil 'silent)
    (make-directory (expand-file-name ".git" repo) t) ; repo in a SUBDIR
    topic))

(defun cc-butler-workspace-test--existing-project-dir (&optional gitlink)
  "Make a temp dir shaped like an EXISTING project (root is a git tree).
When GITLINK is non-nil the root `.git' is a FILE (worktree/submodule) rather
than a directory.  Also seed the scaffold marker to prove the root-`.git'
refusal wins even when a stray marker is present."
  (let* ((proj (file-name-as-directory (make-temp-file "cc-existing" t)))
         (git  (expand-file-name ".git" proj)))
    (if gitlink
        (write-region "gitdir: /elsewhere\n" nil git nil 'silent)
      (make-directory git t))
    ;; a real project's contents + a stray marker (must not rescue it):
    (write-region "" nil (expand-file-name cc-butler-project-marker proj) nil 'silent)
    (write-region "# arch\n" nil (expand-file-name "ARCHITECTURE.md" proj) nil 'silent)
    proj))

(ert-deftest cc-butler-workspace/deletable-accepts-scaffolded-topic ()
  "A scaffolded-topic-shaped dir (marker at root, repo in a subdir, NO root
`.git') is deletable."
  (let ((topic (cc-butler-workspace-test--scaffold-dir)))
    (unwind-protect
        (should (cc-butler--close-topic-deletable-p topic))
      (delete-directory topic t))))

(ert-deftest cc-butler-workspace/deletable-refuses-existing-project ()
  "An existing project (root IS a git working tree) is REFUSED — even with a
stray scaffold marker present — so teardown can never destroy the user's repo.
Both a `.git' directory and a `.git' gitlink file are refused."
  (dolist (gitlink '(nil t))
    (let ((proj (cc-butler-workspace-test--existing-project-dir gitlink)))
      (unwind-protect
          (should-not (cc-butler--close-topic-deletable-p proj))
        (delete-directory proj t)))))

(ert-deftest cc-butler-workspace/deletable-refuses-unscaffolded-dir ()
  "A directory with no scaffold marker (an arbitrary session dir cc-butler did
not lay out) is REFUSED even though it has no root `.git' — the positive
allowlist requires cc-butler's own marker."
  (let ((plain (file-name-as-directory (make-temp-file "cc-plain" t))))
    (unwind-protect
        (should-not (cc-butler--close-topic-deletable-p plain))
      (delete-directory plain t))))

(ert-deftest cc-butler-workspace/deletable-keeps-shallow-and-home-guards ()
  "The pre-existing backstops still hold: home, root, .emacs.d, and shallow
paths are refused regardless of markers."
  (should-not (cc-butler--close-topic-deletable-p "~"))
  (should-not (cc-butler--close-topic-deletable-p "~/.emacs.d"))
  (should-not (cc-butler--close-topic-deletable-p "/"))
  (should-not (cc-butler--close-topic-deletable-p "/home"))
  (should-not (cc-butler--close-topic-deletable-p "/tmp")))

(ert-deftest cc-butler-workspace/teardown-refuses-existing-project ()
  "The shared teardown tail REFUSES to delete an existing project: the dir
survives and the note explains why (no session buffers exist for the temp dir,
so the kill step is a no-op)."
  (let ((proj (cc-butler-workspace-test--existing-project-dir)))
    (unwind-protect
        (cl-letf (((symbol-function 'cc-butler--close-topic-kill-session)
                   (lambda (&rest _) nil))
                  ((symbol-function 'cc-butler--close-topic-audit)
                   (lambda (&rest _) nil)))  ; clean git — audit must NOT rescue
          (let ((res (cc-butler--teardown-workspace proj proj)))
            (should-not (plist-get res :deleted))
            (should (file-directory-p proj))          ; the user's repo survives
            (should (string-match-p "not a cc-butler-scaffolded topic"
                                    (plist-get res :note)))))
      (when (file-directory-p proj) (delete-directory proj t)))))

(provide 'cc-butler-workspace-test)
;;; cc-butler-workspace-test.el ends here
