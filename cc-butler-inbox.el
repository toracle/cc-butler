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

(provide 'cc-butler-inbox)
;;; cc-butler-inbox.el ends here
