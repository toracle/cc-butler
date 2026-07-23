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

(defcustom cc-butler-compact-restore-retries 3
  "How many times the restore command may be re-sent before failing.

Typing and submitting are two separate terminal writes with a gap between
them (`cc-butler-submit-delay').  A worker notification arriving in that gap
starts the session's turn, and the Return lands on a session that is no
longer at its input box — so the command sits there typed but unsubmitted.
The session stays on the cheap model, and the stale text collides with
whatever is dispatched next."
  :type 'integer :group 'cc-butler)

(defcustom cc-butler-compact-modal-answers 3
  "How many times one step may answer a confirmation modal before failing.
The modal is re-answered, not latched after one try.  A single attempt can
land while the modal is still rendering and select nothing, and a latch
would then never try again — leaving the session sitting on an unanswered
dialog until a human clears it.  That is the 2026-07-23 freeze."
  :type 'integer :group 'cc-butler)

;;;; ------------------------------------------------------------------
;;;; Screen reading — pure functions over terminal text
;;;; ------------------------------------------------------------------

(defconst cc-butler-compact--rule-regexp "\\`[ \t]*───"
  "Match a horizontal rule — the top or bottom edge of the input box.")

(defun cc-butler-compact--rule-p (line)
  "Non-nil when LINE is an input-box rule."
  (and (stringp line) (string-match-p cc-butler-compact--rule-regexp line)))

;; The prompt/padding vocabulary — the NBSP-aware `cc-butler--input-pad'
;; character class and this stripper — moved down to cc-butler-session.el on
;; 2026-07-24 with the ghost-vs-real decision it serves (cc-butler#6), so the
;; redaction path in the orchestrator shares one definition of it rather than
;; growing a second.  The compaction-local name stays as an alias: it reads
;; better in `cc-butler-compact--input-line' below, and it is one definition
;; either way.
(defalias 'cc-butler-compact--strip 'cc-butler--strip-input-pad)

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
         (marked (concat "\\`" cc-butler--input-pad "*❯"
                         cc-butler--input-pad "*[0-9]+\\."
                         cc-butler--input-pad "*[^ \t ]"))
         (option (concat "\\`" cc-butler--input-pad "*[0-9]+\\."
                         cc-butler--input-pad "*[^ \t ]")))
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

(defun cc-butler-compact--typed-text (dir)
  "Return the text actually TYPED into DIR's input box, or nil if empty.

Ghost-vs-real is decided by `cc-butler--input-state' — the terminal cursor,
not the painted row.  See that docstring for why no color check can do this
job, and for the live measurements behind it.

FAIL-SAFE DIRECTION, compaction guard: an UNKNOWN state is treated as REAL
INPUT.  What this answer gates is whether the driver may TYPE INTO the
session.  Appending `/compact' to the end of a half-finished sentence a
human is composing corrupts their input and then submits something neither
of us wrote; declining a compaction that could safely have run costs one
sweep, and the session comes back around on the next one.  The two mistakes
are not the same size, so when the cursor is unreadable we fall back to the
painted row and believe whatever is painted there.

The redaction in `cc-butler--redact-ghost-input-line' gates the opposite
thing — whether to SHOW a row to a reader — meets the opposite asymmetry,
and therefore takes UNKNOWN the other way.  That divergence is precisely
why `cc-butler--input-state' reports three outcomes instead of resolving to
a boolean on its callers' behalf."
  (let ((buf (get-buffer (claude-code-ide--get-buffer-name dir))))
    (when (buffer-live-p buf)
      (cc-butler--refresh-terminal-text buf)
      (pcase (with-current-buffer buf (cc-butler--input-state))
        (`(real . ,typed) typed)
        (`(ghost . ,_) nil)
        ;; UNKNOWN -> assume real; see the fail-safe note above.
        (_ (cc-butler-compact--input-line (cc-butler--read-output dir 40)))))))

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

