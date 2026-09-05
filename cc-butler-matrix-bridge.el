;;; cc-butler-matrix-bridge.el --- Matrix lounge relay, supervised by Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jeongsoo Park
;; SPDX-License-Identifier: MIT

;; This module replaces two machine-specific launchd/systemd-supervised
;; Python daemons (m1, x600) that relayed the shared Warmblood Lounge
;; Matrix room into the "butler" cc-butler session and back. Design and
;; rationale: docs/sdd-draft.md in the cc-butler-topics/cc-butler-matrix-
;; bridge workspace. Summary of the decisions this file encodes:
;;
;; - The bridge's only reason to exist is relaying to a live butler
;;   session, so it should live only as long as Emacs does -- no OS
;;   service registration. `make-process' + a sentinel replace launchd/
;;   systemd (SDD §4).
;; - "First run" (skip history, establish a baseline cursor) is judged by
;;   cursor ABSENCE in state.json, never by process/Emacs restart -- see
;;   bridge.py, which already implements this correctly. This file's job
;;   is to never let state.json be reinitialized on a routine restart
;;   (SDD §4, §10 step 2).
;; - Auto-restart on crash must not become an unbounded crash loop (the
;;   warmble-jumble governance vault's "ghost poller" finding). This
;;   module uses eglot's grace-timer pattern instead of a counter: an
;;   auto-restart is allowed unconditionally, but a SECOND crash inside
;;   the grace period after a (re)start refuses to auto-restart again and
;;   fails loudly (SDD §11 item 3).
;; - Startup reachability is checked by reading the room through the
;;   SAME endpoint the poll loop actually uses, never by a membership
;;   check -- a joined account can get zero rooms back from a bare /sync
;;   (SDD §6, m1 measured 2026-09-04).
;; - Secrets (token, room ID) come from `auth-source', never a plaintext
;;   file in this repo or the bridge's own directory (SDD §7).
;; - The only legal path into a cc-butler session is
;;   `cc-butler--send-input' -- see bridge.py's `inject_into_session'.
;;   This file does not add a second one (SDD §9).

;;; Code:

