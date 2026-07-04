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
          (should (null (directory-files (cc-butler--decision-open-dir) nil "\\`[^.].*\\.org\\'")))
          (should (= 1 (length (directory-files (cc-butler--decision-done-dir) nil "\\`[^.].*\\.org\\'")))))
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
      (should (= 1 (length (directory-files (cc-butler--decision-open-dir) nil "\\`[^.].*\\.org\\'"))))
      (should (= 0 (length (directory-files (cc-butler--decision-done-dir) nil "\\`[^.].*\\.org\\'"))))
      (should (equal " ⚖1" cc-butler--decision-indicator)))))

(ert-deftest cc-butler-decision/arrival-note-to-open-unread ()
  "§③ (read-receipt): a note arrival now renders to open/ as UNREAD (read-only),
counted by the indicator — it stays visible until `r' closes it."
  (cc-butler-decision-test--with-arrival
    (cc-butler--mail-file-deliver
     "정수님" '(:id "n9" :kind note :from "steward" :summary "CI is green"))
    (let ((n (cc-butler--decision-on-arrival)))
      (should (= 1 n))
      (should (= 1 (length (directory-files (cc-butler--decision-open-dir) nil "\\`[^.].*\\.org\\'"))))
      (should (= 0 (length (directory-files (cc-butler--decision-done-dir) nil "\\`[^.].*\\.org\\'"))))
      (should (equal " ⚖1" cc-butler--decision-indicator)))))

;;;; ---- create-path (escalate :options) + full flow -----------------

(ert-deftest cc-butler-decision/parse-options ()
  "Options string parses into (:label :tradeoff), tradeoff optional, blanks dropped."
  (let ((opts (cc-butler--decision-parse-options "Stripe — lower fees\nPaddle\n  \nother — misc")))
    (should (= 3 (length opts)))
    (should (equal "Stripe" (plist-get (nth 0 opts) :label)))
    (should (equal "lower fees" (plist-get (nth 0 opts) :tradeoff)))
    (should (equal "Paddle" (plist-get (nth 1 opts) :label)))
    (should (null (plist-get (nth 1 opts) :tradeoff)))
    (should (equal "other" (plist-get (nth 2 opts) :label)))))

