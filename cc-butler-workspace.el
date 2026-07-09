;;; cc-butler-workspace.el --- Topic workspace scaffolding for cc-butler  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jeongsoo Park
;; SPDX-License-Identifier: MIT

;; Create a "topic workspace" for a known project and drop straight into a
;; Claude session there.  A topic workspace is a plain (non-git) directory
;; that holds one or more checked-out repos plus two markers:
;;
;;   .projectile  -- makes projectile treat the topic dir as one project, so
;;                   all sibling repos are visible without /add-dir, and the
;;                   session manager names the session after the topic.
;;   CLAUDE.md    -- a thin file that @-imports the meta repo's shared docs
;;                   (CLAUDE.md / DESIGN.md), so launching Claude at the topic
;;                   dir loads the project's architecture at startup.
;;
;; The layout differs per project, so it lives in DATA: a template registry.
;; A project template knows the meta repo URL and the import list; adding
;; another project is just another entry.  An "arbitrary" choice falls back to
;; `cc-butler-new-session' (pick a directory, start a session, no scaffolding).
;;
;; Entry point: M-x cc-butler-new-topic  (also `t' in the cc-butler hydra,
;; `N' in the session-manager buffer).

(require 'cc-butler-session)

(defvar cc-butler-project-templates nil
  "Registry of project templates for `cc-butler-new-topic'.
Populated by `cc-butler-define-project-template' — the package ships EMPTY and
hard-codes no real repositories; you register your own templates in your own
private config.")

;;;###autoload
(defmacro cc-butler-define-project-template (name &rest plist)
  "Register project template NAME (a symbol) for `cc-butler-new-topic'.
PLIST keys:
  :base-dir       directory under which topic workspaces are created
  :dir-format     `format' string for the topic dir name; %s = topic name
  :repos          list of git URLs to clone into the topic dir; the first is
                  the meta repo (its local name is used for :claude-import)
  :claude-import  paths (relative to the topic dir) to @-import in the
                  generated CLAUDE.md, e.g. \"app/DESIGN.md\"

Put your own templates in your private config (not in this package), e.g. in
your init:

  (cc-butler-define-project-template myproject
    :base-dir \"~/projects\" :dir-format \"myproject-%s\"
    :repos (\"git@github.com:me/myproject.git\")
    :claude-import (\"myproject/CLAUDE.md\"))"
  (declare (indent 1))
  `(setf (alist-get ',name cc-butler-project-templates) ',plist))

(defun cc-butler--template (name)
  "Return the template plist for NAME (a symbol), or nil."
  (alist-get name cc-butler-project-templates))

(defun cc-butler--repo-local-name (url)
  "Return the local clone directory name for a git URL.
\"git@github.com:org/app.git\" -> \"app\"."
  (let ((name (file-name-nondirectory (directory-file-name url))))
    (if (string-suffix-p ".git" name)
        (substring name 0 -4)
      name)))

(defun cc-butler--topic-dir (template topic)
  "Return the absolute topic-workspace directory for TEMPLATE and TOPIC."
  (file-name-as-directory
   (expand-file-name
    (format (plist-get template :dir-format) topic)
    (expand-file-name (plist-get template :base-dir)))))

