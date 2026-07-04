;;; cc-butler-provenance.el --- relay fidelity: verbatim + resolvable refs  -*- lexical-binding: t; -*-

;; Provenance layer (SDD: docs/cc-butler-provenance-sdd.md).  A relay must not
;; degrade 정수님's words into a summary of a summary.  Every dispatch carries a
;; DIGEST (act on this) plus a RESOLVABLE REFERENCE to the verbatim original
;; (open when precision matters) — progressive disclosure, on the maildir bricks
;; (id-addressable documents in the human adapter's done/).
;;
;; 정수님's confirmed choices: appendix inline-if-short / link-if-long;
;; resolution by maildir id; worker-open = the file.

(require 'cc-butler-decision)
(require 'subr-x)

(defcustom cc-butler-provenance-inline-max 600
  "Attach the verbatim original inline below this length; above it, a resolvable
reference the worker opens on demand (progressive disclosure)."
  :type 'integer
  :group 'cc-butler)

(defun cc-butler--provenance-find (id)
  "Return the verbatim source file for reference ID — the id-named decision
document in the human adapter's done/ (or open/), or nil."
  (seq-some
   (lambda (dir)
     (car (ignore-errors
            (directory-files dir t (concat (regexp-quote id) ".*\\.org\\'")))))
   (list (cc-butler--decision-done-dir) (cc-butler--decision-open-dir))))

(defun cc-butler-provenance-resolve (id)
  "Return the VERBATIM original document for reference ID (worker-open = its
text), or nil if not found."
  (when-let ((f (cc-butler--provenance-find id)))
    (with-temp-buffer (insert-file-contents f) (buffer-string))))

(defun cc-butler-provenance-enrich (digest id verbatim)
  "Build a dispatch: DIGEST + a resolvable reference to the verbatim original ID.
The verbatim is attached INLINE when short, else replaced by a resolvable link
(progressive disclosure) — 정수님's exact words are never re-summarized away."
  (concat
   digest
   (format "\n\n--- provenance · ref=%s ---\n" id)
   (if (and verbatim (<= (length verbatim) cc-butler-provenance-inline-max))
       (format "정수님 (verbatim):\n%s\n" (string-trim verbatim))
     (format "정수님's verbatim answer is long — open it with: resolve_reference(%s)\n" id))))

(defun cc-butler-tool-resolve-reference (ref)
  "MCP tool: open the VERBATIM original 정수님 approval/answer for a provenance
REF (the id from a dispatch's `ref='), so you act on the exact words, not a
digest."
  (or (cc-butler-provenance-resolve (string-trim (or ref "")))
      (format "No verbatim source found for reference %s." ref)))

;; Idempotent registration.
(when (fboundp 'claude-code-ide-make-tool)
  (setq claude-code-ide-mcp-server-tools
        (seq-remove
         (lambda (spec)
           (member (plist-get (claude-code-ide--normalize-tool-spec spec) :name)
                   '("resolve_reference")))
         claude-code-ide-mcp-server-tools))
  (claude-code-ide-make-tool
   :function #'cc-butler-tool-resolve-reference
   :name "resolve_reference"
   :description "Open the VERBATIM original of 정수님's decision/approval that a dispatch references (pass the id from the dispatch's 'ref='). Use it when you need 정수님's exact words, not just the digest you were given — the dispatch carries a digest for quick action and this resolves the ground truth (progressive disclosure)."
   :args '((:name "ref" :type string
                  :description "The provenance reference id from the dispatch (its `ref=' value)."))))

(provide 'cc-butler-provenance)
;;; cc-butler-provenance.el ends here
