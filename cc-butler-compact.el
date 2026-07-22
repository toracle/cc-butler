;;; cc-butler-compact.el --- drive context compaction of a session  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jeongsoo Park
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; Compaction is a four-step terminal dance that no single prompt can perform:
;; switch the session to a cheap model, answer the "switch model?" confirmation
;; that Claude Code raises because switching discards the prompt cache, run
;; `/compact', and put the original model back.  `governance/context-ceiling-
;; and-compaction.md' is the standing rule; this file is its mechanism.
;;
;; It exists because an LLM cannot reliably drive it.  Each step needs a
;; *separate* submission (a multi-line body is pasted and submitted once, so
;; three slash commands in one body execute nothing), and the middle step is a
;; modal that only appears sometimes.  Worse, the butler is itself a compaction
;; target — the most important one, since it is the session that grows without
;; bound — and a butler that types compaction commands into its own terminal is
;; injecting into the very context it is trying to shrink.
;;
;; So elisp drives from the outside and the LLM calls one function.  The driver
;; is an asynchronous `run-with-timer' state machine:
;;
;;     switching -> [modal? answer it] -> compacting -> restoring -> done
;;
;; Deliberately NO `sleep-for' anywhere in the waiting path.  Not because
;; `sleep-for' loses terminal output — it does not; process filters and timers
;; both run during it (measured 2026-07-22) — but because it does not
;; redisplay, and ghostel only materializes buffer text on redraw.  A blocking
;; wait therefore reads a stale *frame* unless every read forces
;; `cc-butler--refresh-terminal-text' first.  A timer-driven machine sidesteps
;; the whole class of mistake and keeps Emacs responsive while a 600-second
;; compaction runs.
;;
;; Every read here goes through `cc-butler--read-output', which force-redraws.
;;
;; Entry points:
;;   `cc-butler-compact-session'        one session, asynchronously
;;   `cc-butler-compact-large-sessions' every session over the threshold,
;;                                      butler and steward INCLUDED

;;; Code:

(require 'cl-lib)
(require 'cc-butler-cleanup)   ; cc-butler-cleanup-context-for / -model-for
                               ; (which pulls session/workspace/orchestrator:
                               ;  cc-butler--send-input / --read-output /
                               ;  --sessions / --waiting-p / --display-name)

;;;; ------------------------------------------------------------------
;;;; Knobs
;;;; ------------------------------------------------------------------

(defcustom cc-butler-compact-threshold 300000
  "Input-token count above which a session is a compaction candidate.
Read from the statusline `CTX:' marker via `cc-butler-cleanup-context-for'.
Higher than `cc-butler-cleanup-context-threshold' on purpose: that one
surfaces a worker for cleanup (externalize and tear down), this one is the
cheaper in-place remedy that also applies to the butler itself."
  :type 'integer :group 'cc-butler)

(defcustom cc-butler-compact-model "sonnet"
  "Model to switch a session to before compacting it.
Compaction re-reads the whole transcript, so it is the single most expensive
thing a session does; doing it on the cheap model is the entire point of the
switch.  Must be an argument `/model' accepts."
  :type 'string :group 'cc-butler)

(defcustom cc-butler-compact-poll-interval 3
  "Seconds between polls of a session being compacted."
  :type 'number :group 'cc-butler)

(defcustom cc-butler-compact-step-timeout 90
  "Seconds a model switch (or its confirmation modal) may take before failing."
  :type 'number :group 'cc-butler)

(defcustom cc-butler-compact-timeout 900
  "Seconds `/compact' may take before the driver gives up and restores.
Compacting a 400k-token session is minutes of work, not seconds."
  :type 'number :group 'cc-butler)

(defcustom cc-butler-compact-drop-ratio 0.7
  "Fraction of the pre-compact context size that counts as \"compacted\".
The statusline is the only observable, so completion is inferred from the
context figure falling below RATIO times its starting value."
  :type 'number :group 'cc-butler)

(defcustom cc-butler-compact-keep nil
  "Session display names never compacted automatically."
  :type '(repeat string) :group 'cc-butler)

(defcustom cc-butler-compact-modal-answer "1"
  "Choice to send when the model-switch confirmation modal appears.
Claude Code's confirmation offers 1 = switch anyway (discarding the prompt
cache).  Discarding the cache is exactly what we want: `/compact' rewrites
the context wholesale, so the cache is about to be worthless regardless."
  :type 'string :group 'cc-butler)

;;;; ------------------------------------------------------------------
;;;; Screen reading — pure functions over terminal text
;;;; ------------------------------------------------------------------

(defconst cc-butler-compact--rule-regexp "\\`[ \t]*───"
  "Match a horizontal rule — the top or bottom edge of the input box.")

