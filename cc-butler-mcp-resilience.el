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
(require 'claude-code-ide-mcp-http-server)  ; --send-json-error (Layer 3);
                                             ; claude-code-ide only requires
                                             ; this lazily, at server start

;;;; ------------------------------------------------------------------
;;;; Layer 0 — make claude-code-ide's own error signal catchable
;;;; ------------------------------------------------------------------
;;
;; `claude-code-ide-mcp-http-server.el' signals `json-rpc-error' at three
;; sites (a missing required MCP tool argument, an unknown tool name, an
;; unknown JSON-RPC method) but never registers it via `define-error'.
;; `condition-case' matches a handler by the signaled symbol's
;; `error-conditions' property, not by call-stack position — an
;; unregistered symbol has no such property, so NO `condition-case'
;; anywhere, including that file's own `(error ...)' handler in
;; `--handle-post' (meant to catch exactly this and send a JSON-RPC error
;; response), ever catches it. The signal propagates out of the Emacs
;; process filter uncaught, silently logged to `*Messages*' as
;; "error in process filter: ... peculiar error: ...", and the HTTP
;; response is simply never sent — the connection sits open and the MCP
;; caller (e.g. a fleet session driving `send_to_session') hangs until
;; ITS OWN client-side timeout (observed: 300s), with nothing on the
;; server side indicating anything went wrong.
;;
;; `define-error' only mutates the symbol's plist (`error-conditions',
;; `error-message') — it is not tied to the file that calls it, and the
;; property is looked up dynamically at `signal' time, not at load time,
;; so declaring it HERE (a file that already loads before any MCP request
;; can possibly arrive) is sufficient to make `claude-code-ide's own
;; `condition-case' start catching it, without touching the third-party
;; file at all. Registering it twice is harmless — a later call just
;; overwrites the message, verified directly — so this remains safe if
;; upstream ever adds its own `define-error' for the same symbol.
;;
;; This only fixes the symptom for an Emacs process that loads cc-butler;
;; it does not fix `claude-code-ide' for anyone using it standalone — an
;; upstream fix is still the real fix, tracked separately.
(define-error 'json-rpc-error "JSON-RPC Error" 'error)

;;;; ------------------------------------------------------------------
;;;; Layer 3 — recover the request id an error response discards
;;;; ------------------------------------------------------------------
;;
;; Pin this advice targets: claude-code-ide.el v0.2.7, commit
;; a9485f766ea69f6cb3a3f08dea20d44fd6596673 (see project CLAUDE.md — the
;; pin is deliberate; whoever next bumps it should re-check this file
;; still applies).
;;
;; `--handle-post' binds the JSON-RPC `id' inside a `let*' that its own
;; `condition-case' handlers cannot see, so all three handlers pass a
;; literal `nil' for id to `--send-json-error':
;;
;;   (json-parse-error (--send-json-error request nil -32700 "Parse error"))
;;   (quit             (--send-json-error request nil -32001 "Operation cancelled by user"))
;;   (error            (--send-json-error request nil -32603 (format "Internal error: %s" ...)))
;;
;; The diagnostic MESSAGE is built correctly every time -- "Missing
;; required argument: text" is right there in the payload -- but the
;; caller never sees it: the MCP client rejects the whole envelope
;; because a JSON-RPC response's `id' is required and null fails schema
;; validation, so "a normal missing-argument mistake" and "the server is
;; dead" present identically. See the governance note
;; malformed-mcp-result-means-a-discarded-elisp-error.md (six recorded
;; recurrences as of this fix).
;;
;; -32700 (Parse error) is deliberately left alone: JSON-RPC 2.0
;; mandates id:null there (the body never parsed enough to have a
;; usable id), and if this advice's own re-parse also fails there is
;; nothing to recover anyway. The other two codes ARE recoverable
;; because by the time they fire, `--handle-post' already parsed the
;; body successfully once -- id just isn't lexically visible from the
;; handler clause. Re-parsing it from the request the caller still
;; holds needs no new information, only a second look at what already
;; parsed.

(defun cc-butler--mcp-recover-error-id (orig request id code message)
  ":around `claude-code-ide-mcp-http-server--send-json-error' — Layer 3.

When ID is nil and CODE is not -32700, re-parse `(ws-body request)' and
use its `id' field if present. A second parse failure (or any other
problem recovering it) leaves ID nil exactly as before this advice
existed -- never worse than the unpatched behavior."
  (funcall orig request
           (if (and (null id) (not (eq code -32700)))
               (or (ignore-errors
                     (alist-get 'id (json-parse-string (ws-body request)
                                                        :object-type 'alist)))
                   id)
             id)
           code message))

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
              :around #'cc-butler--mcp-recover-session-context)
  (advice-add 'claude-code-ide-mcp-http-server--send-json-error
              :around #'cc-butler--mcp-recover-error-id))

(defun cc-butler-mcp-resilience-uninstall ()
  "Remove all resilience advices (used by tests; not part of normal life)."
  (advice-remove 'claude-code-ide-mcp-server--stop-server
                 #'cc-butler--mcp-guard-stop-server)
  (advice-remove 'claude-code-ide-mcp-server-get-session-context
                 #'cc-butler--mcp-recover-session-context)
  (advice-remove 'claude-code-ide-mcp-http-server--send-json-error
                 #'cc-butler--mcp-recover-error-id))

(cc-butler-mcp-resilience-install)

(provide 'cc-butler-mcp-resilience)
;;; cc-butler-mcp-resilience.el ends here
