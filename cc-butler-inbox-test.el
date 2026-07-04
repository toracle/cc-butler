;;; cc-butler-inbox-test.el --- tests for the inbox pending queue  -*- lexical-binding: t; -*-

;;   emacs -Q --batch -L . -l ert -l cc-butler-inbox-test.el \
;;     -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'cc-butler-inbox)

(ert-deftest cc-butler-inbox/items-lists-open-queue ()
  "The pending queue lists the OPEN decision/note docs with title + kind +
answerable (decisions need an answer, notes are read-closed); reference
documents are not queued.  Faithful: assert the resulting data, not any call."
  (let ((cc-butler-decision-dir (make-temp-file "cc-inbox-test" t)))
    (unwind-protect
        (progn
          (cc-butler--decision-render
           '(:id "d1" :kind decision :from "steward" :reply-to "steward"
                 :summary "Which auth?" :options ("Stripe")))
          (cc-butler--decision-render
           '(:id "n1" :kind note :from "steward" :reply-to "steward" :summary "CI green"))
          (let ((items (cc-butler-inbox-items)))
            (should (= 2 (length items)))
            (should (= 2 (cc-butler-inbox-count)))
            (let ((d (seq-find (lambda (i) (eq 'decision (plist-get i :kind))) items))
                  (n (seq-find (lambda (i) (eq 'note (plist-get i :kind))) items)))
              (should d)
              (should n)
              (should (plist-get d :answerable))
              (should-not (plist-get n :answerable))
              (should (string-match-p "Which auth?" (plist-get d :title)))
              (should (string-match-p "CI green" (plist-get n :title))))))
      (delete-directory cc-butler-decision-dir t))))

(ert-deftest cc-butler-inbox/empty-queue ()
  "An empty inbox is an empty list (count 0) — not an error."
  (let ((cc-butler-decision-dir (make-temp-file "cc-inbox-empty" t)))
    (unwind-protect
        (progn (should (null (cc-butler-inbox-items)))
               (should (= 0 (cc-butler-inbox-count))))
      (delete-directory cc-butler-decision-dir t))))

(provide 'cc-butler-inbox-test)
;;; cc-butler-inbox-test.el ends here