(require 'cl-lib)
(require 'auth-source)
(require 'json)
(require 'url)

;; Not `(require 'cc-butler-orchestrator)': that pulls in the full
;; claude-code-ide chain just to byte-compile this file. `cc-butler.el'
;; already requires cc-butler-orchestrator before this file, so the real
;; definition is in place by the time these functions actually run.
(declare-function cc-butler--dir-by-name "cc-butler-orchestrator" (name))
(declare-function cc-butler--send-input "cc-butler-orchestrator" (dir text &optional submit))

(defgroup cc-butler-matrix-bridge nil
  "Matrix lounge <-> cc-butler relay, supervised by Emacs."
  :group 'cc-butler
  :prefix "cc-butler-matrix-bridge-")

;;;; --- Per-machine configuration ---

(defcustom cc-butler-matrix-bridge-homeserver-url nil
  "Base URL of this machine's Matrix homeserver, e.g. \"http://localhost:8008\".
Machine-specific -- see docs/sdd-draft.md §2.2. There is no correct
shared default; this must be set per machine."
  :type '(choice (const :tag "Unset" nil) string)
  :group 'cc-butler-matrix-bridge)

(defcustom cc-butler-matrix-bridge-poll-strategy 'messages
  "Which Matrix API this machine's bridge polls with.

`messages' short-polls /rooms/{id}/messages. `sync' long-polls /sync.
Machine-specific, not something to standardize away: /sync does not
surface the lounge room for m1's (account, room) combination even after
a confirmed successful /join (2026-09-04 measured) while /messages works
every time for that same pairing. See docs/sdd-draft.md §2.2."
  :type '(choice (const :tag "/messages short-poll" messages)
                  (const :tag "/sync long-poll" sync))
  :group 'cc-butler-matrix-bridge)

(defcustom cc-butler-matrix-bridge-self-user-id nil
  "This machine's own Matrix user ID (e.g. \"@butler-m1:warmblood-lounge\").
Used to skip re-injecting the bridge's own outgoing messages. Not a
secret -- it is the bridge's public room identity -- but still
machine-specific."
  :type '(choice (const :tag "Unset" nil) string)
  :group 'cc-butler-matrix-bridge)

(defcustom cc-butler-matrix-bridge-human-user-id nil
  "The human operator's Matrix user ID in the lounge room, used to
render the \"정수님\" attribution instead of a raw handle."
  :type '(choice (const :tag "Unset" nil) string)
  :group 'cc-butler-matrix-bridge)

(defcustom cc-butler-matrix-bridge-target-session "butler"
  "Display name of the cc-butler session to relay Matrix messages into,
looked up via `cc-butler--dir-by-name'."
  :type 'string
  :group 'cc-butler-matrix-bridge)

;;;; --- Secrets (auth-source, not plaintext files -- SDD §7) ---

(defcustom cc-butler-matrix-bridge-auth-source-token-host "matrix-bridge-token"
  "`auth-source' host key under which this machine's bearer token is
stored, e.g. in ~/.authinfo.gpg:
  machine matrix-bridge-token login bridge password <token>"
  :type 'string
  :group 'cc-butler-matrix-bridge)

(defcustom cc-butler-matrix-bridge-auth-source-room-host "matrix-bridge-room"
  "`auth-source' host key under which the lounge room ID is stored (not
secret, but kept alongside the token per SDD §7 rather than a plaintext
file in this repo)."
  :type 'string
  :group 'cc-butler-matrix-bridge)

(defun cc-butler-matrix-bridge--auth-source-secret (host)
  "Read the password field of the `auth-source' entry for HOST, erroring
loudly (not silently returning nil) if it is missing -- a missing
secret must not be mistaken for \"bridge intentionally not configured
here\"."
  (let* ((found (car (auth-source-search :host host :max 1 :require '(:secret))))
         (secret (and found (plist-get found :secret))))
    (unless secret
      (error "cc-butler-matrix-bridge: no auth-source entry for host %S" host))
    (if (functionp secret) (funcall secret) secret)))

(defun cc-butler-matrix-bridge--token ()
  (cc-butler-matrix-bridge--auth-source-secret
   cc-butler-matrix-bridge-auth-source-token-host))

(defun cc-butler-matrix-bridge--room-id ()
  (cc-butler-matrix-bridge--auth-source-secret
   cc-butler-matrix-bridge-auth-source-room-host))

;;;; --- Process supervision ---

(defcustom cc-butler-matrix-bridge-script-path
  (expand-file-name "matrix-bridge/bridge.py"
                     (file-name-directory
                      (or load-file-name buffer-file-name default-directory)))
  "Path to the Python bridge script this module supervises."
  :type 'string
  :group 'cc-butler-matrix-bridge)

(defcustom cc-butler-matrix-bridge-python-executable "python3"
  "Python interpreter used to run `cc-butler-matrix-bridge-script-path'."
  :type 'string
  :group 'cc-butler-matrix-bridge)

(defcustom cc-butler-matrix-bridge-restart-grace-period 15
  "Seconds a (re)started bridge process must stay alive before a later
crash is treated as a fresh, unrelated failure rather than a crash loop.
Modeled on eglot's `eglot-autoreconnect': a timer, not a restart
counter -- a crash inside this window after the most recent (re)start
refuses to auto-restart again and fails loudly instead of looping
(warmble-jumble governance: unbounded auto-restart is itself a defect).
See docs/sdd-draft.md §11 item 3."
  :type 'number
  :group 'cc-butler-matrix-bridge)

(defvar cc-butler-matrix-bridge--process nil
  "The running bridge subprocess, or nil.")

(defvar cc-butler-matrix-bridge--inhibit-restart-until nil
  "A `current-time' value before which an automatic restart is refused,
or nil. Set on every (re)start to now + the grace period; a crash while
still in that window means \"didn't last long\" and stops auto-restart.")

(defun cc-butler-matrix-bridge--buffer ()
  (get-buffer-create "*cc-butler-matrix-bridge*"))

(defun cc-butler-matrix-bridge--build-process-environment ()
  "Return `process-environment' extended with the BRIDGE_* variables
bridge.py requires, resolved from this machine's defcustoms and
auth-source secrets. See matrix-bridge/README.md for the full list."
  (dolist (var '(cc-butler-matrix-bridge-homeserver-url
                 cc-butler-matrix-bridge-self-user-id
                 cc-butler-matrix-bridge-human-user-id))
    (unless (symbol-value var)
      (error "cc-butler-matrix-bridge: %S is not configured on this machine" var)))
  (append
   (list (format "BRIDGE_HOMESERVER=%s" cc-butler-matrix-bridge-homeserver-url)
         (format "BRIDGE_TOKEN=%s" (cc-butler-matrix-bridge--token))
         (format "BRIDGE_ROOM_ID=%s" (cc-butler-matrix-bridge--room-id))
         (format "BRIDGE_SELF_USER_ID=%s" cc-butler-matrix-bridge-self-user-id)
         (format "BRIDGE_HUMAN_USER_ID=%s" cc-butler-matrix-bridge-human-user-id)
         (format "BRIDGE_TARGET_SESSION=%s" cc-butler-matrix-bridge-target-session)
         (format "BRIDGE_EMACSCLIENT=%s" (or (executable-find "emacsclient") "emacsclient"))
         (format "BRIDGE_POLL_STRATEGY=%s" (symbol-name cc-butler-matrix-bridge-poll-strategy)))
   process-environment))

(defun cc-butler-matrix-bridge--restart-inhibited-p ()
  "Pure-ish predicate, split out for testing: is an auto-restart
currently refused because the previous (re)start has not yet survived
its grace period?"
  (and cc-butler-matrix-bridge--inhibit-restart-until
       (time-less-p (current-time) cc-butler-matrix-bridge--inhibit-restart-until)))

(defun cc-butler-matrix-bridge--sentinel (proc event)
  (when (memq (process-status proc) '(exit signal))
    (with-current-buffer (process-buffer proc)
      (goto-char (point-max))
      (insert (format "\n[cc-butler-matrix-bridge] process %s (exit %s)\n"
                       (string-trim event) (process-exit-status proc))))
    (if (cc-butler-matrix-bridge--restart-inhibited-p)
        (progn
          (setq cc-butler-matrix-bridge--process nil)
          (message (concat "cc-butler-matrix-bridge: crashed again within the %ss grace "
                            "period -- NOT auto-restarting (would be a crash loop). "
                            "Run M-x cc-butler-matrix-bridge-restart once fixed.")
                   cc-butler-matrix-bridge-restart-grace-period))
      (message "cc-butler-matrix-bridge: process exited (%s), auto-restarting"
               (string-trim event))
      (cc-butler-matrix-bridge-start))))

;;;###autoload
(defun cc-butler-matrix-bridge-start ()
  "Start the Matrix bridge subprocess if it is not already running."
  (interactive)
  (if (process-live-p cc-butler-matrix-bridge--process)
      (message "cc-butler-matrix-bridge: already running")
    (let ((process-environment (cc-butler-matrix-bridge--build-process-environment)))
      (setq cc-butler-matrix-bridge--process
            (make-process
             :name "cc-butler-matrix-bridge"
             :buffer (cc-butler-matrix-bridge--buffer)
             :command (list cc-butler-matrix-bridge-python-executable
                             cc-butler-matrix-bridge-script-path)
             :sentinel #'cc-butler-matrix-bridge--sentinel
             :noquery t)))
    (setq cc-butler-matrix-bridge--inhibit-restart-until
          (time-add (current-time) cc-butler-matrix-bridge-restart-grace-period))
    (message "cc-butler-matrix-bridge: started")))

;;;###autoload
(defun cc-butler-matrix-bridge-stop ()
  "Stop the Matrix bridge subprocess if it is running."
  (interactive)
  (if (process-live-p cc-butler-matrix-bridge--process)
      (progn
        ;; bridge.py saves its cursor every poll iteration already, so a
        ;; plain terminate does not need to coax a save out of it first --
        ;; this just avoids leaving an orphaned subprocess behind, same as
        ;; server.el's kill-emacs-hook convention (SDD §11 item 5).
        (delete-process cc-butler-matrix-bridge--process)
        (setq cc-butler-matrix-bridge--process nil)
        (message "cc-butler-matrix-bridge: stopped"))
    (message "cc-butler-matrix-bridge: not running")))

;;;###autoload
(defun cc-butler-matrix-bridge-restart ()
  "Stop and restart the Matrix bridge subprocess."
  (interactive)
  (cc-butler-matrix-bridge-stop)
  (cc-butler-matrix-bridge-start))

(add-hook 'kill-emacs-hook #'cc-butler-matrix-bridge-stop)

;;;; --- Deferred start: only after the butler session exists ---

;; No hook fires after a cc-butler session's process actually exists
;; (`cc-butler-scaffold-functions' fires at scaffold time, before the
;; session process is launched -- see cc-butler-workspace.el). Absent a
;; real event to hook, this polls for the session with a bounded timer
;; instead of an unbounded wait -- see docs/sdd-draft.md §4's ordering
;; constraint ("bridge starts after the butler session exists").

(defcustom cc-butler-matrix-bridge-deferred-start-poll-interval 2
  "Seconds between checks, while waiting for the target session to exist."
  :type 'number
  :group 'cc-butler-matrix-bridge)

(defcustom cc-butler-matrix-bridge-deferred-start-max-wait 60
  "Seconds to wait for the target session to exist before giving up
loudly instead of starting the bridge with nowhere to inject into."
  :type 'number
  :group 'cc-butler-matrix-bridge)

(defvar cc-butler-matrix-bridge--deferred-start-timer nil)

(defun cc-butler-matrix-bridge--deferred-start-tick (deadline)
  (cond
   ((cc-butler--dir-by-name cc-butler-matrix-bridge-target-session)
    (cancel-timer cc-butler-matrix-bridge--deferred-start-timer)
    (setq cc-butler-matrix-bridge--deferred-start-timer nil)
    (cc-butler-matrix-bridge-start))
   ((time-less-p deadline (current-time))
    (cancel-timer cc-butler-matrix-bridge--deferred-start-timer)
    (setq cc-butler-matrix-bridge--deferred-start-timer nil)
    (message (concat "cc-butler-matrix-bridge: gave up after %ss waiting for "
                      "session %S -- NOT started, run M-x "
                      "cc-butler-matrix-bridge-start once it exists")
             cc-butler-matrix-bridge-deferred-start-max-wait
             cc-butler-matrix-bridge-target-session))))

;;;###autoload
(defun cc-butler-matrix-bridge-start-when-session-ready ()
  "Start the bridge once `cc-butler-matrix-bridge-target-session' exists,
polling boundedly rather than waiting forever."
  (interactive)
  (when (timerp cc-butler-matrix-bridge--deferred-start-timer)
    (cancel-timer cc-butler-matrix-bridge--deferred-start-timer))
  (let ((deadline (time-add (current-time) cc-butler-matrix-bridge-deferred-start-max-wait)))
    (setq cc-butler-matrix-bridge--deferred-start-timer
          (run-at-time 0 cc-butler-matrix-bridge-deferred-start-poll-interval
                       #'cc-butler-matrix-bridge--deferred-start-tick deadline))))

;;;; --- Startup reachability check (SDD §6) ---

(defun cc-butler-matrix-bridge--room-visible-in-response-p (strategy room-id parsed-body)
  "Pure decision, split out from the network fetch for testability: does
PARSED-BODY (a JSON hash-table, string keys) show ROOM-ID as visible
through STRATEGY's endpoint?

For `sync', this checks for ROOM-ID specifically under rooms.join, not
merely that rooms.join is non-empty -- the room could be absent while
other rooms are present. A bare membership check is not a substitute
for this either way (SDD §6): a joined account's plain /sync can come
back with no `rooms' key at all (m1 measured 2026-09-04, real fixture
used in the test for this function)."
  (pcase strategy
    ('messages (> (length (gethash "chunk" parsed-body)) 0))
    ('sync (let* ((rooms (gethash "rooms" parsed-body))
                   (join (and rooms (gethash "join" rooms))))
              (and join (gethash room-id join) t)))
    (_ (error "cc-butler-matrix-bridge: unknown poll strategy %S" strategy))))

(defun cc-butler-matrix-bridge--fetch-json (url token)
  "Fetch URL with bearer TOKEN and return the JSON body as a hash-table
with string keys (NOT alist/symbol keys -- a Matrix room ID like
\"!abc:server\" does not round-trip safely through symbol interning)."
  (let ((url-request-extra-headers `(("Authorization" . ,(concat "Bearer " token)))))
    (with-current-buffer (url-retrieve-synchronously url t nil 15)
      (unwind-protect
          (progn
            (goto-char (point-min))
            (re-search-forward "\n\n" nil t)
            (json-parse-buffer :object-type 'hash-table :array-type 'list))
        (kill-buffer)))))

;;;###autoload
(defun cc-butler-matrix-bridge-check-room-reachable ()
  "Probe the room through the SAME endpoint this machine's poll loop
actually uses (not a membership check -- SDD §6), messaging loudly on
failure rather than failing silently."
  (interactive)
  (let* ((token (cc-butler-matrix-bridge--token))
         (room-id (cc-butler-matrix-bridge--room-id))
         (url (pcase cc-butler-matrix-bridge-poll-strategy
                ('messages (format "%s/_matrix/client/v3/rooms/%s/messages?dir=b&limit=1"
                                    cc-butler-matrix-bridge-homeserver-url
                                    (url-hexify-string room-id)))
                ('sync (format "%s/_matrix/client/v3/sync?timeout=0"
                                cc-butler-matrix-bridge-homeserver-url))))
         (body (cc-butler-matrix-bridge--fetch-json url token))
         (ok (cc-butler-matrix-bridge--room-visible-in-response-p
              cc-butler-matrix-bridge-poll-strategy room-id body)))
    (if ok
        (message "cc-butler-matrix-bridge: room reachable via %s"
                 cc-butler-matrix-bridge-poll-strategy)
      (message (concat "cc-butler-matrix-bridge: ⛔ room NOT visible via %s -- "
                        "joined-but-invisible is a known failure mode (SDD §6), "
                        "do not treat this as merely a slow poll")
               cc-butler-matrix-bridge-poll-strategy))
    ok))

(provide 'cc-butler-matrix-bridge)
;;; cc-butler-matrix-bridge.el ends here
