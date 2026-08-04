;;; cc-butler-session-test.el --- tests for session launch config  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jeongsoo Park
;; SPDX-License-Identifier: MIT

;;   emacs -Q --batch -L . -l ert -l cc-butler-session-test.el \
;;     -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'cc-butler)

(ert-deftest cc-butler-session/configure-installs-refit-hook ()
  "The single session-config path installs a BUFFER-LOCAL window-refit hook, so
any layout change (windmove / C-x o) re-fits the PTY to the largest window (no
20x10 shrink) — the same for every role.  Faithful state assert on the
resulting hook, not on a call."
  (with-temp-buffer
    (cc-butler--configure-session-buffer (current-buffer))
    (should (memq #'cc-butler--session-refit-on-change
                  (buffer-local-value 'window-configuration-change-hook
                                      (current-buffer))))
    (should (local-variable-p 'window-configuration-change-hook))
    ;; idempotent — configuring twice does not double-install
    (cc-butler--configure-session-buffer (current-buffer))
    (should (= 1 (cl-count #'cc-butler--session-refit-on-change
                           (buffer-local-value 'window-configuration-change-hook
                                               (current-buffer)))))))

(ert-deftest cc-butler-session/single-launch-path-exists ()
  "All roles funnel through one launch+config path (global-consistency)."
  (should (fboundp 'cc-butler--launch-session))
  (should (fboundp 'cc-butler--configure-session)))

;;;; ---- ordering (Bug 3b: reordering-on-state-change) ---------------

(ert-deftest cc-butler-session/ordered-workers-fixed-alphabetical ()
  "Workers sort alphabetically by dir and STAY in that order regardless of
waiting-state — no more FIFO-by-wait-timestamp reordering, so a session
flipping to \"waiting\" mid-navigation no longer moves rows out from under
the cursor (regression: `cc-butler--ordered' used to sort waiting workers to
the front as an approval queue)."
  (let ((cc-butler--butler nil) (cc-butler--steward nil)
        (cc-butler--waiting (make-hash-table :test 'equal))
        (sessions (list (list :dir "/c/") (list :dir "/a/") (list :dir "/b/"))))
    (let ((order-1 (mapcar (lambda (s) (plist-get s :dir)) (cc-butler--ordered sessions))))
      (should (equal '("/a/" "/b/" "/c/") order-1))
      (puthash "/a/" (float-time) cc-butler--waiting)   ; "/a/" now waiting
      (let ((order-2 (mapcar (lambda (s) (plist-get s :dir)) (cc-butler--ordered sessions))))
        (should (equal order-1 order-2))))))            ; order unchanged

(ert-deftest cc-butler-session/ordered-pins-butler-and-steward ()
  "Butler and steward stay pinned to the top regardless of alphabetical dir order."
  (let* ((cc-butler--butler "/zzz-butler/") (cc-butler--steward "/steward/")
         (cc-butler--waiting (make-hash-table :test 'equal))
         (sessions (list (list :dir "/a-worker/") (list :dir "/steward/") (list :dir "/zzz-butler/"))))
    (should (equal '("/zzz-butler/" "/steward/" "/a-worker/")
                   (mapcar (lambda (s) (plist-get s :dir)) (cc-butler--ordered sessions))))))

;;;; ---- cursor preservation across redraw (Bug 3a) -------------------

(defvar cc-butler-session-test--sessions nil
  "Fake session-plist list `cc-butler--sessions' is stubbed to return.")

(defun cc-butler-session-test--fake-sessions () cc-butler-session-test--sessions)

(ert-deftest cc-butler-session/render-preserves-cursor-session-across-reorder ()
  "Re-rendering (e.g. the periodic refresh) keeps point on the SAME session by
identity even when a new session shifts row order — it does not reset to
point-min (the top row) just because positions moved (regression: only
`cc-butler--reprint' preserved the cursor, so any other/future direct caller
of `cc-butler--render' silently reset to the top)."
  (let ((cc-butler--butler nil) (cc-butler--steward nil)
        (cc-butler--waiting (make-hash-table :test 'equal))
        (cc-butler-session-test--sessions
         (list (list :dir "/b/" :title "b" :osc "" :status "" :branch "" :forge "")
               (list :dir "/c/" :title "c" :osc "" :status "" :branch "" :forge ""))))
    (cl-letf (((symbol-function 'cc-butler--sessions) #'cc-butler-session-test--fake-sessions))
      (with-temp-buffer
        (cc-butler-mode)
        (cc-butler--render)
        (goto-char (cdr (assoc "/c/" cc-butler--entries)))
        (should (equal "/c/" (cc-butler--dir-at-point)))
        ;; "/a/" arrives, sorting alphabetically BEFORE "/c/" — "/c/" is no
        ;; longer the last row.
        (setq cc-butler-session-test--sessions
              (append (list (list :dir "/a/" :title "a" :osc "" :status "" :branch "" :forge ""))
                      cc-butler-session-test--sessions))
        (cc-butler--reprint)
        (should (equal "/c/" (cc-butler--dir-at-point)))))))

;;;; ---- launch preflight diagnostics (fresh-install gaps) -------------
;;
;; Regression coverage for the fresh-install gap that made a first `B'/`S'
;; press on a newly-installed machine look like "the shortcut doesn't
;; work": `claude-code-ide' defaults to the `vterm' backend, but cc-butler's
;; UI is built on ghostel internals, and the required
;; `(setq claude-code-ide-terminal-backend 'ghostel)' + an absolute
;; `claude-code-ide-cli-path' live only in the user's own Emacs init, never
;; verified by `(require 'cc-butler)' itself. 2026-07-06.

(ert-deftest cc-butler-session/preflight-clean-when-well-configured ()
  "No problems reported when ghostel + an absolute cli-path + a real
executable are all in place."
  (let ((orig-featurep (symbol-function 'featurep)))
    (cl-letf (((symbol-function 'executable-find) (lambda (_) "/usr/bin/claude"))
              ((symbol-function 'featurep)
               (lambda (f) (or (eq f 'ghostel) (funcall orig-featurep f)))))
      (let ((claude-code-ide-terminal-backend 'ghostel)
            (claude-code-ide-cli-path "/usr/bin/claude"))
        (should (null (cc-butler--launch-preflight-diagnostics)))))))

(ert-deftest cc-butler-session/preflight-warns-on-non-ghostel-backend ()
  "A non-ghostel backend is a WARN (cc-butler's UI features degrade), not an
ERROR (the session still launches fine under vterm/eat)."
  (cl-letf (((symbol-function 'executable-find) (lambda (_) "/usr/bin/claude")))
    (let ((claude-code-ide-terminal-backend 'vterm)
          (claude-code-ide-cli-path "/usr/bin/claude"))
      (let ((problems (cc-butler--launch-preflight-diagnostics)))
        (should (= 1 (length problems)))
        (should (eq 'warn (car (car problems))))))))

(ert-deftest cc-butler-session/preflight-errors-when-ghostel-not-installed ()
  "ghostel backend selected but the package itself is not loaded: an ERROR,
since the launch will fail outright."
  (let ((orig-featurep (symbol-function 'featurep)))
    (cl-letf (((symbol-function 'executable-find) (lambda (_) "/usr/bin/claude"))
              ((symbol-function 'featurep)
               (lambda (f) (if (eq f 'ghostel) nil (funcall orig-featurep f)))))
      (let ((claude-code-ide-terminal-backend 'ghostel)
            (claude-code-ide-cli-path "/usr/bin/claude"))
        (should (memq 'error (mapcar #'car (cc-butler--launch-preflight-diagnostics))))))))

(ert-deftest cc-butler-session/preflight-errors-on-unexpanded-tilde-cli-path ()
  "A `~'-prefixed `claude-code-ide-cli-path' under the ghostel backend is a
known-broken combination — ghostel spawns it via execvp with no shell, so
`~' is never expanded and the process dies instantly with a bare \"Invalid
buffer\" error. Must be flagged explicitly, not left to the generic
not-executable check."
  (let ((orig-featurep (symbol-function 'featurep)))
    (cl-letf (((symbol-function 'executable-find) (lambda (_) nil))
              ((symbol-function 'featurep)
               (lambda (f) (or (eq f 'ghostel) (funcall orig-featurep f)))))
      (let* ((claude-code-ide-terminal-backend 'ghostel)
             (claude-code-ide-cli-path "~/.claude/local/claude")
             (problems (cc-butler--launch-preflight-diagnostics)))
        (should (seq-find (lambda (p) (string-match-p "execvp" (cdr p))) problems))))))

(ert-deftest cc-butler-session/preflight-errors-when-cli-not-executable ()
  "No usable `claude' binary at all is an ERROR regardless of backend."
  (cl-letf (((symbol-function 'executable-find) (lambda (_) nil)))
    (let ((claude-code-ide-terminal-backend 'vterm)
          (claude-code-ide-cli-path "claude"))
      (should (memq 'error (mapcar #'car (cc-butler--launch-preflight-diagnostics)))))))

(ert-deftest cc-butler-session/launch-session-refuses-on-preflight-error ()
  "`cc-butler--launch-session' raises a loud `user-error' — and never reaches
`claude-code-ide' — when the preflight reports an ERROR, so a fresh-install
misconfiguration is impossible to miss (regression: it used to fail silently
or with a cryptic downstream error)."
  (cl-letf (((symbol-function 'executable-find) (lambda (_) nil))
            ((symbol-function 'claude-code-ide)
             (lambda (&rest _) (error "claude-code-ide should not have been called"))))
    (let ((claude-code-ide-cli-path "/nonexistent/claude"))
      (should-error (cc-butler--launch-session "/tmp") :type 'user-error))))

;;;; ---- launch readiness (cc-butler#8, 2026-07-21) -------------------

(ert-deftest cc-butler-session/wait-for-ready-returns-once-input-line-appears ()
  "`cc-butler--wait-for-session-ready' returns (no error) as soon as the
session buffer shows a live input row — it does not wait out the full
timeout when the row is already there."
  (let ((term-buf (get-buffer-create " *cc-butler-test-ready-term*")))
    (unwind-protect
        (progn
          (with-current-buffer term-buf
            (insert (make-string 24 cc-butler--border-rule-char))
            (insert "\n❯ \n")
            (insert (make-string 24 cc-butler--border-rule-char)))
          (cl-letf (((symbol-function 'claude-code-ide--get-buffer-name)
                     (lambda (_d) (buffer-name term-buf)))
                    ((symbol-function 'cc-butler--refresh-terminal-text) (lambda (_buf) t))
                    (cc-butler-launch-ready-timeout 2))
            (should (progn (cc-butler--wait-for-session-ready "/worker/") t))))
      (when (buffer-live-p term-buf) (kill-buffer term-buf)))))

(ert-deftest cc-butler-session/wait-for-ready-errors-on-timeout ()
  "`cc-butler--wait-for-session-ready' signals a loud error — rather than
returning as if launch succeeded — when no input row ever appears within
`cc-butler-launch-ready-timeout'. Silently returning here would hand a
caller a false-ready session (cc-butler#8)."
  (let ((term-buf (get-buffer-create " *cc-butler-test-ready-term-2*")))
    (unwind-protect
        (progn
          (with-current-buffer term-buf (insert "still starting up...\n"))
          (cl-letf (((symbol-function 'claude-code-ide--get-buffer-name)
                     (lambda (_d) (buffer-name term-buf)))
                    ((symbol-function 'cc-butler--refresh-terminal-text) (lambda (_buf) t))
                    (cc-butler-launch-ready-timeout 0.3))
            (should-error (cc-butler--wait-for-session-ready "/worker/"))))
      (when (buffer-live-p term-buf) (kill-buffer term-buf)))))

;;;; ---- folder-trust dialog (cc-butler#8, 2026-07-21) ----------------
;;;; A directory Claude Code has never opened before shows a one-time
;;;; "trust this folder?" screen instead of the normal input row. This is
;;;; the exact case a NEW ENVIRONMENT hits (정수님's original report) —
;;;; the readiness gate must recognize and answer it, not just time out.

(defun cc-butler-session-test--insert-trust-dialog ()
  "Insert the verbatim folder-trust screen (captured live 2026-07-21 on
two never-before-launched directories)."
  (insert (make-string 24 cc-butler--border-rule-char) "\n")
  (insert " Accessing workspace:\n\n /tmp/some-new-dir/\n\n")
  (insert " Quick safety check: Is this a project you created or one you trust?\n\n")
  (insert " Claude Code'll be able to read, edit, and execute files here.\n\n")
  (let ((start (point)))
    (insert "❯ 1. Yes, I trust this folder")
    (put-text-property start (point) 'face
                        (list :foreground "#b1b9f9" :background "#262626")))
  (insert "\n   2. No, exit\n"))

(ert-deftest cc-butler-session/trust-dialog-showing-p-detects-real-screen ()
  "`cc-butler--trust-dialog-showing-p' recognizes the actual captured
folder-trust screen."
  (let ((buf (get-buffer-create " *cc-butler-test-trust*")))
    (unwind-protect
        (progn
          (with-current-buffer buf (cc-butler-session-test--insert-trust-dialog))
          (should (cc-butler--trust-dialog-showing-p buf)))
      (kill-buffer buf))))

(ert-deftest cc-butler-session/trust-dialog-showing-p-nil-on-normal-input-row ()
  "`cc-butler--trust-dialog-showing-p' does not fire on an ordinary
border-sandwiched input row — it is specific to the trust screen."
  (let ((buf (get-buffer-create " *cc-butler-test-trust-2*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (insert (make-string 24 cc-butler--border-rule-char))
            (insert "\n❯ \n")
            (insert (make-string 24 cc-butler--border-rule-char)))
          (should-not (cc-butler--trust-dialog-showing-p buf)))
      (kill-buffer buf))))

(ert-deftest cc-butler-session/trust-dialog-showing-p-nil-on-lookalike-dialog ()
  "A DIFFERENT first-run confirmation that happens to share the
numbered-option shape (and even mentions \"trust\" in passing) must NOT
be auto-accepted — only the exact folder-trust wording qualifies
(cc-butler#8: a wrong auto-accept here is worse than a slow timeout)."
  (let ((buf (get-buffer-create " *cc-butler-test-trust-3*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (insert (make-string 24 cc-butler--border-rule-char) "\n")
            (insert " This MCP server requests filesystem access. Only allow it if you trust the source.\n\n")
            (insert "❯ 1. Allow always\n   2. Allow once\n   3. Deny\n"))
          (should-not (cc-butler--trust-dialog-showing-p buf)))
      (kill-buffer buf))))

(ert-deftest cc-butler-session/wait-for-ready-accepts-trust-dialog-then-proceeds ()
  "`cc-butler--wait-for-session-ready' recognizes the folder-trust screen,
sends a bare Return to accept it (\"Yes, trust\" is pre-highlighted), and
keeps polling for the real input row afterward instead of timing out —
this is the exact case a genuinely new directory hits."
  (let ((term-buf (get-buffer-create " *cc-butler-test-trust-wait*"))
        (return-count 0))
    (unwind-protect
        (progn
          (with-current-buffer term-buf (cc-butler-session-test--insert-trust-dialog))
          (cl-letf (((symbol-function 'claude-code-ide--get-buffer-name)
                     (lambda (_d) (buffer-name term-buf)))
                    ((symbol-function 'cc-butler--refresh-terminal-text) (lambda (_buf) t))
                    ((symbol-function 'claude-code-ide--terminal-send-return)
                     (lambda ()
                       (cl-incf return-count)
                       (with-current-buffer term-buf
                         (erase-buffer)
                         (insert (make-string 24 cc-butler--border-rule-char))
                         (insert "\n❯ \n")
                         (insert (make-string 24 cc-butler--border-rule-char)))))
                    (cc-butler-launch-ready-timeout 2))
            (should (progn (cc-butler--wait-for-session-ready "/worker/") t))
            (should (= 1 return-count))))
      (when (buffer-live-p term-buf) (kill-buffer term-buf)))))

(ert-deftest cc-butler-session/launch-session-waits-for-readiness ()
  "`cc-butler--launch-session' calls `cc-butler--wait-for-session-ready'
after spawning and configuring, so a caller can never be handed a
false-ready session into which a `send_to_session' silently vanishes
(cc-butler#8)."
  (let ((orig-featurep (symbol-function 'featurep))
        waited-for)
    (cl-letf (((symbol-function 'executable-find) (lambda (_) "/usr/bin/claude"))
              ((symbol-function 'featurep)
               (lambda (f) (or (eq f 'ghostel) (funcall orig-featurep f))))
              ((symbol-function 'claude-code-ide) (lambda (&rest _) nil))
              ((symbol-function 'cc-butler--configure-session) (lambda (_dir) nil))
              ((symbol-function 'cc-butler--wait-for-session-ready)
               (lambda (dir) (setq waited-for dir))))
      (let ((claude-code-ide-terminal-backend 'ghostel)
            (claude-code-ide-cli-path "/usr/bin/claude"))
        (cc-butler--launch-session "/tmp/some-worker/")))
    (should (equal waited-for (file-name-as-directory (expand-file-name "/tmp/some-worker/"))))))

;;;; ------------------------------------------------------------------
;;;; PTY minimum size
;;;; ------------------------------------------------------------------

;; A new session's terminal buffer is never displayed before it is created,
;; so the size that reaches the pty comes from whatever window it first
;; lands in — applied with no lower bound.  With the frame split narrow,
;; sessions have come up at ELEVEN columns: the TUI cannot lay out its input
;; row, keystrokes go nowhere, and it presents as "input doesn't work"
;; rather than as a size problem.

(defmacro cc-butler-test--with-pty (rows cols &rest body)
  "Run BODY with a fake ghostel session buffer sized ROWSxCOLS.
Binds `sized' to the (ROWS . COLS) passed to `set-process-window-size' and
`grid' to the (ROWS . COLS) passed to ghostel's own sizer."
  (declare (indent 2))
  `(let ((buf (generate-new-buffer " *cc-pty-test*"))
         (sized nil) (grid nil))
     (unwind-protect
         (with-current-buffer buf
           (setq-local ghostel--term-rows ,rows)
           (setq-local ghostel--term-cols ,cols)
           (setq-local ghostel--term 'fake-term)
           (cl-letf (((symbol-function 'get-buffer-process) (lambda (_b) 'proc))
                     ((symbol-function 'process-live-p) (lambda (_p) t))
                     ((symbol-function 'set-process-window-size)
                      (lambda (_p r c) (setq sized (cons r c))))
                     ((symbol-function 'ghostel--set-size-with-cell-dims)
                      (lambda (_t r c) (setq grid (cons r c))))
                     ((symbol-function 'cc-butler--log) #'ignore)
                     ((symbol-function 'claude-code-ide--get-buffer-name)
                      (lambda (_d) (buffer-name buf))))
             ,@body))
       (kill-buffer buf))))

(ert-deftest cc-butler-session/pty-floor-raises-a-degenerate-terminal ()
  "REGRESSION: an 11-column session is raised to the floor, and BOTH the pty
ioctl and ghostel's grid are corrected — the process and the display have to
agree about how wide the world is."
  (cc-butler-test--with-pty 24 11
    (should (equal (cc-butler--pty-size-floor (current-buffer))
                   (cons cc-butler-terminal-min-height
                         cc-butler-terminal-min-width)))
    (should (equal sized (cons cc-butler-terminal-min-height
                               cc-butler-terminal-min-width)))
    (should (equal grid sized))))

(ert-deftest cc-butler-session/pty-floor-never-shrinks-a-healthy-terminal ()
  "A terminal already at or above the floor is left completely alone — this
is a floor, not a resize policy, and must not fight the window layout."
  (cc-butler-test--with-pty 50 200
    (should-not (cc-butler--pty-size-floor (current-buffer)))
    (should-not sized)
    (should-not grid)))

(ert-deftest cc-butler-session/pty-floor-raises-only-the-dimension-below-it ()
  "Height and width are floored independently; a tall narrow window keeps its
height."
  (cc-butler-test--with-pty 60 11
    (cc-butler--pty-size-floor (current-buffer))
    (should (equal (car sized) 60))
    (should (equal (cdr sized) cc-butler-terminal-min-width))))

(ert-deftest cc-butler-session/launch-sizes-the-pty-before-waiting-for-ready ()
  "Order is load-bearing: the readiness wait watches for the TUI's input row,
and a terminal eleven columns wide cannot draw one.  Sizing after the wait
would mean timing out on a session that was only ever too narrow to look
ready."
  (let ((orig-featurep (symbol-function 'featurep)) (order nil))
    (cl-letf (((symbol-function 'executable-find) (lambda (_) "/usr/bin/claude"))
              ((symbol-function 'featurep)
               (lambda (f) (or (eq f 'ghostel) (funcall orig-featurep f))))
              ((symbol-function 'claude-code-ide) (lambda (&rest _) nil))
              ((symbol-function 'cc-butler--configure-session) (lambda (_d) nil))
              ((symbol-function 'cc-butler--ensure-pty-size)
               (lambda (_d) (push 'sized order)))
              ((symbol-function 'cc-butler--wait-for-session-ready)
               (lambda (_d) (push 'waited order))))
      (let ((claude-code-ide-terminal-backend 'ghostel)
            (claude-code-ide-cli-path "/usr/bin/claude"))
        (cc-butler--launch-session "/tmp/some-worker/")))
    (should (equal (nreverse order) '(sized waited)))))

(ert-deftest cc-butler-session/resume-also-sizes-the-pty ()
  "`cc-butler--resume-in' is the OTHER spawn site.  A restore after a restart
brings every session back at once into whatever layout the frame is in,
which is the likeliest time to hit this at all."
  (require 'cc-butler-persist)
  (let ((order nil))
    (cl-letf (((symbol-function 'claude-code-ide) (lambda (&rest _) nil))
              ((symbol-function 'cc-butler--ensure-pty-size)
               (lambda (_d) (push 'sized order)))
              ((symbol-function 'cc-butler--wait-for-session-ready)
               (lambda (_d) (push 'waited order))))
      (cc-butler--resume-in "/tmp/some-worker/"))
    (should (equal (nreverse order) '(sized waited)))))

(ert-deftest cc-butler-session/refit-reapplies-the-floor ()
  "A refit is sized from a window, so it can drop back under the floor the
moment the frame is split narrow.  Without re-applying it there, the
launch-time guarantee lasts only until the first layout change."
  (let ((floored nil))
    (cl-letf (((symbol-function 'derived-mode-p) (lambda (&rest _) t))
              ((symbol-function 'ghostel--adjust-size) (lambda (_w) nil))
              ((symbol-function 'window-live-p) (lambda (_w) t))
              ((symbol-function 'cc-butler--pty-size-floor)
               (lambda (_b) (setq floored t))))
      (cc-butler--fit-pty-largest 'window))
    (should floored)))

;;;; ---- the shared ghost-vs-real predicate (cc-butler#6, 2026-07-24) ----
;;;; `cc-butler--input-state' is the ONE answer to "is there real typed
;;;; input in this box".  It lives here, below both callers, because the
;;;; compaction guard (cc-butler-compact.el) and read_session_output's
;;;; redaction (cc-butler-orchestrator.el) used to answer it separately and
;;;; only one of the two was right.  It reports three outcomes and resolves
;;;; none of them: the callers need opposite fail-safes, so each picks its
;;;; own direction at its own call site.

(defconst cc-butler-session-test--prompt (concat "❯" (string #x00A0))
  "`❯' + U+00A0 NO-BREAK SPACE, the prompt Claude Code actually renders.
Spelled as explicit code points so no editor can normalise the NBSP away —
a fixture with an ordinary space is what let an earlier miss ship green.")

(defmacro cc-butler-session-test--with-box (fill cursor-needle &rest body)
  "Run BODY in a buffer painted by FILL, with the terminal cursor reported
at the end of the first match of CURSOR-NEEDLE (nil = no cursor readable)."
  (declare (indent 2))
  `(with-temp-buffer
     ,fill
     (let ((cursor (when ,cursor-needle
                     (goto-char (point-min))
                     (search-forward ,cursor-needle)
                     (point))))
       (cl-letf (((symbol-function 'ghostel-cursor-point) (lambda () cursor)))
         ,@body))))

(defun cc-butler-session-test--box (text)
  "Insert a border-framed input box holding TEXT after the prompt."
  (insert (make-string 24 cc-butler--border-rule-char) "\n")
  (insert cc-butler-session-test--prompt text "\n")
  (insert (make-string 24 cc-butler--border-rule-char) "\n"))

(ert-deftest cc-butler-session/input-state-ghost-when-cursor-is-at-the-prompt ()
  "A painted suggestion leaves the cursor at the prompt because the input
buffer is genuinely empty — so the box reads GHOST no matter how much text
is painted into it (measured across eight live sessions 2026-07-23)."
  (cc-butler-session-test--with-box
      (cc-butler-session-test--box "네, 꺼내주세요")
      cc-butler-session-test--prompt
    (should (equal '(ghost) (cc-butler--input-state)))))

(ert-deftest cc-butler-session/input-state-real-when-cursor-is-past-the-prompt ()
  "Typed text advances the cursor, and the distance past the prompt IS the
pending input."
  (cc-butler-session-test--with-box
      (cc-butler-session-test--box "abcd")
      (concat cc-butler-session-test--prompt "abcd")
    (should (equal '(real . "abcd") (cc-butler--input-state)))))

(ert-deftest cc-butler-session/input-state-is-blind-to-the-face-color ()
  "The whole point of the redesign: the painted color decides nothing.  The
same row in this fleet's ghost face (#8686a8/#00005f), in the legacy face
the deleted constant keyed on (#a7a7a7/#262626), in an accent face, and
unfaced, all classify identically — by the cursor alone."
  (dolist (face '((:foreground "#8686a8" :background "#00005f")
                  (:foreground "#a7a7a7" :background "#262626")
                  (:foreground "#b1b9f9")
                  nil))
    (cc-butler-session-test--with-box
        (progn (insert (make-string 24 cc-butler--border-rule-char) "\n")
               (insert cc-butler-session-test--prompt)
               (let ((start (point)))
                 (insert "merge PR #72 please")
                 (when face (put-text-property start (point) 'face face)))
               (insert "\n")
               (insert (make-string 24 cc-butler--border-rule-char) "\n"))
        cc-butler-session-test--prompt
      (should (equal '(ghost) (cc-butler--input-state))))))

(ert-deftest cc-butler-session/input-state-empty-nbsp-padded-box-is-ghost ()
  "An empty box trims to a one-character string under `string-trim' because
the padding is U+00A0, not a space.  `cc-butler--strip-input-pad' knows that;
losing it made every idle session in the fleet read as \"has text typed\"."
  (cc-butler-session-test--with-box
      (cc-butler-session-test--box "")
      cc-butler-session-test--prompt
    (should (equal '(ghost) (cc-butler--input-state)))))

(ert-deftest cc-butler-session/input-state-typed-slash-command-is-real ()
  "A half-typed slash command is the most dangerous pending input there is —
our own command would be appended to it — and Claude Code renders it in an
accent face, which a face-based rule read as \"decorated, therefore ghost\"."
  (cc-butler-session-test--with-box
      (progn (insert (make-string 24 cc-butler--border-rule-char) "\n")
             (insert cc-butler-session-test--prompt)
             (let ((start (point)))
               (insert "/clear")
               (put-text-property start (point) 'face '(:foreground "#b1b9f9")))
             (insert "\n")
             (insert (make-string 24 cc-butler--border-rule-char) "\n"))
      (concat cc-butler-session-test--prompt "/clear")
    (should (equal '(real . "/clear") (cc-butler--input-state)))))

(ert-deftest cc-butler-session/input-state-multi-line-input-is-seen-whole ()
  "A multi-line box must report everything ahead of the cursor, not just the
cursor's own row — otherwise a second line looks empty and we type into it."
  (cc-butler-session-test--with-box
      (progn (insert (make-string 24 cc-butler--border-rule-char) "\n")
             (insert cc-butler-session-test--prompt "first line\n")
             (insert "  second line\n")
             (insert (make-string 24 cc-butler--border-rule-char) "\n"))
      "second line"
    (let ((state (cc-butler--input-state)))
      (should (eq 'real (car state)))
      (should (string-match-p "first line" (cdr state)))
      (should (string-match-p "second line" (cdr state))))))

(ert-deftest cc-butler-session/input-state-unknown-when-no-cursor-is-readable ()
  "A terminal backend with no readable cursor yields UNKNOWN — never GHOST.
Reporting an unread box as empty would hand the redaction path a false
determination and the compaction guard a licence to type."
  (cc-butler-session-test--with-box
      (cc-butler-session-test--box "something")
      nil
    (should (equal '(unknown) (cc-butler--input-state)))))

(ert-deftest cc-butler-session/input-state-unknown-when-cursor-is-outside-a-box ()
  "A modal dialog owns the screen and the cursor sits nowhere near an input
box.  That is UNKNOWN, not GHOST: \"no box at the cursor\" is not evidence
that the box is empty."
  (cc-butler-session-test--with-box
      (progn (insert "❯ 1. yes\n  2. no\n")
             (cc-butler-session-test--box "leftover"))
      "1. yes"
    (should (equal '(unknown) (cc-butler--input-state)))))

(ert-deftest cc-butler-session/input-state-never-resolves-unknown-itself ()
  "Guard on the design constraint, not on a behaviour: `cc-butler--input-state'
must keep UNKNOWN as its own outcome.  If it ever collapses UNKNOWN into
GHOST or REAL, one of the two call sites silently inherits the other's
fail-safe — and those fail-safes point in opposite directions on purpose
\(compaction refuses to type; redaction refuses to show)."
  (should (memq (car (cc-butler-session-test--with-box
                         (cc-butler-session-test--box "text")
                         nil
                       (cc-butler--input-state)))
                '(unknown)))
  (should (eq 'ghost (car (cc-butler-session-test--with-box
                              (cc-butler-session-test--box "text")
                              cc-butler-session-test--prompt
                            (cc-butler--input-state))))))

;;;; ------------------------------------------------------------------
;;;; OSC terminal title
;;;; ------------------------------------------------------------------

(ert-deftest cc-butler-session/osc-title-reads-the-title-variable ()
  "The installed ghostel has no `ghostel--get-title' function — it only ever
stores the OSC 0/2 title in the buffer-local `ghostel--title' variable.  Read
that directly rather than returning nil because a function that does not
exist could not be called."
  (with-temp-buffer
    (setq-local ghostel--term 'fake-term)
    (setq-local ghostel--title "  building the widget  ")
    (should (equal (cc-butler--osc-title (current-buffer))
                   "building the widget"))))

(ert-deftest cc-butler-session/osc-title-prefers-the-function-if-it-exists ()
  "A future ghostel that adds `ghostel--get-title' must win over the variable
fallback, so this does not silently regress once that function exists."
  (with-temp-buffer
    (setq-local ghostel--term 'fake-term)
    (setq-local ghostel--title "stale variable value")
    (cl-letf (((symbol-function 'ghostel--get-title)
               (lambda (_term) "fresh from the function")))
      (should (equal (cc-butler--osc-title (current-buffer))
                     "fresh from the function")))))

(ert-deftest cc-butler-session/osc-title-nil-without-a-ghostel-term ()
  "No ghostel terminal in this buffer at all (a non-ghostel backend, or a
buffer that never became one) — nil, not an error from reading unbound
variables."
  (with-temp-buffer
    (should-not (cc-butler--osc-title (current-buffer)))))

(ert-deftest cc-butler-session/osc-title-nil-on-blank-title ()
  "An empty or all-whitespace title is treated the same as no title."
  (with-temp-buffer
    (setq-local ghostel--term 'fake-term)
    (setq-local ghostel--title "   ")
    (should-not (cc-butler--osc-title (current-buffer)))))

;;;; ------------------------------------------------------------------
;;;; P2: transcript-based liveness (compaction gate)
;;;; ------------------------------------------------------------------

(require 'cl-lib)

(ert-deftest cc-butler-session/claude-project-dir-slugs-the-path ()
  "The per-project dir is ~/.claude/projects/<slug>/ where slug replaces every
`/' and `.' in the absolute path with `-'."
  (should (equal (cc-butler--claude-project-dir "/tmp/foo.bar/")
                 (expand-file-name "-tmp-foo-bar/" "~/.claude/projects/")))
  (should (null (cc-butler--claude-project-dir nil))))

(ert-deftest cc-butler-session/last-activity-is-max-over-both-globs ()
  "`cc-butler--session-last-activity' returns the MAX mtime over the main
transcript glob AND the sub-agent glob."
  (let ((now (float-time)))
    (cl-letf (((symbol-function 'file-expand-wildcards)
               (lambda (pat &optional _full)
                 (if (string-match-p "subagents" pat)
                     '("/p/x/subagents/a.jsonl")   ; sub-agent transcript
                   '("/p/main.jsonl"))))           ; main transcript
              ((symbol-function 'file-attributes)
               (lambda (f &rest _)
                 ;; sub-agent is the FRESHER of the two
                 (list nil nil nil nil nil
                       (if (string-match-p "subagents" f)
                           (seconds-to-time (- now 10))
                         (seconds-to-time (- now 500)))))))
      (should (< (abs (- (cc-butler--session-last-activity "/d/") (- now 10)))
                 1.0)))))

(ert-deftest cc-butler-session/last-activity-degrades-without-subagents ()
  "Empty sub-agent glob falls back to the main glob; both empty -> nil."
  (cl-letf (((symbol-function 'file-attributes)
             (lambda (_f &rest _)
               (list nil nil nil nil nil (seconds-to-time (- (float-time) 42))))))
    ;; only main present
    (cl-letf (((symbol-function 'file-expand-wildcards)
               (lambda (pat &optional _full)
                 (unless (string-match-p "subagents" pat) '("/p/main.jsonl")))))
      (should (numberp (cc-butler--session-last-activity "/d/"))))
    ;; both empty -> nil
    (cl-letf (((symbol-function 'file-expand-wildcards) (lambda (&rest _) nil)))
      (should (null (cc-butler--session-last-activity "/d/"))))))

(ert-deftest cc-butler-session/transcript-idle-p-honours-threshold ()
  "Idle only once activity is at least the threshold old; unknown activity
\(nil) is treated as BUSY, the safe default for a destructive op."
  (let ((cc-butler-idle-threshold 600)
        (now (float-time)))
    (cl-letf (((symbol-function 'cc-butler--session-last-activity)
               (lambda (_d) (- now 900))))
      (should (cc-butler--transcript-idle-p "/d/")))
    (cl-letf (((symbol-function 'cc-butler--session-last-activity)
               (lambda (_d) (- now 5))))
      (should-not (cc-butler--transcript-idle-p "/d/")))
    (cl-letf (((symbol-function 'cc-butler--session-last-activity)
               (lambda (_d) nil)))
      (should-not (cc-butler--transcript-idle-p "/d/")))))

;;;; ------------------------------------------------------------------
;;;; Model of record: the transcript, when the screen cannot say
;;;; ------------------------------------------------------------------

;; Row shapes below are modelled on real transcripts measured 2026-07-31:
;; the model lives at .message.model on `"type":"assistant"' rows, and a
;; `/model' switch writes a `<local-command-stdout>Set model to ...' user row
;; BEFORE any assistant row exists on the new model.

(defun cc-butler-session-test--transcript (dir name &rest lines)
  "Write LINES as NAME.jsonl under DIR and return the file."
  (let ((f (expand-file-name name dir)))
    (make-directory (file-name-directory f) t)
    (with-temp-file f (insert (string-join lines "\n") "\n"))
    f))

(defmacro cc-butler-session-test--with-project (proj &rest body)
  "Bind PROJ to a fresh temp project dir that `cc-butler--claude-project-dir'
resolves to, run BODY, then delete it."
  (declare (indent 1))
  `(let ((,proj (file-name-as-directory (make-temp-file "ccb-proj" t))))
     (unwind-protect
         (cl-letf (((symbol-function 'cc-butler--claude-project-dir)
                    (lambda (_d) ,proj)))
           ,@body)
       (delete-directory ,proj t))))

(ert-deftest cc-butler-session/transcript-model-reads-last-assistant-row ()
  "With no later switch, the newest assistant row names the model."
  (cc-butler-session-test--with-project proj
    (cc-butler-session-test--transcript
     proj "s.jsonl"
     "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"model\":\"claude-sonnet-5\"}}"
     "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"go on\"}}"
     "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"model\":\"claude-opus-5\"}}")
    (should (equal "claude-opus-5" (cc-butler--transcript-model "/d/")))))

(ert-deftest cc-butler-session/transcript-model-prefers-later-set-row ()
  "THE staleness case.  After `/model', the newest assistant row still names the
OLD model -- sometimes for days, sometimes forever if the new model never
answers.  The later `Set model to' row is the one that reflects reality."
  (cc-butler-session-test--with-project proj
    (cc-butler-session-test--transcript
     proj "s.jsonl"
     "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"model\":\"claude-sonnet-5\"}}"
     (concat "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":"
             "\"<local-command-stdout>Set model to \\u001b[1mOpus 5\\u001b[22m"
             " and saved as your default for new sessions</local-command-stdout>\"}}"))
    ;; Assert the EXACT tag, not merely that "opus" occurs somewhere in it.
    ;; A `Set model to' row reports the display name verbatim — spaces intact —
    ;; unlike the statusline, which collapses them.  A loose assertion here
    ;; passes for `Opus 5' and equally for anything else containing "opus", so
    ;; it silently rests on whatever the consumer happens to tolerate; when the
    ;; consumer's matching rule changes, this keeps passing while the pipeline
    ;; breaks.  Pin the shape so the next change to the consumer has to face it.
    (should (equal "Opus 5" (cc-butler--transcript-model "/d/")))))

(ert-deftest cc-butler-session/transcript-model-ignores-subagent-transcripts ()
  "Sub-agents run on their OWN model and their transcripts can be the newest
file in the tree.  Only the main glob counts, and a sidechain row never does."
  (cc-butler-session-test--with-project proj
    (cc-butler-session-test--transcript
     proj "s.jsonl"
     "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"model\":\"claude-opus-5\"}}")
    (cc-butler-session-test--transcript
     proj "s/subagents/agent-1.jsonl"
     "{\"type\":\"assistant\",\"isSidechain\":true,\"message\":{\"role\":\"assistant\",\"model\":\"claude-haiku-4-5-20251001\"}}")
    (should (equal "claude-opus-5" (cc-butler--transcript-model "/d/")))))

(ert-deftest cc-butler-session/transcript-model-skips-synthetic-rows ()
  "`<synthetic>' marks a locally generated row (interrupt / API error); it is a
sentinel, not a model."
  (cc-butler-session-test--with-project proj
    (cc-butler-session-test--transcript
     proj "s.jsonl"
     "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"model\":\"claude-opus-5\"}}"
     "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"model\":\"<synthetic>\"}}")
    (should (equal "claude-opus-5" (cc-butler--transcript-model "/d/")))))

(ert-deftest cc-butler-session/transcript-model-nil-without-signal ()
  "A young session that has never answered carries no model signal at all --
return nil so the caller can refuse, rather than guessing."
  (cc-butler-session-test--with-project proj
    (cc-butler-session-test--transcript
     proj "s.jsonl"
     "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"hello\"}}")
    (should (null (cc-butler--transcript-model "/d/"))))
  ;; no transcript at all
  (cl-letf (((symbol-function 'cc-butler--claude-project-dir) (lambda (_d) nil)))
    (should (null (cc-butler--transcript-model "/d/")))))
;;;; A read must be able to report its own failure
;;;; ------------------------------------------------------------------

;; For a background session buffer, forcing the redraw is the ONLY thing that
;; ever writes text into it.  When that call failed the error was swallowed and
;; the caller read the untouched buffer anyway — so a permanently failing
;; refresh was served as ordinary output, indistinguishable from a live screen.
;; A stale screen believed to be current is worse than no screen at all.

(ert-deftest cc-butler-session/refresh-reports-a-failed-redraw ()
  "A redraw that signals must be reported as failure, not swallowed."
  (let (logged)
    (cl-letf (((symbol-function 'cc-butler--log)
               (lambda (fmt &rest args) (push (apply #'format fmt args) logged)))
              ((symbol-function 'ghostel--redraw)
               (lambda (&rest _) (error "ReentrantRedraw"))))
      (with-temp-buffer
        (setq-local ghostel--term 'fake-term)
        (should (null (cc-butler--refresh-terminal-text (current-buffer))))
        ;; and it must say WHY — swallowing the reason is what made this
        ;; undiagnosable in the first place
        (should logged)
        (should (string-match-p "ReentrantRedraw"
                                (mapconcat #'identity logged " ")))))))

(ert-deftest cc-butler-session/refresh-succeeds-quietly ()
  "A redraw that works reports success and logs nothing."
  (let (logged)
    (cl-letf (((symbol-function 'cc-butler--log)
               (lambda (&rest args) (push args logged)))
              ((symbol-function 'ghostel--redraw) (lambda (&rest _) t)))
      (with-temp-buffer
        (setq-local ghostel--term 'fake-term)
        (should (cc-butler--refresh-terminal-text (current-buffer)))
        (should (null logged))))))

(ert-deftest cc-butler-session/no-terminal-is-not-a-failure ()
  "A buffer with no ghostel terminal is not a FAILED refresh — its text is
maintained by something else (another backend, or a plain buffer).  Reporting
that as failure would blank out every non-ghostel setup."
  (with-temp-buffer
    (should (cc-butler--refresh-terminal-text (current-buffer)))))

;;;; ------------------------------------------------------------------
;;;; The refresh must give the redraw the context it requires
;;;; ------------------------------------------------------------------

;; Measured 2026-07-31 on a live frozen session: calling the native redraw with
;; no window binding errors with "Specified window is not displaying the current
;; buffer" and the buffer does not move (1128 -> 1128 bytes).  Supplying the
;; binding ghostel's own redraw path uses, the same call returns ok and the
;; buffer jumps to the live screen (1128 -> 157599).  The grid was current the
;; whole time; only the hand-off into the Emacs buffer was failing.

(defmacro cc-butler-session-test--recording-redraw (record &rest body)
  "Run BODY with `ghostel--redraw' stubbed to push a snapshot onto RECORD.
Each entry is (SELECTED-WINDOW-SHOWS-BUFFER . INHIBIT-REDISPLAY)."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'ghostel--redraw)
              (lambda (&rest _)
                (push (cons (eq (window-buffer (selected-window)) (current-buffer))
                            inhibit-redisplay)
                      ,record)
                t)))
     ,@body))

(ert-deftest cc-butler-session/refresh-gives-the-redraw-a-window ()
  "The native redraw requires the selected window to be showing the buffer.
Nothing displays a background session, so one must be lent to it — otherwise
the redraw errors and the buffer keeps whatever it last rendered."
  (let ((buf (get-buffer-create " *ccb-refresh-test*")) rec)
    (unwind-protect
        (with-current-buffer buf
          (setq-local ghostel--term 'fake-term)
          (cc-butler-session-test--recording-redraw rec
            (should (cc-butler--refresh-terminal-text buf)))
          (should (= 1 (length rec)))
          (should (car (car rec))))              ; window WAS showing the buffer
      (kill-buffer buf))))

(ert-deftest cc-butler-session/refresh-suppresses-redisplay-while-borrowing ()
  "Lending a window must not flash another session's screen at whoever is
sitting in front of Emacs — the same binding ghostel's own path uses."
  (let ((buf (get-buffer-create " *ccb-refresh-test2*")) rec)
    (unwind-protect
        (with-current-buffer buf
          (setq-local ghostel--term 'fake-term)
          (cc-butler-session-test--recording-redraw rec
            (cc-butler--refresh-terminal-text buf))
          (should (cdr (car rec))))              ; inhibit-redisplay was bound
      (kill-buffer buf))))

(ert-deftest cc-butler-session/refresh-leaves-the-layout-as-it-found-it ()
  "Borrowing a window is invisible: afterwards it shows exactly what it did."
  (let ((buf (get-buffer-create " *ccb-refresh-test3*"))
        (before (window-buffer (selected-window)))
        rec)
    (unwind-protect
        (with-current-buffer buf
          (setq-local ghostel--term 'fake-term)
          (cc-butler-session-test--recording-redraw rec
            (cc-butler--refresh-terminal-text buf))
          (should (eq before (window-buffer (selected-window)))))
      (kill-buffer buf))))

;; REGRESSION (2026-07-31, live): the borrow above took the SELECTED window
;; without asking whether it could be used.  cc-butler dedicates its own
;; session-list window (`cc-butler-session.el', `set-window-dedicated-p'), so
;; whenever point rested there `set-window-buffer' signalled "Window is
;; dedicated to `*claude-sessions*'".  That signal escaped the honest-nil
;; channel this same change built — it sits outside the `condition-case' in
;; `cc-butler--redraw-in-window' — so reads AND the compaction probe failed
;; with a raw Emacs error instead of reporting a refresh they could not do.
;; Gated on two conditions at once (buffer displayed nowhere AND the selected
;; window dedicated), which is why it struck intermittently.

(defmacro cc-butler-session-test--with-two-windows (list-buf &rest body)
  "Run BODY with a fresh two-window layout: LIST-BUF in the selected window,
a scratch buffer in a second one.  Restores the layout afterwards."
  (declare (indent 1))
  `(save-window-excursion
     (delete-other-windows)
     (split-window (selected-window) nil 'right)
     (set-window-buffer (selected-window) ,list-buf)
     ,@body))

(ert-deftest cc-butler-session/refresh-does-not-borrow-a-dedicated-window ()
  "A dedicated window cannot be lent — `set-window-buffer' signals on one.
Another window must be used instead, and the dedicated one left untouched."
  (let ((buf (get-buffer-create " *ccb-dedicated*"))
        (listbuf (get-buffer-create " *ccb-fake-list*"))
        rec)
    (unwind-protect
        (cc-butler-session-test--with-two-windows listbuf
          (set-window-dedicated-p (selected-window) t)
          ;; the conditions that produced the live failure, both present
          (should (window-dedicated-p (selected-window)))
          (should-not (get-buffer-window-list buf nil t))
          (with-current-buffer buf (setq-local ghostel--term 'fake-term))
          (cc-butler-session-test--recording-redraw rec
            (should (cc-butler--refresh-terminal-text buf)))
          (should (= 1 (length rec)))
          (should (car (car rec)))      ; it did get a window showing the buffer
          ;; and the dedicated window is exactly as it was
          (should (eq listbuf (window-buffer (selected-window))))
          (should (window-dedicated-p (selected-window))))
      (kill-buffer buf)
      (kill-buffer listbuf))))

(ert-deftest cc-butler-session/refresh-refuses-rather-than-rearranging-the-frame ()
  "With no window that may be borrowed, report the failure and stop.
Splitting one to make room would let a READ rearrange the frame a human is
looking at — an observation that alters what it observes.  The honest nil
costs that session's text until something displays it, which is the cheaper
mistake, and the caller already renders it as \"could not read\"."
  (let ((buf (get-buffer-create " *ccb-nowindow*"))
        (listbuf (get-buffer-create " *ccb-fake-list2*")))
    (unwind-protect
        (cc-butler-session-test--with-two-windows listbuf
          (dolist (w (window-list)) (set-window-dedicated-p w t))
          (with-current-buffer buf (setq-local ghostel--term 'fake-term))
          (let ((before (length (window-list))) rec)
            ;; stub the render too, so a nil here can only mean "no window to
            ;; borrow" and not "there was no terminal to redraw in the first
            ;; place" — those are different answers and `no-terminal' is truthy
            (cc-butler-session-test--recording-redraw rec
              (should-not (cc-butler--refresh-terminal-text buf))
              (should-not rec))          ; never got as far as rendering
            ;; no window was split into existence to get around it
            (should (= before (length (window-list))))))
      (kill-buffer buf)
      (kill-buffer listbuf))))

(ert-deftest cc-butler-session/refresh-reports-an-unborrowable-window-as-failure ()
  "Dedication is one way acquiring a window can fail; there will be others.
Every such failure has to leave by the same nil the caller already checks —
a reporting channel an exception can step around is not a channel.  Pinning
this to the dedicated case alone would reopen the same hole on the next
window error nobody predicted."
  (let ((buf (get-buffer-create " *ccb-borrowfail*")) rec)
    (unwind-protect
        (with-current-buffer buf
          (setq-local ghostel--term 'fake-term)
          (cc-butler-session-test--recording-redraw rec
            (cl-letf (((symbol-function 'set-window-buffer)
                       (lambda (&rest _) (error "some other window problem"))))
              (should-not (cc-butler--refresh-terminal-text buf))))
          ;; nil because the borrow failed, not because there was nothing to
          ;; redraw: the render was available and simply never reached
          (should-not rec))
      (kill-buffer buf))))

(ert-deftest cc-butler-session/refresh-coalesces-a-burst-of-reads ()
  "A full redraw rebuilds the whole buffer from the grid — up to
`ghostel-max-scrollback' of it — and one refresh cycle reads every session in
the fleet.  Repeating that per read, now with a window borrow on top, is how an
8s I/O timeout gets hit.  Within the coalesce window, reuse the last redraw;
past it, redraw again."
  (let ((buf (get-buffer-create " *ccb-refresh-test4*"))
        (cc-butler-refresh-coalesce-seconds 30)
        (cc-butler--refresh-times (make-hash-table :test 'eq))
        rec)
    (unwind-protect
        (with-current-buffer buf
          (setq-local ghostel--term 'fake-term)
          (cc-butler-session-test--recording-redraw rec
            (should (cc-butler--refresh-terminal-text buf))
            (should (cc-butler--refresh-terminal-text buf))   ; coalesced
            (should (= 1 (length rec)))
            ;; past the window, it redraws again
            (let ((cc-butler-refresh-coalesce-seconds 0))
              (should (cc-butler--refresh-terminal-text buf))
              (should (= 2 (length rec))))))
      (kill-buffer buf))))

(ert-deftest cc-butler-session/refresh-does-not-coalesce-a-failure ()
  "A failed redraw must not be remembered as a fresh one — otherwise one
failure would suppress the retries that follow it."
  (let ((buf (get-buffer-create " *ccb-refresh-test5*"))
        (cc-butler-refresh-coalesce-seconds 30)
        (cc-butler--refresh-times (make-hash-table :test 'eq))
        (calls 0))
    (unwind-protect
        (with-current-buffer buf
          (setq-local ghostel--term 'fake-term)
          (cl-letf (((symbol-function 'cc-butler--log) #'ignore)
                    ((symbol-function 'ghostel--redraw)
                     (lambda (&rest _) (setq calls (1+ calls)) (error "nope"))))
            (should (null (cc-butler--refresh-terminal-text buf)))
            (should (null (cc-butler--refresh-terminal-text buf)))
            (should (= 2 calls))))
      (kill-buffer buf))))

;;;; ---- a render must not restart inside itself ----------------------
;;
;; Observed live 2026-07-31: the session list rendered UPSIDE DOWN — each
;; session's detail row above its own name row, butler and steward at the
;; bottom, two orphaned detail rows at the top — and the selection overlay
;; painted every session instead of one.  `cc-butler--entries' held
;; 1,36,34,23,21,... : not ascending, so not buffer positions at all, which a
;; single uninterrupted render cannot produce.
;;
;; The render reads each session's ctx/model tag while it draws, and that read
;; borrows a window (cache TTL is 3s, so nearly every row really reads).  A
;; refresh arriving during that read starts a SECOND render inside the first:
;; it erases the buffer, rebuilds it, and leaves point at the top.  The outer
;; loop then keeps inserting its remaining rows at that point — prepending
;; them, hence the inversion — labels them with `start' positions that now
;; point into the inner render's text, and finally stores entries that are no
;; longer positions in the buffer anyone is looking at.

(defun cc-butler-session-test--render-fixture ()
  "Three sessions, each with a detail row.
The detail row matters: a row is drawn in two inserts, and the tearing shows
up between them.  A fixture with nothing to put on the second line renders in
one insert per session and hides the defect."
  (list (list :dir "/a/" :title "a" :osc "" :status "" :branch "main" :forge "")
        (list :dir "/b/" :title "b" :osc "" :status "" :branch "main" :forge "")
        (list :dir "/c/" :title "c" :osc "" :status "" :branch "main" :forge "")))

(ert-deftest cc-butler-session/render-does-not-restart-inside-itself ()
  "A refresh arriving mid-render must not tear the buffer it lands in.
Reentry is triggered here the way it happens live — from the per-row ctx tag,
which is what yields — rather than from a timer, so the test is deterministic."
  (let ((cc-butler--butler nil) (cc-butler--steward nil)
        (cc-butler--waiting (make-hash-table :test 'equal))
        (cc-butler-session-test--sessions (cc-butler-session-test--render-fixture))
        (reentered 0))
    (cl-letf (((symbol-function 'cc-butler--sessions)
               #'cc-butler-session-test--fake-sessions)
              ((symbol-function 'cc-butler-cleanup-context-tag)
               (lambda (_dir)
                 ;; Exactly one reentry, from inside the outer render's loop.
                 (when (zerop reentered)
                   (setq reentered 1)
                   (cc-butler--render))
                 nil))
              ((symbol-function 'cc-butler-cleanup-model-tag) (lambda (_dir) nil))
              ((symbol-function 'cc-butler-cleanup-context-over-threshold-p)
               (lambda (_dir) nil)))
      (with-temp-buffer
        (cc-butler-mode)
        (cc-butler--render)
        (should (= 1 reentered))       ; the reentry really happened
        ;; Assert on what a person sees, not on the text properties: the outer
        ;; render paints its own dirs OVER the inner render's text, so a
        ;; property lookup answers correctly about a row that is not there.
        (let ((text (buffer-substring-no-properties (point-min) (point-max))))
          ;; Each session is drawn exactly once.  Reentry drew /b/ and /c/
          ;; twice and left an ownerless detail row at the top.
          (dolist (name '("● a" "● b" "● c"))
            (should (= 1 (cl-count-if (lambda (l) (equal l name))
                                      (split-string text "\n")))))
          ;; The buffer opens on a session row, not on a stray detail row.
          (should (string-prefix-p "●" text)))
        (should (equal '("/a/" "/b/" "/c/") (mapcar #'car cc-butler--entries)))
        (let ((ps (mapcar #'cdr cc-butler--entries)))
          (should (equal ps (sort (copy-sequence ps) #'<))))))))

(ert-deftest cc-butler-session/entries-stay-real-buffer-positions ()
  "Every entry position must be a distinct, ascending position in the buffer.
`cc-butler--highlight' derives the selected block from entry N's start and
entry N+1's start, and navigation jumps by the same table, so once these stop
being real positions the highlight lands somewhere other than the row it
belongs to.  On screen that read as every session turning yellow at once.

Live, the table held 1,36,34,23,21,...  Reentering on every row (the read
happens per row, and its cache TTL is 3s, so live it really does) reproduces
the same class of damage: positions that repeat instead of advancing."
  (let ((cc-butler--butler nil) (cc-butler--steward nil)
        (cc-butler--waiting (make-hash-table :test 'equal))
        (cc-butler-session-test--sessions (cc-butler-session-test--render-fixture))
        (depth 0))
    (cl-letf (((symbol-function 'cc-butler--sessions)
               #'cc-butler-session-test--fake-sessions)
              ((symbol-function 'cc-butler-cleanup-context-tag)
               (lambda (_dir)
                 (when (= depth 0)
                   (let ((depth 1)) (cc-butler--render)))
                 "ctx 9k"))
              ((symbol-function 'cc-butler-cleanup-model-tag) (lambda (_dir) "Opus-5"))
              ((symbol-function 'cc-butler-cleanup-context-over-threshold-p)
               (lambda (_dir) nil)))
      (with-temp-buffer
        (cc-butler-mode)
        (cc-butler--render)
        (let ((ps (mapcar #'cdr cc-butler--entries)))
          (should (equal ps (sort (copy-sequence ps) #'<)))
          (should (equal ps (delete-dups (copy-sequence ps)))))
        ;; And each recorded position really is where that session's row starts.
        (dolist (e cc-butler--entries)
          (should (equal (car e)
                         (get-text-property (cdr e) 'cc-butler-dir))))))))

(provide 'cc-butler-session-test)
;;; cc-butler-session-test.el ends here
