;;; capture-showcase.el --- render cc-butler surfaces to HTML  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jeongsoo Park
;; SPDX-License-Identifier: MIT

;; Generate the README showcase assets by rendering each cc-butler surface and
;; htmlize-ing it (faces → CSS), so the capture is faithful and works headless
;; (the daemon frames are terminal — window-system nil — so x-export-frames→PNG
;; is not available; htmlize is).  For PNGs, open a surface in a GUI Emacs and
;; screenshot, or render these HTML files in a browser.
;;
;;   emacs -Q --batch -l docs/showcase/capture-showcase.el

(let ((root (file-name-directory
             (directory-file-name
              (file-name-directory
               (directory-file-name
                (file-name-directory (or load-file-name buffer-file-name))))))))
  (add-to-list 'load-path root)
  (let ((elpa (expand-file-name "~/.emacs.d/elpa")))
    (when (file-directory-p elpa)
      (dolist (d (directory-files elpa t "\\`[^.]"))
        (when (file-directory-p d) (add-to-list 'load-path d))))))

(require 'cc-butler-decision)
(require 'cc-butler-inbox)
(require 'htmlize)

(defvar cc-showcase-dir
  (file-name-directory (or load-file-name buffer-file-name)))

(defun cc-showcase--write (buffer name)
  "htmlize BUFFER and write it to NAME.html in the showcase dir."
  (with-current-buffer buffer
    (font-lock-ensure)
    (let ((html (htmlize-buffer)))
      (with-current-buffer html
        (write-region (point-min) (point-max)
                      (expand-file-name (concat name ".html") cc-showcase-dir)
                      nil 'silent))
      (kill-buffer html)))
  (princ (format "captured: %s.html\n" name)))

(defun cc-showcase--org (doc name)
  "Render org DOC text in a temp buffer and capture it as NAME."
  (with-temp-buffer
    (insert doc)
    (org-mode)
    (cc-showcase--write (current-buffer) name)))

;; 1. An answerable decision (envelope From/Via + options + answer region).
(cc-showcase--org
 (cc-butler--decision-doc-string
  '(:id "20260704T1930-1-0072" :kind decision :from "worker-monocle"
    :origin "worker-monocle" :via ("worker-monocle" "steward")
    :summary "Ship the payment flow to staging?"
    :options ("Yes — deploy to staging now" "Hold — needs another review")))
 "decision")

;; 2. An up-direction briefing (worker deliverable, read-only + optional reply).
(cc-showcase--org
 (cc-butler--decision-doc-string
  '(:id "20260704T1935-1-0073" :kind briefing :from "worker-monocle"
    :origin "worker-monocle" :via ("worker-monocle" "steward")
    :summary "Payment flow deployed to staging; smoke tests green (12/12)."))
 "briefing")

;; 3. The inbox list surface (with a couple of sample items).
(let ((cc-butler-decision-dir (make-temp-file "cc-showcase" t)))
  (unwind-protect
      (progn
        (cc-butler--decision-render
         '(:id "20260704T1930-1-0072" :kind decision :from "worker-monocle"
           :summary "Ship the payment flow to staging?" :options ("Yes" "Hold")))
        (cc-butler--decision-render
         '(:id "20260704T1936-1-0074" :kind note :from "steward"
           :summary "CI is green on main after the merge."))
        (with-current-buffer (get-buffer-create "*showcase-inbox*")
          (let ((inhibit-read-only t)) (erase-buffer))
          (cc-butler-inbox-mode)
          (cc-butler--inbox-render)
          (cc-showcase--write (current-buffer) "inbox")))
    (delete-directory cc-butler-decision-dir t)))

;;; capture-showcase.el ends here