(defun cc-butler-compact--answer-cooldown ()
  "Seconds to leave between two answers of the same modal.
Two poll intervals: long enough for the terminal to have repainted, so a
retry is a response to a modal that is really still up rather than to a
stale frame."
  (* 2 cc-butler-compact-poll-interval))

(defun cc-butler-compact--answer-modal (dir st what)
  "Answer a confirmation modal on DIR's screen if one is up.
ST is the compaction state; WHAT names the step, for the log.  Returns
non-nil when an answer was sent, so a caller can use this directly as a
`cond' branch.

Both model switches raise the same modal — the one into
`cc-butler-compact-model' and the one back to the original — so both go
through here rather than each open-coding its own handling.

`cc-butler--send-input' with SUBMIT is the mechanism that actually selects
an entry.  A bare Return does not, and `claude-code-ide--terminal-send-string'
alone reaches the modal without selecting anything; confirmed by hand on
2026-07-23 while clearing this modal from a frozen session.

Answering is retried up to `cc-butler-compact-modal-answers' times rather
than latched after one attempt: the first answer can arrive before the
modal has finished rendering and select nothing at all.

Retries are spaced by `cc-butler-compact--answer-cooldown' seconds.  The
screen this reads is a frame, so an answered modal can still be painted on
the next tick; answering again immediately would drop a stray \"1\" into the
input box of whatever screen followed.  Waiting a couple of poll intervals
means a modal still visible after the cooldown is one that genuinely did
not take."
  (let ((tries (or (plist-get st :answers) 0))
        (last (plist-get st :answered-at)))
    (when (and (< tries cc-butler-compact-modal-answers)
               (or (null last)
                   (> (- (float-time) last) (cc-butler-compact--answer-cooldown)))
               (cc-butler-compact--menu-p (cc-butler--read-output dir 40)))
      (cc-butler-compact--set-state dir :answers (1+ tries)
                                    :answered-at (float-time))
      (cc-butler--send-input dir cc-butler-compact-modal-answer t)
      (cc-butler--log "compact: %s │ answered %s modal with %s (attempt %d)"
                      (cc-butler--display-name dir) what
                      cc-butler-compact-modal-answer (1+ tries))
      t)))

(defun cc-butler-compact--ensure-no-modal (dir)
  "Answer a confirmation modal still standing on DIR, if there is one.
Called from `cc-butler-compact--finish', so every way this driver can stop
— success, timeout, abort — passes through here first.

Giving up on a compaction is recoverable; walking away from a session
parked on a modal the driver itself opened is not.  That session is stopped
dead until a human notices, which on 2026-07-23 took two and a half hours."
  (ignore-errors
    (when (and (get-buffer (claude-code-ide--get-buffer-name dir))
               (cc-butler-compact--menu-p (cc-butler--read-output dir 40)))
      (cc-butler--send-input dir cc-butler-compact-modal-answer t)
      (cc-butler--log "compact: %s │ cleared a modal left standing at finish"
                      (cc-butler--display-name dir))
      t)))

(defun cc-butler-compact--send-raw (dir string)
  "Write STRING into DIR's terminal — no Return, no paste wrapping.
`cc-butler--send-input' is the call for text; this is for the control
characters it does not carry.  Like it, the write happens inside the session
buffer, because the terminal primitives act on the current buffer and take
no session argument."
  (when-let ((buf (get-buffer (claude-code-ide--get-buffer-name dir))))
    (with-current-buffer buf
      (claude-code-ide--terminal-send-string string))
    t))

(defun cc-butler-compact--send-return (dir)
  "Press Return in DIR's terminal without typing anything first.
Used to submit a command already sitting in the input box."
  (when-let ((buf (get-buffer (claude-code-ide--get-buffer-name dir))))
    (with-current-buffer buf
      (claude-code-ide--terminal-send-return))
    t))

