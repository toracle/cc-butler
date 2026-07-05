;;; cc-butler-cleanup.el --- Session cleaner: externalize -> verify -> teardown  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jeongsoo Park
;; SPDX-License-Identifier: MIT

;; The inverse of the scaffold (`cc-butler-new-topic'): a generic, override-based
;; SESSION CLEANER.  A session is ephemeral compute over a DURABLE externalized
;; record; cleaning up = externalize -> verify -> teardown.  The externalized
;; record is what keeps the work answerable-for (accountability) after the
;; session is gone, so teardown is allowed ONLY after verification proves the
;; record is sufficient to resume from.
;;
;; Teardown tiers (increasing, decreasing reversibility):
;;   `clear'      -- /clear the context; the workspace DIR stays, re-hydratable.
;;   `delete-dir' -- remove the tmp project directory; IRREVERSIBLE, and routed
;;                   through the shared `cc-butler--teardown-workspace' so it
;;                   keeps the git-safety audit + human confirmation.
;;
;; ARCHITECTURE: cc-butler is open source, so the core holds only the MECHANISM
;; and the TRIGGER.  HOW to externalize, HOW to judge it sufficient, WHEN to
;; fire, and how deep to tear down are all OVERRIDABLE by the using site through
;; idiomatic `defcustom' / function-valued variables / hooks, with sane generic
;; defaults here.  Site specifics (e.g. a private knowledge vault or
;; issue-tracker procedure) live in that site's private config as overrides,
;; NOT in core.
;;
;; Entry points:
;;   M-x cc-butler-cleanup-scan             -- manual: pick idle candidates, clean.
;;   M-x cc-butler-cleanup-surface-candidates -- soft 200k: raise candidates to
;;                                             the butler's decision queue.
;;   (cc-butler-session-cleanup DIR TIER)   -- clean one session (async).

(require 'cc-butler-session)
(require 'cc-butler-workspace)
(require 'cc-butler-orchestrator)   ; cc-butler--send-input / cc-butler--read-output

;;;; ------------------------------------------------------------------
;;;; Override points (defcustom / function slots / hooks)
;;;; ------------------------------------------------------------------

;;;; --- externalization -----------------------------------------------

;; The record has TWO distinct roles; keep them separate:
;;   - the RE-HYDRATION record lives INSIDE the topic dir; it survives `/clear'
;;     (context only, dir stays), which is all the `clear' tier needs.
;;   - the DURABLE ACCOUNTABILITY record must survive `delete-dir' (the dir is
;;     gone), so it must live OUTSIDE the topic dir, in a durable store.
;; The generic default writes the re-hydration record in-dir, then PROMOTES a
;; copy to the durable store before a delete-dir teardown; the delete-dir verify
;; checks the OUTSIDE copy.

