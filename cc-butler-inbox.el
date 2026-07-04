;;; cc-butler-inbox.el --- 정수님's inbox: the pending queue (Option C)  -*- lexical-binding: t; -*-

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

(defun cc-butler-inbox-items ()
  "Return the pending inbox queue — 정수님's OPEN decision/note documents, oldest
first (filename = timestamp order).  Each item is a plist:
  (:file FILE :title TITLE :kind decision|note :answerable BOOL)
`answerable' is non-nil for decisions (need a C-c C-c answer); notes are closed
by the read-receipt `r'.  Reference documents are NOT queued here."
  (mapcar
   (lambda (f)
     (let* ((title (cc-butler--inbox-title f))
            (decisionp (string-prefix-p "Decision" title)))
       (list :file f :title title
             :kind (if decisionp 'decision 'note)
             :answerable decisionp)))
   (sort (ignore-errors
           (directory-files (cc-butler--decision-open-dir) t cc-butler--decision-org-re))
         #'string<)))

(defun cc-butler-inbox-count ()
  "Number of pending inbox items (the unread badge count)."
  (length (cc-butler-inbox-items)))

;;;; ------------------------------------------------------------------
;;;; The inbox list surface (browse the pending queue)
;;;; ------------------------------------------------------------------

(defvar cc-butler-inbox-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "RET") #'cc-butler-inbox-open)
    (define-key m "n" #'next-line)
    (define-key m "p" #'previous-line)
    (define-key m "g" #'cc-butler-inbox-refresh)
    (define-key m "q" #'quit-window)
    m)
  "Keymap for `cc-butler-inbox-mode'.")

(define-derived-mode cc-butler-inbox-mode special-mode "cc-Inbox"
  "정수님's inbox — the pending queue of decisions and notes to attend to.")

(defun cc-butler--inbox-render ()
  "Render the pending queue into the current buffer as a read-only list."
  (let ((inhibit-read-only t) (items (cc-butler-inbox-items)))
    (erase-buffer)
    (insert (format "cc-butler inbox — %d pending   (RET open · n/p move · g refresh · q quit)\n\n"
                    (length items)))
    (if (null items)
        (insert "  (empty — nothing awaiting you)\n")
      (dolist (it items)
        (insert (propertize
                 (format "  %s  %s\n"
                         (if (eq (plist-get it :kind) 'decision) "⚖ decide" "• note  ")
                         (plist-get it :title))
                 'cc-butler-inbox-file (plist-get it :file)))))
    (goto-char (point-min))
    (forward-line (if items 2 0))))

(defun cc-butler-inbox-refresh ()
  "Re-read the pending queue into the inbox list."
  (interactive)
  (when (derived-mode-p 'cc-butler-inbox-mode) (cc-butler--inbox-render)))

;;;###autoload
(defun cc-butler-inbox ()
  "Open 정수님's inbox — the pending queue of decisions and notes."
  (interactive)
  (let ((buf (get-buffer-create "*cc-butler-inbox*")))
    (with-current-buffer buf
      (unless (derived-mode-p 'cc-butler-inbox-mode) (cc-butler-inbox-mode))
      (cc-butler--inbox-render))
    (pop-to-buffer buf)))

(defun cc-butler-inbox-open ()
  "Open the inbox item at point for reading/answering (the reading surface)."
  (interactive)
  (let ((file (get-text-property (point) 'cc-butler-inbox-file)))
    (if (not file)
        (message "cc-butler: no inbox item on this line")
      (let ((create-lockfiles nil)) (find-file file))
      (cc-butler-decision-mode 1))))

(with-eval-after-load 'cc-butler-session
  (when (boundp 'cc-butler-mode-map)
    (define-key cc-butler-mode-map "i" #'cc-butler-inbox)))

(provide 'cc-butler-inbox)
;;; cc-butler-inbox.el ends here