(defconst cc-butler-compact--blank "[ \t ​]"
  "One character of input-box padding.
Not the same set as ordinary whitespace: Claude Code pads the `❯' prompt
with U+00A0 NO-BREAK SPACE on some builds (measured on this fleet
2026-07-22; upstream hit the same thing in cc-butler#6).  `string-trim'
leaves NBSP in place, so an empty box trims to a one-character string and
every idle session in the fleet reads as \"has text typed in it\".")

(defun cc-butler-compact--rule-p (line)
  "Non-nil when LINE is an input-box rule."
  (and (stringp line) (string-match-p cc-butler-compact--rule-regexp line)))

(defun cc-butler-compact--strip (s)
  "Strip the prompt glyph and padding — NBSP included — from both ends of S."
  (replace-regexp-in-string
   (concat "\\`\\(?:" cc-butler-compact--blank "\\|[❯>]\\)+"
           "\\|" cc-butler-compact--blank "+\\'")
   "" (or s "")))

(defcustom cc-butler-compact-menu-lines 25
  "How many lines up from the bottom count as the live screen.
Menu detection is confined to this tail.  Scrollback is full of numbered
lists that Claude wrote; only the bottom of the screen is a live dialog."
  :type 'integer :group 'cc-butler)

(defun cc-butler-compact--menu-p (screen)
  "Non-nil when SCREEN shows an open numbered choice menu awaiting a key.

Anchored on the selection marker sitting on a numbered option (`❯ 1.') plus
at least one sibling option row — the same structural signature
`cc-butler--trust-dialog-showing-p' keys on.  Deliberately NOT on wording
and NOT on color: both are theme- and locale-dependent, and this codebase
has been burned three separate times by color-anchored terminal detection
\(see the cc-butler#6 postmortem in `cc-butler--redact-ghost-input-line').

Requiring the marker is what keeps prose out.  Claude writes numbered lists
constantly; none of them carry a selection caret.

Used two ways: as a pre-flight refusal, and — after `/model' — as the
signal that the prompt-cache confirmation is up and waiting for a choice."
  (let* ((all (split-string (or screen "") "\n"))
         (lines (last all (min (length all) cc-butler-compact-menu-lines)))
         (marked (concat "\\`" cc-butler-compact--blank "*❯"
                         cc-butler-compact--blank "*[0-9]+\\."
                         cc-butler-compact--blank "*[^ \t ]"))
         (option (concat "\\`" cc-butler-compact--blank "*[0-9]+\\."
                         cc-butler-compact--blank "*[^ \t ]")))
    (and (cl-some (lambda (l) (string-match-p marked l)) lines)
         (cl-some (lambda (l) (string-match-p option l)) lines)
         t)))

