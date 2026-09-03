;;; cc-butler-decision.el --- Human adapter: decision documents  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jeongsoo Park
;; SPDX-License-Identifier: MIT

;; The HUMAN adapter of the cc-butler message bus (maildir B).  Where an agent
;; drains its inbox programmatically (`check_inbox' / `pending_*'), the human
;; (정수님) reads and answers.  This module renders a `decision' message as an
;; answerable org document — options to select (AskUserQuestion style) plus a
;; free-form "Other" — and, on an explicit `C-c C-c', routes 정수님's answer back
;; to whoever asked via the same maildir correlation (return-path) as B.
;;
;; Design:
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
A reversible toggle, independent of `cc-butler-message-transport'.

KNOWN GAP before enabling: with this on, escalations are rendered into the
decision documents under `open/', which `cc-butler-tool-pending-decisions'
does NOT scan — while `escalate_to_butler' returns the same success string
either way.  Escalations would be answerable by the human but invisible to a
butler that drains `pending_decisions'.  Dormant while this is nil."
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

(defvar cc-butler-decision-after-submit-functions nil
  "Abnormal hook run after a decision is submitted.
Each function is called with one plist argument (:to :id :answer).")

;;;; ------------------------------------------------------------------
;;;; Rendering a message → an org document
;;;; ------------------------------------------------------------------

(defun cc-butler--decision-open-dir ()
  (let ((d (expand-file-name "open/" cc-butler-decision-dir)))
    (make-directory d t) d))

(defun cc-butler--decision-done-dir ()
  (let ((d (expand-file-name "done/" cc-butler-decision-dir)))
    (make-directory d t) d))

(defconst cc-butler--decision-org-re "\\`[^.].*\\.org\\'"
  "Match decision .org files, excluding dotfiles like lock files (.#foo.org).")

(defun cc-butler--decision-option-label (o)
  "Label string for option O (a string, or a plist (:label :tradeoff))."
  (if (stringp o) o (plist-get o :label)))

(defun cc-butler--decision-normalize (s)
  (downcase (string-trim (replace-regexp-in-string "[ \t\n]+" " " (or s "")))))

(defun cc-butler--decision-topic-key (msg)
  "A stable single-token key identifying \"the same decision\" for dedup.
From MSG's explicit :topic, else its normalized summary/body."
  (md5 (or (plist-get msg :topic)
           (cc-butler--decision-normalize
            (or (plist-get msg :summary) (plist-get msg :body) "")))))

(defun cc-butler--decision-when (id)
  "An absolute time string from ID's leading timestamp, or empty."
  (if (and id (string-match "\\`\\([0-9]\\{4\\}\\)\\([0-9][0-9]\\)\\([0-9][0-9]\\)T\\([0-9][0-9]\\)\\([0-9][0-9]\\)" id))
      (format "%s-%s-%s %s:%s" (match-string 1 id) (match-string 2 id)
              (match-string 3 id) (match-string 4 id) (match-string 5 id))
    ""))

(defun cc-butler--decision-envelope (msg)
  "An org PROPERTIES-drawer envelope (From/Via/To/When/Kind/Re) at the top of an
inbox document — the provenance graph edges made visible.  `From' is the ORIGIN
author (:origin, else :from) — never the last relayer; `Via' is the relay-path
(:via, a hop list or string) carried alongside, so origin and path both show."
  (let* ((kind (or (plist-get msg :kind) 'decision))
         (whenstr (cc-butler--decision-when (plist-get msg :id)))
         (re (plist-get msg :in-reply-to))
         (from (or (plist-get msg :origin) (plist-get msg :from) "?"))
         (via (plist-get msg :via)))
    (concat
     ":PROPERTIES:\n"                        ; the document's own org properties
     (format ":From: %s\n" from)
     (if via (format ":Via: %s\n" (cc-butler--via-string via)) "")
     (format ":To: %s\n" cc-butler-human-agent)
     (if (string-empty-p whenstr) "" (format ":When: %s\n" whenstr))
     (format ":Kind: %s%s\n" kind
             (cond ((eq kind 'decision) " — needs your answer (C-c C-c)")
                   ((eq kind 'briefing) " — result; read (r), c to reply")
                   ((memq kind '(note relay)) " — read (r to close)")
                   (t "")))
     (if re (format ":Re: %s\n" re) "")
     ":END:\n")))

(defun cc-butler--decision-sanitize (s)
  "Truncate free-text S at the first leaked raw tool-call-XML marker, if any.
cc-butler#N: callers occasionally pass a SUMMARY/NEEDS/option string that
already contains a fragment of raw Anthropic tool-call markup (`<invoke
...>', `<parameter name=\"...\">...'), apparently echoed rather than
authored content -- what produces it is upstream of this renderer and
unconfirmed. Stored verbatim, that fragment can fool a downstream reader
keying on body substrings instead of the document's own `:Kind:' property
(nearly closed 3 live decisions as inert notifications, 2026-09-03,
88/885 decision docs found contaminated on full sweep). There is nothing
genuine to recover past such a marker, so truncate rather than try to
parse or repair it."
  (if (and s (string-match "</?invoke\\b\\|</?parameter\\b" s))
      (string-trim (substring s 0 (match-beginning 0)))
    s))

(defun cc-butler--decision-doc-string (msg)
  "Return the org document text rendering decision MSG.
MSG: (:id :kind :from :reply-to :summary :needs :options).  `decision' kind is
answerable; `note'/`relay' render a read-only notification."
  (let* ((kind (or (plist-get msg :kind) 'decision))
         (id (or (plist-get msg :id) "?"))
         (to (or (plist-get msg :reply-to) (plist-get msg :from) "?"))
         (summary (cc-butler--decision-sanitize
                   (string-trim (or (plist-get msg :summary)
                                    (plist-get msg :body) ""))))
         (needs (cc-butler--decision-sanitize (plist-get msg :needs)))
         (from (plist-get msg :from))
         (options (plist-get msg :options))
         (first (car (split-string summary "\n"))))
    (with-temp-buffer
      (insert (cc-butler--decision-envelope msg))   ; file-level org properties at BOB
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
                                  (cc-butler--decision-sanitize
                                   (cc-butler--decision-option-label o))
                                  (if tr (format " — %s" (cc-butler--decision-sanitize tr)) "")))
                  (setq letter (1+ letter)))))
            (insert "\n" cc-butler--decision-answer-begin "\n")
            (let ((letter ?A))
              (dolist (_o options)
                (insert (format "- [ ] %c\n" letter))
                (setq letter (1+ letter))))
            (insert "Other: \n")
            (insert cc-butler--decision-answer-end "\n"))
        ;; note / relay / briefing — read-only, no answer region (reply is
        ;; optional via `c'); a briefing is a worker deliverable flowing UP.
        (insert (format "#+TITLE: %s — %s\n\n"
                        (if (eq kind 'briefing) "Briefing" "Note") first))
        (insert (format "* %s\n" (if (eq kind 'briefing)
                                     "Briefing (result — read, c to reply)"
                                   "Notification (read-only)"))
                summary "\n")
        (when from (insert (format "\n_(from %s)_\n" from))))
      (insert (format "\n# cc-butler decision id=%s to=%s topic=%s  (routing — do not edit)\n"
                      id to (cc-butler--decision-topic-key msg)))
      (buffer-string))))

(defun cc-butler--decision-render (msg &optional dir)
  "Render decision MSG to a timestamped file in DIR; return the path.
DIR defaults to open/.  For any `:kind' other than `decision' the
filename gets a `.KIND' suffix before `.org' (e.g. `ID.note.org'), so
`cc-butler--decision-file-kind' can classify open/ documents -- e.g.
to exclude a note/relay from the answer-required backlog count -- from
the filename alone, with no file content read."
  (let* ((id (or (plist-get msg :id) (cc-butler--mail-id)))
         (msg (plist-put msg :id id))
         (kind (or (plist-get msg :kind) 'decision))
         (file (expand-file-name
                (if (eq kind 'decision) (format "%s.org" id)
                  (format "%s.%s.org" id kind))
                (or dir (cc-butler--decision-open-dir)))))
    (with-temp-file file (insert (cc-butler--decision-doc-string msg)))
    file))

(defun cc-butler-decision-refresh ()
  "Drain the human node's inbox and render each decision as an open/ document,
deduplicating by topic (`cc-butler--decision-ingest') the same way arrival-driven
rendering does: a re-escalated topic supersedes its open doc (unless 정수님 is
mid-answer) and an already-answered topic is not resurfaced — so a topic that
arrives twice before this is called doesn't leave a stray duplicate behind, and
one already answered and archived doesn't reappear.  `note'/`relay' messages
render read-only; nothing is typed anywhere.  Returns the count of docs newly
surfaced (new or superseded)."
  (let ((msgs (cc-butler--ch-drain cc-butler-human-agent))
        (rendered 0))
    (dolist (m msgs)
      (when (memq (cdr (cc-butler--decision-ingest m)) '(new superseded))
        (setq rendered (1+ rendered))))
    rendered))

(defun cc-butler--decision-parse-options (s)
  "Parse an options STRING into a list of (:label :tradeoff) plists.
One option per line, `Label — tradeoff' (the tradeoff, after - or —, optional)."
  (when (and s (stringp s))
    (delq nil
          (mapcar
           (lambda (line)
             (let ((l (string-trim line)))
               (unless (string-empty-p l)
                 (if (string-match "\\`\\(.*?\\)[ \t]*[-—][ \t]+\\(.*\\)\\'" l)
                     (list :label (string-trim (match-string 1 l))
                           :tradeoff (string-trim (match-string 2 l)))
                   (list :label l)))))
           (split-string s "\n")))))

(defun cc-butler-decision-create (from-dir summary needs options &optional kind)
  "Deliver a decision, or (KIND `note') a read-only notification, to
정수님's inbox (the human-adapter create-path).
FROM-DIR is the escalating session; for a decision, 정수님's answer
returns to it via the correlation -- a note has no answer to
correlate, but FROM-DIR is still shown as the sender. OPTIONS is a
list of (:label :tradeoff), meaningful only for a decision. KIND
defaults to `decision'. Returns the id.
The arrival watcher renders it when the workflow is active."
  (let ((id (cc-butler--mail-id))
        (from (and from-dir (cc-butler--display-name from-dir))))
    (cc-butler--ch-deliver
     cc-butler-human-agent
     (list :id id :kind (or kind 'decision) :from from :reply-to from
           :summary summary :needs needs :options options))
    id))

(defun cc-butler-briefing-create (from-dir summary &optional via)
  "Deliver a worker BRIEFING (a result) UP to 정수님's inbox (the bus's
up-direction).  FROM-DIR is the worker (the ORIGIN, shown as `From', never a
relayer); VIA is the relay-path (a hop list/string, shown as `Via').  Renders
read-only (r to acknowledge) with an OPTIONAL reply (c) back to the worker.
Returns the id."
  (let ((id (cc-butler--mail-id))
        (from (and from-dir (cc-butler--display-name from-dir))))
    (cc-butler--ch-deliver
     cc-butler-human-agent
     (list :id id :kind 'briefing :from from :origin from :reply-to from
           :via via :summary summary))
    id))

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

(defun cc-butler--decision-notify-recipient (to)
  "Wake agent TO to drain its inbox for 정수님's answer — unless TO is the
butler (whose box stays clean; the human drives it).  The nudge is a signal
only; the answer itself travels in the maildir inbox (read via pending_events)."
  (unless (or (null to) (equal to "?") (equal to (cc-butler--mail-butler-agent)))
    (when-let ((dir (cc-butler--dir-by-name to)))
      (ignore-errors
        (cc-butler--send-input
         dir "[cc-butler] 정수님 answered a decision — run pending_events to read it." t)))))

(defun cc-butler--decision-cc-butler (summary &optional id)
  "CC a terse receipt SUMMARY to the butler's inbox so the butler stays COHERENT
with 정수님's decision state (visibility, not routing — never a hop that can drop
or delay the answer).  No-op if the butler is unset or is the human node itself."
  (let ((butler (cc-butler--mail-butler-agent)))
    (when (and butler (not (equal butler cc-butler-human-agent)))
      (cc-butler--ch-deliver
       butler (list :kind 'receipt :from cc-butler-human-agent
                    :in-reply-to id :body summary)))))

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
      (cc-butler--decision-notify-recipient to)
      (unless (equal to (cc-butler--mail-butler-agent))   ; butler already got the direct reply
        (cc-butler--decision-cc-butler
         (format "정수님 answered decision %s (routed to %s): %s" id to answer) id))
      (let ((file (buffer-file-name)))
        (when (and file (file-exists-p file))
          (let ((dest (expand-file-name (file-name-nondirectory file)
                                        (cc-butler--decision-done-dir))))
            (save-buffer)
            (rename-file file dest t)
            (set-visited-file-name dest nil t)))
        (set-buffer-modified-p nil))
      (cc-butler--decision-update-indicator)
      (run-hook-with-args 'cc-butler-decision-after-submit-functions
                          (list :to to :id id :answer answer))
      (message "cc-butler: answer sent to %s; decision archived to done/" to)
      answer)))

(defun cc-butler--decision-footer ()
  "Return (ID . TO) from the routing footer, or nil for a doc with no sender."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward "^# cc-butler decision id=\\(\\S-+\\) to=\\(\\S-+\\)" nil t)
      (cons (match-string 1) (match-string 2)))))

(defun cc-butler--decision-doc-title ()
  (save-excursion
    (goto-char (point-min))
    (if (re-search-forward "^#\\+TITLE: \\(.*\\)$" nil t) (match-string 1) "document")))

;;;###autoload
(defun cc-butler-decision-to-inbox ()
  "Go back to the inbox list from the reader (the reader is answer-only; item
navigation lives in the list)."
  (interactive)
  (if (fboundp 'cc-butler-inbox)
      (cc-butler-inbox)
    (quit-window)))

(defun cc-butler--decision-archive-current ()
  "Move the current decision file open/ → done/ (audit trail)."
  (let ((file (buffer-file-name)))
    (when (and file (file-exists-p file))
      (let ((dest (expand-file-name (file-name-nondirectory file)
                                    (cc-butler--decision-done-dir))))
        (ignore-errors (save-buffer))
        (rename-file file dest t)
        (set-visited-file-name dest nil t)))
    (set-buffer-modified-p nil)))

;;;###autoload
(defun cc-butler-decision-mark-read ()
  "Mark the current inbox document read: send a read-receipt to its sender.
For a `note'/`relay' this also closes it (open/ → done/).  A `decision' stays
open — only `C-c C-c' closes a decision (an unanswered decision is never lost).
A plain document with no sender is marked read locally (no receipt)."
  (interactive)
  (let ((footer (cc-butler--decision-footer))
        (decisionp (cc-butler--decision-answer-bounds)))
    (if (not footer)
        (progn (cc-butler--decision-update-indicator)
               (message "cc-butler: read (local — no sender to receipt)."))
      (let ((id (car footer)) (to (cdr footer)))
        (unless (equal to "?")
          (cc-butler--ch-deliver
           to (list :kind 'read :from cc-butler-human-agent :in-reply-to id
                    :body (format "read: %s" (cc-butler--decision-doc-title)))))
        (if decisionp
            (message "cc-butler: read-receipt sent to %s (decision stays open — answer with C-c C-c)." to)
          (cc-butler--decision-archive-current)
          (message "cc-butler: read — receipt sent to %s; archived." to))
        (cc-butler--decision-update-indicator)))))

;;;; ------------------------------------------------------------------
;;;; Doc-view operations (item 3) — confirm / navigate / quit
;;;; ------------------------------------------------------------------

(defun cc-butler-decision-confirm ()
  "Move point to the answer region so you can reply, then C-c C-c to send.
For a note/relay (no answer region) one is added, turning a read-only
notification into something you can comment on."
  (interactive)
  (let ((bounds (cc-butler--decision-answer-bounds)))
    (unless bounds
      (let ((inhibit-read-only t))
        (save-excursion
          (goto-char (point-min))
          (if (re-search-forward "^# cc-butler decision id=" nil t)
              (goto-char (line-beginning-position))
            (goto-char (point-max)))
          (insert "\n" cc-butler--decision-answer-begin "\nOther: \n"
                  cc-butler--decision-answer-end "\n"))
        (when (bound-and-true-p cc-butler-decision-mode) (cc-butler--decision-protect)))
      (setq bounds (cc-butler--decision-answer-bounds)))
    (when bounds (goto-char (car bounds)))
    (message "Edit your answer, then C-c C-c to send.")))

;;;; ---- dedicated-buffer compose (4b, org-edit-special style) --------

(defvar-local cc-butler--compose-source nil
  "The decision buffer a compose buffer writes back to.")

(defvar cc-butler-compose-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "C-c C-c") #'cc-butler-decision-compose-commit) ; the Emacs-conventional submit
    (define-key m (kbd "C-c '")   #'cc-butler-decision-compose-commit) ; org-edit-special alias
    (define-key m (kbd "C-c C-k") #'cc-butler-decision-compose-abort)
    m)
  "Keymap for `cc-butler-compose-mode'.")

(define-derived-mode cc-butler-compose-mode text-mode "cc-Compose"
  "Compose a cc-butler decision answer in a dedicated buffer; `C-c C-c' commits
it back into the decision document and sends it, `C-c C-k' aborts.")

(defun cc-butler-decision-compose ()
  "Answer this decision in a DEDICATED buffer opened as a bottom split (the
org-edit-special pattern): edit freely — no command-key collisions — then
`C-c C-c' writes it back into the answer region and sends it (sign & next)."
  (interactive)
  (let ((bounds (cc-butler--decision-answer-bounds)))
    (unless bounds (cc-butler-decision-confirm)
            (setq bounds (cc-butler--decision-answer-bounds)))
    (unless bounds (user-error "No answer region to compose"))
    (let ((content (buffer-substring-no-properties (car bounds) (cdr bounds)))
          (src (current-buffer))
          (cbuf (get-buffer-create "*cc-butler compose*")))
      (with-current-buffer cbuf
        (cc-butler-compose-mode)
        (let ((inhibit-read-only t)) (erase-buffer) (insert content))
        (setq cc-butler--compose-source src)
        (set-buffer-modified-p nil)
        (goto-char (point-min)))
      (let ((cwin (split-window (selected-window) nil 'below)))
        (set-window-buffer cwin cbuf)
        (select-window cwin))
      (message "Compose your answer; C-c C-c to send, C-c C-k to abort."))))

(defun cc-butler--compose-writeback (src content)
  "Replace SRC decision buffer's answer region with CONTENT (record)."
  (with-current-buffer src
    (let ((bounds (cc-butler--decision-answer-bounds))
          (inhibit-read-only t))
      (when bounds
        (delete-region (car bounds) (cdr bounds))
        (goto-char (car bounds))
        (insert content)
        (unless (bolp) (insert "\n")))
      (cc-butler--decision-protect))))

(defun cc-butler-decision-compose-commit ()
  "Write this compose buffer back into the decision and send it (one step)."
  (interactive)
  (let ((content (buffer-substring-no-properties (point-min) (point-max)))
        (src cc-butler--compose-source)
        (cbuf (current-buffer)))
    (unless (buffer-live-p src) (user-error "The decision buffer is gone"))
    (cc-butler--compose-writeback src content)
    (let ((win (get-buffer-window cbuf)))
      (when (and win (window-live-p win) (not (one-window-p))) (delete-window win)))
    (let ((kill-buffer-query-functions nil)) (kill-buffer cbuf))
    (with-current-buffer src (cc-butler-decision-submit)))) ; record + channel push + sign&next

(defun cc-butler-decision-compose-abort ()
  "Discard the compose buffer without sending."
  (interactive)
  (let ((win (get-buffer-window (current-buffer))))
    (when (and win (window-live-p win) (not (one-window-p))) (delete-window win)))
  (let ((kill-buffer-query-functions nil)) (kill-buffer))
  (message "cc-butler: compose aborted (nothing sent)."))

(defun cc-butler-decision-quit ()
  "Bury the decision view — the decision stays open in the queue (never deleted)."
  (interactive)
  (quit-window))

(defun cc-butler-decision-revert ()
  "Re-read the decision document from disk."
  (interactive)
  (when (buffer-file-name)
    (revert-buffer 'ignore-auto 'noconfirm)
    (cc-butler-decision-mode 1)))

(defun cc-butler--decision-open-files ()
  "Full paths of `decision'-kind documents in open/, sorted by filename
\(= arrival order\).  Excludes `note'/`relay'/`briefing' documents -- see
`cc-butler--decision-file-kind' -- so `n'/`p' navigation and
`cc-butler-decision-answer-next' never land on a document that has no
answer region to actually respond to."
  (seq-filter (lambda (f) (eq (cc-butler--decision-file-kind f) 'decision))
              (sort (ignore-errors (directory-files (cc-butler--decision-open-dir) t cc-butler--decision-org-re))
                    #'string<)))

(defun cc-butler--decision-move (step)
  (let* ((files (cc-butler--decision-open-files))
         (cur (and (buffer-file-name) (expand-file-name (buffer-file-name))))
         (idx (and cur (seq-position files cur #'equal))))
    (cond
     ((null files) (message "cc-butler: no open decisions."))
     ((null idx) (cc-butler--decision-display (car files)))
     (t (cc-butler--decision-display (nth (mod (+ idx step) (length files)) files))))))

(defun cc-butler-decision-next () "Next open decision." (interactive) (cc-butler--decision-move 1))
(defun cc-butler-decision-prev () "Previous open decision." (interactive) (cc-butler--decision-move -1))

;;;; ------------------------------------------------------------------
;;;; The decision-document minor mode (read-only + C-c C-c)
;;;; ------------------------------------------------------------------

(require 'hydra)

(declare-function cc-butler-doc-reopen "cc-butler-doc-panel" ())

;; NOTE: `defhydra' generates a docstring per -and-exit command from the hint;
;; those can exceed 80 cols regardless of the hint text — the only remaining
;; byte-compile warnings are this one cosmetic (a known hydra-macro artifact).
(defhydra cc-butler-decision-hydra (:color blue :hint nil)
  "
 answer-only:  _r_ead  _c_ompose  _u_ inbox
 _g_ reload  _q_ close  _v_ reopen  _k_ remove
"
  ("r" cc-butler-decision-mark-read)
  ("c" cc-butler-decision-compose)
  ("u" cc-butler-decision-to-inbox)
  ("k" cc-butler-decision-quit)
  ("g" cc-butler-decision-revert)
  ("q" cc-butler-decision-quit)
  ("v" cc-butler-doc-reopen)        ; the close (q) ⇄ reopen (v) pair, discoverable
  ("RET" cc-butler-decision-submit "submit")
  ("?" nil "cancel"))

(defvar cc-butler-decision-mode-map (make-sparse-keymap)
  "Keymap for `cc-butler-decision-mode'.")
;; Unified lowercase scheme; `?' opens the discoverable hydra of all of them.
(define-key cc-butler-decision-mode-map (kbd "C-c C-c") #'cc-butler-decision-submit)
(define-key cc-butler-decision-mode-map "r" #'cc-butler-decision-mark-read)
(define-key cc-butler-decision-mode-map "c" #'cc-butler-decision-compose)
(define-key cc-butler-decision-mode-map "k" #'cc-butler-decision-quit)
;; The reader is ANSWER-ONLY (surface model (b)): n/p move the cursor within the
;; doc; navigation BETWEEN items is the inbox list's job (i), not the reader's —
;; this removes the n-leak (in the reader `n' no longer jumps to another doc).
(define-key cc-butler-decision-mode-map "n" #'next-line)
(define-key cc-butler-decision-mode-map "p" #'previous-line)
;; u — back to the inbox list (정수님's dogfood: "U 누르면 뒤로 목록으로").
(define-key cc-butler-decision-mode-map "u" #'cc-butler-decision-to-inbox)
(define-key cc-butler-decision-mode-map "g" #'cc-butler-decision-revert)
(define-key cc-butler-decision-mode-map "q" #'cc-butler-decision-quit)
(define-key cc-butler-decision-mode-map "v" #'cc-butler-doc-reopen)
(define-key cc-butler-decision-mode-map "?" #'cc-butler-decision-hydra/body)

(defvar cc-butler--decision-compose-map
  (let ((m (make-sparse-keymap)))
    ;; Inside the answer region the bare command letters must TYPE, not fire —
    ;; otherwise an answer containing r/c/k/n/p/g/q/? loses characters to a
    ;; command (e.g. `k' quitting mid-word = a data-loss).  A `keymap' text
    ;; property out-ranks the minor-mode map, so this wins only in the region.
    (dolist (k '("r" "c" "k" "n" "p" "g" "q" "?"))
      (define-key m k #'self-insert-command))
    m)
  "Keymap layered on the answer region so command letters type normally.")

(defun cc-butler--decision-protect ()
  "Make everything outside the answer region read-only (integrity), and let the
bare command letters TYPE inside it (compose safety — a data-loss guard)."
  (let ((bounds (cc-butler--decision-answer-bounds))
        (inhibit-read-only t))
    (remove-text-properties (point-min) (point-max) '(read-only nil keymap nil))
    (if bounds
        (progn
          (add-text-properties (point-min) (car bounds) '(read-only t))
          (add-text-properties (cdr bounds) (point-max) '(read-only t))
          ;; compose region: letters self-insert (only C-c C-c submits)
          (add-text-properties (car bounds) (cdr bounds)
                               (list 'keymap cc-butler--decision-compose-map)))
      (add-text-properties (point-min) (point-max) '(read-only t)))))

(defun cc-butler--decision-in-compose-p ()
  "Non-nil when point is inside the editable answer region (compose mode)."
  (let ((b (cc-butler--decision-answer-bounds)))
    (and b (>= (point) (car b)) (< (point) (cdr b)))))

(defun cc-butler--decision-mode-lighter ()
  "Mode-line signal (guarantee 7): show whether keys TYPE or ACT right now."
  (if (cc-butler--decision-in-compose-p) " ✎compose" " ⌘cmd"))

;;;###autoload
(define-minor-mode cc-butler-decision-mode
  "Answer a cc-butler decision document: pick an option and/or write Other,
then \\[cc-butler-decision-submit].  Keeps org-mode (highlighting); the
decision text, option labels, and routing footer are read-only — only the
answer region is editable and parsed.  The mode-line shows the current mode —
`⌘cmd' (bare keys act) vs `✎compose' (keys type) — so a keystroke is never a
surprise."
  :lighter (:eval (cc-butler--decision-mode-lighter))
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

(defcustom cc-butler-decision-auto-display nil
  "When non-nil, a freshly-arrived decision is shown in a side window.
Default nil (guarantee 4): an arrival NEVER switches the view you are looking
at — especially while you are composing an answer — it only bumps the ⚖ unread
indicator (and the inbox list).  You navigate to new items yourself (`i' / n/p).
Leaving this nil is what protects an answer-in-progress from being interrupted."
  :type 'boolean
  :group 'cc-butler)

(defvar cc-butler--decision-indicator ""
  "Mode-line indicator string for open decisions (in `global-mode-string').")
(put 'cc-butler--decision-indicator 'risky-local-variable t)

(defvar cc-butler--decision-watch nil
  "The `file-notify' descriptor for 정수님's inbox, or nil.")

(defun cc-butler--decision-file-kind (filename)
  "Return the `:kind' symbol encoded in FILENAME, defaulting to `decision'.
Reads the `.KIND.org' suffix `cc-butler--decision-render' writes for any
non-`decision' kind -- from the name alone, no file content read.  A
plain `ID.org', including every file written before this encoding
existed, is `decision' -- correct, since all of those really were
decisions (see the governance note titled
escalate-to-butler-is-decision-only-a-notification-sent-through-it-never-closes)."
  (if (string-match "\\.\\(note\\|relay\\|briefing\\)\\.org\\'" filename)
      (intern (match-string 1 filename))
    'decision))

(defun cc-butler--decision-file-time (filename)
  "Parse FILENAME's leading id timestamp into a float-time, or nil if it
doesn't start with one.  Reads the same field `cc-butler--decision-when'
does (minute precision, no seconds), from the NAME alone -- no file
content read, so this stays cheap even at hundreds of files.  Filename
beats file mtime as an age source: `cc-butler--decision-ingest' deletes
and rewrites a file on `superseded', and an abandoned partial answer
touches mtime too, neither of which means \"raised again\"; the
filename is written once, at creation, and never rewritten."
  (when (string-match "\\`\\([0-9]\\{4\\}\\)\\([0-9][0-9]\\)\\([0-9][0-9]\\)T\\([0-9][0-9]\\)\\([0-9][0-9]\\)"
                       filename)
    (float-time (encode-time 0
                              (string-to-number (match-string 5 filename))
                              (string-to-number (match-string 4 filename))
                              (string-to-number (match-string 3 filename))
                              (string-to-number (match-string 2 filename))
                              (string-to-number (match-string 1 filename))))))

(defun cc-butler--decision-format-age (seconds)
  "Render SECONDS as a short age string: \"Nm\", \"Nh\", or \"Nd\"."
  (cond ((< seconds 3600) (format "%dm" (max 1 (round (/ seconds 60)))))
        ((< seconds 86400) (format "%dh" (round (/ seconds 3600))))
        (t (format "%dd" (round (/ seconds 86400))))))

(defun cc-butler--decision-open-files-and-oldest ()
  "Return (FILES . OLDEST-FLOAT-TIME-OR-NIL) for `decision'-kind documents
in the open/ dir -- the answer-required subset -- one `directory-files'
call shared by the indicator and the backlog line below so neither
re-lists the directory the other just listed.

A `note'/`relay'/`briefing' document renders read-only in this same
open/ directory (see `cc-butler--decision-render') but needs no answer,
so counting it here would reproduce, under a new label, the exact
backlog-inflation this counting feature exists to fix -- see the governance
note titled escalate-to-butler-is-decision-only-a-notification-sent-through-it-never-closes.
Classification reads the FILENAME only (`cc-butler--decision-file-kind'),
never file content, so this stays cheap even at hundreds of files and on
every arrival, where `cc-butler--decision-update-indicator' calls it."
  (let ((files (delq nil (mapcar (lambda (f) (and (eq (cc-butler--decision-file-kind f) 'decision) f))
                                  (ignore-errors (directory-files (cc-butler--decision-open-dir) nil
                                                                   cc-butler--decision-org-re))))))
    (cons files
          (let ((times (delq nil (mapcar #'cc-butler--decision-file-time files))))
            (and times (apply #'min times))))))

(defun cc-butler--decision-update-indicator ()
  "Set the mode-line indicator to the open-decision count plus the
oldest one's age, e.g. \" ⚖476 (oldest 41d)\"; return the count.

The age is not decorative: a bare count cannot distinguish a backlog
someone is actively working through from one nobody has looked at in
weeks, which is exactly what let the 2026-07-04 REFINEMENT-3 backlog
grow to hundreds of files unnoticed -- see governance
decision-proposal-format.md and this PR's body."
  (pcase-let ((`(,files . ,oldest) (cc-butler--decision-open-files-and-oldest)))
    (let ((n (length files)))
      (setq cc-butler--decision-indicator
            (if (> n 0)
                (format " ⚖%d%s" n
                        (if oldest
                            (format " (oldest %s)"
                                    (cc-butler--decision-format-age (- (float-time) oldest)))
                          ""))
              ""))
      (force-mode-line-update t)
      n)))

(defun cc-butler--decision-open-backlog-line ()
  "One-line, read-only summary of the open/ decision-doc backlog, or nil
when empty: count plus the oldest item's age, from filenames alone (no
file content read).  Exists so `cc-butler-tool-pending-decisions' can
stop asserting \"No pending decisions\" while decisions actually sit
in open/ -- see that function's docstring for why the two queues can
diverge.

This is a queued-duration signal, not a read/answered one: it cannot
tell a decision nobody has seen from one already answered elsewhere
and never moved to done/, or from a status report that never needed
an answer at all -- a manual sample of this backlog on 2026-08-13
found all three shapes mixed together. Treat it as \"worth a look\",
not as ground truth about what's actually pending."
  (pcase-let ((`(,files . ,oldest) (cc-butler--decision-open-files-and-oldest)))
    (when files
      (format "⚖ %d decision(s) queued in the open/ workflow (not this drain) — oldest %s ago; see decisions/open/ or the mode-line ⚖ indicator"
              (length files)
              (if oldest (cc-butler--decision-format-age (- (float-time) oldest)) "?")))))

(defun cc-butler--decision-display (file)
  "Show decision FILE in a side window without stealing focus."
  (let* ((create-lockfiles nil)
         (buf (find-file-noselect file)))
    (with-current-buffer buf (cc-butler-decision-mode 1))
    (display-buffer buf '(display-buffer-in-side-window (side . right)))))

;;;; dedup / supersede (item 2) — one open doc per topic ---------------

(defun cc-butler--decision-scan-dir (dir topic-key state)
  "Find a doc in DIR whose footer topic = TOPIC-KEY; return (FILE . STATE) or nil."
  (seq-some
   (lambda (f)
     (with-temp-buffer
       (insert-file-contents f)
       (goto-char (point-min))
       (when (re-search-forward (format "topic=%s\\b" (regexp-quote topic-key)) nil t)
         (cons f state))))
   (ignore-errors (directory-files dir t cc-butler--decision-org-re))))

(defun cc-butler--decision-find-by-topic (topic-key)
  "Return (FILE . STATE) for an existing doc of TOPIC-KEY (open takes precedence)."
  (or (cc-butler--decision-scan-dir (cc-butler--decision-open-dir) topic-key 'open)
      (cc-butler--decision-scan-dir (cc-butler--decision-done-dir) topic-key 'done)))

(defun cc-butler--decision-file-answered-p (file)
  "Non-nil if FILE's answer region already holds an in-progress answer."
  (with-temp-buffer
    (insert-file-contents file)
    (let ((p (ignore-errors (cc-butler--decision-parse))))
      (and p (or (plist-get p :selected) (plist-get p :other))))))

(defun cc-butler--decision-ingest (msg)
  "Render MSG, deduplicating by topic.  Return (FILE . DISPOSITION):
DISPOSITION is `new', `superseded', `kept' (an open doc 정수님 is answering —
not clobbered), or `skipped' (already answered → not resurfaced)."
  (let* ((topic (cc-butler--decision-topic-key msg))
         (existing (cc-butler--decision-find-by-topic topic)))
    (cond
     ((and existing (eq (cdr existing) 'done))
      (cons (car existing) 'skipped))
     ((and existing (eq (cdr existing) 'open)
           (cc-butler--decision-file-answered-p (car existing)))
      (cons (car existing) 'kept))
     ((and existing (eq (cdr existing) 'open))
      (ignore-errors (delete-file (car existing)))
      (cons (cc-butler--decision-render msg) 'superseded))
     (t (cons (cc-butler--decision-render msg) 'new)))))

(defun cc-butler--decision-on-arrival ()
  "Render newly-arrived inbox messages (dedup by topic) and refresh the indicator.
Arrival-driven: runs on an inbox change, independent of any agent turn.  Every
message renders to open/ as unread; a re-escalated topic supersedes its open doc
(unless 정수님 is mid-answer) and an already-answered topic is not resurfaced.
Returns the count of docs newly surfaced (new or superseded)."
  (let ((msgs (cc-butler--ch-drain cc-butler-human-agent))
        (surfaced '()))
    (dolist (m msgs)
      (let ((r (cc-butler--decision-ingest m)))
        (when (memq (cdr r) '(new superseded))
          (push (car r) surfaced)
          ;; CC the butler: a decision/note is now pending for 정수님 (visibility).
          (cc-butler--decision-cc-butler
           (format "Pending for 정수님: %s — %s [%s]"
                   (or (plist-get m :kind) 'decision)
                   (car (split-string (or (plist-get m :summary)
                                          (plist-get m :body) "") "\n"))
                   (plist-get m :id))
           (plist-get m :id))
          ;; Active PUSH to 정수님's real attention — the always-on daemon's job,
          ;; so a decision reaches them even while the butler agent is asleep.
          (when (and (eq (or (plist-get m :kind) 'decision) 'decision)
                     (fboundp 'cc-butler-notify-decision))
            (cc-butler-notify-decision
             "cc-butler — a decision needs you"
             (car (split-string (or (plist-get m :summary)
                                    (plist-get m :body) "") "\n")))))))
    (cc-butler--decision-update-indicator)
    (when (and surfaced cc-butler-decision-auto-display)
      (cc-butler--decision-display (car (last surfaced))))
    (length surfaced)))

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
  "Open the oldest open decision for answering, in `cc-butler-decision-mode'.
Renders any freshly-arrived decisions from the human inbox first.  Only
considers `decision'-kind documents (`cc-butler--decision-open-files') --
a `note'/`relay'/`briefing' has no answer region, so \"go to the next
thing that needs an answer\" must never land on one."
  (interactive)
  (cc-butler-decision-refresh)
  (let ((files (cc-butler--decision-open-files)))
    (if (null files)
        (message "cc-butler: no open decisions.")
      (let ((create-lockfiles nil)) (find-file (car files)))
      (cc-butler-decision-mode 1)
      (goto-char (point-min))
      (when (search-forward cc-butler--decision-answer-begin nil t)
        (forward-line 1)))))

;;;; ------------------------------------------------------------------
;;;; Demo — a self-contained, reversible walkthrough of the whole flow
;;;; ------------------------------------------------------------------
;;
;; `cc-butler-decision-demo' stages the full flow (arrival → indicator →
;; render → tick → C-c C-c → routing) in isolated temp directories with no
;; live wiring: it flips nothing permanent, touches no worker, and restores
;; every setting on exit (`cc-butler-decision-demo-end', run automatically
;; after you submit).  Meant to let 정수님 feel the UX before we wire it live.

(defvar cc-butler--decision-demo-state nil
  "Saved (mail-dir decision-dir human-agent) while a demo is staged.")

(defun cc-butler-decision-demo-end ()
  "End the staged demo: delete temp dirs, remove the hook, restore settings."
  (interactive)
  (remove-hook 'cc-butler-decision-after-submit-functions
               #'cc-butler--decision-demo-result)
  (when cc-butler--decision-demo-state
    (ignore-errors (delete-directory cc-butler-mail-dir t))
    (ignore-errors (delete-directory cc-butler-decision-dir t))
    (setq cc-butler-mail-dir (nth 0 cc-butler--decision-demo-state)
          cc-butler-decision-dir (nth 1 cc-butler--decision-demo-state)
          cc-butler-human-agent (nth 2 cc-butler--decision-demo-state)
          cc-butler--decision-demo-state nil))
  (cc-butler--decision-update-indicator))

(defun cc-butler--decision-demo-result (info)
  "Show the routed demo answer (INFO plist) in the demo buffer, then clean up."
  (let ((to (plist-get info :to)))
    (with-current-buffer (get-buffer-create "*cc-butler-decision-demo*")
      (goto-char (point-max))
      (let ((inhibit-read-only t))
        (insert (format "\n✓ answer routed to %s (in-reply-to %s):\n    %s\n"
                        to (plist-get info :id) (plist-get info :answer)))
        (let ((delivered (car (cc-butler--ch-drain to))))
          (insert (format "  → landed in %s's inbox as: kind=%s in-reply-to=%s\n"
                          to (plist-get delivered :kind)
                          (plist-get delivered :in-reply-to))))
        (insert "  → decision file moved open/ → done/ (audit trail)\n"
                "\nDemo complete; temp state cleaned up. Replay: M-x cc-butler-decision-demo\n"))))
  (cc-butler-decision-demo-end))

;;;###autoload
(defun cc-butler-decision-demo ()
  "Stage an isolated, reversible walkthrough of the decision workflow.
Delivers a sample decision (and a note) into a throwaway inbox, renders it
arrival-driven, and opens it for you to answer with C-c C-c.  Nothing live is
touched; end early with `cc-butler-decision-demo-end'."
  (interactive)
  (when (or (eq cc-butler-message-transport 'maildir) cc-butler--decision-watch)
    (user-error "Run the demo with B flag-off and the decision watcher stopped (to stay isolated)"))
  (when cc-butler--decision-demo-state (cc-butler-decision-demo-end))
  (setq cc-butler--decision-demo-state
        (list cc-butler-mail-dir cc-butler-decision-dir cc-butler-human-agent)
        cc-butler-mail-dir (file-name-as-directory (make-temp-file "cc-butler-demo-mail" t))
        cc-butler-decision-dir (file-name-as-directory (make-temp-file "cc-butler-demo-dec" t)))
  (add-hook 'cc-butler-decision-after-submit-functions #'cc-butler--decision-demo-result)
  (cc-butler--mail-file-deliver
   cc-butler-human-agent
   (list :id "demo-1" :kind 'decision :from "app-billing" :reply-to "app-billing"
         :summary "Which billing provider for the SaaS?"
         :needs "pick one; we can start in sandbox"
         :options '((:label "Stripe" :tradeoff "lower fees, great API")
                    (:label "Paddle" :tradeoff "merchant-of-record, handles VAT")
                    (:label "other"))))
  (cc-butler--mail-file-deliver
   cc-butler-human-agent
   (list :id "demo-note" :kind 'note :from "steward" :summary "FYI: CI is green on main."))
  (let ((cc-butler-decision-auto-display t))   ; the demo explicitly shows the doc
    (cc-butler--decision-on-arrival))
  (with-current-buffer (get-buffer-create "*cc-butler-decision-demo*")
    (erase-buffer)
    (insert "cc-butler decision workflow — DEMO  (isolated · reversible · nothing live)\n"
            "========================================================================\n\n"
            "1. ARRIVAL → RENDER → INDICATOR (Emacs-native, no agent turn):\n"
            "   A decision just 'arrived' in your inbox and was rendered automatically.\n"
            (format "   Mode-line now shows:  %s   (⚖N = N open decisions)\n"
                    (string-trim cc-butler--decision-indicator))
            "   The decision opened in a side window — org highlighting, and read-only\n"
            "   everywhere except the answer region (the integrity guarantee).\n"
            "   (The `note' message rendered read-only in open/ too, but the ⚖ count\n"
            "   above only counts answer-required decisions -- it's excluded. `r' closes\n"
            "   it to done/, same mechanism as a decision, just no answer required.)\n\n"
            "2. ANSWER (your turn — the conversation half):\n"
            "   In the decision buffer:\n"
            "     a. tick an option:  - [ ] A   →   - [X] A\n"
            "     b. optionally type after `Other:'\n"
            "     c. press  C-c C-c\n\n"
            "3. ROUTING: your answer returns to the asking session (app-billing)\n"
            "   via the maildir correlation, and the file moves open/ → done/.\n\n"
            "   End anytime:  M-x cc-butler-decision-demo-end\n"
            "   ------------------------------------------------------------------\n")
    (setq buffer-read-only t)
    (display-buffer (current-buffer)))
  (message "cc-butler demo staged — tick an option and press C-c C-c in the decision buffer."))

(provide 'cc-butler-decision)
;;; cc-butler-decision.el ends here
