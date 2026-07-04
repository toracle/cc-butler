;;; cc-butler-doc-panel-test.el --- tests for the doc panel  -*- lexical-binding: t; -*-

;;   emacs -Q --batch -L . -l ert -l cc-butler-doc-panel-test.el \
;;     -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'cc-butler)
(require 'org)

(ert-deftest cc-butler-doc/open-link-adds-target-tab ()
  "RET on an Org file-link opens the target as a `file' tab in this panel,
resolving the link relative to the index document's directory."
  (let ((added nil)
        (idx (make-temp-file "cc-idx" nil ".org"))
        (target (make-temp-file "cc-tgt" nil ".org")))
    (unwind-protect
        (cl-letf (((symbol-function 'cc-butler--doc-target-dir) (lambda () "/session/"))
                  ((symbol-function 'cc-butler--doc-add)
                   (lambda (dir kind ref &rest _) (setq added (list dir kind ref))))
                  ((symbol-function 'cc-butler--doc-refresh-layout) (lambda (_dir) nil)))
          (with-temp-buffer
            (setq buffer-file-name idx)          ; base dir for relative links
            (org-mode)
            (insert (format "* Index\n[[file:%s][the target]]\n"
                            (file-name-nondirectory target)))
            (goto-char (point-min))
            (re-search-forward "file:")           ; point inside the link
            (cc-butler-doc-open-link))
          (should added)
          (should (equal "/session/" (nth 0 added)))
          (should (eq 'file (nth 1 added)))
          (should (equal (expand-file-name (file-name-nondirectory target)
                                           (file-name-directory idx))
                         (nth 2 added))))
      (delete-file idx)
      (delete-file target))))

(ert-deftest cc-butler-doc/open-link-errors-off-link ()
  "Off a link, `cc-butler-doc-open-link' errors rather than acting."
  (with-temp-buffer
    (org-mode)
    (insert "* Index\njust some text\n")
    (goto-char (point-min))
    (should-error (cc-butler-doc-open-link) :type 'user-error)))

(ert-deftest cc-butler-doc/panel-survives-dead-buffer ()
  "Guarantee 1/6 (bug ④ family): when the current document's buffer is killed,
the panel REVIVES a live buffer instead of blanking — so navigation/refresh
onto a dead buffer never closes the panel.  Faithful assert on resulting
state (a live buffer visiting the file), not on any call."
  (let ((tmp (make-temp-file "cc-docp" nil ".org"))
        (cc-butler--docs (make-hash-table :test 'equal))
        (kill-buffer-query-functions nil))
    (unwind-protect
        (progn
          (with-temp-file tmp (insert "* Doc\ncontent\n"))
          (cc-butler--doc-add "/session/" 'file tmp)
          ;; the current doc has a live buffer …
          (let ((buf (plist-get (cc-butler--current-doc "/session/") :buffer)))
            (should (buffer-live-p buf))
            (kill-buffer buf))                       ; … now kill it (dead buffer)
          ;; recovery: a LIVE buffer visiting the same file, not nil (would close)
          (let ((revived (cc-butler--current-doc-buffer "/session/")))
            (should (buffer-live-p revived))
            (should (equal (expand-file-name tmp) (buffer-file-name revived)))
            ;; and the state's item now points at the live buffer (faithful state)
            (should (eq revived (plist-get (cc-butler--current-doc "/session/") :buffer)))))
      (dolist (b (buffer-list))
        (when (equal (buffer-file-name b) (expand-file-name tmp)) (kill-buffer b)))
      (delete-file tmp))))

(provide 'cc-butler-doc-panel-test)
;;; cc-butler-doc-panel-test.el ends here
