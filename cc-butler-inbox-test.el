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

(ert-deftest cc-butler-inbox/render-lists-items ()
  "The inbox list renders one line per pending item, with the count, a kind
badge, and a text property linking each line back to its file (so RET opens it).
Faithful: assert the rendered buffer state."
  (let ((cc-butler-decision-dir (make-temp-file "cc-inbox-r" t)))
    (unwind-protect
        (progn
          (cc-butler--decision-render
           '(:id "d1" :kind decision :from "s" :reply-to "s"
                 :summary "Which auth?" :options ("Stripe")))
          (with-temp-buffer
            (cc-butler--inbox-render)
            (let ((s (buffer-string)))
              (should (string-match-p "1 pending" s))
              (should (string-match-p "Which auth?" s))
              (should (string-match-p "decide" s)))
            (goto-char (point-min))
            (should (re-search-forward "Which auth?" nil t))
            (should (get-text-property (match-beginning 0) 'cc-butler-inbox-file))))
      (delete-directory cc-butler-decision-dir t))))

(ert-deftest cc-butler-inbox/render-empty ()
  "An empty inbox renders an explicit empty state, not a blank."
  (let ((cc-butler-decision-dir (make-temp-file "cc-inbox-re" t)))
    (unwind-protect
        (with-temp-buffer
          (cc-butler--inbox-render)
          (should (string-match-p "0 pending" (buffer-string)))
          (should (string-match-p "empty" (buffer-string))))
      (delete-directory cc-butler-decision-dir t))))

(provide 'cc-butler-inbox-test)
;;; cc-butler-inbox-test.el ends here
