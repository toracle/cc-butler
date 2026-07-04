;;; cc-butler-decision.el --- Human adapter: decision documents  -*- lexical-binding: t; -*-

;; The HUMAN adapter of the cc-butler message bus (maildir B).  Where an agent
;; drains its inbox programmatically (`check_inbox' / `pending_*'), the human
;; (정수님) reads and answers.  This module renders a `decision' message as an
;; answerable org document — options to select (AskUserQuestion style) plus a
;; free-form "Other" — and, on an explicit `C-c C-c', routes 정수님's answer back
;; to whoever asked via the same maildir correlation (return-path) as B.
;;
;; Design (see docs/cc-butler-decision-workflow-sdd.md):
;;   - one file per decision, timestamp-named, in open/ → done/ (audit trail);
;;   - render by :kind — `decision' is answerable, `note'/`relay' are read-only
;;     notifications (so the answer queue is exactly the open decisions);
;;   - integrity — only the delimited answer region is editable and parsed; the
;;     decision text, option labels, and the routing footer are read-only, and
;;     routing depends solely on the footer, never on editable text.
;;
;; Reversible: behind `cc-butler-decision-workflow' (default off); it does not
;; touch workers and is independent of `cc-butler-message-transport'.

(require 'cc-butler-mail)
(require 'org)
(require 'subr-x)

(defcustom cc-butler-decision-dir
  (expand-file-name "decisions/" cc-butler-mail-dir)
  "Directory holding rendered decision documents (open/ and done/ subdirs)."
  :type 'directory
  :group 'cc-butler)

(defcustom cc-butler-decision-workflow nil
  "When non-nil, escalations are also rendered as answerable decision documents.
A reversible toggle, independent of `cc-butler-message-transport'."
  :type 'boolean
  :group 'cc-butler)

(defcustom cc-butler-human-agent "정수님"
  "Agent id of the human node — the `from' on answers 정수님 submits."
  :type 'string
  :group 'cc-butler)

(defconst cc-butler--decision-answer-begin
  "# >>> your answer — tick an option and/or write below, then C-c C-c >>>"
  "Marker line opening the editable answer region.")

(defconst cc-butler--decision-answer-end
  "# <<< end answer <<<"
  "Marker line closing the editable answer region.")

;;;; ------------------------------------------------------------------
;;;; Rendering a message → an org document
;;;; ------------------------------------------------------------------

(defun cc-butler--decision-open-dir ()
  (let ((d (expand-file-name "open/" cc-butler-decision-dir)))
    (make-directory d t) d))

(defun cc-butler--decision-done-dir ()
  (let ((d (expand-file-name "done/" cc-butler-decision-dir)))
    (make-directory d t) d))

(defun cc-butler--decision-option-label (o)
  "Label string for option O (a string, or a plist (:label :tradeoff))."
  (if (stringp o) o (plist-get o :label)))

(defun cc-butler--decision-doc-string (msg)
  "Return the org document text rendering decision MSG.
MSG: (:id :kind :from :reply-to :summary :needs :options).  `decision' kind is
answerable; `note'/`relay' render a read-only notification."
  (let* ((kind (or (plist-get msg :kind) 'decision))
         (id (or (plist-get msg :id) "?"))
         (to (or (plist-get msg :reply-to) (plist-get msg :from) "?"))
         (summary (string-trim (or (plist-get msg :summary)
                                   (plist-get msg :body) "")))
         (needs (plist-get msg :needs))
         (from (plist-get msg :from))
         (options (plist-get msg :options))
         (first (car (split-string summary "\n"))))
    (with-temp-buffer
      (if (eq kind 'decision)
          (progn
            (insert (format "#+TITLE: Decision — %s\n\n" first))
            (insert "* Decision\n" summary "\n")
            (when needs (insert "\nNeeds: " needs "\n"))
            (when from (insert (format "\n_(from %s)_\n" from)))
            (insert "\n* Options (reference)\n")
            (let ((letter ?A))
              (dolist (o options)
                (let ((tr (and (not (stringp o)) (plist-get o :tradeoff))))
                  (insert (format "  %c. %s%s\n" letter
                                  (cc-butler--decision-option-label o)
                                  (if tr (format " — %s" tr) "")))
                  (setq letter (1+ letter)))))
            (insert "\n" cc-butler--decision-answer-begin "\n")
            (let ((letter ?A))
              (dolist (_o options)
                (insert (format "- [ ] %c\n" letter))
                (setq letter (1+ letter))))
            (insert "Other: \n")
            (insert cc-butler--decision-answer-end "\n"))
        ;; note / relay — read-only notification, no answer region
        (insert (format "#+TITLE: Note — %s\n\n" first))
        (insert "* Notification (read-only)\n" summary "\n")
        (when from (insert (format "\n_(from %s)_\n" from))))
      (insert (format "\n# cc-butler decision id=%s to=%s  (routing — do not edit)\n"
                      id to))
      (buffer-string))))

(defun cc-butler--decision-render (msg &optional dir)
  "Render decision MSG to a timestamped file in DIR (default open/); return the path."
  (let* ((id (or (plist-get msg :id) (cc-butler--mail-id)))
         (msg (plist-put msg :id id))
         (file (expand-file-name (format "%s.org" id)
                                 (or dir (cc-butler--decision-open-dir)))))
    (with-temp-file file (insert (cc-butler--decision-doc-string msg)))
    file))

(defun cc-butler-decision-refresh ()
  "Drain the human node's inbox and render each decision as an open/ document.
`note'/`relay' messages render read-only; nothing is typed anywhere."
  (let ((msgs (cc-butler--ch-drain cc-butler-human-agent))
        (rendered 0))
    (dolist (m msgs)
      (cc-butler--decision-render m)
      (setq rendered (1+ rendered)))
    rendered))

;;;; ------------------------------------------------------------------
;;;; Parsing the answer region + routing the reply
;;;; ------------------------------------------------------------------

(defun cc-butler--decision-answer-bounds ()
  "Return (BEG . END) of the editable answer region, or nil if absent."
  (save-excursion
    (goto-char (point-min))
    (when (search-forward cc-butler--decision-answer-begin nil t)
      (let ((beg (line-beginning-position 2)))
        (when (search-forward cc-butler--decision-answer-end nil t)
          (cons beg (line-beginning-position)))))))

(defun cc-butler--decision-labels ()
  "Alist of (LETTER-string . label) parsed from the read-only Options section."
  (save-excursion
    (goto-char (point-min))
    (let (alist)
      (when (re-search-forward "^\\* Options (reference)" nil t)
        (forward-line 1)
        (while (looking-at "^  \\([A-Z]\\)\\. \\(.*?\\)\\(?: — .*\\)?$")
          (push (cons (match-string 1) (string-trim (match-string 2))) alist)
          (forward-line 1)))
      (nreverse alist))))

(defun cc-butler--decision-parse ()
  "Parse the current decision buffer.
Return a plist (:id :to :selected :other :answer), or nil if it is not an
answerable decision document.  Only the answer region is read; routing (:id
:to) comes from the read-only footer."
  (let ((bounds (cc-butler--decision-answer-bounds)))
    (when bounds
      (let (id to selected other)
        (save-excursion
          (goto-char (point-min))
          (when (re-search-forward "^# cc-butler decision id=\\(\\S-+\\) to=\\(\\S-+\\)" nil t)
            (setq id (match-string 1) to (match-string 2))))
        (save-restriction
          (narrow-to-region (car bounds) (cdr bounds))
          (goto-char (point-min))
          (while (re-search-forward "^- \\[[Xx]\\] \\([A-Z]\\)\\b" nil t)
            (push (match-string 1) selected))
          (goto-char (point-min))
          (when (re-search-forward "^Other:[ \t]*\\(.*\\)$" nil t)
            (let ((s (string-trim (match-string 1))))
              (unless (string-empty-p s) (setq other s)))))
        (setq selected (nreverse selected))
        (let* ((labels (cc-butler--decision-labels))
               (picked (mapcar (lambda (l) (or (cdr (assoc l labels)) l)) selected))
               (answer (string-join
                        (delq nil (append picked (and other (list (concat "Other: " other)))))
                        "; ")))
          (list :id id :to to :selected selected :other other :answer answer))))))

(defun cc-butler-decision-submit ()
  "Submit the current decision document's answer (bound to `C-c C-c').
Routes 정수님's answer back to the asker via the maildir correlation, then
moves the file to done/."
  (interactive)
  (let ((parsed (cc-butler--decision-parse)))
    (unless parsed
      (user-error "Not an answerable decision document"))
    (let ((id (plist-get parsed :id))
          (to (plist-get parsed :to))
          (answer (plist-get parsed :answer)))
      (unless (and id to (not (equal to "?")))
        (user-error "Decision routing footer missing or corrupt — refusing to send"))
      (when (string-empty-p (or answer ""))
        (user-error "No answer selected or written"))
      (cc-butler--ch-deliver
       to (list :kind 'reply :from cc-butler-human-agent
                :in-reply-to id :body answer))
      (let ((file (buffer-file-name)))
        (when (and file (file-exists-p file))
          (let ((dest (expand-file-name (file-name-nondirectory file)
                                        (cc-butler--decision-done-dir))))
            (save-buffer)
            (rename-file file dest t)
            (set-visited-file-name dest nil t)))
        (set-buffer-modified-p nil))
      (message "cc-butler: answer sent to %s; decision archived to done/" to)
      answer)))

;;;; ------------------------------------------------------------------
;;;; The decision-document minor mode (read-only + C-c C-c)
;;;; ------------------------------------------------------------------

(defvar cc-butler-decision-mode-map (make-sparse-keymap)
  "Keymap for `cc-butler-decision-mode'.")
(define-key cc-butler-decision-mode-map (kbd "C-c C-c") #'cc-butler-decision-submit)

(defun cc-butler--decision-protect ()
  "Make everything outside the answer region read-only (integrity)."
  (let ((bounds (cc-butler--decision-answer-bounds))
        (inhibit-read-only t))
    (remove-text-properties (point-min) (point-max) '(read-only nil))
    (if bounds
        (progn
          (add-text-properties (point-min) (car bounds) '(read-only t))
          (add-text-properties (cdr bounds) (point-max) '(read-only t)))
      (add-text-properties (point-min) (point-max) '(read-only t)))))

;;;###autoload
(define-minor-mode cc-butler-decision-mode
  "Answer a cc-butler decision document: pick an option and/or write Other,
then \\[cc-butler-decision-submit].  Keeps org-mode (highlighting); the
decision text, option labels, and routing footer are read-only — only the
answer region is editable and parsed."
  :lighter " ccDecide"
  :keymap cc-butler-decision-mode-map
  (when cc-butler-decision-mode
    (cc-butler--decision-protect)))

;;;; ------------------------------------------------------------------
;;;; Arrival-render layer — Emacs-native, arrival-driven (not agent-turn)
;;;; ------------------------------------------------------------------
;;
;; The render half of the human adapter belongs to Emacs, not the butler
;; agent: a decision must be surfaced the moment it ARRIVES in 정수님's inbox,
;; not when the butler agent next takes a conversational turn.  A file-watcher
;; on the inbox renders the doc + sets a mode-line indicator (and gently shows
;; the panel) with no agent turn and nothing typed into any input box.  The
;; conversation half (answering, C-c C-c) stays 정수님-driven.

(require 'filenotify)

(defcustom cc-butler-decision-auto-display t
  "When non-nil, a freshly-arrived decision is shown in a side window.
Uses `display-buffer' (no focus stealing); the mode-line indicator fires
regardless."
  :type 'boolean
  :group 'cc-butler)

(defvar cc-butler--decision-indicator ""
  "Mode-line indicator string for open decisions (in `global-mode-string').")
(put 'cc-butler--decision-indicator 'risky-local-variable t)

(defvar cc-butler--decision-watch nil
  "The `file-notify' descriptor for 정수님's inbox, or nil.")

(defun cc-butler--decision-open-count ()
  (length (ignore-errors
            (directory-files (cc-butler--decision-open-dir) nil "\\.org\\'"))))

(defun cc-butler--decision-update-indicator ()
  "Set the mode-line indicator to the open-decision count; return it."
  (let ((n (cc-butler--decision-open-count)))
    (setq cc-butler--decision-indicator (if (> n 0) (format " ⚖%d" n) ""))
    (force-mode-line-update t)
    n))

(defun cc-butler--decision-display (file)
  "Show decision FILE in a side window without stealing focus."
  (let ((buf (find-file-noselect file)))
    (with-current-buffer buf (cc-butler-decision-mode 1))
    (display-buffer buf '(display-buffer-in-side-window (side . right)))))

(defun cc-butler--decision-on-arrival ()
  "Render newly-arrived inbox messages and refresh the indicator.
Arrival-driven: this runs on an inbox change, independent of any agent turn.
`decision' messages render into open/ (the answer queue); `note'/`relay'
render read-only straight to done/.  Returns the count of new decisions."
  (let ((msgs (cc-butler--ch-drain cc-butler-human-agent))
        (fresh '()))
    (dolist (m msgs)
      (let ((decision (eq (or (plist-get m :kind) 'decision) 'decision)))
        (let ((file (cc-butler--decision-render
                     m (if decision (cc-butler--decision-open-dir)
                         (cc-butler--decision-done-dir)))))
          (when decision (push file fresh)))))
    (cc-butler--decision-update-indicator)
    (when (and fresh cc-butler-decision-auto-display)
      (cc-butler--decision-display (car (last fresh))))
    (length fresh)))

(defun cc-butler-decision-watch-start ()
  "Watch 정수님's inbox and render on arrival (Emacs-native, no agent turn)."
  (cc-butler-decision-watch-stop)
  (let ((newdir (expand-file-name "new/" (cc-butler--mail-inbox cc-butler-human-agent))))
    (make-directory newdir t)
    (setq cc-butler--decision-watch
          (file-notify-add-watch
           newdir '(change)
           (lambda (event)
             (when (memq (nth 1 event) '(created renamed))
               (cc-butler--decision-on-arrival))))))
  (add-to-list 'global-mode-string 'cc-butler--decision-indicator t)
  (cc-butler--decision-update-indicator))

(defun cc-butler-decision-watch-stop ()
  "Stop watching 정수님's inbox and clear the indicator."
  (when cc-butler--decision-watch
    (ignore-errors (file-notify-rm-watch cc-butler--decision-watch))
    (setq cc-butler--decision-watch nil))
  (setq global-mode-string (delq 'cc-butler--decision-indicator global-mode-string))
  (force-mode-line-update t))

;;;###autoload
(defun cc-butler-decision-workflow-toggle (&optional arg)
  "Toggle the arrival-driven decision workflow (render + indicator).
With ARG, enable if positive.  Reversible; touches no worker and types
nothing into any input box."
  (interactive "P")
  (setq cc-butler-decision-workflow
        (if arg (> (prefix-numeric-value arg) 0)
          (not cc-butler-decision-workflow)))
  (if cc-butler-decision-workflow
      (progn (cc-butler-decision-watch-start)
             (message "cc-butler decision workflow: ON (arrival-driven render + indicator)"))
    (cc-butler-decision-watch-stop)
    (message "cc-butler decision workflow: OFF")))

;;;###autoload
(defun cc-butler-decision-answer-next ()
  "Open the oldest open decision document for answering (in `cc-butler-decision-mode').
Renders any freshly-arrived decisions from the human inbox first."
  (interactive)
  (cc-butler-decision-refresh)
  (let* ((open (cc-butler--decision-open-dir))
         (files (sort (directory-files open t "\\.org\\'") #'string<)))
    (if (null files)
        (message "cc-butler: no open decisions.")
      (find-file (car files))
      (cc-butler-decision-mode 1)
      (goto-char (point-min))
      (when (search-forward cc-butler--decision-answer-begin nil t)
        (forward-line 1)))))

(provide 'cc-butler-decision)
;;; cc-butler-decision.el ends here
