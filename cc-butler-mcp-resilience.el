;;; cc-butler-mcp-resilience.el --- survive the shared-MCP registry wipe  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jeongsoo Park
;; SPDX-License-Identifier: MIT

;; cc-butler's whole identity story rests on one lookup:
;; `cc-butler--caller-dir' asks `claude-code-ide-mcp-server-get-session-context'
;; which session is speaking, and that is a gethash into
;; `claude-code-ide-mcp-server--sessions' (session-id -> plist), owned by the
;; third-party claude-code-ide package.  That table can be wiped out from
;; under live sessions.  Root-caused live on 2026-08-14, with 9 of 15 fleet
;; sessions orphaned and a clean time boundary (everything started before the
;; wipe orphaned, everything after fine):
;;
;;   1. ONE shared MCP HTTP server serves ALL fleet sessions, guarded by ONE
;;      global counter, `claude-code-ide-mcp-server--session-count'.
;;   2. `claude-code-ide-mcp-server-session-ended' decrements it; at zero it
;;      calls `claude-code-ide-mcp-server--stop-server', which does
;;      (clrhash claude-code-ide-mcp-server--sessions) — EVERY session's
;;      registration, including sessions alive and mid-conversation.  The
;;      counter desyncs from reality whenever one session's teardown is
;;      signalled more than once (`claude-code-ide--cleanup-on-exit' is
;;      reachable from both the process sentinel and explicit stop paths;
;;      the duplicate end decrements again because the unregister half is a
;;      silent no-op while the decrement half only checks > 0).
;;   3. The server restarts when the next NEW session spawns, but
;;      registration only ever happens at process creation
;;      (`claude-code-ide-mcp-server-session-started').  Already-running
;;      sessions never re-register, so they are orphaned PERMANENTLY: every
;;      identity-requiring MCP tool (report_to_steward, send_to_session,
;;      ask_worker, check_inbox, ...) fails with "No calling session
;;      context" until the session is restarted.
;;
;; The recovery asset: `claude-code-ide--session-ids' (dir -> session-id)
;; SURVIVES the wipe — it is only mutated per-session at create/cleanup,
;; never cleared wholesale.  Together with `claude-code-ide--processes'
;; (dir -> process) it holds everything a registration needs.
;;
;; Two independent layers, either of which alone stops the permanent
;; orphaning; together they also cover each other's blind spots:
;;
;;   LAYER 1 — PREVENTION: before the server is allowed to stop and clrhash,
;;   check ground truth — are there live Claude session processes?  Ground
;;   truth is `claude-code-ide--processes' filtered by `process-live-p',
;;   NOT the counter: the counter is exactly the thing that desyncs.
;;
;;   LAYER 2 — SELF-HEALING: when the identity lookup misses for a session
;;   id the transport knows about, rebuild the registration on the spot from
;;   the surviving tables.  This also retroactively heals sessions orphaned
;;   BEFORE this module loaded: their next tool call re-registers them, so
;;   no mass re-registration operation is ever needed.
;;
;; Identity-trust invariant (see the attribution comment in
;; cc-butler-orchestrator.el): session ids are minted at launch into each
;; session's own MCP config and recovered SERVER-SIDE from the request URL
;; path, so a session cannot claim to be another.  Recovery preserves this:
;; it consults only server-side tables (`claude-code-ide--session-ids',
;; `claude-code-ide--processes') keyed by the id the transport already
;; extracted — nothing caller-supplied is trusted.

;;; Code:

(require 'cl-lib)
(require 'cc-butler-session)                ; cc-butler--log
(require 'claude-code-ide)

;;;; ------------------------------------------------------------------
;;;; Layer 1 — don't wipe the registry while sessions are alive
;;;; ------------------------------------------------------------------

(defun cc-butler--mcp-live-session-count ()
  "Number of live Claude session processes, from ground truth.
Counts `claude-code-ide--processes' entries whose process passes
`process-live-p'.  This is deliberately NOT
`claude-code-ide-mcp-server--session-count': that counter desyncing from
reality is the defect this module exists for."
  (let ((n 0))
    (maphash (lambda (_dir proc)
               (when (process-live-p proc) (cl-incf n)))
             claude-code-ide--processes)
    n))

(defun cc-butler--mcp-guard-stop-server (orig &rest args)
  ":around `claude-code-ide-mcp-server--stop-server' — Layer 1.

Interception point: `--stop-server' rather than `session-ended'.  The
destructive act (stop + clrhash) lives in exactly one place, and by the
time it is reached the per-session bookkeeping we WANT to keep — the
unregister and the counter decrement in `session-ended' — has already
run untouched.  Advising `session-ended' instead would mean
re-implementing that bookkeeping just to suppress its last line, and
would not cover any other path that reaches `--stop-server'.

If ground truth says sessions are still alive, refuse the stop and
resync the counter to the live-process count so subsequent session ends
count down from reality again (ending at zero exactly when the last
real session ends).  If nothing is alive, let the stop proceed."
  (let ((live (cc-butler--mcp-live-session-count)))
    (if (zerop live)
        (apply orig args)
      (setq claude-code-ide-mcp-server--session-count live)
      (cc-butler--log
       "mcp-resilience: averted registry wipe — counter hit zero with %d live session(s); counter resynced"
       live)
      nil)))

;;;; ------------------------------------------------------------------
;;;; Layer 2 — lazily re-register a wiped session on lookup miss
;;;; ------------------------------------------------------------------

(defun cc-butler--mcp-recover-session-context (orig &optional session-id)
  ":around `claude-code-ide-mcp-server-get-session-context' — Layer 2.

When the original lookup misses, try to rebuild the registration from
the tables that survive a wipe.  The id in play is the argument or
`claude-code-ide-mcp-server--current-session-id' — both recovered
server-side from the request URL path, never claimed by the caller.
Reverse-look it up in `claude-code-ide--session-ids'; if the matching
dir's process is still live in `claude-code-ide--processes',
re-register (id, dir, buffer), resync the counter to the number of
registered sessions (the invariant `session-started'/`session-ended'
maintain when nothing desyncs), and return the fresh context.  No
match, or a dead process: return nil exactly as before — no phantom
registrations.  Idempotent: once re-registered, the original lookup
hits and recovery never runs again for that id."
  (or (funcall orig session-id)
      (let ((id (or session-id claude-code-ide-mcp-server--current-session-id)))
        (when id
          (let (dir)
            (maphash (lambda (d sid)
                       (when (and (null dir) (equal sid id))
                         (setq dir d)))
                     claude-code-ide--session-ids)
            (when dir
              (let ((proc (gethash dir claude-code-ide--processes)))
                (when (and proc (process-live-p proc))
                  (claude-code-ide-mcp-server-register-session
                   id dir (get-buffer (claude-code-ide--get-buffer-name dir)))
                  (setq claude-code-ide-mcp-server--session-count
                        (hash-table-count claude-code-ide-mcp-server--sessions))
                  (cc-butler--log
                   "mcp-resilience: healed orphaned session %s (%s) — re-registered on lookup miss"
                   id (cc-butler--display-name dir))
                  (funcall orig session-id)))))))))

;;;; ------------------------------------------------------------------
;;;; Installation — idempotent, hot-reload safe
;;;; ------------------------------------------------------------------

(defun cc-butler-mcp-resilience-install ()
  "Install both resilience advices.
Idempotent: `advice-add' of the same named function replaces the
existing advice rather than stacking a duplicate, so a hot reload
(`cc-butler-reload') re-running this is safe — the same guarantee the
`remove-hook'/`add-hook' pairs elsewhere in cc-butler provide."
  (advice-add 'claude-code-ide-mcp-server--stop-server
              :around #'cc-butler--mcp-guard-stop-server)
  (advice-add 'claude-code-ide-mcp-server-get-session-context
              :around #'cc-butler--mcp-recover-session-context))

(defun cc-butler-mcp-resilience-uninstall ()
  "Remove both resilience advices (used by tests; not part of normal life)."
  (advice-remove 'claude-code-ide-mcp-server--stop-server
                 #'cc-butler--mcp-guard-stop-server)
  (advice-remove 'claude-code-ide-mcp-server-get-session-context
                 #'cc-butler--mcp-recover-session-context))

(cc-butler-mcp-resilience-install)

(provide 'cc-butler-mcp-resilience)
;;; cc-butler-mcp-resilience.el ends here