(defun cc-butler-compact--own-input (dir st)
  "Return the text WE left unsubmitted in DIR's input box, or nil.

Only ever our own.  What is in the box is compared against the last thing
this driver typed, so genuinely typed operator input — the thing the whole
guard exists to protect — is never mistaken for ours and never touched.  A
prefix counts: the send can be interrupted partway through the string, not
only between the string and the Return."
  (let ((sent (plist-get st :last-sent)))
    (when sent
      (let ((typed (ignore-errors (cc-butler-compact--typed-text dir))))
        (and typed (string-prefix-p typed sent) typed)))))

(defun cc-butler-compact--clear-own-input (dir st)
  "Remove text this driver left sitting in DIR's input box.

The input-box analogue of `cc-butler-compact--ensure-no-modal', and for the
same reason: an abandoned `/model opus' does not just fail quietly, it waits
in the box and prepends itself to whatever is dispatched next.  That is how
a compaction failure turns into a corrupted instruction to an unrelated
session later.

C-u is the kill-to-start the input box responds to.  Verified afterwards —
if the box is still not clear this says so in the log rather than reporting
a tidy finish over a dirty screen."
  (ignore-errors
    (when-let ((mine (cc-butler-compact--own-input dir st)))
      (cc-butler-compact--send-raw dir "\C-u")
      (let ((left (cc-butler-compact--own-input dir st)))
        (cc-butler--log "compact: %s │ %s unsubmitted %S from the input box"
                        (cc-butler--display-name dir)
                        (if left "FAILED to clear" "cleared") mine)
        (not left)))))

(defun cc-butler-compact--finish (dir fmt &rest args)
  "Conclude the compaction of DIR with a message/log built from FMT/ARGS."
  (cc-butler-compact--ensure-no-modal dir)
  (when-let ((st (gethash dir cc-butler-compact--state)))
    (cc-butler-compact--clear-own-input dir st))
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
                                :answers 0 :last-sent text)
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
       ((eq phase 'restore-wait)
        (cc-butler-compact--poll-restore-wait dir st sent))
       ((eq phase 'restoring)   (cc-butler-compact--poll-restore dir st sent))
       (t (cc-butler-compact--finish dir "unknown phase %S — stopped" phase))))))

