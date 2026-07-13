;;; cc-butler-workspace-test.el --- tests for project templates  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jeongsoo Park
;; SPDX-License-Identifier: MIT

(require 'ert)
(require 'cl-lib)
(require 'cc-butler-workspace)

(ert-deftest cc-butler-workspace/define-template-registers ()
  "cc-butler-define-project-template registers a template into the registry,
retrievable by name (users add their own in private config — no real
org-specific repos are hard-coded in the package; see the built-in-default
tests below for the one exception, which is itself repo-free)."
  (let ((cc-butler-project-templates nil))
    (should (null (cc-butler--template 'anything)))   ; empty when isolated
    (cc-butler-define-project-template testproj
      :base-dir "~/x" :dir-format "testproj-%s"
      :repos ("git@github.com:me/testproj.git")
      :claude-import ("testproj/CLAUDE.md"))
    (let ((tpl (cc-butler--template 'testproj)))
      (should tpl)
      (should (equal (plist-get tpl :dir-format) "testproj-%s"))
      (should (equal (plist-get tpl :repos) '("git@github.com:me/testproj.git"))))))

;;;; ------------------------------------------------------------------
;;;; The built-in `default' template: repo-free, ships with the package
;;;; ------------------------------------------------------------------

(ert-deftest cc-butler-workspace/built-in-default-template-is-repo-free ()
  "The package ships exactly one built-in template, `default' — repo-free
(:repos nil), so no org-specific repository is hard-coded in the package
itself, while still giving a fresh install a real template besides
`arbitrary'.  Checks the REAL global registry (not isolated), since this is
about what ships, not what a test defines."
  (let ((tpl (cc-butler--template 'default)))
    (should tpl)
    (should (null (plist-get tpl :repos)))
    (should (stringp (plist-get tpl :base-dir)))
    (should (stringp (plist-get tpl :dir-format)))))

(ert-deftest cc-butler-workspace/new-topic-repo-free-template-does-not-error ()
  "A repo-free template (like the built-in `default') must not crash computing
the prior-clone check — `(car nil)' into `cc-butler--repo-local-name' errored
before this fix.  It should scaffold directly, no clone attempted."
  (let ((cc-butler-project-templates nil)
        (base (make-temp-file "cc-newtopic" t))
        finished-dir)
    (setf (alist-get 'blanktest cc-butler-project-templates)
          (list :base-dir base :dir-format "%s" :repos nil :claude-import nil))
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "blanktest"))
              ((symbol-function 'read-string) (lambda (&rest _) "mytopic"))
              ((symbol-function 'cc-butler--finish-topic)
               (lambda (topic-dir _template) (setq finished-dir topic-dir))))
      (cc-butler-new-topic))
    (should finished-dir)
    (should (file-directory-p finished-dir))))

;;;; ------------------------------------------------------------------
;;;; Scaffold: CLAUDE.md must not carry a dangling import blurb when the
;;;; template has nothing to import (the repo-free case)
;;;; ------------------------------------------------------------------

(defun cc-butler-workspace-test--claude-md (topic-dir)
  "Return the freshly scaffolded CLAUDE.md contents under TOPIC-DIR."
  (with-temp-buffer
    (insert-file-contents (expand-file-name "CLAUDE.md" topic-dir))
    (buffer-string)))

(ert-deftest cc-butler-workspace/scaffold-skips-import-blurb-when-no-imports ()
  "A repo-free template (:claude-import nil) must not leave a dangling
\"imported from the meta repo\" sentence with nothing listed under it."
  (let* ((topic-dir (file-name-as-directory (make-temp-file "cc-scaffold-blank" t)))
         (template (list :claude-import nil)))
    (cc-butler--scaffold topic-dir template)
    (should (file-exists-p (expand-file-name ".projectile" topic-dir)))
    (should-not (string-match-p
                 "imported from the meta repo"
                 (cc-butler-workspace-test--claude-md topic-dir)))))

(ert-deftest cc-butler-workspace/scaffold-includes-import-blurb-when-imports-present ()
  "A template WITH :claude-import still emits the import blurb and @-imports
(no regression from the repo-free fix)."
  (let* ((topic-dir (file-name-as-directory (make-temp-file "cc-scaffold-imp" t)))
         (template (list :claude-import '("app/CLAUDE.md"))))
    (cc-butler--scaffold topic-dir template)
    (let ((claude-md (cc-butler-workspace-test--claude-md topic-dir)))
      (should (string-match-p "imported from the meta repo" claude-md))
      (should (string-match-p "@app/CLAUDE.md" claude-md)))))

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