(defvar cc-butler-scaffold-functions nil
  "Abnormal hook run after a topic workspace is scaffolded.
Each function receives (TOPIC-DIR TEMPLATE).  A generic seam for site or
optional-feature setup that must ride new-worker creation without core knowing
about it — e.g. the session cleaner installs its context-reporting statusLine
here.  Run with `run-hook-with-args'.")

(defun cc-butler--scaffold (topic-dir template)
  "Write `.projectile' and `CLAUDE.md' markers into TOPIC-DIR (idempotent).
Existing files are never clobbered.
Runs `cc-butler-scaffold-functions' with (TOPIC-DIR TEMPLATE) at the end."
  (let ((proj (expand-file-name ".projectile" topic-dir))
        (cmd  (expand-file-name "CLAUDE.md" topic-dir)))
    (unless (file-exists-p proj)
      (write-region "" nil proj nil 'silent))
    (unless (file-exists-p cmd)
      (let ((imports (plist-get template :claude-import))
            (topic (file-name-nondirectory (directory-file-name topic-dir))))
        (with-temp-file cmd
          (insert (format "# %s workspace\n\n" topic))
          (insert "Shared architecture and conventions, imported from the meta repo:\n\n")
          (dolist (imp imports)
            (insert (format "@%s\n" imp)))
          (insert "\n## Reporting up (cc-butler)\n\n")
          (insert "This session may run as a *worker* under cc-butler orchestration. When you\n")
          (insert "finish a task, get blocked, or need a human decision, call the\n")
          (insert "`report_to_steward` tool with real content — `summary` (what you did /\n")
          (insert "what happened), `status` (current state), and `needs` (what you need from\n")
          (insert "the human, or omit if just informing). Keep it concise; the steward (or the\n")
          (insert "butler, in single mode) triages it and escalates to the human only when a\n")
          (insert "decision is actually needed.\n")
          (insert "\n## Delegating to sub-agents\n\n")
          (insert "Treat delegation as your default working mode, not the exception. When a\n")
          (insert "task means more than skimming a file — reading long session output or logs,\n")
          (insert "searching across many files, carrying out a multi-step investigation,\n")
          (insert "analysis, or review, or running a self-contained job where only the result\n")
          (insert "matters — hand it to a sub-agent and keep only the distilled conclusion in\n")
          (insert "this window. Working directly here is reserved for the cases that genuinely\n")
          (insert "need it: when you need the content itself for your very next action (a `Read`\n")
          (insert "before an `Edit`, or scoping a change), when the work is small and fast, or\n")
          (insert "when a tight loop would lose more to round-trips than it saves. The reason\n")
          (insert "is simple — re-reading accumulated context is the single largest cost\n")
          (insert "driver, so this window stays a thin coordination layer while the raw\n")
          (insert "material lives in the sub-agents you dispatch.\n"))))
    (run-hook-with-args 'cc-butler-scaffold-functions topic-dir template)
    topic-dir))

(defun cc-butler--start-session-in (dir)
  "Start a Claude session with DIR as the working directory.
Routes through `cc-butler--launch-session' — the single launch+config path all
roles share — so worker, butler, and steward ghostel config cannot diverge."
  (cc-butler--launch-session dir))