(defcustom cc-butler-cleanup-handoff-file "HANDOFF.md"
  "Relative path (within the topic workspace) of the in-dir RE-HYDRATION record.
This copy survives `/clear' (the `clear' tier) but NOT `delete-dir'; for
delete-dir it is promoted to `cc-butler-cleanup-handoff-dir' first.  Shared by
the default externalize instruction and the default verifier."
  :type 'string
  :group 'cc-butler)

(defcustom cc-butler-cleanup-handoff-dir
  (expand-file-name "cc-butler/handoffs/" user-emacs-directory)
  "Durable directory, OUTSIDE any topic workspace, for accountability records.
A delete-dir teardown promotes the in-dir re-hydration record here (named
`<session-name>.md') BEFORE deleting the workspace, so the record — the recall/
audit anchor — survives the dir's removal.  Must not live under any topic dir."
  :type 'directory
  :group 'cc-butler)

(defcustom cc-butler-cleanup-externalize-preamble
  "Before this session is cleaned up, externalize its durable record so a blank \
future session can resume the work from that record alone."
  "Leading sentence of the default externalize instruction."
  :type 'string
  :group 'cc-butler)

(defcustom cc-butler-cleanup-sentinel "CC-BUTLER-EXTERNALIZE-DONE"
  "Sentinel line the worker prints when it has finished externalizing.
The default completion predicate greps the session terminal for it — a robust
positive signal, versus guessing from idle/waiting transitions."
  :type 'string
  :group 'cc-butler)

(defcustom cc-butler-cleanup-externalize-function
  #'cc-butler-cleanup--default-externalize-instruction
  "Function returning the externalize INSTRUCTION to type into a session.
Called with the session plist (see `cc-butler-cleanup--session'); returns the
prompt string the core sends to the worker (the worker does the writing).  A
site overrides this to externalize its own way and place (e.g. a vault)."
  :type 'function
  :group 'cc-butler)

;;;; --- verification --------------------------------------------------

(defcustom cc-butler-cleanup-verify-min-bytes 200
  "Minimum size (bytes) for the default verifier to accept a handoff doc."
  :type 'integer
  :group 'cc-butler)

(defcustom cc-butler-cleanup-verify-min-lines 8
  "Minimum line count for the default verifier to accept a handoff doc."
  :type 'integer
  :group 'cc-butler)

(defcustom cc-butler-cleanup-verify-function
  #'cc-butler-cleanup--default-verify
  "Function judging whether externalization sufficed.
Called with the session plist (its :tier key says which tier is running);
returns t when sufficient, or a REASON STRING explaining why not (teardown is
then refused).  For the `delete-dir' tier it MUST check the OUTSIDE durable
record, not an in-dir file that the delete would destroy.  A site overrides this
to check its own record (e.g. a hub note + GitHub cross-ref present)."
  :type 'function
  :group 'cc-butler)

(defcustom cc-butler-cleanup-promote-function
  #'cc-butler-cleanup--default-promote
  "Function that establishes the DURABLE record OUTSIDE the topic dir.
Called with the session plist before a `delete-dir' teardown; returns t on
success or a REASON STRING (teardown is then refused, unless FORCE).  The
generic default copies the in-dir re-hydration record to
`cc-butler-cleanup-handoff-dir'.  A site whose externalize already writes
OUTSIDE the dir (e.g. into a vault) sets this to a no-op that returns t."
  :type 'function
  :group 'cc-butler)

;;;; --- teardown ------------------------------------------------------

(defcustom cc-butler-cleanup-teardown-tier 'clear
  "Default teardown depth: `clear' (context only, dir stays) or `delete-dir'
\(remove the tmp workspace, irreversible)."
  :type '(choice (const :tag "Clear context (re-hydratable)" clear)
                 (const :tag "Delete workspace dir (irreversible)" delete-dir))
  :group 'cc-butler)

(defcustom cc-butler-cleanup-clear-command "/clear"
  "The command typed into a session to clear its context (the `clear' tier)."
  :type 'string
  :group 'cc-butler)

;;;; --- trigger / timing ----------------------------------------------

(defcustom cc-butler-cleanup-context-threshold 200000
  "Context-size (input tokens) at/above which an idle session is RECOMMENDED for
cleanup.  SOFT: crossing it surfaces the session as a candidate (to the butler
decision queue), never a forced auto-teardown.  Nil disables the context rule."
  :type '(choice (const :tag "Disabled" nil) integer)
  :group 'cc-butler)

(defcustom cc-butler-cleanup-idle-threshold 1800
  "Seconds a WAITING/idle session must sit before it is RECOMMENDED for cleanup.
Nil disables the idle rule."
  :type '(choice (const :tag "Disabled" nil) number)
  :group 'cc-butler)

(defcustom cc-butler-cleanup-context-function
  #'cc-butler-cleanup--default-context
  "Function returning a session's current context size in input tokens, or nil.
Called with the session plist.  The default scrapes a `CTX:<n>' marker emitted
by the shipped statusLine helper from the session terminal."
  :type 'function
  :group 'cc-butler)

(defcustom cc-butler-cleanup-context-ttl 3
  "Seconds to cache a session's scraped context size.
The sessions-list feedback tag reads this cache, so a redraw does not re-scrape
every terminal on every refresh."
  :type 'number
  :group 'cc-butler)

(defcustom cc-butler-cleanup-trigger-predicate
  #'cc-butler-cleanup--default-trigger-p
  "Predicate deciding whether a session should be RECOMMENDED for cleanup now.
Called with the session plist; non-nil = recommend.  Only ever consulted at a
SAFE point (the caller pre-filters to WAITING, worker-role, not on the keep
list)."
  :type 'function
  :group 'cc-butler)

(defcustom cc-butler-cleanup-keep nil
  "Display names of sessions to NEVER treat as cleanup candidates.
For genuinely long-running / continuous work that must not be torn down."
  :type '(repeat string)
  :group 'cc-butler)

;;;; --- completion detection ------------------------------------------

(defcustom cc-butler-cleanup-completion-predicate
  #'cc-butler-cleanup--default-completion-p
  "Predicate: has the worker finished externalizing?
Called with (SESSION SENT-TIME); non-nil = done.  The default greps the session
terminal for `cc-butler-cleanup-sentinel'."
  :type 'function
  :group 'cc-butler)

(defcustom cc-butler-cleanup-poll-interval 5
  "Seconds between polls while waiting for externalization to complete."
  :type 'number
  :group 'cc-butler)

(defcustom cc-butler-cleanup-completion-timeout 600
  "Seconds to wait for externalization before aborting the cleanup (untouched)."
  :type 'number
  :group 'cc-butler)

(defcustom cc-butler-cleanup-read-lines 60
  "How many trailing terminal lines to scan for the sentinel / context marker."
  :type 'integer
  :group 'cc-butler)

;;;; --- site extension hooks ------------------------------------------

(defcustom cc-butler-cleanup-after-externalize-functions nil
  "Abnormal hook run AFTER verification passes and BEFORE teardown.
Each function receives the session plist.  Where a site adds outward, gated
side-effects (e.g. a GitHub issue<->vault pointer comment): such actions should
RAISE A BUTLER DECISION rather than act, because they are outward/irreversible.
Run with `run-hook-with-args'."
  :type 'hook
  :group 'cc-butler)

(defcustom cc-butler-cleanup-surface-function
  #'cc-butler-cleanup--default-surface
  "Function that surfaces a recommended cleanup candidate.
Called with (SESSION REASON).  The default appends to the butler's
open-decisions doc (if available), fires the active human push, and logs —
i.e. it RECOMMENDS, it does not act."
  :type 'function
  :group 'cc-butler)

;;;; ------------------------------------------------------------------
;;;; The session model the seams receive
;;;; ------------------------------------------------------------------

(defun cc-butler-cleanup--session (dir &optional tier)
  "Return the session plist the cleaner seams operate on for DIR.
TIER (when a cleanup is in flight) is carried so tier-aware seams (verify,
externalize) can branch on it.  Keys: :dir :name :session-id :topic-dir :tier
:waiting :context."
  (let ((base (list :dir dir
                    :name (cc-butler--display-name dir)
                    :session-id (cc-butler--session-id dir)
                    :topic-dir (cc-butler--close-topic-dir dir)
                    :tier tier
                    :waiting (cc-butler--waiting-p dir))))
    (plist-put base :context
               (ignore-errors (funcall cc-butler-cleanup-context-function base)))
    base))

(defun cc-butler-cleanup--rehydration-file (session)
  "Absolute path of SESSION's in-dir re-hydration record (survives `/clear')."
  (expand-file-name cc-butler-cleanup-handoff-file (plist-get session :topic-dir)))

(defun cc-butler-cleanup--durable-file (session)
  "Absolute path of SESSION's durable OUTSIDE record (survives `delete-dir').
Lives in `cc-butler-cleanup-handoff-dir', named after the session — never inside
the topic dir."
  (expand-file-name (concat (plist-get session :name) ".md")
                    (file-name-as-directory
                     (expand-file-name cc-butler-cleanup-handoff-dir))))

;;;; ------------------------------------------------------------------
;;;; Default seam implementations (generic, site-agnostic)
;;;; ------------------------------------------------------------------

(defun cc-butler-cleanup--default-externalize-instruction (session)
  "Default: instruct the worker to write the in-dir re-hydration record.
On a delete-dir teardown cc-butler promotes this file to a durable store outside
the dir, so it is also the accountability record — write it to stand alone."
  (let ((file (cc-butler-cleanup--rehydration-file session)))
    (concat
     cc-butler-cleanup-externalize-preamble "\n\n"
     (format "Write (or update) a handoff document at `%s`.  Capture, concisely \
but completely: the GOAL, the full current STATE, the DECISIONS already made \
(and why), the concrete NEXT STEPS, and the DURABILITY of every artifact \
(what is committed/pushed/merged vs. only local).  Write it so a blank future \
session could resume this work from THIS FILE ALONE.\n\n" file)
     (format "When you are finished writing it, print a final line containing \
exactly:\n\n%s\n" cc-butler-cleanup-sentinel))))

(defun cc-butler-cleanup--record-sufficient-p (file)
  "Return t when FILE is a non-trivial record, else a reason string."
  (cond
   ((not (file-exists-p file)) (format "record missing: %s" file))
   (t (let ((size (or (file-attribute-size (file-attributes file)) 0))
            (lines (with-temp-buffer
                     (insert-file-contents file)
                     (count-lines (point-min) (point-max)))))
        (cond
         ((< size cc-butler-cleanup-verify-min-bytes)
          (format "record too small (%d < %d bytes): %s"
                  size cc-butler-cleanup-verify-min-bytes file))
         ((< lines cc-butler-cleanup-verify-min-lines)
          (format "record too thin (%d < %d lines): %s"
                  lines cc-butler-cleanup-verify-min-lines file))
         (t t))))))

(defun cc-butler-cleanup--default-verify (session)
  "Default verify: the operative record exists and is non-trivial.
For the `delete-dir' tier this checks the OUTSIDE durable record (it must
survive the dir's removal); otherwise the in-dir re-hydration record."
  (cc-butler-cleanup--record-sufficient-p
   (if (eq (plist-get session :tier) 'delete-dir)
       (cc-butler-cleanup--durable-file session)
     (cc-butler-cleanup--rehydration-file session))))

(defun cc-butler-cleanup--default-promote (session)
  "Default promote: copy the in-dir re-hydration record to the durable store.
Returns t on success or a reason string.  Establishes the OUTSIDE record so it
survives `delete-dir'."
  (let ((src (cc-butler-cleanup--rehydration-file session))
        (dst (cc-butler-cleanup--durable-file session)))
    (cond
     ((not (file-exists-p src)) (format "no in-dir record to promote: %s" src))
     (t (make-directory (file-name-directory dst) t)
        (copy-file src dst t)
        (if (file-exists-p dst) t
          (format "failed to write durable record: %s" dst))))))

(defcustom cc-butler-cleanup-context-window 200000
  "Assumed context-window size (input tokens) for converting a bare
\"<N>% context used\" terminal indicator into a token estimate.  Used only when
no explicit token count is shown."
  :type 'integer
  :group 'cc-butler)

(defun cc-butler-cleanup--default-context (session)
  "Default: read SESSION's current context size (input tokens) from its terminal.
Tries, in order: a `CTX:<n>' marker (from the optional statusLine helper); the
default Claude Code hint \"/clear to save <N>k tokens\" (also M); or \"<N>%
context used\" (estimated against `cc-butler-cleanup-context-window').  Returns
nil when the terminal shows no context indicator (e.g. mid-task)."
  (let ((out (cc-butler--read-output (plist-get session :dir)
                                     cc-butler-cleanup-read-lines)))
    (when out
      (cond
       ((string-match "CTX:\\([0-9]+\\)" out)
        (string-to-number (match-string 1 out)))
       ((string-match "save \\([0-9.]+\\)[kK] tokens" out)
        (round (* 1000 (string-to-number (match-string 1 out)))))
       ((string-match "save \\([0-9.]+\\)[mM] tokens" out)
        (round (* 1000000 (string-to-number (match-string 1 out)))))
       ((string-match "\\([0-9]+\\)% context used" out)
        (round (* (/ (string-to-number (match-string 1 out)) 100.0)
                  cc-butler-cleanup-context-window)))))))

;;;; --- context feedback for the sessions list (cached) ---------------

(defvar cc-butler-cleanup--context-cache (make-hash-table :test 'equal)
  "Map a session dir -> (TIMESTAMP . TOKENS); a short TTL keeps the sessions-list
tag cheap so a redraw does not re-scrape every terminal.")

(defun cc-butler-cleanup-context-for (dir)
  "Return DIR's context size in input tokens, cached for a short TTL.
The TTL is `cc-butler-cleanup-context-ttl'; the value comes from
`cc-butler-cleanup-context-function'.  Nil when unknown."
  (let ((cached (gethash dir cc-butler-cleanup--context-cache))
        (now (float-time)))
    (if (and cached (< (- now (car cached)) cc-butler-cleanup-context-ttl))
        (cdr cached)
      (let ((tok (ignore-errors
                   (funcall cc-butler-cleanup-context-function (list :dir dir)))))
        (puthash dir (cons now tok) cc-butler-cleanup--context-cache)
        tok))))

(defun cc-butler-cleanup-context-tag (dir)
  "Return a compact context tag like \"ctx 187k\" for DIR, or nil when unknown.
This is the sessions-list feedback device; `cc-butler--render' calls it."
  (let ((tok (cc-butler-cleanup-context-for dir)))
    (and (integerp tok) (format "ctx %dk" (max 0 (/ tok 1000))))))

(defun cc-butler-cleanup-context-over-threshold-p (dir)
  "Non-nil when DIR's cached context is at/above the cleanup context threshold.
The threshold is `cc-butler-cleanup-context-threshold'."
  (let ((tok (cc-butler-cleanup-context-for dir)))
    (and cc-butler-cleanup-context-threshold (integerp tok)
         (>= tok cc-butler-cleanup-context-threshold))))

(defun cc-butler-cleanup--default-completion-p (session _sent-time)
  "Default: the session terminal shows the externalize sentinel."
  (let ((out (cc-butler--read-output (plist-get session :dir)
                                     cc-butler-cleanup-read-lines)))
    (and out (string-search cc-butler-cleanup-sentinel out) t)))

(defun cc-butler-cleanup--default-trigger-p (session)
  "Default recommendation rule: over the context OR idle threshold.
The caller has already established the SAFE point (WAITING, worker role, not on
the keep list)."
  (let ((ctx (plist-get session :context))
        (waiting (plist-get session :waiting)))
    (or (and cc-butler-cleanup-context-threshold (integerp ctx)
             (>= ctx cc-butler-cleanup-context-threshold))
        (and cc-butler-cleanup-idle-threshold waiting
             (>= (- (float-time) waiting) cc-butler-cleanup-idle-threshold)))))

(defun cc-butler-cleanup--default-surface (session reason)
  "Default: RECOMMEND SESSION for cleanup (log + decision doc + human push)."
  (let* ((name (plist-get session :name))
         (summary (format "Cleanup candidate: %s" name)))
    (cc-butler--log "cleanup: candidate %s │ %s" name reason)
    (when (fboundp 'cc-butler--append-decision)
      (ignore-errors
        (cc-butler--append-decision (plist-get session :dir) summary reason)))
    (when (fboundp 'cc-butler-notify-decision)
      (ignore-errors (cc-butler-notify-decision summary reason)))
    (message "cc-butler: %s — %s" summary reason)))

;;;; ------------------------------------------------------------------
;;;; Safe-point + candidacy helpers
;;;; ------------------------------------------------------------------

(defun cc-butler-cleanup--worker-p (dir)
  "Non-nil when DIR is an ordinary worker (never the butler or steward)."
  (and (not (equal dir cc-butler--butler))
       (not (and (boundp 'cc-butler--steward) (equal dir cc-butler--steward)))
       (eq 2 (cc-butler--role-rank dir))))

(defun cc-butler-cleanup--safe-candidate-p (dir)
  "Non-nil when DIR is at a SAFE, eligible point to consider for cleanup:
an ordinary worker, currently WAITING/idle (not mid-work), not on the keep list."
  (and (cc-butler-cleanup--worker-p dir)
       (cc-butler--waiting-p dir)
       (not (member (cc-butler--display-name dir) cc-butler-cleanup-keep))))

(defun cc-butler-cleanup--candidates ()
  "Return the session plists that are safe, eligible cleanup candidates."
  (let (out)
    (dolist (s (cc-butler--sessions))
      (let ((dir (plist-get s :dir)))
        (when (and (cc-butler-cleanup--safe-candidate-p dir)
                   (not (cc-butler-cleanup--active-p dir)))
          (push (cc-butler-cleanup--session dir) out))))
    (nreverse out)))

;;;; ------------------------------------------------------------------
;;;; Target resolution: EXPLICIT + CONFIRMED, never a transient point
;;;; ------------------------------------------------------------------
;;
;; The sessions-list cursor can reset to the top (the butler), so a point-based
;; target could silently hit the butler and /clear it.  Targets must therefore
;; be resolved AND confirmed by NAME before any action, and the butler/steward
;; can never be chosen (they are not ordinary workers).

(defun cc-butler-cleanup--eligible-worker-dirs ()
  "All live ordinary-worker session dirs (butler/steward excluded)."
  (let (out)
    (dolist (s (cc-butler--sessions))
      (let ((dir (plist-get s :dir)))
        (when (cc-butler-cleanup--worker-p dir) (push dir out))))
    (nreverse out)))

(defun cc-butler-cleanup--context-target ()
  "Best-effort target dir from context, WITHOUT acting: the session terminal we
are visiting, else the session at point in the list, else nil."
  (or (and (fboundp 'cc-butler--dir-for-buffer)
           (cc-butler--dir-for-buffer (current-buffer)))
      (and (derived-mode-p 'cc-butler-mode)
           (fboundp 'cc-butler--dir-at-point)
           (cc-butler--dir-at-point))))

(defun cc-butler-cleanup--read-target ()
  "Resolve and CONFIRM a worker cleanup target BY NAME; return its dir.
Offers only eligible workers (butler/steward can never appear), defaulting to
the context-resolved session when it is itself an eligible worker.  Signals if
there are no eligible workers or the confirmed name resolves to none."
  (let* ((dirs (cc-butler-cleanup--eligible-worker-dirs)))
    (unless dirs (user-error "No eligible worker sessions to clean"))
    (let* ((names (mapcar #'cc-butler--display-name dirs))
           (cand (cc-butler-cleanup--context-target))
           (default (and cand (cc-butler-cleanup--worker-p cand)
                         (cc-butler--display-name cand)))
           (name (completing-read
                  (if default (format "Clean up worker (default %s): " default)
                    "Clean up worker: ")
                  names nil t nil nil default)))
      (or (seq-find (lambda (d) (equal (cc-butler--display-name d) name)) dirs)
          (user-error "No eligible worker session named %S" name)))))

;;;; ------------------------------------------------------------------
;;;; Soft trigger: surface over-threshold idle sessions as candidates
;;;; ------------------------------------------------------------------

(defvar cc-butler-cleanup--surfaced (make-hash-table :test 'equal)
  "Set of dirs already surfaced as candidates, so we recommend each once.")

(defun cc-butler-cleanup--reason (session)
  "A short human REASON string describing why SESSION is recommended."
  (let ((ctx (plist-get session :context))
        (waiting (plist-get session :waiting)))
    (string-join
     (delq nil
           (list (and cc-butler-cleanup-context-threshold (integerp ctx)
                      (>= ctx cc-butler-cleanup-context-threshold)
                      (format "context ~%dk (≥%dk)" (/ ctx 1000)
                              (/ cc-butler-cleanup-context-threshold 1000)))
                 (and cc-butler-cleanup-idle-threshold waiting
                      (>= (- (float-time) waiting) cc-butler-cleanup-idle-threshold)
                      (format "idle %dm" (/ (truncate (- (float-time) waiting)) 60)))))
     ", ")))

;;;###autoload
(defun cc-butler-cleanup-surface-candidates ()
  "Recommend over-threshold idle worker sessions for cleanup (SOFT).
Scans the fleet at its SAFE points, and for each session the trigger predicate
flags, calls `cc-butler-cleanup-surface-function' (default: raise it to the
butler's decision queue).  Recommends only — never tears anything down.  Each
session is surfaced once until it stops being a candidate."
  (interactive)
  (let ((n 0))
    (dolist (session (cc-butler-cleanup--candidates))
      (let ((dir (plist-get session :dir)))
        (if (funcall cc-butler-cleanup-trigger-predicate session)
            (unless (gethash dir cc-butler-cleanup--surfaced)
              (puthash dir t cc-butler-cleanup--surfaced)
              (funcall cc-butler-cleanup-surface-function
                       session (cc-butler-cleanup--reason session))
              (setq n (1+ n)))
          ;; no longer a candidate — allow it to be surfaced again later
          (remhash dir cc-butler-cleanup--surfaced))))
    (when (called-interactively-p 'interactive)
      (message "cc-butler cleanup: surfaced %d candidate(s)" n))
    n))

;;;; ------------------------------------------------------------------
;;;; The async cleanup state machine: externalize -> verify -> teardown
;;;; ------------------------------------------------------------------

(defvar cc-butler-cleanup--state (make-hash-table :test 'equal)
  "Map a session dir -> in-flight cleanup state plist.
Keys: :phase (`externalizing'|`verifying'|`teardown') :tier :force :sent-time
:timer.  Presence guards against a second cleanup racing the same session.")

(defvar cc-butler-cleanup--inhibit-timers nil
  "When non-nil, do not schedule real poll timers (tests drive polls manually).")

(defun cc-butler-cleanup--active-p (dir)
  "Non-nil when a cleanup is already in flight for DIR."
  (and (gethash dir cc-butler-cleanup--state) t))

(defun cc-butler-cleanup--set-state (dir &rest kvs)
  "Merge KVS into the cleanup state for DIR; return the plist."
  (let ((st (gethash dir cc-butler-cleanup--state)))
    (while kvs (setq st (plist-put st (pop kvs) (pop kvs))))
    (puthash dir st cc-butler-cleanup--state)
    st))

(defun cc-butler-cleanup--end-state (dir)
  "Cancel any timer and drop the cleanup state for DIR."
  (when-let ((st (gethash dir cc-butler-cleanup--state)))
    (when (timerp (plist-get st :timer)) (cancel-timer (plist-get st :timer))))
  (remhash dir cc-butler-cleanup--state))

(defun cc-butler-cleanup--finish (dir fmt &rest args)
  "Conclude the cleanup of DIR with a message/log built from FMT/ARGS."
  (cc-butler-cleanup--end-state dir)
  (let ((msg (apply #'format fmt args)))
    (cc-butler--log "cleanup: %s │ %s" (cc-butler--display-name dir) msg)
    (cc-butler--maybe-refresh)
    (message "cc-butler cleanup: %s — %s" (cc-butler--display-name dir) msg)
    msg))

;;;###autoload
(defun cc-butler-session-cleanup (dir &optional tier force)
  "Clean up session DIR: externalize -> verify -> (confirm) -> teardown.
TIER defaults to `cc-butler-cleanup-teardown-tier'.  With FORCE, the verify gate
is skipped (an explicit operator escape).  Asynchronous: the externalize
instruction is typed into the worker, then the terminal is polled for the
completion sentinel; on completion the record is verified and, only then, the
session is torn down.  Never tears down before verification passes.

The target is resolved and CONFIRMED BY NAME (see
`cc-butler-cleanup--read-target'); the butler/steward can never be a target —
enforced in the core here, not only in the picker."
  (interactive
   (list (cc-butler-cleanup--read-target)
         (and current-prefix-arg
              (intern (completing-read "Tier: " '("clear" "delete-dir") nil t)))
         nil))
  ;; HARD core guard (defense in depth): the butler/steward and any non-worker
  ;; are never a valid target, however DIR was obtained.
  (unless (cc-butler-cleanup--worker-p dir)
    (user-error "Refusing to clean the butler/steward, or a non-worker: %s"
                (cc-butler--display-name dir)))
  (let ((tier (or tier cc-butler-cleanup-teardown-tier)))
    (when (cc-butler-cleanup--active-p dir)
      (user-error "Cleanup already in flight for %s" (cc-butler--display-name dir)))
    (let* ((session (cc-butler-cleanup--session dir tier))
           (instruction (funcall cc-butler-cleanup-externalize-function session)))
      (cc-butler-cleanup--set-state dir :phase 'externalizing :tier tier
                                    :force force :sent-time (float-time))
      (cc-butler--send-input dir instruction t)
      (cc-butler--log "cleanup: %s │ externalizing (tier %s%s)"
                      (cc-butler--display-name dir) tier
                      (if force ", FORCE" ""))
      (cc-butler-cleanup--schedule-poll dir)
      (message "cc-butler cleanup: %s — externalizing…"
               (cc-butler--display-name dir)))))

(defun cc-butler-cleanup--schedule-poll (dir)
  "Arrange the next externalization-completion poll for DIR."
  (unless cc-butler-cleanup--inhibit-timers
    (cc-butler-cleanup--set-state
     dir :timer (run-with-timer cc-butler-cleanup-poll-interval nil
                                #'cc-butler-cleanup--poll dir))))

(defun cc-butler-cleanup--poll (dir)
  "One poll tick: advance to verify when done, abort on timeout, else re-poll."
  (when-let ((st (gethash dir cc-butler-cleanup--state)))
    (let* ((session (cc-butler-cleanup--session dir (plist-get st :tier)))
           (sent (plist-get st :sent-time)))
      (cond
       ((not (get-buffer (claude-code-ide--get-buffer-name dir)))
        (cc-butler-cleanup--finish dir "session vanished mid-externalize — aborted"))
       ((funcall cc-butler-cleanup-completion-predicate session sent)
        (cc-butler-cleanup--verify-and-teardown dir))
       ((> (- (float-time) sent) cc-butler-cleanup-completion-timeout)
        (cc-butler-cleanup--finish
         dir "externalization timed out — NOT torn down (session untouched)"))
       (t (cc-butler-cleanup--schedule-poll dir))))))

(defun cc-butler-cleanup--verify-and-teardown (dir)
  "Verify externalization for DIR; on success run hooks, then tear down.
For `delete-dir', first PROMOTE the record to the durable OUTSIDE store (so it
survives the dir) and verify THAT copy.  Never tears down when the durable
record cannot be established or verification fails (unless FORCE was set)."
  (let* ((st (gethash dir cc-butler-cleanup--state))
         (force (plist-get st :force))
         (tier (plist-get st :tier))
         (session (cc-butler-cleanup--session dir tier))
         (name (cc-butler--display-name dir)))
    (cc-butler-cleanup--set-state dir :phase 'verifying)
    ;; delete-dir: establish the durable OUTSIDE record before verify/delete.
    (let ((promote (if (eq tier 'delete-dir)
                       (funcall cc-butler-cleanup-promote-function session)
                     t)))
      (cond
       ((and (not (eq promote t)) (not force))
        (cc-butler-cleanup--finish
         dir "durable record not established (%s) — NOT torn down"
         (if (stringp promote) promote "promotion failed")))
       (t
        (when (and (not (eq promote t)) force)
          (cc-butler--log "cleanup: %s │ promote failed, continuing (FORCE)" name))
        (let ((res (funcall cc-butler-cleanup-verify-function session)))
          (cond
           ((and (not force) (not (eq res t)))
            (cc-butler-cleanup--finish
             dir "verification FAILED (%s) — NOT torn down"
             (if (stringp res) res "insufficient externalization")))
           (t
            (when (and force (not (eq res t)))
              (cc-butler--log "cleanup: %s │ verify skipped (FORCE)" name))
            ;; Outward/gated site side-effects recommend decisions; never act.
            (ignore-errors
              (run-hook-with-args 'cc-butler-cleanup-after-externalize-functions
                                  session))
            (cc-butler-cleanup--set-state dir :phase 'teardown)
            (cc-butler-cleanup--teardown dir tier force session)))))))))

(defun cc-butler-cleanup--teardown (dir tier force session)
  "Perform the TIER teardown of DIR after verification.
`clear' types the clear command (dir stays, re-hydratable).  `delete-dir' is
irreversible and routes through the shared `cc-butler--teardown-workspace' with
its git-safety audit + explicit human confirmation."
  (pcase tier
    ('clear
     (cc-butler--send-input dir cc-butler-cleanup-clear-command t)
     (cc-butler-cleanup--finish dir "externalized, verified, cleared (dir kept)"))
    ('delete-dir
     (let ((topic (plist-get session :topic-dir)))
       ;; Second, independent guarantee: git-clean (the first is verify above).
       (let ((bad (unless force (cc-butler--close-topic-audit topic))))
         (cond
          (bad
           (cc-butler-cleanup--finish
            dir "delete refused — workspace unsafe (%s); NOT deleted"
            (mapconcat (lambda (c) (file-name-nondirectory
                                    (directory-file-name (car c))))
                       bad ", ")))
          ((not (yes-or-no-p
                 (format "Externalized+verified. DELETE workspace %s%s? "
                         topic (if force " [FORCE]" ""))))
           (cc-butler-cleanup--finish dir "delete declined by operator — dir kept"))
          (t
           (let* ((res (cc-butler--teardown-workspace dir topic force))
                  (deleted (plist-get res :deleted))
                  (note (plist-get res :note)))
             (cc-butler-cleanup--finish
              dir "%s" (cond (deleted (format "torn down; deleted %s" topic))
                             (note (format "kill done; %s" note))
                             (t (format "kill done; %s NOT deleted" topic))))))))))
    (_ (cc-butler-cleanup--finish dir "unknown teardown tier %S — nothing done"
                                  tier))))

;;;; ------------------------------------------------------------------
;;;; Manual trigger: scan + pick + clean
;;;; ------------------------------------------------------------------

(defun cc-butler-cleanup--annotate (session)
  "A one-line label for SESSION in the scan picker."
  (let ((ctx (plist-get session :context))
        (waiting (plist-get session :waiting)))
    (format "%s%s%s"
            (plist-get session :name)
            (if (integerp ctx) (format "  ctx:%dk" (/ ctx 1000)) "")
            (if waiting (format "  idle:%dm"
                                (/ (truncate (- (float-time) waiting)) 60)) ""))))

;;;###autoload
(defun cc-butler-cleanup-scan ()
  "Manual trigger: pick safe idle worker sessions and clean each up.
Lists the fleet's safe, eligible candidates (WAITING workers, not on the keep
list, no cleanup already in flight) annotated with context/idle, lets you
select any, choose a tier, and runs `cc-butler-session-cleanup' on each."
  (interactive)
  (let* ((cands (cc-butler-cleanup--candidates)))
    (unless cands (user-error "No safe cleanup candidates (need an idle worker)"))
    (let* ((labels (mapcar (lambda (s) (cons (cc-butler-cleanup--annotate s)
                                             (plist-get s :dir)))
                           cands))
           (picked (completing-read-multiple
                    "Clean up (comma-separated): " (mapcar #'car labels) nil t))
           (tier (intern (completing-read
                          "Tier: " '("clear" "delete-dir") nil t
                          (symbol-name cc-butler-cleanup-teardown-tier))))
           (dirs (delq nil (mapcar (lambda (l) (cdr (assoc l labels))) picked))))
      (unless dirs (user-error "Nothing selected"))
      (dolist (dir dirs)
        (cc-butler-session-cleanup dir tier))
      (message "cc-butler cleanup: started %d session(s) at tier %s"
               (length dirs) tier))))

;;;; ------------------------------------------------------------------
;;;; MCP tool: close_topic (the butler's IRREVERSIBLE teardown hand)
;;;; ------------------------------------------------------------------
;;
;; Lets the user-facing butler CALL the same teardown the operator would run by
;; hand with `M-x cc-butler-close-topic', turning "type M-x" into "the butler
;; calls the tool -> the operator approves the harness permission prompt".  The
;; human stays in the loop for the irreversible delete; only the friction moves.
;;
;; It reuses (never reimplements) the shared teardown machinery, applying the
;; same guards as the interactive command, in the same order:
;;   1. worker-only        -- `cc-butler-cleanup--worker-p' (never butler/steward)
;;   2. git-safety audit    -- `cc-butler--close-topic-audit' (refuse if unsafe)
;;   3. shared teardown tail -- `cc-butler--teardown-workspace' (kill + delete,
;;                              with its own pre-delete safety RE-CHECK).
;; It never passes FORCE, so both the audit and the teardown re-check are live.

(defun cc-butler-tool-close-topic (name)
  "MCP tool: IRREVERSIBLY tear down worker session NAME and delete its workspace.
Resolve NAME to a live session dir, then apply the interactive command's guards:
the target MUST be an ordinary worker (never the butler or steward); the
git-safety audit MUST pass (no local-only commits, uncommitted changes, or
stashes); only then kill the session and delete the workspace via the shared
`cc-butler--teardown-workspace' (which re-checks safety just before removal).
Returns a human-readable line: deleted (which dir), or refused (why)."
  (let ((dir (cc-butler--dir-by-name name)))
    (cond
     ((not dir)
      (format "No session named %S.  Call list_claude_sessions for names." name))
     ;; Guard 1: worker only — refuse the butler/steward (role-rank 0/1).
     ((not (cc-butler-cleanup--worker-p dir))
      (format "Refused: %S is the butler or steward, not a worker.  \
close_topic only tears down ordinary workers." name))
     (t
      (let* ((topic (cc-butler--close-topic-dir dir))
             ;; Guard 2: git-safety audit — refuse a workspace with local work.
             (bad (cc-butler--close-topic-audit topic)))
        (if bad
            (format "Refused: %s has unsafe git state, NOT deleted —\n%s"
                    name
                    (mapconcat
                     (lambda (cell)
                       (format "  %s: %s"
                               (file-name-nondirectory
                                (directory-file-name (car cell)))
                               (string-join (cdr cell) ", ")))
                     bad "\n"))
          ;; Guard 3: kill + delete via the shared irreversible tail (no FORCE,
          ;; so it re-checks git safety immediately before removing the dir).
          (let* ((res (cc-butler--teardown-workspace dir topic))
                 (killed (plist-get res :killed))
                 (deleted (plist-get res :deleted))
                 (note (plist-get res :note))
                 (bufs (if killed (string-join killed ", ") "(no buffers)")))
            (cc-butler--log "close_topic: %s │ %s" name
                            (if deleted (format "deleted %s" topic)
                              (or note "not deleted")))
            (cc-butler--maybe-refresh)
            (cond
             (deleted (format "Deleted: closed %s — killed %s; removed workspace %s."
                              name bufs topic))
             (note (format "Refused after kill: closed %s (killed %s); \
workspace NOT deleted — %s." name bufs note))
             (t (format "Refused: killed %s's session (%s) but workspace %s \
was NOT deleted." name bufs topic))))))))))

;; Idempotent (re)registration: drop a prior copy before adding.
(setq claude-code-ide-mcp-server-tools
      (seq-remove
       (lambda (spec)
         (equal "close_topic"
                (plist-get (claude-code-ide--normalize-tool-spec spec) :name)))
       claude-code-ide-mcp-server-tools))

(claude-code-ide-make-tool
 :function #'cc-butler-tool-close-topic
 :name "close_topic"
 :description "DESTRUCTIVE, IRREVERSIBLE: kill a finished worker's Claude session and permanently DELETE its topic workspace directory — its git clone(s) and every local file — from disk.  This cannot be undone.  Use it to tear a worker down once its work is safely committed/pushed and you no longer need its workspace.  Safety gates enforced by the tool, in order: (1) refuses unless the target is an ordinary WORKER — it can NEVER close the butler or the steward; (2) runs a git-safety audit and REFUSES, deleting nothing, if any repo in the workspace has local-only commits, uncommitted changes, or stashes; (3) only then kills the session and deletes the directory, re-checking git safety one last time immediately before removal.  Identify the target by its session NAME (from list_claude_sessions).  Returns whether the workspace was deleted, or the reason it was refused.  Because it is irreversible, the operator is asked to approve each call."
 :args '((:name "name"
                :type string
                :description "Session name of the WORKER to close, from list_claude_sessions (e.g. 'app-billing').  Must be a worker — never the butler or steward.")))

;;;; ------------------------------------------------------------------
;;;; Permission gate: keep the destructive tool OUT of the auto-allow list
;;;; ------------------------------------------------------------------
;;
;; The human-approval gate for `close_topic' is the HARNESS permission prompt in
;; the calling Claude session — NOT anything inside Emacs.  But upstream
;; `claude-code-ide-mcp-allowed-tools' defaults to `auto', which passes EVERY
;; registered emacs-tools tool to `--allowedTools' at launch (see
;; `claude-code-ide' launch).  Left at `auto', `close_topic' would be
;; pre-approved and the delete would run UNATTENDED — exactly the bypass we must
;; not allow.  So when the setting is still that default, we replace it with an
;; explicit allow-list of only the NON-destructive tools; the destructive ones
;; are then omitted from `--allowedTools' and fall through to the operator's
;; approval prompt on every call.  Reversible tools stay freely agent-callable.
;; A user who has deliberately customised the setting is left untouched.

(defcustom cc-butler-destructive-tools '("close_topic")
  "Names of emacs-tools MCP tools that IRREVERSIBLY destroy state.
These must never be silently auto-allowed: cc-butler carves them out of the
auto-generated `--allowedTools' list (see `cc-butler-install-tool-permissions')
so the harness prompts the operator for approval on every call.  Names are the
bare tool names (e.g. \"close_topic\"), without the mcp__emacs-tools__ prefix."
  :type '(repeat string)
  :group 'cc-butler)

(defun cc-butler--nondestructive-allowed-tools ()
  "Return the emacs-tools MCP tool names to auto-allow.
Every currently-registered tool EXCEPT those in `cc-butler-destructive-tools',
each fully prefixed as mcp__emacs-tools__NAME for `--allowedTools'."
  (let ((deny (mapcar (lambda (n) (concat "mcp__emacs-tools__" n))
                      cc-butler-destructive-tools)))
    (seq-remove (lambda (full) (member full deny))
                (claude-code-ide-mcp-server-get-tool-names "mcp__emacs-tools__"))))

(defun cc-butler-install-tool-permissions ()
  "Ensure destructive MCP tools require operator approval by default.
When `claude-code-ide-mcp-allowed-tools' is still the upstream default `auto'
\(which would auto-allow every tool, including the irreversible ones), replace it
with an explicit allow-list of only the non-destructive tools, so the
destructive ones fall through to the harness permission prompt.  A user who has
deliberately set the variable to a string or list is left untouched.  Safe to
call again; recomputes from the current tool set."
  (when (and (boundp 'claude-code-ide-mcp-allowed-tools)
             (eq claude-code-ide-mcp-allowed-tools 'auto))
    (setq claude-code-ide-mcp-allowed-tools
          (cc-butler--nondestructive-allowed-tools))))

;; Install once, after every cc-butler tool has registered (this file loads
;; last), so the carve-out sees the full tool set.
(cc-butler-install-tool-permissions)

;;;; ------------------------------------------------------------------
;;;; statusLine helper: ship it + wire it onto new workers
;;;; ------------------------------------------------------------------

(defconst cc-butler-cleanup--dir
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Directory holding this source file (to locate the shipped statusLine helper).")

(defcustom cc-butler-cleanup-statusline-script
  (expand-file-name "statusline/cc-butler-statusline.sh" cc-butler-cleanup--dir)
  "Absolute path to the statusLine helper that emits the `CTX:<n>' marker."
  :type 'file
  :group 'cc-butler)

(defcustom cc-butler-cleanup-statusline-refresh 2
  "`refreshInterval' (seconds) for the worker statusLine, so idle sessions still
update their context marker.  Nil omits it."
  :type '(choice (const :tag "Default" nil) number)
  :group 'cc-butler)

(defcustom cc-butler-cleanup-configure-statusline t
  "When non-nil, install the context-reporting statusLine on each new worker
workspace (via `cc-butler-scaffold-functions')."
  :type 'boolean
  :group 'cc-butler)

(defun cc-butler-cleanup-install-statusline (dir &optional _template)
  "Write a `.claude/settings.json' in DIR wiring the cc-butler statusLine.
Never clobbers an existing settings file (idempotent, non-destructive)."
  (when (and cc-butler-cleanup-configure-statusline
             (file-executable-p cc-butler-cleanup-statusline-script))
    (let* ((cdir (expand-file-name ".claude" dir))
           (file (expand-file-name "settings.json" cdir)))
      (unless (file-exists-p file)
        (make-directory cdir t)
        (let* ((sl (append (list :type "command"
                                 :command cc-butler-cleanup-statusline-script)
                           (when cc-butler-cleanup-statusline-refresh
                             (list :refreshInterval
                                   cc-butler-cleanup-statusline-refresh))))
               (json (json-encode (list :statusLine sl))))
          (write-region json nil file nil 'silent)
          file)))))

(add-hook 'cc-butler-scaffold-functions #'cc-butler-cleanup-install-statusline)

;;;; ------------------------------------------------------------------
;;;; Keybinding
;;;; ------------------------------------------------------------------

(with-eval-after-load 'cc-butler-session
  (when (boundp 'cc-butler-mode-map)
    (define-key cc-butler-mode-map "C" #'cc-butler-cleanup-scan)))

(provide 'cc-butler-cleanup)
;;; cc-butler-cleanup.el ends here