(defun cc-butler-compact--poll-switch (dir st sent)
  "Wait for the switch to `cc-butler-compact-model', answering the modal."
  (let ((tag (cc-butler-compact--model-now dir)))
    (cond
     ((cc-butler-compact--model-is-p tag cc-butler-compact-model)
      (cc-butler-compact--step dir 'compacting "/compact"))
     ((cc-butler-compact--answer-modal dir st "model switch")
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
      ;; Do not type yet — hold until the session is at a waiting point.
      (cc-butler-compact--set-state dir :phase 'restore-wait
                                    :sent-time (float-time) :answers 0)
      (cc-butler-compact--poll-restore-wait
       dir (gethash dir cc-butler-compact--state) (float-time)))))

(defun cc-butler-compact--send-restore (dir st arg)
  "Put the restore command into DIR, retrying a send that never submitted.

If our command is already sitting in the box, only the Return was lost —
submit what is there rather than typing it again, which would append to it
and produce `/model opus/model opus'.  Otherwise send it fresh."
  (if (cc-butler-compact--own-input dir st)
      (progn
        (cc-butler-compact--set-state dir :phase 'restoring
                                      :sent-time (float-time) :answers 0)
        (cc-butler-compact--send-return dir)
        (cc-butler--log "compact: %s │ restoring (submitted the command already typed)"
                        (cc-butler--display-name dir))
        (cc-butler-compact--schedule-poll dir))
    (cc-butler-compact--step dir 'restoring (format "/model %s" arg))))

(defun cc-butler-compact--poll-restore-wait (dir st sent)
  "Hold the model restore until DIR is idle, then send it.

`/compact' can still be running when the compact phase stops watching, and
typing `/model' into a session that is mid-work is what caused the
2026-07-23 freeze: the restore was sent while the compaction ran on, so the
confirmation modal appeared long after the restore step's own timeout had
fired and stopped polling.  Nothing was left watching, and the session sat
on an unanswered dialog for two and a half hours.

Sending only from a waiting point keeps the modal inside the window that is
actually being watched.  The wait is bounded by `cc-butler-compact-timeout'
and answers any modal that is already up while it waits."
  (let ((arg (plist-get st :orig-arg)))
    (cond
     ((cc-butler-compact--answer-modal dir st "pre-restore")
      (cc-butler-compact--schedule-poll dir))
     ((cc-butler--waiting-p dir)
      (cc-butler-compact--send-restore dir st arg))
     ((> (- (float-time) sent) cc-butler-compact-timeout)
      (cc-butler-compact--finish
       dir "compacted (%s) but model NOT restored — session never reached a waiting point; still on %s, wanted %s"
       (or (plist-get st :note) "no delta observed")
       (or (cc-butler-compact--model-now dir) "?") arg))
     (t (cc-butler-compact--schedule-poll dir)))))

(defun cc-butler-compact--poll-restore (dir st sent)
  "Wait for the original model to come back, answering the modal."
  (let ((tag (cc-butler-compact--model-now dir))
        (arg (plist-get st :orig-arg)))
    (cond
     ((cc-butler-compact--model-is-p tag arg)
      (cc-butler-compact--finish dir "compacted (%s); model restored to %s"
                                 (or (plist-get st :note) "no delta observed") tag))
     ((cc-butler-compact--answer-modal dir st "model restore")
      (cc-butler-compact--schedule-poll dir))
     ;; The command is still sitting in the box: typed, never submitted.
     ;; A notification landed in the gap between the string and the Return
     ;; and started the turn, so the Return went to a session that was no
     ;; longer at its input box.  Waiting cannot fix this — nothing is in
     ;; flight — so go back and send it again once the session is idle.
     ((cc-butler-compact--own-input dir st)
      (let ((tries (or (plist-get st :restore-tries) 0)))
        (if (>= tries cc-butler-compact-restore-retries)
            (cc-butler-compact--finish
             dir "compacted (%s) but model NOT restored — the restore never submitted after %d attempts; session left on %s, wanted %s"
             (or (plist-get st :note) "no delta observed")
             (1+ tries) (or tag "?") arg)
          (cc-butler-compact--set-state dir :restore-tries (1+ tries))
          (cc-butler--log "compact: %s │ restore never submitted (attempt %d) — waiting for idle to retry"
                          (cc-butler--display-name dir) (1+ tries))
          (cc-butler-compact--set-state dir :phase 'restore-wait
                                        :sent-time (float-time))
          (cc-butler-compact--schedule-poll dir))))
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
               ;; Same held restore as the success path — an abort is if
               ;; anything MORE likely to leave the session mid-work.
               (cc-butler-compact--restore dir))
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
;;;; Fleet monitor: tell the steward WHAT needs compacting, mechanically
;;;; ------------------------------------------------------------------
;;
;; Deciding when a session should be compacted is arithmetic — a number is
;; over a threshold — and nothing is gained by having a model rediscover it
;; by reading terminals.  Deciding WHEN to act on that, against whose turn
;; and at what cost, is judgement.  So elisp reports and the steward
;; decides; this layer is deliberately not clever and never acts on its own.

(defcustom cc-butler-compact-monitor-interval 900
  "Seconds between fleet compaction scans when the monitor is enabled."
  :type 'number :group 'cc-butler)

(defcustom cc-butler-compact-monitor-repeat 3600
  "Seconds before the monitor re-reports an unchanged set of candidates.
Without this the steward is told the same thing every scan; with it, a
standing situation is restated occasionally rather than constantly.  A
CHANGED set always reports immediately regardless."
  :type 'number :group 'cc-butler)

(defcustom cc-butler-compact-monitor-notify 'submit
  "How the monitor delivers its report to the steward.

`submit'  type the report in and press Enter — the steward is told, and
          acts on it in that turn.  The default: a report that waits to be
          asked for is a report nobody reads, which is how this fleet got
          to 500k in the first place.
`type'    type it in without submitting.  Rarely what you want: the text
          then sits in the steward's input box, where it both waits for a
          human and reads as pending input to every guard in this file.
nil       queue only, delivered when the steward next drains
          `pending_events'.

Whatever this says, nothing is typed unless the steward is safely idle —
see `cc-butler-compact--blocked-reason'."
  :type '(choice (const :tag "Type and submit" submit)
                 (const :tag "Type without submitting" type)
                 (const :tag "Queue only" nil))
  :group 'cc-butler)

(defcustom cc-butler-compact-remedies
  (concat
   "- compact_session NAME — shrink one session in place, keeping it alive and working.\n"
   "  Safe to call on a session that is mid-turn: it queues and starts when that turn ends.\n"
   "  You may target the butler, the steward, and yourself.\n"
   "- compact_large_sessions — the same sweep across everything over the threshold.\n"
   "- close_topic NAME — for a WORKER whose work is finished and pushed: kills the session\n"
   "  and deletes its workspace outright, reclaiming the whole context rather than shrinking\n"
   "  it. DESTRUCTIVE and gated on a git-safety audit; never the butler or steward.\n"
   "Compaction is the cheap reversible move; closing a finished worker is the one that\n"
   "actually reduces the fleet. A worker that is done does not need compacting.")
  "The remedies quoted to the steward alongside a context-ceiling report.
A report that says only \"this is too big\" leaves the reader to remember
what may be done about it, and the useful distinction — shrink a live
session versus retire a finished one — is exactly what gets forgotten."
  :type 'string :group 'cc-butler)

(defvar cc-butler-compact--last-report nil
  "Cons of (NAMES . TIME) for the monitor's last report, for de-duplication.")

(defvar cc-butler-compact--monitor-timer nil
  "Timer running the fleet compaction scan, or nil.")

(defun cc-butler-compact-fleet-summary ()
  "Return a report of sessions that want compacting, or nil when none.

Pure observation: computed fresh from the current context figures, acts on
nothing, and is safe to call on every steward turn.  Each candidate is
annotated with whether it could be compacted right now or what is in the
way, so the steward can tell \"do it\" from \"wait\" without going to look."
  (let (rows)
    (dolist (dir (cc-butler-compact-candidates))
      (let* ((ctx (cc-butler-cleanup-context-for dir))
             (why (cc-butler-compact--blocked-reason dir)))
        (push (format "- %s (%.0fk) — %s"
                      (cc-butler--display-name dir)
                      (/ (or ctx 0) 1000.0)
                      (cond ((cc-butler-compact-waiting-p dir)
                             "compaction already queued, waiting for it to go idle")
                            ((null why) "ready: compact_session now")
                            ((string-prefix-p "session is busy" why)
                             "mid-turn: compact_session queues it and it starts when the turn ends")
                            (t why)))
              rows)))
    (when rows
      (format "🧠 Context ceiling: %d session(s) over %.0fk and wanting attention:\n%s\n\nWhat you can do — yours to time, since each one interrupts whatever that session does next:\n%s"
              (length rows) (/ cc-butler-compact-threshold 1000.0)
              (mapconcat #'identity (nreverse rows) "\n")
              cc-butler-compact-remedies))))

(defun cc-butler-compact--monitor-scan ()
  "One monitor tick: report new or long-standing candidates to the steward.
No-op when there is no session to report to — a scan with nobody listening
is just a way to be wrong later."
  (when (cc-butler--ops-dir)
    (let* ((dirs (cc-butler-compact-candidates))
           (names (sort (mapcar #'cc-butler--display-name dirs) #'string<))
           (last-names (car cc-butler-compact--last-report))
           (last-time (cdr cc-butler-compact--last-report))
           (changed (not (equal names last-names)))
           (stale (or (null last-time)
                      (> (- (float-time) last-time)
                         cc-butler-compact-monitor-repeat))))
      (when (and names (or changed stale))
        (when-let ((summary (cc-butler-compact-fleet-summary)))
          (setq cc-butler-compact--last-report (cons names (float-time)))
          (cc-butler-compact--report-to-ops summary)))
      ;; Nothing over the line any more: forget, so a recurrence is reported
      ;; afresh instead of being suppressed as a repeat.
      (unless names (setq cc-butler-compact--last-report nil)))))

(defun cc-butler-compact--report-to-ops (summary)
  "Put SUMMARY in front of the steward (or the butler in single mode).
Always queues it for the next `pending_events' drain, and additionally
types it in when `cc-butler-compact-monitor-notify' says so and the
target is safely idle.  Returns non-nil if it was actually typed."
  (let ((ops (cc-butler--ops-dir)))
    (push (list :time (current-time) :dir nil :name "cc-butler" :id nil
                :body summary)
          cc-butler--inbox)
    ;; Typing reuses the compaction guard unchanged: if it is not safe to
    ;; type a slash command at this session, it is not safe to type a
    ;; report at it either.  A blocked target still has the queued copy.
    (let ((typed
           (when (and cc-butler-compact-monitor-notify ops
                      (not (cc-butler-compact--blocked-reason ops)))
             (ignore-errors
               (cc-butler--send-input
                ops (concat "[cc-butler fleet monitor]\n" summary)
                (eq cc-butler-compact-monitor-notify 'submit))
               t))))
      (cc-butler--log "compact monitor │ %d candidate(s) → %s (%s)"
                      (length (cc-butler-compact-candidates))
                      (if ops (cc-butler--display-name ops) "nobody")
                      (cond (typed "notified") (ops "queued only") (t "no ops session")))
      typed)))

;;;###autoload
(define-minor-mode cc-butler-compact-monitor-mode
  "Periodically tell the steward which sessions want compacting or closing.

ON BY DEFAULT, started when this module loads.  Watching the fleet's
context sizes is not an optional extra that someone opts into after the
problem appears — by then a session is at 500k and the opting-in is the
thing that did not happen.  The scan is arithmetic, it costs nothing when
the fleet is healthy, and it no-ops entirely while no butler or steward is
running, so there is no state in which having it on is worse than not.

It reports and stops there.  Every decision about timing — whose turn is
worth spending, shrink versus retire — stays with the steward.

Complements the `pending_events' payload, which carries the same summary
but only when the steward takes a turn.  This covers what that cannot: a
steward sitting idle is never handed a payload, so a fleet can drift over
the ceiling with nobody reading."
  :global t :group 'cc-butler :init-value nil
  (when (timerp cc-butler-compact--monitor-timer)
    (cancel-timer cc-butler-compact--monitor-timer))
  (setq cc-butler-compact--monitor-timer nil
        cc-butler-compact--last-report nil)
  (when cc-butler-compact-monitor-mode
    (setq cc-butler-compact--monitor-timer
          (run-with-timer cc-butler-compact-monitor-interval
                          cc-butler-compact-monitor-interval
                          #'cc-butler-compact--monitor-scan))
    (cc-butler--log "compact monitor │ on (every %ds, threshold %.0fk, notify %s)"
                    cc-butler-compact-monitor-interval
                    (/ cc-butler-compact-threshold 1000.0)
                    (or cc-butler-compact-monitor-notify "queue-only"))))

;; Start with cc-butler itself.  Idempotent: `cc-butler-reload' re-runs this
;; and the mode body cancels the previous timer before arming a new one, so
;; reloading cannot leave two scans running.
(cc-butler-compact-monitor-mode 1)

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