(defun cc-butler--clone-repos (topic-dir repos done-fn)
  "Clone REPOS into TOPIC-DIR sequentially and asynchronously.
Each already-present repo is skipped.  On completion DONE-FN is called
with t (all succeeded) or nil (a clone failed)."
  (if (null repos)
      (funcall done-fn t)
    (let* ((url (car repos))
           (rest (cdr repos))
           (name (cc-butler--repo-local-name url))
           (dest (expand-file-name name topic-dir)))
      (if (file-directory-p dest)
          (cc-butler--clone-repos topic-dir rest done-fn)
        (let ((default-directory (file-name-as-directory topic-dir))
              (buf (generate-new-buffer (format " *cc-butler-clone:%s*" name))))
          (message "cc-butler: cloning %s ..." url)
          (make-process
           :name (format "cc-butler-clone-%s" name)
           :buffer buf
           :command (list "git" "clone" url name)
           :noquery t
           :sentinel
           (lambda (proc _event)
             (when (memq (process-status proc) '(exit signal))
               (if (eq 0 (process-exit-status proc))
                   (progn
                     (when (buffer-live-p buf) (kill-buffer buf))
                     (cc-butler--clone-repos topic-dir rest done-fn))
                 (message "cc-butler: `git clone %s' failed — see %s"
                          url (buffer-name buf))
                 (funcall done-fn nil))))))))))

(defun cc-butler--finish-topic (topic-dir template)
  "Scaffold TOPIC-DIR, start a session there, and open the manager."
  (cc-butler--scaffold topic-dir template)
  (cc-butler--start-session-in topic-dir)
  (cc-butler))

;;;###autoload
(defun cc-butler-new-topic ()
  "Create a topic workspace from a template and start a Claude session in it.
Prompts for a template (or `arbitrary', which delegates to
`cc-butler-new-session') and a topic name, clones the template's repos if
needed, scaffolds the markers, and launches Claude at the topic dir."
  (interactive)
  (let* ((names (append (mapcar (lambda (e) (symbol-name (car e)))
                                cc-butler-project-templates)
                        '("arbitrary")))
         (choice (completing-read "Workspace template: " names nil t)))
    (if (equal choice "arbitrary")
        (call-interactively #'cc-butler-new-session)
      (let* ((template (cc-butler--template (intern choice)))
             (topic (string-trim (read-string (format "%s topic name: " choice)))))
        (when (string-empty-p topic)
          (user-error "Topic name must not be empty"))
        (when (string-match-p "[/ \t]" topic)
          (user-error "Topic name must not contain spaces or slashes: %S" topic))
        (let* ((topic-dir (cc-butler--topic-dir template topic))
               (repos (plist-get template :repos))
               (meta-dir (expand-file-name
                          (cc-butler--repo-local-name (car repos)) topic-dir)))
          (make-directory topic-dir t)
          (if (file-directory-p meta-dir)
              ;; Already cloned — just scaffold (idempotent) and start.
              (cc-butler--finish-topic topic-dir template)
            (cc-butler--clone-repos
             topic-dir repos
             (lambda (ok)
               (if ok
                   (cc-butler--finish-topic topic-dir template)
                 (message "cc-butler: workspace %s not started (clone failed)"
                          topic-dir))))))))))

;;;; ------------------------------------------------------------------
;;;; Close a topic: safety-gated session teardown + workspace removal
;;;; ------------------------------------------------------------------
;;
;; The inverse of `cc-butler-new-topic'.  Before deleting anything it proves no
;; *local* work would be lost — every git clone in the workspace must have no
;; local-only commits, a clean working tree, and no stashes.  These are checked
;; with real `git' invocations (not ref/fetch state, which has misled before).
;; If any check fails, nothing is killed or deleted.  Whether the work reached
;; production is out of scope; the guarantee is only "everything local is on
;; origin and clean".

(defun cc-butler--close-topic-dir (session-dir)
  "Return the topic-workspace root for SESSION-DIR.
The nearest ancestor holding `cc-butler-project-marker', else SESSION-DIR."
  (file-name-as-directory
   (expand-file-name
    (or (locate-dominating-file session-dir cc-butler-project-marker)
        session-dir))))

(defun cc-butler--close-topic-repos (topic-dir)
  "Return the git clones to vet before removing TOPIC-DIR.
TOPIC-DIR itself when it is a repo, else its immediate child repos."
  (if (file-directory-p (expand-file-name ".git" topic-dir))
      (list (file-name-as-directory topic-dir))
    (seq-filter
     (lambda (p) (and (file-directory-p p)
                      (file-directory-p (expand-file-name ".git" p))))
     (ignore-errors (directory-files topic-dir t "\\`[^.]")))))

(defun cc-butler--git-run (dir args)
  "Run git ARGS in DIR; return (OK . TRIMMED-OUTPUT)."
  (let ((default-directory (file-name-as-directory dir)))
    (with-temp-buffer
      (let ((code (ignore-errors (apply #'process-file "git" nil t nil args))))
        (cons (eq code 0) (string-trim (buffer-string)))))))

(defun cc-butler--close-topic-unsafe (repo)
  "Return the reasons REPO is unsafe to delete (nil = safe).
No local-only commits, clean working tree, no stashes; a failed `git'
invocation is itself unsafe (we could not verify)."
  (let (reasons)
    (pcase-dolist
        (`(,label . ,args)
         '(("local-only commits" "log" "--branches" "--not" "--remotes" "--oneline")
           ("uncommitted changes" "status" "--porcelain")
           ("stashed changes"     "stash" "list")))
      (let ((res (cc-butler--git-run repo args)))
        (cond
         ((not (car res))
          (push (format "%s: `git %s' failed" label (string-join args " ")) reasons))
         ((not (string-empty-p (cdr res)))
          (push label reasons)))))
    (nreverse reasons)))

(defun cc-butler--close-topic-audit (topic-dir)
  "Return an alist (REPO . REASONS) for every unsafe repo under TOPIC-DIR."
  (let (bad)
    (dolist (repo (cc-butler--close-topic-repos topic-dir))
      (when-let ((reasons (cc-butler--close-topic-unsafe repo)))
        (push (cons repo reasons) bad)))
    (nreverse bad)))

(defun cc-butler--close-topic-kill-session (dir)
  "Terminate the Claude session for DIR (process, buffers, state).
Returns the list of buffer names killed."
  (let* ((name (cc-butler--display-name dir))
         (bufname (claude-code-ide--get-buffer-name dir))
         (buf (get-buffer bufname))
         killed)
    (when (buffer-live-p buf)
      (let ((proc (get-buffer-process buf)))
        (when (process-live-p proc) (ignore-errors (delete-process proc))))
      (let ((kill-buffer-query-functions nil))
        (ignore-errors (kill-buffer buf)))
      (push bufname killed))
    ;; A manager-side buffer literally named after the topic, if any.
    (when-let ((tb (get-buffer name)))
      (let ((kill-buffer-query-functions nil))
        (ignore-errors (kill-buffer tb)))
      (push name killed))
    (ignore-errors (claude-code-ide--cleanup-on-exit dir))
    (when (fboundp 'cc-butler--clear-waiting) (cc-butler--clear-waiting dir))
    (when (boundp 'cc-butler--docs) (remhash dir cc-butler--docs))
    (when (equal dir cc-butler--butler) (setq cc-butler--butler nil))
    (when (fboundp 'cc-butler--maybe-refresh) (cc-butler--maybe-refresh))
    (nreverse killed)))

(defun cc-butler--close-topic-deletable-p (dir)
  "Return non-nil only when DIR is a cc-butler-SCAFFOLDED topic workspace.
Teardown deletes a directory only when this returns non-nil, and it is
deliberately built to REFUSE anything cc-butler did not itself scaffold.
The guarantee: teardown never deletes a directory cc-butler did not create
— most importantly an EXISTING project the user merely opened as a session
\(a real repo whose own root is a git working tree, full of the user's work),
which deleting would destroy.

DIR qualifies as a scaffolded topic only when ALL of these hold:
  - it exists and is not an obviously-wrong target — home, root, .emacs.d,
    or any path shallower than three components (the long-standing backstop);
  - it is NOT itself a git working-tree root: no `.git' entry (dir OR file)
    directly inside it.  `cc-butler--scaffold' always clones repos into
    SUBDIRS of a topic, so a scaffold root never carries its own `.git';
    a `.git' at the root is the signature of an existing project and is
    REFUSED unconditionally — the decisive data-loss backstop, effective
    even if a stray marker is present; and
  - it carries cc-butler's scaffold marker `cc-butler-project-marker'
    (the `.projectile' file `cc-butler--scaffold' writes at the topic root)
    — a POSITIVE \"cc-butler laid this directory out\" signal, so teardown
    only ever removes dirs cc-butler is known to have scaffolded (allowlist),
    not arbitrary directories a session happened to run in.
The git-clean commit-safety gate remains a separate, independent guarantee."
  (let* ((d (directory-file-name (expand-file-name dir)))
         (dslash (file-name-as-directory d)))
    (and (file-directory-p d)
         (> (length (split-string d "/" t)) 2)
         (not (member d (list (directory-file-name (expand-file-name "~"))
                              (directory-file-name (expand-file-name "~/.emacs.d"))
                              "/" "/home" "/root" "/tmp")))
         ;; Blocklist: an existing project's root is a git working tree.
         ;; `.git' may be a directory (normal repo) or a file (worktree /
         ;; submodule gitlink); refuse either.  A scaffold root never has one.
         (not (file-exists-p (expand-file-name ".git" dslash)))
         ;; Allowlist: only a cc-butler-scaffolded topic carries this marker.
         (file-exists-p (expand-file-name cc-butler-project-marker dslash)))))

(defun cc-butler--teardown-workspace (dir topic-dir &optional force)
  "Kill DIR's Claude session and delete TOPIC-DIR — the shared teardown tail.
Callers MUST run the pre-audit gate (`cc-butler--close-topic-audit') and the
human confirmation first; this only performs the irreversible tail with a
pre-delete safety RE-CHECK, so state that drifted between the gate and now (a
background write, a new stash) still blocks removal (skipped under FORCE).
Returns a plist (:killed BUFFER-NAMES :deleted BOOL :note STRING-OR-NIL).

This is the single delete-dir path; both `cc-butler-close-topic' and the
session cleaner (`cc-butler-cleanup') route through it, so the irreversible
operation cannot diverge (mirrors the single-launch-path discipline)."
  (let* ((killed (cc-butler--close-topic-kill-session dir))
         (recheck (unless force (cc-butler--close-topic-audit topic-dir)))
         deleted note)
    (cond
     ((not (cc-butler--close-topic-deletable-p topic-dir))
      (setq note (format "refusing to delete %s: not a cc-butler-scaffolded \
topic (existing project or unrecognized path)" topic-dir)))
     (recheck
      (setq note
            (format "became unsafe just before deletion (%s) — NOT deleted"
                    (mapconcat (lambda (c)
                                 (file-name-nondirectory
                                  (directory-file-name (car c))))
                               recheck ", "))))
     (t (ignore-errors (delete-directory topic-dir t))
        (setq deleted (not (file-exists-p topic-dir)))))
    (list :killed killed :deleted deleted :note note)))

;;;###autoload
(defun cc-butler-close-topic (&optional force)
  "Close a topic: vet its repos, kill the session, delete the workspace.
Select a live session by name.  Unless FORCE (a prefix arg), refuse unless
every git clone in the workspace has no local-only commits, a clean working
tree, and no stashes — so no committed or staged work is lost.  Prod/remote
state is out of scope."
  (interactive "P")
  (let* ((sessions (cc-butler--sessions))
         (names (mapcar (lambda (s) (cc-butler--display-name (plist-get s :dir)))
                        sessions))
         (default (and (derived-mode-p 'cc-butler-mode)
                       (cc-butler--dir-at-point)
                       (cc-butler--display-name (cc-butler--dir-at-point))))
         (name (completing-read
                (format "Close topic%s: " (if force " (FORCE — skip safety)" ""))
                names nil t nil nil default))
         (dir (and name (seq-some
                         (lambda (s)
                           (let ((d (plist-get s :dir)))
                             (and (equal (cc-butler--display-name d) name) d)))
                         sessions)))
         (topic-dir (and dir (cc-butler--close-topic-dir dir))))
    (unless dir (user-error "No live session named %S" name))
    ;; 1) safety gate — abort before touching anything.
    (unless force
      (let ((bad (cc-butler--close-topic-audit topic-dir)))
        (when bad
          (user-error
           "Refusing to close %s — unsafe, nothing killed or deleted:\n%s"
           name
           (mapconcat
            (lambda (cell)
              (format "  %s: %s"
                      (file-name-nondirectory (directory-file-name (car cell)))
                      (string-join (cdr cell) ", ")))
            bad "\n")))))
    (unless (yes-or-no-p
             (format "Kill session %s and DELETE %s%s? "
                     name topic-dir (if force " [FORCE: safety skipped]" "")))
      (user-error "Aborted"))
    ;; 2) kill session + delete workspace via the shared teardown tail (which
    ;;    re-checks safety immediately before the irreversible delete).
    (let* ((res (cc-butler--teardown-workspace dir topic-dir force))
           (killed (plist-get res :killed))
           (deleted (plist-get res :deleted))
           (note (plist-get res :note)))
      ;; 3) report.
      (message "cc-butler: closed %s — killed %s%s"
               name
               (if killed (string-join killed ", ") "(no buffers)")
               (cond (deleted (format "; deleted %s" topic-dir))
                     (note (format "; %s" note))
                     (t (format "; workspace NOT deleted (%s)" topic-dir)))))))

;; Reachable from the session manager and the LLM hydra.
(with-eval-after-load 'cc-butler-session
  (when (boundp 'cc-butler-mode-map)
    (define-key cc-butler-mode-map "N" #'cc-butler-new-topic)
    (define-key cc-butler-mode-map "K" #'cc-butler-close-topic)))

(provide 'cc-butler-workspace)
;;; cc-butler-workspace.el ends here
