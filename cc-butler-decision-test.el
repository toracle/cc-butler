;;; cc-butler-decision-test.el --- BDD tests for the human decision adapter  -*- lexical-binding: t; -*-

;; Acceptance oracle for `cc-butler-decision' (the human adapter of maildir B).
;; Routing runs against B's in-memory MOCK channel (reused from
;; cc-butler-mail-test); rendering/parse/integrity are pure buffer operations.
;;
;;   emacs -Q --batch -L . -l ert -l cc-butler-decision-test.el \
;;     -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'cc-butler-decision)
(require 'cc-butler-mail-test)   ; mock channel + inboxes/pokes vars

(defconst cc-butler-decision-test--msg
  '(:id "d1" :kind decision :from "worker-a" :reply-to "worker-a"
        :summary "Which auth for billing?" :needs "pick one"
        :options ((:label "Stripe" :tradeoff "lower fees")
                  (:label "Paddle" :tradeoff "handles VAT")
                  (:label "other")))
  "A representative decision message.")

(defun cc-butler-decision-test--fill (doc &optional letter other)
  "Return DOC with option LETTER ticked and OTHER written in the answer region."
  (with-temp-buffer
    (insert doc)
    (when letter
      (goto-char (point-min))
      (when (search-forward cc-butler--decision-answer-begin nil t)
        (when (re-search-forward (format "^- \\[\\( \\)\\] %c" letter) nil t)
          (replace-match "X" nil nil nil 1))))
    (when other
      (goto-char (point-min))
      (search-forward cc-butler--decision-answer-begin nil t)
      (when (re-search-forward "^Other:[ \t]*$" nil t)
        (replace-match (concat "Other: " other))))
    (buffer-string)))

;;;; ---- rendering ---------------------------------------------------

(ert-deftest cc-butler-decision/render-decision ()
  "A decision message renders an answerable doc: labelled options, a bare-checkbox
answer region, an Other line, and a routing footer."
  (let ((doc (cc-butler--decision-doc-string cc-butler-decision-test--msg)))
    (should (string-match-p "#\\+TITLE: Decision — Which auth for billing?" doc))
    (should (string-match-p "^  A\\. Stripe — lower fees$" doc))
    (should (string-match-p "^  B\\. Paddle — handles VAT$" doc))
    (should (string-match-p (regexp-quote cc-butler--decision-answer-begin) doc))
    (should (string-match-p "^- \\[ \\] A$" doc))
    (should (string-match-p "^Other: $" doc))
    (should (string-match-p "id=d1 to=worker-a" doc))))

(ert-deftest cc-butler-decision/render-note-readonly ()
  "A note message renders a read-only notification — no answer region."
  (let ((doc (cc-butler--decision-doc-string
              '(:id "n1" :kind note :from "steward" :summary "CI is green"))))
    (should (string-match-p "Notification (read-only)" doc))
    (should-not (string-match-p (regexp-quote cc-butler--decision-answer-begin) doc))))

;;;; ---- parsing / integrity -----------------------------------------

(ert-deftest cc-butler-decision/parse-selection-and-other ()
  "Parsing reads the ticked option (by its label) and the Other free-form, and
takes routing from the footer."
  (let* ((doc (cc-butler-decision-test--fill
               (cc-butler--decision-doc-string cc-butler-decision-test--msg)
               ?A "use sandbox keys"))
         (parsed (with-temp-buffer (insert doc) (cc-butler--decision-parse))))
    (should (equal '("A") (plist-get parsed :selected)))
    (should (equal "use sandbox keys" (plist-get parsed :other)))
    (should (equal "d1" (plist-get parsed :id)))
    (should (equal "worker-a" (plist-get parsed :to)))
    (should (string-match-p "Stripe" (plist-get parsed :answer)))
    (should (string-match-p "Other: use sandbox keys" (plist-get parsed :answer)))))

(ert-deftest cc-butler-decision/parse-ignores-outside-answer-region ()
  "Only the answer region is parsed — a stray tick elsewhere is not counted."
  (let* ((doc (cc-butler-decision-test--fill
               (cc-butler--decision-doc-string cc-butler-decision-test--msg) ?A))
         ;; inject a rogue ticked line BEFORE the answer region
         (tampered (replace-regexp-in-string
                    "^\\* Decision\n" "* Decision\n- [X] B\n" doc))
         (parsed (with-temp-buffer (insert tampered) (cc-butler--decision-parse))))
    (should (equal '("A") (plist-get parsed :selected)))   ; not ("B" "A")
    (should-not (member "B" (plist-get parsed :selected)))))

;;;; ---- submit routes via correlation -------------------------------

(ert-deftest cc-butler-decision/submit-routes-and-archives ()
  "Submitting a filled decision delivers the answer to the asker (correlation)
and moves the file open/ → done/."
  (let* ((cc-butler-decision-dir (make-temp-file "cc-butler-dec-test" t))
         (cc-butler-mail-test--inboxes nil)
         (cc-butler-mail-test--pokes nil)
         (cc-butler--channel (cc-butler-mail-test--mock-channel))
         (cc-butler-human-agent "정수님")
         (file (cc-butler--decision-render cc-butler-decision-test--msg)))
    (unwind-protect
        (progn
          ;; fill the file (tick A + Other) on disk, then open it
          (let ((doc (with-temp-buffer (insert-file-contents file) (buffer-string))))
            (with-temp-file file
              (insert (cc-butler-decision-test--fill doc ?A "sandbox"))))
          (let ((buf (find-file-noselect file)))
            (unwind-protect
                (with-current-buffer buf (cc-butler-decision-submit))
              (kill-buffer buf)))
          ;; the reply reached the asker's inbox, correlated to the decision
          (let ((r (car (cc-butler--ch-drain "worker-a"))))
            (should (eq 'reply (plist-get r :kind)))
            (should (equal "d1" (plist-get r :in-reply-to)))
            (should (equal "정수님" (plist-get r :from)))
            (should (string-match-p "Stripe" (plist-get r :body)))
            (should (string-match-p "sandbox" (plist-get r :body))))
          ;; the file moved open/ → done/
          (should (null (directory-files (cc-butler--decision-open-dir) nil "\\.org\\'")))
          (should (= 1 (length (directory-files (cc-butler--decision-done-dir) nil "\\.org\\'")))))
      (delete-directory cc-butler-decision-dir t))))

(ert-deftest cc-butler-decision/submit-refuses-empty ()
  "An un-answered (half-written) decision does not route — no leak."
  (let* ((cc-butler-mail-test--inboxes nil)
         (cc-butler--channel (cc-butler-mail-test--mock-channel))
         (doc (cc-butler--decision-doc-string cc-butler-decision-test--msg)))
    (with-temp-buffer
      (insert doc)
      (should-error (cc-butler-decision-submit) :type 'user-error))
    (should (null (cc-butler--ch-drain "worker-a")))))

(ert-deftest cc-butler-decision/submit-refuses-note ()
  "A note (no answer region) is not submittable."
  (with-temp-buffer
    (insert (cc-butler--decision-doc-string
             '(:id "n1" :kind note :from "steward" :summary "CI green")))
    (should-error (cc-butler-decision-submit) :type 'user-error)))

;;;; ---- arrival-render layer (Emacs-native, arrival-driven) ---------

(defmacro cc-butler-decision-test--with-arrival (&rest body)
  "Fresh temp mail + decision dirs, file adapter, no auto-display."
  (declare (indent 0))
  `(let* ((cc-butler-mail-dir (make-temp-file "cc-butler-arr-mail" t))
          (cc-butler-decision-dir (make-temp-file "cc-butler-arr-dec" t))
          (cc-butler--channel nil)                 ; real file adapter
          (cc-butler-human-agent "정수님")
          (cc-butler-decision-auto-display nil)
          (cc-butler--decision-indicator ""))
     (unwind-protect (progn ,@body)
       (delete-directory cc-butler-mail-dir t)
       (delete-directory cc-butler-decision-dir t))))