(ert-deftest cc-butler-decision/create-path-to-human-inbox ()
  "The escalate create-path delivers a decision (parsed options + return path to
the escalator) into 정수님's inbox."
  (cc-butler-decision-test--with-arrival
    (cl-letf (((symbol-function 'cc-butler--display-name)
               (lambda (d) (if (equal d "/worker/") "worker-a" d))))
      (let ((id (cc-butler-decision-create
                 "/worker/" "which auth?" "pick one"
                 (cc-butler--decision-parse-options "Stripe — lower fees\nPaddle — handles VAT"))))
        (let ((m (car (cc-butler--ch-drain cc-butler-human-agent))))
          (should (eq 'decision (plist-get m :kind)))
          (should (equal id (plist-get m :id)))
          (should (equal "worker-a" (plist-get m :from)))
          (should (equal "worker-a" (plist-get m :reply-to)))   ; answer returns to escalator
          (should (equal "which auth?" (plist-get m :summary)))
          (let ((opts (plist-get m :options)))
            (should (= 2 (length opts)))
            (should (equal "Stripe" (plist-get (car opts) :label)))
            (should (equal "lower fees" (plist-get (car opts) :tradeoff)))))))))

(ert-deftest cc-butler-decision/full-flow-create-to-route ()
  "End to end: create → arrival render → answer + submit → routed back to the
escalator via correlation."
  (cc-butler-decision-test--with-arrival
    (cl-letf (((symbol-function 'cc-butler--display-name)
               (lambda (d) (if (equal d "/worker/") "worker-a" d))))
      (let ((id (cc-butler-decision-create
                 "/worker/" "ship?" nil
                 (cc-butler--decision-parse-options "yes — now\nno — wait"))))
        (should (= 1 (cc-butler--decision-on-arrival)))
        (let* ((file (car (directory-files (cc-butler--decision-open-dir) t
                                           cc-butler--decision-org-re)))
               (doc (with-temp-buffer (insert-file-contents file) (buffer-string))))
          (with-temp-file file (insert (cc-butler-decision-test--fill doc ?A "asap")))
          (let ((buf (find-file-noselect file)))
            (unwind-protect (with-current-buffer buf (cc-butler-decision-submit))
              (kill-buffer buf))))
        (let ((r (car (cc-butler--ch-drain "worker-a"))))
          (should (eq 'reply (plist-get r :kind)))
          (should (equal id (plist-get r :in-reply-to)))
          (should (string-match-p "yes" (plist-get r :body)))
          (should (string-match-p "asap" (plist-get r :body))))))))

;;;; ---- dedup / supersede (item 2) ----------------------------------

(ert-deftest cc-butler-decision/dedup-supersedes-open ()
  "Re-escalating the same topic supersedes the open doc (no duplicate); the
superseded doc reflects the new content."
  (cc-butler-decision-test--with-arrival
    (cc-butler--mail-file-deliver "정수님"
      '(:id "a1" :kind decision :from "steward" :reply-to "steward"
            :summary "Which auth?" :options ("Stripe")))
    (should (= 1 (cc-butler--decision-on-arrival)))
    (should (= 1 (length (directory-files (cc-butler--decision-open-dir) nil cc-butler--decision-org-re))))
    (cc-butler--mail-file-deliver "정수님"
      '(:id "a2" :kind decision :from "steward" :reply-to "steward"
            :summary "Which auth?" :options ("Stripe" "Paddle")))
    (should (= 1 (cc-butler--decision-on-arrival)))       ; superseded, still surfaced
    (should (= 1 (length (directory-files (cc-butler--decision-open-dir) nil cc-butler--decision-org-re))))
    (let ((file (car (directory-files (cc-butler--decision-open-dir) t cc-butler--decision-org-re))))
      (should (string-match-p "Paddle" (with-temp-buffer (insert-file-contents file) (buffer-string)))))))

(ert-deftest cc-butler-decision/dedup-keeps-in-progress-answer ()
  "A re-escalation does NOT clobber an open doc 정수님 is already answering."
  (cc-butler-decision-test--with-arrival
    (cc-butler--mail-file-deliver "정수님"
      '(:id "b1" :kind decision :from "steward" :reply-to "steward"
            :summary "Ship?" :options ("yes" "no")))
    (cc-butler--decision-on-arrival)
    (let* ((file (car (directory-files (cc-butler--decision-open-dir) t cc-butler--decision-org-re)))
           (doc (with-temp-buffer (insert-file-contents file) (buffer-string))))
      (with-temp-file file (insert (cc-butler-decision-test--fill doc ?A))))
    (cc-butler--mail-file-deliver "정수님"
      '(:id "b2" :kind decision :from "steward" :reply-to "steward"
            :summary "Ship?" :options ("yes" "no" "maybe")))
    (should (= 0 (cc-butler--decision-on-arrival)))        ; kept, not surfaced anew
    (should (= 1 (length (directory-files (cc-butler--decision-open-dir) nil cc-butler--decision-org-re))))
    (let ((content (with-temp-buffer
                     (insert-file-contents
                      (car (directory-files (cc-butler--decision-open-dir) t cc-butler--decision-org-re)))
                     (buffer-string))))
      (should (string-match-p "\\[X\\] A" content))         ; 정수님's tick preserved
      (should-not (string-match-p "maybe" content)))))       ; not superseded

(ert-deftest cc-butler-decision/dedup-skips-answered ()
  "An already-answered topic is not resurfaced by a re-escalation."
  (cc-butler-decision-test--with-arrival
    (cl-letf (((symbol-function 'cc-butler--display-name) (lambda (d) d)))
      (cc-butler--mail-file-deliver "정수님"
        '(:id "c1" :kind decision :from "steward" :reply-to "steward"
              :summary "Deploy?" :options ("yes" "no")))
      (cc-butler--decision-on-arrival)
      (let* ((file (car (directory-files (cc-butler--decision-open-dir) t cc-butler--decision-org-re)))
             (doc (with-temp-buffer (insert-file-contents file) (buffer-string)))
             (create-lockfiles nil) (kill-buffer-query-functions nil))
        (with-temp-file file (insert (cc-butler-decision-test--fill doc ?A "go")))
        (let ((buf (find-file-noselect file)))
          (unwind-protect (with-current-buffer buf (cc-butler-decision-submit))
            (ignore-errors (kill-buffer buf)))))
      (should (= 0 (length (directory-files (cc-butler--decision-open-dir) nil cc-butler--decision-org-re))))
      (should (= 1 (length (directory-files (cc-butler--decision-done-dir) nil cc-butler--decision-org-re))))
      (cc-butler--mail-file-deliver "정수님"
        '(:id "c2" :kind decision :from "steward" :reply-to "steward"
              :summary "Deploy?" :options ("yes" "no")))
      (should (= 0 (cc-butler--decision-on-arrival)))        ; skipped
      (should (= 0 (length (directory-files (cc-butler--decision-open-dir) nil cc-butler--decision-org-re)))))))

;;;; ---- read-receipt (`r') ------------------------------------------

(defun cc-butler-decision-test--open-first ()
  "Open the first open/ decision doc in a buffer (no lock files)."
  (let* ((file (car (directory-files (cc-butler--decision-open-dir) t cc-butler--decision-org-re)))
         (create-lockfiles nil))
    (find-file-noselect file)))

(ert-deftest cc-butler-decision/mark-read-note-closes-and-receipts ()
  "`r' on a note: sends a `read' receipt to the sender (correlation) and closes
it (open/ → done/); the indicator decrements."
  (cc-butler-decision-test--with-arrival
    (cl-letf (((symbol-function 'cc-butler--display-name) (lambda (d) d)))
      (cc-butler--mail-file-deliver "정수님"
        '(:id "n1" :kind note :from "steward" :reply-to "steward" :summary "CI green"))
      (cc-butler--decision-on-arrival)
      (let ((buf (cc-butler-decision-test--open-first))
            (kill-buffer-query-functions nil))
        (unwind-protect (with-current-buffer buf (cc-butler-decision-mark-read))
          (ignore-errors (kill-buffer buf))))
      (let ((r (car (cc-butler--ch-drain "steward"))))
        (should (eq 'read (plist-get r :kind)))
        (should (equal "n1" (plist-get r :in-reply-to)))
        (should (equal "정수님" (plist-get r :from))))
      (should (= 0 (length (directory-files (cc-butler--decision-open-dir) nil cc-butler--decision-org-re))))
      (should (= 1 (length (directory-files (cc-butler--decision-done-dir) nil cc-butler--decision-org-re))))
      (should (equal "" cc-butler--decision-indicator)))))

(ert-deftest cc-butler-decision/mark-read-decision-stays-open ()
  "`r' on a decision: sends a read-receipt but KEEPS it in open/ — only C-c C-c
closes a decision (correctness: an unanswered decision is never lost)."
  (cc-butler-decision-test--with-arrival
    (cl-letf (((symbol-function 'cc-butler--display-name) (lambda (d) d)))
      (cc-butler--mail-file-deliver "정수님"
        '(:id "d1" :kind decision :from "worker-a" :reply-to "worker-a"
              :summary "ship?" :options ("yes" "no")))
      (cc-butler--decision-on-arrival)
      (let ((buf (cc-butler-decision-test--open-first))
            (kill-buffer-query-functions nil))
        (unwind-protect (with-current-buffer buf (cc-butler-decision-mark-read))
          (ignore-errors (kill-buffer buf))))
      (let ((r (car (cc-butler--ch-drain "worker-a"))))
        (should (eq 'read (plist-get r :kind)))
        (should (equal "d1" (plist-get r :in-reply-to))))
      (should (= 1 (length (directory-files (cc-butler--decision-open-dir) nil cc-butler--decision-org-re))))
      (should (= 0 (length (directory-files (cc-butler--decision-done-dir) nil cc-butler--decision-org-re)))))))

(ert-deftest cc-butler-decision/mark-read-plain-doc-local-only ()
  "`r' on a document with no routing footer sends NO receipt (local read only)."
  (cc-butler-decision-test--with-arrival
    (with-temp-buffer
      (insert "#+TITLE: Dashboard\n* Status\nall green\n")   ; no sender footer
      (cc-butler-decision-mark-read)
      (should (null (cc-butler--ch-drain "steward")))
      (should (null (cc-butler--ch-drain "worker-a"))))))

;;;; ---- reply notification (poke the escalator, never the butler) ---

(ert-deftest cc-butler-decision/notify-recipient-pokes-non-butler-only ()
  "Delivering an answer wakes the escalator to drain pending_events, but never
the butler (its box stays clean) and never a bad target."
  (let (poked)
    (cl-letf (((symbol-function 'cc-butler--mail-butler-agent) (lambda () "butler"))
              ((symbol-function 'cc-butler--dir-by-name) (lambda (n) (concat "/dir/" n)))
              ((symbol-function 'cc-butler--send-input)
               (lambda (dir &rest _) (push dir poked))))
      (cc-butler--decision-notify-recipient "steward")
      (cc-butler--decision-notify-recipient "butler")   ; skipped (butler)
      (cc-butler--decision-notify-recipient "?")         ; skipped (bad target)
      (should (equal '("/dir/steward") poked)))))

;;;; ---- doc-view operations + hydra (item 3) ------------------------

(ert-deftest cc-butler-decision/confirm-adds-answer-region-to-note ()
  "`c' on a read-only note adds an answer region so it can be replied to."
  (with-temp-buffer
    (insert (cc-butler--decision-doc-string
             '(:id "n1" :kind note :from "steward" :reply-to "steward" :summary "FYI")))
    (should-not (cc-butler--decision-answer-bounds))
    (cc-butler-decision-confirm)
    (should (cc-butler--decision-answer-bounds))))

(ert-deftest cc-butler-decision/keys-bound ()
  "The unified scheme + hydra are bound in the decision keymap."
  (dolist (k '("r" "c" "k" "n" "p" "g" "q" "?"))
    (should (commandp (lookup-key cc-butler-decision-mode-map k))))
  ;; v = reopen (cross-module; assert the binding symbol, not commandp)
  (should (eq (lookup-key cc-butler-decision-mode-map "v") #'cc-butler-doc-reopen))
  (should (eq (lookup-key cc-butler-decision-mode-map "r") #'cc-butler-decision-mark-read))
  (should (eq (lookup-key cc-butler-decision-mode-map "?") #'cc-butler-decision-hydra/body))
  (should (fboundp 'cc-butler-decision-hydra/body)))

;;;; ---- compose safety (data-loss guard) ----------------------------

(ert-deftest cc-butler-decision/compose-region-types-command-letters ()
  "In the answer region the bare command letters TYPE (self-insert), so an
answer containing r/c/k/… is never eaten as a command (data-loss guard);
outside, in the read-only decision text, they remain commands."
  (with-temp-buffer
    (insert (cc-butler--decision-doc-string cc-butler-decision-test--msg))
    (cc-butler-decision-mode 1)
    (let ((bounds (cc-butler--decision-answer-bounds)))
      (should bounds)
      (should (eq #'self-insert-command (key-binding "k" nil nil (car bounds))))
      (should (eq #'self-insert-command (key-binding "r" nil nil (car bounds))))
      (should (eq #'self-insert-command (key-binding "q" nil nil (car bounds))))
      ;; C-c C-c still submits from inside the answer region
      (should (eq #'cc-butler-decision-submit (key-binding (kbd "C-c C-c") nil nil (car bounds))))
      ;; outside the region, the letters are commands
      (should (eq #'cc-butler-decision-quit (key-binding "k" nil nil (point-min)))))))

;;;; ---- demo (staged, isolated, reversible) -------------------------

(ert-deftest cc-butler-decision/demo-roundtrip ()
  "The staged demo renders a decision + indicator; submitting routes the answer
and auto-restores every setting (nothing leaks)."
  (let ((orig-mail cc-butler-mail-dir)
        (orig-dec cc-butler-decision-dir)
        (orig-human cc-butler-human-agent)
        (cc-butler-message-transport 'in-memory)
        (cc-butler--decision-watch nil)
        (cc-butler--channel nil)
        (cc-butler-decision-auto-display nil))   ; no side-window in batch
    (unwind-protect
        (progn
          (cc-butler-decision-demo)
          (should cc-butler--decision-demo-state)
          ;; §③: the demo delivers a decision AND a note — both land in open/.
          (should (= 2 (length (directory-files (cc-butler--decision-open-dir) nil "\\`[^.].*\\.org\\'"))))
          (should (string-match-p "⚖2" cc-butler--decision-indicator))
          ;; the decision (demo-1) sorts before the note (demo-note); answer it
          (let* ((file (car (directory-files (cc-butler--decision-open-dir) t "\\`[^.].*\\.org\\'")))
                 (doc (with-temp-buffer (insert-file-contents file) (buffer-string)))
                 (kill-buffer-query-functions nil))
            ;; drop any buffer the demo's display opened (stale), then fill fresh
            (when-let ((b (get-file-buffer file))) (kill-buffer b))
            (with-temp-file file
              (insert (cc-butler-decision-test--fill doc ?A "sandbox")))
            (let ((buf (find-file-noselect file)))
              (unwind-protect (with-current-buffer buf (cc-butler-decision-submit))
                (kill-buffer buf))))
          ;; the after-submit hook fired demo-result → demo-end restored settings
          (should (null cc-butler--decision-demo-state))
          (should (equal orig-mail cc-butler-mail-dir))
          (should (equal orig-dec cc-butler-decision-dir)))
      (when cc-butler--decision-demo-state (cc-butler-decision-demo-end))
      (setq cc-butler-mail-dir orig-mail
            cc-butler-decision-dir orig-dec
            cc-butler-human-agent orig-human))))

(provide 'cc-butler-decision-test)
;;; cc-butler-decision-test.el ends here