(defun cc-butler-compact--input-line (screen)
  "Return text sitting in SCREEN's input box, or nil when it is empty.
The box is the non-rule line sandwiched between two rules; the last such
sandwich wins, since scrollback can hold older boxes.  The `❯' prompt and
its padding are stripped."
  (let ((lines (split-string (or screen "") "\n"))
        found)
    (cl-loop for (a b c) on lines
             when (and a b c
                       (cc-butler-compact--rule-p a)
                       (cc-butler-compact--rule-p c)
                       (not (cc-butler-compact--rule-p b)))
             do (setq found b))
    (when found
      (let ((s (cc-butler-compact--strip found)))
        (unless (string-empty-p s) s)))))

(defconst cc-butler-compact--box-scan-lines 12
  "How far from the cursor to look for the input box's rules.
Bounds the search for a multi-line input box, without letting a cursor
parked somewhere unrelated be mistaken for one.")

(defun cc-butler-compact--box-region-at (pos)
  "Return (BEG . END) of the input-box text preceding POS, or nil.
BEG is just after the box's opening rule and END is POS, so the result
covers everything typed ahead of the cursor — multi-line input included."
  (save-excursion
    (goto-char pos)
    (let ((cursor-bol (line-beginning-position))
          top bottom (n 0))
      (unless (save-excursion (goto-char cursor-bol) (looking-at "[ \t]*───"))
        (save-excursion
          (goto-char cursor-bol)
          (while (and (not top) (< n cc-butler-compact--box-scan-lines)
                      (zerop (forward-line -1)))
            (setq n (1+ n))
            (when (looking-at "[ \t]*───") (setq top (line-end-position)))))
        (setq n 0)
        (save-excursion
          (goto-char cursor-bol)
          (while (and (not bottom) (< n cc-butler-compact--box-scan-lines)
                      (zerop (forward-line 1)))
            (setq n (1+ n))
            (when (looking-at "[ \t]*───") (setq bottom t))))
        (when (and top bottom) (cons (1+ top) pos))))))

(defun cc-butler-compact--typed-text (dir)
  "Return the text actually TYPED into DIR's input box, or nil if empty.

Reads the terminal CURSOR, not the painted row.  Claude Code paints a
dimmed suggestion — a previous prompt, or a `Try \"...\"' placeholder — into
an EMPTY input box.  That suggestion is decoration: the terminal's input
buffer holds nothing and the cursor stays at the prompt.  Type one
character and the suggestion vanishes and the cursor advances.  So the
cursor's distance past the prompt IS the length of the pending input, and
the painted text is evidence of nothing at all.

Measured across the live fleet 2026-07-23: eight sessions; every empty or
suggestion-showing box had its cursor at column 2, immediately after `❯ ' —
including one painting a full sentence of dimmed Korean — while a session
with `abcd' genuinely typed had it at column 6.

This replaced a face-color test, which cannot be made to work.  Real input
is not reliably unfaced: a typed slash command renders in an accent color
\(#b1b9f9 on this fleet).  The suggestion color is theme-dependent
\(#8686a8 here; the constants upstream keys on say #a7a7a7, which is why
`cc-butler--ghost-face-p' still carries diagnostics for an unresolved miss,
cc-butler#6).  Telling `dim' from `accent' apart by hex is exactly the check
this codebase has been burned by three times.  The cursor is state, styling
is not — and reading styling as state is the same error that had the butler
repeatedly judging its own delivered sends to be unsubmitted.

Fail-safe: if the cursor cannot be read (a non-ghostel terminal backend) or
does not sit inside an input box, fall back to the painted row and treat
whatever is painted there as real."
  (let ((buf (get-buffer (claude-code-ide--get-buffer-name dir))))
    (when (buffer-live-p buf)
      (cc-butler--refresh-terminal-text buf)
      (with-current-buffer buf
        (let ((cursor (and (fboundp 'ghostel-cursor-point)
                           (ignore-errors (ghostel-cursor-point)))))
          (if (not cursor)
              (cc-butler-compact--input-line (cc-butler--read-output dir 40))
            (let ((region (cc-butler-compact--box-region-at cursor)))
              (if (not region)
                  ;; The cursor is not inside an input box — a dialog may own
                  ;; the screen.  Do not conclude the box is empty.
                  (cc-butler-compact--input-line (cc-butler--read-output dir 40))
                (let ((typed (cc-butler-compact--strip
                              (buffer-substring-no-properties
                               (car region) (cdr region)))))
                  (unless (string-empty-p typed) typed))))))))))

(defun cc-butler-compact--pending-input-p (dir)
  "Non-nil when DIR's input box holds text the operator actually typed.
A dimmed suggestion is not input — see `cc-butler-compact--typed-text'."
  (and (cc-butler-compact--typed-text dir) t))

;;;; ------------------------------------------------------------------
;;;; Model names
;;;; ------------------------------------------------------------------

(defconst cc-butler-compact--families '("opus" "sonnet" "haiku")
  "Model families `/model' accepts as a bare alias.")

(defun cc-butler-compact--model-arg (tag)
  "Return the `/model' argument that restores model TAG, or nil.
TAG is a statusline `MODEL:' marker, i.e. Claude Code's display name with
runs of punctuation collapsed to dashes (\"Opus 4.8\" -> \"Opus-4.8\").
Display names are not valid `/model' arguments, so map back to the family
alias.  Returning nil is load-bearing: a model we cannot name is a model we
cannot restore, and the driver refuses to switch away from it at all rather
than strand a session on the wrong model."
  (when (stringp tag)
    (let ((low (downcase tag)))
      (cl-find-if (lambda (f) (string-match-p (regexp-quote f) low))
                  cc-butler-compact--families))))

(defun cc-butler-compact--model-is-p (tag arg)
  "Non-nil when statusline TAG denotes the model named by `/model' ARG."
  (and (stringp tag) (stringp arg)
       (string-match-p (regexp-quote (downcase arg)) (downcase tag))))

(defun cc-butler-compact--model-now (dir)
  "Read DIR's current model tag, bypassing the cleanup layer's TTL cache.
The cache is right for a status display and wrong for a state machine that
polls faster than the TTL and must see the switch the moment it lands."
  (when (boundp 'cc-butler-cleanup--model-cache)
    (remhash dir cc-butler-cleanup--model-cache))
  (cc-butler-cleanup-model-for dir))

(defun cc-butler-compact--context-now (dir)
  "Read DIR's current context size, bypassing the TTL cache.  See above."
  (when (boundp 'cc-butler-cleanup--context-cache)
    (remhash dir cc-butler-cleanup--context-cache))
  (cc-butler-cleanup-context-for dir))

;;;; ------------------------------------------------------------------
;;;; Pre-flight guards
;;;; ------------------------------------------------------------------

(defun cc-butler-compact--blocked-reason (dir &optional ignore-busy)
  "Return a string explaining why DIR must not be compacted now, else nil.
Every branch guards the same failure: a Return landing somewhere we did not
intend.  Unlike `cc-butler-cleanup--safe-candidate-p' this does NOT exclude
the butler or steward — they are the sessions that grow largest and are the
reason the driver exists.

With IGNORE-BUSY, do not treat \"not at a waiting point\" as a blocker.
Callers waiting for a session to go idle use this to test the conditions
that will still matter once it does; busy is the one blocker that resolves
on its own."
  (let ((name (cc-butler--display-name dir)))
    (cond
     ((cc-butler-compact--active-p dir) "compaction already in flight")
     ((member name cc-butler-compact-keep) "on `cc-butler-compact-keep'")
     ((not (let ((b (get-buffer (claude-code-ide--get-buffer-name dir))))
             (and b (buffer-live-p b))))
      "no live terminal")
     ((and (not ignore-busy) (not (cc-butler--waiting-p dir)))
      "session is busy — not at a safe waiting point")
     ((cc-butler-compact--menu-p (cc-butler--read-output dir 40))
      "an interactive menu/wizard is open — Enter would answer it")
     ((cc-butler-compact--pending-input-p dir)
      "unsubmitted text is sitting in the input box")
     (t nil))))

;;;; ------------------------------------------------------------------
;;;; The async state machine
;;;; ------------------------------------------------------------------

(defvar cc-butler-compact--state (make-hash-table :test 'equal)
  "Map a session dir -> in-flight compaction state plist.
Keys: :phase (`switching'|`compacting'|`restoring') :orig-model :orig-arg
:orig-ctx :sent-time :timer :answered :note.  Presence is the lock that
stops a second compaction racing the same session.")

(defvar cc-butler-compact--inhibit-timers nil
  "When non-nil, schedule no real timers (tests drive polls by hand).")

(defun cc-butler-compact--active-p (dir)
  "Non-nil when a compaction is already in flight for DIR."
  (and (gethash dir cc-butler-compact--state) t))

(defun cc-butler-compact--set-state (dir &rest kvs)
  "Merge KVS into the compaction state for DIR; return the plist."
  (let ((st (gethash dir cc-butler-compact--state)))
    (while kvs (setq st (plist-put st (pop kvs) (pop kvs))))
    (puthash dir st cc-butler-compact--state)
    st))

(defun cc-butler-compact--end-state (dir)
  "Cancel any timer and drop the compaction state for DIR."
  (when-let ((st (gethash dir cc-butler-compact--state)))
    (when (timerp (plist-get st :timer)) (cancel-timer (plist-get st :timer))))
  (remhash dir cc-butler-compact--state))

(defun cc-butler-compact--finish (dir fmt &rest args)
  "Conclude the compaction of DIR with a message/log built from FMT/ARGS."
  (cc-butler-compact--end-state dir)
  (let ((msg (apply #'format fmt args)))
    (cc-butler--log "compact: %s │ %s" (cc-butler--display-name dir) msg)
    (ignore-errors (cc-butler--maybe-refresh))
    (message "cc-butler compact: %s — %s" (cc-butler--display-name dir) msg)
    msg))

(defun cc-butler-compact--schedule-poll (dir)
  "Arrange the next poll tick for DIR."
  (unless cc-butler-compact--inhibit-timers
    (cc-butler-compact--set-state
     dir :timer (run-with-timer cc-butler-compact-poll-interval nil
                                #'cc-butler-compact--poll dir))))

(defun cc-butler-compact--step (dir phase text)
  "Send TEXT to DIR, enter PHASE, and re-arm the clock."
  (cc-butler-compact--set-state dir :phase phase :sent-time (float-time)
                                :answered nil)
  (cc-butler--send-input dir text t)
  (cc-butler--log "compact: %s │ %s (sent %s)"
                  (cc-butler--display-name dir) phase text)
  (cc-butler-compact--schedule-poll dir))

(defcustom cc-butler-compact-idle-wait 1800
  "Seconds to wait for a busy session to reach a safe waiting point.
Only used by `cc-butler-compact-session-when-idle'.  Generous by design:
the caller is typically a session queueing its OWN compaction, and the
wait is just a timer — nothing is held and nothing is typed until the
target actually goes idle."
  :type 'number :group 'cc-butler)

(defvar cc-butler-compact--pending (make-hash-table :test 'equal)
  "Map a session dir -> timer waiting for it to become idle.
Separate from `cc-butler-compact--state', which covers a compaction that
has actually started typing.")

(defun cc-butler-compact-waiting-p (dir)
  "Non-nil when a compaction of DIR is queued, waiting for it to go idle."
  (and (gethash dir cc-butler-compact--pending) t))

(defun cc-butler-compact-cancel (dir)
  "Cancel a compaction of DIR that is queued waiting for idle.
Does not touch a compaction already in flight."
  (interactive (list (cc-butler--dir-by-name
                      (completing-read "Cancel queued compaction: "
                                       (mapcar #'cc-butler--display-name
                                               (hash-table-keys cc-butler-compact--pending))
                                       nil t))))
  (when-let ((timer (gethash dir cc-butler-compact--pending)))
    (when (timerp timer) (cancel-timer timer))
    (remhash dir cc-butler-compact--pending)
    (cc-butler--log "compact: %s │ queued compaction cancelled"
                    (cc-butler--display-name dir))
    t))

;;;###autoload
(defun cc-butler-compact-session-when-idle (dir &optional deadline)
  "Compact DIR as soon as it reaches a safe waiting point.

`cc-butler-compact-session' refuses a busy session, which makes it
unusable for the case the whole feature exists for: a session compacting
ITSELF.  A session can only call a tool from inside its own turn, and a
session inside its own turn is by definition busy — so the butler, the
largest context in the fleet, could never be its own target.  It would ask,
be refused for being busy, and the refusal would be structural rather than
circumstantial.

So instead of refusing, wait.  Every OTHER blocker is still checked up
front and still refuses immediately — an open menu or genuinely typed input
is a real problem that waiting does not fix.  Busy is the one blocker that
resolves on its own, so it is the one we poll for: the turn ends, the
session goes idle, and the compaction starts from a timer with nobody's
turn in progress.  DEADLINE defaults to `cc-butler-compact-idle-wait'
seconds from now; `cc-butler-compact-cancel' calls it off."
  (interactive (list (cc-butler--dir-by-name
                      (completing-read "Compact when idle: "
                                       (mapcar (lambda (s)
                                                 (cc-butler--display-name (plist-get s :dir)))
                                               (cc-butler--sessions))
                                       nil t))))
  (let ((name (cc-butler--display-name dir))
        (deadline (or deadline (+ (float-time) cc-butler-compact-idle-wait))))
    (when (cc-butler-compact-waiting-p dir)
      (user-error "A compaction of %s is already queued" name))
    ;; Check everything EXCEPT busy now, so a hopeless request fails loudly
    ;; at the call site instead of silently idling for half an hour.
    (when-let ((why (cc-butler-compact--blocked-reason dir t)))
      (user-error "Refusing to compact %s: %s" name why))
    (if (and (cc-butler--waiting-p dir)
             (not (cc-butler-compact--blocked-reason dir)))
        (progn (cc-butler-compact-session dir) 'started)
      (cc-butler-compact--queue-idle-poll dir deadline)
      (cc-butler--log "compact: %s │ queued — waiting for a safe idle point" name)
      'queued)))

(defun cc-butler-compact--queue-idle-poll (dir deadline)
  "Arrange the next idle check for DIR, giving up at DEADLINE.
The queue entry is recorded whether or not a real timer is scheduled, so
that `cc-butler-compact-waiting-p' and `cc-butler-compact-cancel' describe
the same state under test as in production."
  (puthash dir (or (unless cc-butler-compact--inhibit-timers
                     (run-with-timer cc-butler-compact-poll-interval nil
                                     #'cc-butler-compact--idle-poll dir deadline))
                   t)                   ; queued, but driven by hand (tests)
           cc-butler-compact--pending))

(defun cc-butler-compact--idle-poll (dir deadline)
  "One idle-wait tick: start the compaction once DIR is safely idle."
  (remhash dir cc-butler-compact--pending)
  (let ((name (cc-butler--display-name dir)))
    (cond
     ((not (get-buffer (claude-code-ide--get-buffer-name dir)))
      (cc-butler--log "compact: %s │ session vanished while queued" name))
     ((> (float-time) deadline)
      (cc-butler--log "compact: %s │ gave up waiting for idle (nothing typed)" name)
      (message "cc-butler compact: %s — gave up waiting for a safe idle point" name))
     ((cc-butler-compact--blocked-reason dir)
      ;; Still busy, or something new is in the way; keep waiting.
      (cc-butler-compact--queue-idle-poll dir deadline))
     (t
      (condition-case err
          (cc-butler-compact-session dir)
        (error (cc-butler--log "compact: %s │ queued start failed: %s" name
                               (error-message-string err))))))))

;;;###autoload
(defun cc-butler-compact-session (dir)
  "Compact the context of session DIR, asynchronously.

Switches to `cc-butler-compact-model', answers the prompt-cache
confirmation modal if it appears, runs `/compact', then restores the model
the session started on.  Returns immediately; progress lands in the butler
log and the echo area.

The butler and the steward ARE valid targets — they are the sessions this
exists for.  Refuses when the target is busy, has a menu open, or has
unsubmitted text in its input box (see `cc-butler-compact--blocked-reason'),
and refuses when the current model cannot be named well enough to restore."
  (interactive
   (list (let* ((all (mapcar (lambda (s) (cc-butler--display-name (plist-get s :dir)))
                             (cc-butler--sessions)))
                (pick (completing-read "Compact session: " all nil t)))
           (cl-find-if (lambda (d) (equal (cc-butler--display-name d) pick))
                       (mapcar (lambda (s) (plist-get s :dir)) (cc-butler--sessions))))))
  (let ((name (cc-butler--display-name dir)))
    (when-let ((why (cc-butler-compact--blocked-reason dir)))
      (user-error "Refusing to compact %s: %s" name why))
    ;; Capture the model BEFORE anything is typed — after the switch the
    ;; original is unrecoverable, and an unrestorable session is worse than
    ;; an uncompacted one.
    (let* ((tag (cc-butler-compact--model-now dir))
           (arg (cc-butler-compact--model-arg tag))
           (ctx (cc-butler-compact--context-now dir)))
      (unless arg
        (user-error "Refusing to compact %s: cannot determine a restorable model (statusline says %s)"
                    name (or tag "nothing")))
      (cc-butler-compact--set-state dir :orig-model tag :orig-arg arg
                                    :orig-ctx ctx :note nil)
      (cc-butler--log "compact: %s │ start (ctx %s, model %s)"
                      name (or ctx "?") tag)
      (if (cc-butler-compact--model-is-p tag cc-butler-compact-model)
          ;; Already on the cheap model: nothing to switch, nothing to restore.
          (progn
            (cc-butler-compact--set-state dir :orig-arg nil)
            (cc-butler-compact--step dir 'compacting "/compact"))
        (cc-butler-compact--step
         dir 'switching (format "/model %s" cc-butler-compact-model)))
      (message "cc-butler compact: %s — started (ctx %s)" name (or ctx "?")))))

(defun cc-butler-compact--poll (dir)
  "One poll tick: answer a modal, advance a phase, or time out."
  (when-let ((st (gethash dir cc-butler-compact--state)))
    (let ((phase (plist-get st :phase))
          (sent (plist-get st :sent-time)))
      (cond
       ((not (get-buffer (claude-code-ide--get-buffer-name dir)))
        (cc-butler-compact--finish dir "session vanished mid-compaction — aborted"))
       ((eq phase 'switching)   (cc-butler-compact--poll-switch dir st sent))
       ((eq phase 'compacting)  (cc-butler-compact--poll-compact dir st sent))
       ((eq phase 'restoring)   (cc-butler-compact--poll-restore dir st sent))
       (t (cc-butler-compact--finish dir "unknown phase %S — stopped" phase))))))

(defun cc-butler-compact--poll-switch (dir st sent)
  "Wait for the switch to `cc-butler-compact-model', answering the modal."
  (let ((tag (cc-butler-compact--model-now dir)))
    (cond
     ((cc-butler-compact--model-is-p tag cc-butler-compact-model)
      (cc-butler-compact--step dir 'compacting "/compact"))
     ;; The modal is answered at most once: a slow render must not draw a
     ;; second Return onto whatever screen follows.
     ((and (not (plist-get st :answered))
           (cc-butler-compact--menu-p (cc-butler--read-output dir 40)))
      (cc-butler-compact--set-state dir :answered t)
      (cc-butler--send-input dir cc-butler-compact-modal-answer t)
      (cc-butler--log "compact: %s │ answered switch modal with %s"
                      (cc-butler--display-name dir) cc-butler-compact-modal-answer)
      (cc-butler-compact--schedule-poll dir))
     ((> (- (float-time) sent) cc-butler-compact-step-timeout)
      (cc-butler-compact--abort dir "model switch timed out"))
     (t (cc-butler-compact--schedule-poll dir)))))

(defun cc-butler-compact--poll-compact (dir st sent)
  "Wait for `/compact' to shrink the context, then restore the model."
  (let* ((before (plist-get st :orig-ctx))
         (now (cc-butler-compact--context-now dir))
         (done (and (integerp before) (integerp now)
                    (< now (* cc-butler-compact-drop-ratio before)))))
    (cond
     (done
      (cc-butler-compact--set-state
       dir :note (format "ctx %s -> %s" before now))
      (cc-butler-compact--restore dir))
     ((> (- (float-time) sent) cc-butler-compact-timeout)
      ;; The compaction may still be running; we stop watching, but the model
      ;; must go back regardless.
      (cc-butler-compact--set-state dir :note "compaction not observed to finish")
      (cc-butler-compact--restore dir))
     (t (cc-butler-compact--schedule-poll dir)))))

(defun cc-butler-compact--restore (dir)
  "Begin restoring DIR's original model, or finish when there is none."
  (let* ((st (gethash dir cc-butler-compact--state))
         (arg (plist-get st :orig-arg)))
    (if (not arg)
        (cc-butler-compact--finish dir "compacted (%s); model unchanged"
                                   (or (plist-get st :note) "no delta observed"))
      (cc-butler-compact--step dir 'restoring (format "/model %s" arg)))))

(defun cc-butler-compact--poll-restore (dir st sent)
  "Wait for the original model to come back, answering the modal."
  (let ((tag (cc-butler-compact--model-now dir))
        (arg (plist-get st :orig-arg)))
    (cond
     ((cc-butler-compact--model-is-p tag arg)
      (cc-butler-compact--finish dir "compacted (%s); model restored to %s"
                                 (or (plist-get st :note) "no delta observed") tag))
     ((and (not (plist-get st :answered))
           (cc-butler-compact--menu-p (cc-butler--read-output dir 40)))
      (cc-butler-compact--set-state dir :answered t)
      (cc-butler--send-input dir cc-butler-compact-modal-answer t)
      (cc-butler-compact--schedule-poll dir))
     ((> (- (float-time) sent) cc-butler-compact-step-timeout)
      (cc-butler-compact--finish
       dir "compacted (%s) but model NOT restored — session is on %s, wanted %s"
       (or (plist-get st :note) "no delta observed") (or tag "?") arg))
     (t (cc-butler-compact--schedule-poll dir)))))

(defun cc-butler-compact--abort (dir why)
  "Give up on DIR for WHY, but still try to put the original model back."
  (let* ((st (gethash dir cc-butler-compact--state))
         (arg (plist-get st :orig-arg)))
    (cc-butler--log "compact: %s │ ABORT — %s" (cc-butler--display-name dir) why)
    (if (and arg (not (cc-butler-compact--model-is-p
                       (cc-butler-compact--model-now dir) arg)))
        (progn (cc-butler-compact--set-state dir :note (format "aborted: %s" why))
               (cc-butler-compact--step dir 'restoring (format "/model %s" arg)))
      (cc-butler-compact--finish dir "aborted: %s" why))))

;;;; ------------------------------------------------------------------
;;;; Fleet sweep
;;;; ------------------------------------------------------------------

(defun cc-butler-compact-candidates ()
  "Return dirs of sessions over `cc-butler-compact-threshold', largest first.
Includes the butler and the steward by design."
  (let (out)
    (dolist (s (cc-butler--sessions))
      (let* ((dir (plist-get s :dir))
             (ctx (cc-butler-cleanup-context-for dir)))
        (when (and (integerp ctx) (> ctx cc-butler-compact-threshold))
          (push (cons dir ctx) out))))
    (mapcar #'car (sort out (lambda (a b) (> (cdr a) (cdr b)))))))

;;;###autoload
(defun cc-butler-compact-large-sessions ()
  "Compact every session whose context exceeds `cc-butler-compact-threshold'.

The butler and the steward are included — they are the long-lived sessions
that grow without bound, and excluding them would leave the biggest context
in the fleet as the one nobody may touch.

Each candidate is guarded independently, so a busy or menu-blocked session
is skipped with a reason rather than blocking the sweep.  Returns the list
of dirs actually started."
  (interactive)
  (let (started skipped)
    (dolist (dir (cc-butler-compact-candidates))
      (let ((why (cc-butler-compact--blocked-reason dir)))
        (if why
            (push (format "%s (%s)" (cc-butler--display-name dir) why) skipped)
          (condition-case err
              (progn (cc-butler-compact-session dir) (push dir started))
            (error
             (push (format "%s (%s)" (cc-butler--display-name dir)
                           (error-message-string err))
                   skipped))))))
    (setq started (nreverse started) skipped (nreverse skipped))
    (cc-butler--log "compact: sweep │ started %d, skipped %d%s"
                    (length started) (length skipped)
                    (if skipped (concat ": " (string-join skipped ", ")) ""))
    (message "cc-butler compact: started %d, skipped %d%s"
             (length started) (length skipped)
             (if skipped (concat " — " (string-join skipped ", ")) ""))
    started))

;;;; ------------------------------------------------------------------
;;;; MCP tools — the whole point: the LLM calls one function
;;;; ------------------------------------------------------------------

(defun cc-butler-compact--status-line (dir)
  "One status row for DIR: name, context size, model, and readiness."
  (let* ((name (cc-butler--display-name dir))
         (ctx (cc-butler-cleanup-context-for dir))
         (model (cc-butler-cleanup-model-for dir))
         (why (cc-butler-compact--blocked-reason dir)))
    (format "%-36s %9s  %-10s  %-13s  %s"
            name
            (if (integerp ctx) (format "%.0fk" (/ ctx 1000.0)) "?")
            (or model "?")
            (if (cc-butler--waiting-p dir) "WAITING" "running")
            (cond ((and (integerp ctx) (> ctx cc-butler-compact-threshold) (not why))
                   "OVER THRESHOLD — compactable now")
                  ((and (integerp ctx) (> ctx cc-butler-compact-threshold))
                   (format "OVER THRESHOLD — blocked: %s" why))
                  (why (format "blocked: %s" why))
                  (t "ok")))))

(defun cc-butler-tool-session-status ()
  "MCP tool: per-session context size, model, and compaction readiness."
  (let ((rows (mapcar (lambda (s) (cc-butler-compact--status-line (plist-get s :dir)))
                      (cc-butler--sessions))))
    (if (null rows)
        "No live sessions."
      (concat (format "%-36s %9s  %-10s  %-13s  %s\n" "SESSION" "CONTEXT" "MODEL" "STATE" "COMPACTION")
              (string-join rows "\n")
              (format "\n\nThreshold: %.0fk. A context figure is what the session's statusline last reported, not a live measurement; \"?\" means the statusline is not installed there."
                      (/ cc-butler-compact-threshold 1000.0))))))

(defun cc-butler-tool-compact-session (name)
  "MCP tool: compact the session called NAME, waiting for it to go idle."
  (let ((dir (cc-butler--dir-by-name name)))
    (unless dir
      (error "No live session named %S.  Use session_status for names" name))
    (pcase (cc-butler-compact-session-when-idle dir)
      ('started
       (format "Compaction started for %s — it runs asynchronously (switch to %s, /compact, then restore the original model). Do not send it anything until it finishes; poll session_status to watch the context drop and the model come back."
               name cc-butler-compact-model))
      (_
       (format "Compaction QUEUED for %s — it is mid-turn, so nothing has been typed yet. It will start on its own the moment that turn ends and the session is safely idle, and will give up after %d minutes. If you queued this for YOURSELF, just finish your turn normally: the compaction runs once you stop. Poll session_status to watch it happen."
               name (round (/ cc-butler-compact-idle-wait 60)))))))

(defun cc-butler-tool-compact-large-sessions ()
  "MCP tool: compact every session over the threshold, butler/steward included."
  (let ((started (cc-butler-compact-large-sessions)))
    (if (null started)
        (format "Nothing started. Either no session is over %.0fk, or the ones that are are busy or have something open — session_status shows the per-session reason."
                (/ cc-butler-compact-threshold 1000.0))
      (format "Compaction started for %d session(s): %s. Each runs asynchronously; poll session_status."
              (length started)
              (string-join (mapcar #'cc-butler--display-name started) ", ")))))

;; Idempotent registration.
(when (fboundp 'claude-code-ide-make-tool)
  (setq claude-code-ide-mcp-server-tools
        (seq-remove
         (lambda (spec)
           (member (plist-get (claude-code-ide--normalize-tool-spec spec) :name)
                   '("session_status" "compact_session" "compact_large_sessions")))
         claude-code-ide-mcp-server-tools))

  (claude-code-ide-make-tool
   :function #'cc-butler-tool-session-status
   :name "session_status"
   :description "Show every live session's CONTEXT SIZE alongside its model, whether it is waiting for input, and whether it can be compacted right now. Use this to decide what needs compacting — list_claude_sessions gives the model but not the context size, and scraping the terminal for it is unreliable. Includes the butler and steward, which are usually the largest."
   :args nil)

  (claude-code-ide-make-tool
   :function #'cc-butler-tool-compact-session
   :name "compact_session"
   :description "Compact one session's context: switches it to a cheap model, answers the prompt-cache confirmation, runs /compact, and restores the original model. Driven entirely from elisp — do NOT try to type these commands into a session yourself; each step needs its own submission and the confirmation is a modal. You MAY target the butler, the steward, and YOURSELF: if the target is mid-turn the compaction is queued and starts by itself once that turn ends, so calling this on yourself works — queue it and finish your turn normally. It still refuses outright if a menu is open or someone has genuinely typed something into the input box, since waiting does not fix those."
   :args '((:name "name" :type string
                  :description "Target session name, as shown by session_status.")))

  (claude-code-ide-make-tool
   :function #'cc-butler-tool-compact-large-sessions
   :name "compact_large_sessions"
   :description "Compact every session whose context is over the threshold, largest first — the routine fleet-wide sweep. The butler and steward are included by design; they are the sessions that grow without bound. Sessions that are busy or have something open are skipped with a reason rather than blocking the sweep."
   :args nil))

(provide 'cc-butler-compact)
;;; cc-butler-compact.el ends here
