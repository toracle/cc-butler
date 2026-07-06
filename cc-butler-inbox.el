;;; cc-butler-inbox.el --- 정수님's inbox: the pending queue (Option C)  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jeongsoo Park
;; SPDX-License-Identifier: MIT

;; The inbox is the *pending queue* half of the documents↔inbox coexistence
;; model (Option C, docs/cc-butler-inbox-vs-documents-ux.md): a browsable index
;; of the push/transient items 정수님 must attend to — the open decision and note
;; documents — that FEEDS the one reading surface (the doc-view panel).  Handled
;; items move to done/ and stay re-referenceable; reference documents are opened
;; into the reader directly and are not queued here.
;;
;; This file is the data layer (the queue as data, testable without any UI); the
;; list surface, the `i' entry, and dedicated-buffer compose land on top of it.

(require 'cc-butler-decision)
(require 'subr-x)

(defun cc-butler--inbox-title (file)
  "The #+TITLE of decision/note FILE, or its base name."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (if (re-search-forward "^#\\+TITLE: \\(.*\\)$" nil t)
        (string-trim (match-string 1))
      (file-name-base file))))

(defun cc-butler--inbox-dir (folder)
  "The directory backing inbox FOLDER: `unread' = open/, `archive' = done/."
  (if (eq folder 'archive) (cc-butler--decision-done-dir) (cc-butler--decision-open-dir)))

(defun cc-butler-inbox-items (&optional folder)
  "Return the inbox items in FOLDER, oldest first (filename = timestamp order).
FOLDER is `unread' (the open/ pending queue, default) or `archive' (done/, the
handled items, re-referenceable — email-folder style).  Each item is a plist:
  (:file FILE :title TITLE :kind decision|note :answerable BOOL)
`answerable' is non-nil for decisions; reference documents are NOT queued here."
  (mapcar
   (lambda (f)
     (let* ((title (cc-butler--inbox-title f))
            (decisionp (string-prefix-p "Decision" title)))
       (list :file f :title title
             :kind (if decisionp 'decision 'note)
             :answerable decisionp)))
   (sort (ignore-errors
           (directory-files (cc-butler--inbox-dir (or folder 'unread))
                            t cc-butler--decision-org-re))
         #'string<)))

(defun cc-butler-inbox-count ()
  "Number of UNREAD inbox items (the badge count — open/ only)."
  (length (cc-butler-inbox-items 'unread)))

;;;; ------------------------------------------------------------------
;;;; The inbox list surface (browse the pending queue)
;;;; ------------------------------------------------------------------

(defun cc-butler-inbox-next ()
  "Move to the next inbox entry.
Each entry is exactly one logical buffer line (see `cc-butler--inbox-render'),
so this moves by `forward-line' rather than `next-line' — a long title that
soft-wraps across several screen rows still takes exactly one press to clear,
instead of one press per wrapped row."
  (interactive)
  (forward-line 1))

(defun cc-butler-inbox-prev ()
  "Move to the previous inbox entry (see `cc-butler-inbox-next')."
  (interactive)
  (forward-line -1))

(defvar cc-butler-inbox-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "RET") #'cc-butler-inbox-open)
    (define-key m "n" #'cc-butler-inbox-next)
    (define-key m "p" #'cc-butler-inbox-prev)
    (define-key m "f" #'cc-butler-inbox-cycle-folder)
    (define-key m "g" #'cc-butler-inbox-refresh)
    (define-key m "q" #'quit-window)
    m)
  "Keymap for `cc-butler-inbox-mode'.")

;; Top-level so a hot-load (which won't re-init the defvar keymap) still binds it.
(define-key cc-butler-inbox-mode-map "f" #'cc-butler-inbox-cycle-folder)

(defvar-local cc-butler-inbox-folder 'unread
  "Which folder the inbox list shows: `unread' (open/) or `archive' (done/).")

(define-derived-mode cc-butler-inbox-mode special-mode "cc-Inbox"
  "정수님's inbox — the pending queue of decisions and notes to attend to.")

(defun cc-butler--inbox-render ()
  "Render the current inbox folder into the buffer as a read-only list."
  (let* ((inhibit-read-only t)
         (folder (or cc-butler-inbox-folder 'unread))
         (items (cc-butler-inbox-items folder)))
    (erase-buffer)
    (insert (format "cc-butler inbox — [%s] %d   (RET open · n/p move · f folder · g refresh · q quit)\n\n"
                    folder (length items)))
    (if (null items)
        (insert (format "  (empty — no %s items)\n" folder))
      (dolist (it items)
        (insert (propertize
                 (format "  %s  %s\n"
                         (if (eq (plist-get it :kind) 'decision) "⚖ decide" "• note  ")
                         (plist-get it :title))
                 'cc-butler-inbox-file (plist-get it :file)))))
    (goto-char (point-min))
    (forward-line (if items 2 0))))

(defun cc-butler-inbox-refresh ()
  "Re-read the current folder into the inbox list."
  (interactive)
  (when (derived-mode-p 'cc-butler-inbox-mode) (cc-butler--inbox-render)))

(defun cc-butler-inbox-cycle-folder ()
  "Switch the inbox between unread (open/) and archive (done/) — email-folder
style; unread is the default and always one keystroke away."
  (interactive)
  (when (derived-mode-p 'cc-butler-inbox-mode)
    (setq cc-butler-inbox-folder (if (eq cc-butler-inbox-folder 'archive) 'unread 'archive))
    (cc-butler--inbox-render)))

;;;###autoload
(defun cc-butler-inbox ()
  "Open 정수님's inbox — the pending queue of decisions and notes."
  (interactive)
  (let ((buf (get-buffer-create "*cc-butler-inbox*")))
    (with-current-buffer buf
      (unless (derived-mode-p 'cc-butler-inbox-mode) (cc-butler-inbox-mode))
      (cc-butler--inbox-render))
    (pop-to-buffer buf)))

(defvar-local cc-butler--inbox-opened nil
  "Non-nil in a doc buffer opened from the inbox — drives sign & next.")

(defun cc-butler-inbox-open ()
  "Open the inbox item at point for reading/answering (the reading surface)."
  (interactive)
  (let ((file (get-text-property (point) 'cc-butler-inbox-file)))
    (if (not file)
        (message "cc-butler: no inbox item on this line")
      (let ((create-lockfiles nil)) (find-file file))
      (cc-butler-decision-mode 1)
      (setq-local cc-butler--inbox-opened t))))

(defun cc-butler--inbox-sign-and-next (_info)
  "Sign & next: after answering an inbox-opened decision, drop it from view and
return to the inbox list (now one fewer) — \"sign, next; sign, next\".  Only
fires for inbox-opened docs, so other flows (e.g. the demo) are untouched."
  (when cc-butler--inbox-opened
    (let ((buf (current-buffer)) (kill-buffer-query-functions nil))
      (run-at-time
       0 nil
       (lambda ()
         (when (buffer-live-p buf) (ignore-errors (kill-buffer buf)))
         (cc-butler-inbox))))))

(add-hook 'cc-butler-decision-after-submit-functions #'cc-butler--inbox-sign-and-next)

(with-eval-after-load 'cc-butler-session
  (when (boundp 'cc-butler-mode-map)
    (define-key cc-butler-mode-map "i" #'cc-butler-inbox)))

(provide 'cc-butler-inbox)
;;; cc-butler-inbox.el ends here
