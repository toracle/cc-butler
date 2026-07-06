;;; cc-butler-inbox-test.el --- tests for the inbox pending queue  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jeongsoo Park
;; SPDX-License-Identifier: MIT

;;   emacs -Q --batch -L . -l ert -l cc-butler-inbox-test.el \
;;     -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'cc-butler-inbox)
(require 'cc-butler-decision-test)   ; the --fill helper

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
              (should (string-match-p "\\[unread\\] 1" s))
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
          (should (string-match-p "\\[unread\\] 0" (buffer-string)))
          (should (string-match-p "empty" (buffer-string))))
      (delete-directory cc-butler-decision-dir t))))

(ert-deftest cc-butler-inbox/sign-and-next-registered-and-guarded ()
  "Sign & next is registered on submit, and no-ops for non-inbox docs."
  (should (memq #'cc-butler--inbox-sign-and-next cc-butler-decision-after-submit-functions))
  (with-temp-buffer
    (should-not cc-butler--inbox-opened)
    (cc-butler--inbox-sign-and-next nil)))   ; guarded — no error, no schedule

(ert-deftest cc-butler-inbox/end-to-end-answer-removes-from-queue ()
  "END TO END: an open decision is in the pending queue; after it is answered it
LEAVES the queue (archived to done/) — the inbox reflects sign & next."
  (let ((cc-butler-decision-dir (make-temp-file "cc-e2e" t))
        (cc-butler-mail-dir (make-temp-file "cc-e2e-mail" t))
        (cc-butler--channel nil)
        (cc-butler-human-agent "정수님"))
    (unwind-protect
        (cl-letf (((symbol-function 'cc-butler--display-name) (lambda (d) d)))
          (cc-butler--decision-render
           '(:id "e1" :kind decision :from "steward" :reply-to "steward"
                 :summary "Ship?" :options ("yes" "no")))
          (should (= 1 (cc-butler-inbox-count)))
          (let* ((file (plist-get (car (cc-butler-inbox-items)) :file))
                 (doc (with-temp-buffer (insert-file-contents file) (buffer-string)))
                 (create-lockfiles nil) (kill-buffer-query-functions nil))
            (with-temp-file file (insert (cc-butler-decision-test--fill doc ?A "go")))
            (let ((buf (find-file-noselect file)))
              (unwind-protect (with-current-buffer buf (cc-butler-decision-submit))
                (ignore-errors (kill-buffer buf)))))
          (should (= 0 (cc-butler-inbox-count))))   ; signed → gone from the queue
      (delete-directory cc-butler-decision-dir t)
      (delete-directory cc-butler-mail-dir t))))

(ert-deftest cc-butler-inbox/folders-unread-and-archive ()
  "A (view scope): the inbox reads two folders — unread=open/, archive=done/ —
and the badge count is unread-only."
  (let ((cc-butler-decision-dir (make-temp-file "cc-fold" t)))
    (unwind-protect
        (progn
          (make-directory (cc-butler--decision-open-dir) t)
          (make-directory (cc-butler--decision-done-dir) t)
          (with-temp-file (expand-file-name "a-0001.org" (cc-butler--decision-open-dir))
            (insert "#+TITLE: Decision — open one\n"))
          (with-temp-file (expand-file-name "b-0002.org" (cc-butler--decision-done-dir))
            (insert "#+TITLE: Decision — done one\n"))
          (should (= 1 (length (cc-butler-inbox-items 'unread))))
          (should (= 1 (length (cc-butler-inbox-items 'archive))))
          (should (= 1 (cc-butler-inbox-count)))           ; unread only
          (should (string-match-p "open one"
                                  (plist-get (car (cc-butler-inbox-items 'unread)) :title)))
          (should (string-match-p "done one"
                                  (plist-get (car (cc-butler-inbox-items 'archive)) :title))))
      (delete-directory cc-butler-decision-dir t))))

(ert-deftest cc-butler-inbox/render-shows-folder-and-cycles ()
  "The render names the active folder; f cycles unread↔archive, default unread."
  (let ((cc-butler-decision-dir (make-temp-file "cc-foldr" t)))
    (unwind-protect
        (with-temp-buffer
          (cc-butler-inbox-mode)
          (cc-butler--inbox-render)
          (should (eq cc-butler-inbox-folder 'unread))
          (should (string-match-p "\\[unread\\]" (buffer-string)))
          (cc-butler-inbox-cycle-folder)
          (should (eq cc-butler-inbox-folder 'archive))
          (should (string-match-p "\\[archive\\]" (buffer-string)))
          (cc-butler-inbox-cycle-folder)
          (should (eq cc-butler-inbox-folder 'unread)))
      (delete-directory cc-butler-decision-dir t))))

(ert-deftest cc-butler-inbox/next-prev-bound-to-entry-movers ()
  "n/p are bound to the entry-boundary movers, not raw `next-line'/`previous-line'
(regression: those move by wrapped screen line, so a long title spanning
several rows used to take one press per row instead of one press per entry)."
  (should (eq (lookup-key cc-butler-inbox-mode-map "n") #'cc-butler-inbox-next))
  (should (eq (lookup-key cc-butler-inbox-mode-map "p") #'cc-butler-inbox-prev)))

(ert-deftest cc-butler-inbox/next-prev-move-by-entry ()
  "cc-butler-inbox-next/-prev land on the next/previous entry's file, one
press each, regardless of how many buffer lines a title's content spans."
  (let ((cc-butler-decision-dir (make-temp-file "cc-inbox-nav" t)))
    (unwind-protect
        (progn
          (cc-butler--decision-render
           '(:id "d1" :kind decision :from "s" :reply-to "s"
                 :summary "First decision" :options ("a")))
          (cc-butler--decision-render
           '(:id "d2" :kind decision :from "s" :reply-to "s"
                 :summary "Second decision" :options ("a")))
          (with-temp-buffer
            (cc-butler-inbox-mode)
            (cc-butler--inbox-render)
            (goto-char (point-min))
            (should (re-search-forward "First decision" nil t))
            (goto-char (line-beginning-position))
            (let ((file1 (get-text-property (point) 'cc-butler-inbox-file)))
              (should file1)
              (cc-butler-inbox-next)
              (let ((file2 (get-text-property (point) 'cc-butler-inbox-file)))
                (should file2)
                (should-not (equal file1 file2))
                (cc-butler-inbox-prev)
                (should (equal file1 (get-text-property (point) 'cc-butler-inbox-file)))))))
      (delete-directory cc-butler-decision-dir t))))

(provide 'cc-butler-inbox-test)
;;; cc-butler-inbox-test.el ends here