(ert-deftest cc-butler-decision/arrival-renders-and-indicates ()
  "A decision ARRIVING in 정수님's inbox renders to open/ and sets the mode-line
indicator — driven by arrival, with no agent turn involved."
  (cc-butler-decision-test--with-arrival
    (cc-butler--mail-file-deliver
     "정수님" '(:id "d9" :kind decision :from "worker-a" :reply-to "worker-a"
                 :summary "ship it?" :options ("yes" "no")))
    (let ((n (cc-butler--decision-on-arrival)))     ; the watcher's callback, called directly
      (should (= 1 n))
      (should (= 1 (length (directory-files (cc-butler--decision-open-dir) nil "\\.org\\'"))))
      (should (= 0 (length (directory-files (cc-butler--decision-done-dir) nil "\\.org\\'"))))
      (should (equal " ⚖1" cc-butler--decision-indicator)))))

(ert-deftest cc-butler-decision/arrival-note-not-queued ()
  "A note arrival renders read-only to done/, never the answer queue, and leaves
the indicator clear."
  (cc-butler-decision-test--with-arrival
    (cc-butler--mail-file-deliver
     "정수님" '(:id "n9" :kind note :from "steward" :summary "CI is green"))
    (let ((n (cc-butler--decision-on-arrival)))
      (should (= 0 n))
      (should (= 0 (length (directory-files (cc-butler--decision-open-dir) nil "\\.org\\'"))))
      (should (= 1 (length (directory-files (cc-butler--decision-done-dir) nil "\\.org\\'"))))
      (should (equal "" cc-butler--decision-indicator)))))

(provide 'cc-butler-decision-test)
;;; cc-butler-decision-test.el ends here
