;;; matrix-bridge.el --- Matrix lounge -> cc-butler session relay  -*- lexical-binding: t; -*-

;; WHAT THIS IS
;; ------------
;; The receive side of the Warmblood Lounge relay, moved inside Emacs.
;; It long-polls the Matrix homeserver's /sync as @butler-x600 and turns each
;; new room message from anyone else into one human-readable line:
;;
;;     [matrix · <sender> · id:$xxx · thread:$yyy] body
;;
;; which is then injected into the "butler" Claude Code session's terminal.
;;
;; WHY IT EXISTS
;; -------------
;; bridge.py did the same thing from outside, reaching in through
;; `emacsclient --eval' with the message hand-escaped into an elisp string
;; literal.  That escaping layer is where a real defect happened.  Running in
;; Emacs, the text is passed as a value and never round-trips through source
;; syntax, so the layer — and its whole class of bug — is gone.
;;
;; It keeps its OWN cursor file (state-elisp.json), deliberately not shared
;; with bridge.py's state.json, so both can run side by side during the
;; changeover without stealing each other's place in the stream.
;;
;; NEVER BLOCK EMACS
;; -----------------
;; Emacs is single-threaded and the poll is a 30-second long poll.  Every
;; request goes through `url-retrieve''s asynchronous callback; there is no
;; `url-retrieve-synchronously' anywhere in this file, and there must never be
;; one.  A blocking call here freezes 정수님's typing for 30 seconds at a time.
;;
;; SHADOW MODE (the default)
;; -------------------------
;; `matrix-bridge-shadow' is t out of the box: messages are appended to the
;; *matrix-bridge-shadow* buffer instead of being injected, so you can watch
;; it run beside the Python bridge and compare.  To go live:
;;
;;     (setq matrix-bridge-shadow nil)
;;
;; and stop bridge.py, so the same message is not delivered twice.
;;
;;     M-x matrix-bridge-start / M-x matrix-bridge-stop / M-x matrix-bridge-self-test

;;; Code:

(require 'url)
(require 'cl-lib)

(defvar matrix-bridge-shadow t
  "When non-nil, log messages to a buffer instead of injecting them.
Set to nil to go live.  See the commentary at the top of this file.")

(defvar matrix-bridge-homeserver "http://localhost:8008")
(defvar matrix-bridge-dir "/home/toracle/services/matrix-bridge")
(defvar matrix-bridge-conduit-dir "/home/toracle/services/conduit")
(defvar matrix-bridge-token-file
  (expand-file-name "butler-x600.token" matrix-bridge-conduit-dir))
(defvar matrix-bridge-room-id-file
  (expand-file-name "lounge-room-id.txt" matrix-bridge-conduit-dir))
;; Deliberately NOT state.json -- bridge.py owns that one.
(defvar matrix-bridge-state-file
  (expand-file-name "state-elisp.json" matrix-bridge-dir))

(defvar matrix-bridge-target-session "butler")
(defvar matrix-bridge-self-user-id nil
  "This fleet's own Matrix user id, e.g. \"@butler-x600:warmblood-lounge\".

Deliberately nil: it feeds the \"don't re-deliver my own messages\" filter in
`matrix-bridge-event-line', and a default belonging to ONE fleet is worse than
no default at all.  Carrying another fleet's id here means the filter drops
exactly that fleet's messages -- the relay starts cleanly, logs nothing, and
delivers nothing, which on screen is indistinguishable from a quiet room.

`matrix-bridge-start' refuses to run while this is nil, so a fleet that forgets
to set it fails loudly at startup instead of going silently deaf.  Set it in
per-machine config, not here.")
(defvar matrix-bridge-human-user-id "@jeongsoo:warmblood-lounge")
(defvar matrix-bridge-human-reminder
  "\n※ 이 메시지에 대한 답은 반드시 이 방(Matrix)에 남겨라 — 터미널 응답만으로 \
끝내지 말 것. 답할 때는 이 줄 머리 대괄호 안의 `id:'/`thread:'/`reply:' 값을 \
그대로 넘겨 같은 스레드·답장으로 이어 붙여라."
  "Reminder appended to messages from `matrix-bridge-human-user-id'.

The human asked (2026-09-06) for two things the relaying session kept
forgetting: answer IN the room rather than only in its own terminal, and keep
the thread by reusing the ids this line already carries.  Both are per-turn
discipline, so the reminder rides along with every message he sends instead of
living in a document someone has to remember to reread.

A string, not a hardcoded sentence in the formatter, because the way a fleet
posts back to the room is fleet-local -- naming one fleet's script here would
be the same mistake as shipping one fleet's `matrix-bridge-self-user-id'.
Set it to the empty string to switch the reminder off.")

(defvar matrix-bridge-sync-timeout-ms 30000)
(defvar matrix-bridge-retry-seconds 5)

(defvar matrix-bridge-media-dir
  (expand-file-name "media" matrix-bridge-dir)
  "Directory downloaded Matrix attachments (currently: `m.audio' only) are
written to.  Derived from `matrix-bridge-dir' like `matrix-bridge-state-file'
-- override directly if a fleet's media directory does not live under it.")

(defvar matrix-bridge-monocle-path nil
  "Absolute path to THIS machine's `monocle' CLI binary.

Deliberately nil, like `matrix-bridge-self-user-id': a path that is right on
one fleet's machine is wrong on the other's, and PATH cannot be trusted to
find it either -- a future launchd/systemd launch context inherits no
interactive shell PATH at all (the same defect class documented on
`matrix-bridge-monocle-home'). Set in per-machine config.  Left nil, the
monocle call simply fails to start -- caught like any other start failure,
degrading to the `텍스트 변환 시작 실패' branch rather than crashing.")

(defvar matrix-bridge-monocle-home nil
  "Absolute value to inject as HOME for the `monocle' subprocess call ONLY.

`monocle' reads $HOME to find ~/.monocle/credentials.json.  Under a future
launchd/systemd launch context the launching process may inherit no HOME at
all, so this must be an explicit per-machine value set in config -- reading
`(getenv \"HOME\")' here at load time would silently reintroduce the exact
gap this variable exists to close (see the ported reference README's \"Why
HOME has to be injected\" section: the Python original hardcodes this same
path as a literal for the same reason).

Used ONLY as a `let'-bound addition to `process-environment' around the
single `make-process' call in `matrix-bridge--transcribe-audio' -- never via
`setenv' -- so it can never leak into the rest of this Emacs process's
environment.  Left nil, no HOME override is applied at all.")

(defvar matrix-bridge--generation 0
  "Bumped by start and stop.  A callback or timer from an older generation
does nothing, so a stopped loop cannot resurrect itself and a second start
cannot leave two loops running.")
(defvar matrix-bridge--timer nil)
(defvar matrix-bridge--watchdog nil)
(defvar matrix-bridge--since nil)
(defvar matrix-bridge--token nil)
(defvar matrix-bridge--room-id nil)

;;; --- small helpers --------------------------------------------------------

(defun matrix-bridge--log (fmt &rest args)
  (let ((line (concat (format-time-string "%Y-%m-%d %H:%M:%S ")
                      (apply #'format fmt args))))
    (with-current-buffer (get-buffer-create "*matrix-bridge-log*")
      (goto-char (point-max))
      (insert line "\n"))))

(defun matrix-bridge--shadow-deliver (text)
  (with-current-buffer (get-buffer-create "*matrix-bridge-shadow*")
    (goto-char (point-max))
    (insert (format-time-string "%Y-%m-%d %H:%M:%S ") text "\n")))

(defun matrix-bridge--get (obj key)
  "Value of KEY in the alist OBJ produced by `json-parse-string'."
  (cdr (assq key obj)))

(defun matrix-bridge--flag (obj key)
  "Read KEY from OBJ as a boolean.

JSON `false' parses to `:json-false', which is *non-nil* in Lisp -- reading it
with `matrix-bridge--get' and testing it directly inverts the answer.  Element
writes `\"is_falling_back\": false' explicitly on a genuine reply inside a
thread, so the naive test silently dropped every such reply (observed on 4 of
248 real room events, 2026-09-05).  Normalize the JSON falsehoods here, once."
  (let ((v (matrix-bridge--get obj key)))
    (and v (not (eq v :json-false)) (not (eq v 'false)))))

(defun matrix-bridge--read-trimmed (file)
  (with-temp-buffer
    (insert-file-contents file)
    (string-trim (buffer-string))))

(defun matrix-bridge--load-since ()
  (when (file-exists-p matrix-bridge-state-file)
    (matrix-bridge--get
     (json-parse-string (matrix-bridge--read-trimmed matrix-bridge-state-file)
                        :object-type 'alist :null-object nil :false-object nil)
     'since)))

(defun matrix-bridge--save-since (token)
  (with-temp-file matrix-bridge-state-file
    (insert (json-serialize `((since . ,token))))))

;;; --- formatting (pure; covered by `matrix-bridge-self-test') --------------

(defun matrix-bridge-attribution (sender)
  "Human-facing name for SENDER."
  (if (equal sender matrix-bridge-human-user-id)
      "정수님"
    ;; "@butler-macbook-m1-max:..." -> "butler-macbook-m1-max"
    (string-remove-prefix "@" (car (split-string sender ":")))))

(defun matrix-bridge-envelope (event-id content)
  "The courier's markings: which message this is, and what it answers.

Always carries the event's own id -- that is what lets the session open a
NEW thread on a plain message, not merely answer inside an existing one."
  (let ((parts (list (format "id:%s" event-id)))
        (rel (matrix-bridge--get content 'm.relates_to)))
    (when (consp rel)
      (let ((thread-id (matrix-bridge--get rel 'event_id))
            (reply (matrix-bridge--get rel 'm.in_reply_to)))
        (when (and (equal (matrix-bridge--get rel 'rel_type) "m.thread") thread-id)
          (push (format "thread:%s" thread-id) parts))
        ;; A thread reply carries a synthetic in_reply_to for old clients;
        ;; only a genuine reply (no fallback flag) is worth announcing.
        (when (and (consp reply)
                   (matrix-bridge--get reply 'event_id)
                   (not (matrix-bridge--flag rel 'is_falling_back)))
          (push (format "reply:%s" (matrix-bridge--get reply 'event_id)) parts))))
    (concat " · " (string-join (nreverse parts) " · "))))

(defun matrix-bridge-describe (content)
  "The letter itself -- or a claim ticket when it is not text.

Audio, images and files are NOT fetched here (that is a later step); the
point is that they stop vanishing silently."
  (let ((msgtype (or (matrix-bridge--get content 'msgtype) ""))
        (body (or (matrix-bridge--get content 'body) "")))
    (if (member msgtype '("m.text" "m.notice" "m.emote"))
        body
      (let* ((info (matrix-bridge--get content 'info))
             (bits (list msgtype body
                         (matrix-bridge--get info 'mimetype)
                         (matrix-bridge--get content 'url))))
        (concat "[첨부 "
                (string-join (seq-remove #'string-empty-p (delq nil bits)) " · ")
                "]")))))

(defun matrix-bridge-event-line (ev)
  "One relay line for room event EV, or nil if EV is not ours to deliver."
  (let ((sender (matrix-bridge--get ev 'sender))
        (content (matrix-bridge--get ev 'content)))
    (when (and (equal (matrix-bridge--get ev 'type) "m.room.message")
               (not (equal sender matrix-bridge-self-user-id))
               ;; a redaction or state-ish payload has nothing to deliver
               (matrix-bridge--get content 'msgtype))
      (format "[matrix · %s%s] %s%s"
              (matrix-bridge-attribution sender)
              (matrix-bridge-envelope (or (matrix-bridge--get ev 'event_id) "") content)
              (matrix-bridge-describe content)
              (if (equal sender matrix-bridge-human-user-id)
                  matrix-bridge-human-reminder
                "")))))

;;; --- delivery -------------------------------------------------------------

(defun matrix-bridge--deliver (text)
  (cond
   (matrix-bridge-shadow
    (matrix-bridge--shadow-deliver text))
   ((not (and (fboundp 'cc-butler--send-input) (fboundp 'cc-butler--dir-by-name)))
    (matrix-bridge--log "WARN cc-butler injection unavailable; shadowing instead")
    (matrix-bridge--shadow-deliver text))
   (t
    (condition-case err
        (funcall 'cc-butler--send-input
                 (funcall 'cc-butler--dir-by-name matrix-bridge-target-session)
                 text t)
      (error
       (matrix-bridge--log "FAIL inject: %S -- shadowing instead" err)
       (matrix-bridge--shadow-deliver text))))))

;;; --- audio transcription (the `m.audio' axis) ------------------------------
;;
;; Ported from audio_axis.py (macbook-m1-max's bridge.py, live-verified
;; 2026-09-06 21:14, both success and failure) -- see
;; reference/audio-transcription-from-bridge-py/ on the branch this landed
;; from for the ground truth this was ported from (deleted from this branch
;; once the port was verified, per that bundle's own README).
;;
;; Two invariants carried over unchanged from the Python original:
;;
;;   1. HOME is injected for the `monocle' subprocess call ONLY, via a
;;      `let'-bound `process-environment' around that one `make-process'
;;      call (see `matrix-bridge--transcribe-audio') -- never `setenv'.
;;   2. The downloaded bytes are written to disk BEFORE `monocle' is ever
;;      invoked (see `matrix-bridge--handle-audio'), so the original file's
;;      survival never depends on anything `monocle' does afterwards.  This
;;      is achieved purely by ordering -- there is deliberately no
;;      `condition-case' safety net "restoring" the file on failure, because
;;      the ordering already makes that unnecessary.
;;
;; One deliberate PLUMBING substitution from the Python original:
;; `poll_pending_transcriptions()' there is a manually-maintained list
;; polled once per main-loop tick, because that script had no better async
;; primitive available.  `make-process''s `:sentinel' is elisp's native
;; equivalent -- Emacs invokes it automatically on process exit, no manual
;; polling required -- and this file already uses the equivalent
;; event-driven idiom for HTTP (the `url-retrieve' callback in
;; `matrix-bridge--poll').  This swap changes none of the six outcome
;; branches or the two invariants above; it only replaces how completion is
;; noticed.

(defun matrix-bridge--sanitize-filename (name)
  "Reduce NAME (sender-controlled message body text) to a safe filename
component.  Not just stripping \"/\" and calling it done -- this replaces
everything outside alnum/dot/dash/underscore, so \"../../etc/passwd\"
collapses to a plain filename with no directory component."
  (let ((safe (replace-regexp-in-string "[^A-Za-z0-9._-]" "_" (or name ""))))
    (substring safe 0 (min 100 (length safe)))))

(defun matrix-bridge--media-path (event-id body)
  "Where a downloaded attachment for EVENT-ID/BODY is written.  EVENT-ID is
server-assigned (not sender-controlled) and already unique, so no other
collision handling is needed on top of it."
  (unless (file-directory-p matrix-bridge-media-dir)
    (make-directory matrix-bridge-media-dir t))
  (expand-file-name (format "%s-%s" event-id (matrix-bridge--sanitize-filename body))
                     matrix-bridge-media-dir))

(defun matrix-bridge--audio-message (sender envelope text audio-path human-reminder)
  "Format one audio-axis delivery line: attribution + ENVELOPE + TEXT, plus a
`첨부:' line naming AUDIO-PATH when non-nil, plus HUMAN-REMINDER.

AUDIO-PATH is nil for the two branches where nothing has been written to
disk yet (download itself failed, or the mxc url did not parse) and non-nil
for the other four (the file is on disk by the time any of those can
happen) -- see the invariants note at the top of this section."
  (concat (format "[matrix · %s%s] %s" (matrix-bridge-attribution sender) envelope text)
          (if audio-path (format "\n첨부: %s" audio-path) "")
          human-reminder))

(defun matrix-bridge--download-media (mxc-url callback)
  "Fetch MXC-URL's bytes via the authenticated media endpoint (MSC3916),
async like every other network call in this file -- never
`url-retrieve-synchronously'.  Calls CALLBACK with (DATA ERR):

  ERR non-nil            -- the request itself failed (branch 1).
  DATA and ERR both nil  -- MXC-URL did not parse as `mxc://server/id'
                             (branch 2); no request was even attempted.
  otherwise              -- DATA is the raw (undecoded) response bytes."
  (if (not (string-match "\\`mxc://\\([^/]+\\)/\\(.+\\)\\'" (or mxc-url "")))
      (funcall callback nil nil)
    (let* ((server (match-string 1 mxc-url))
           (media-id (match-string 2 mxc-url))
           (url (format "%s/_matrix/client/v1/media/download/%s/%s"
                        matrix-bridge-homeserver server media-id))
           (url-request-method "GET")
           (url-request-extra-headers
            (list (cons "Authorization" (concat "Bearer " matrix-bridge--token)))))
      (url-retrieve
       url
       (lambda (status)
         (let ((body (unwind-protect
                         (matrix-bridge--response-bytes)
                       (kill-buffer (current-buffer)))))
           (if (plist-get status :error)
               (funcall callback nil (plist-get status :error))
             (funcall callback body nil))))
       nil t t))))

(defun matrix-bridge--finish-transcription
    (audio-path sender envelope human-reminder rc stdout stderr)
  "Deliver the outcome of a finished `monocle audio transcribe' run (RC/
STDOUT/STDERR).  Mirrors audio_axis.py's `finish_transcription' -- all three
outcomes handled here (branches 4/5/6) carry AUDIO-PATH, same as the
start-failure branch (3) handled in `matrix-bridge--transcribe-audio': the
original file is never dropped from the delivered message regardless of how
transcription went."
  (matrix-bridge--log "audio: transcription finished rc=%s for %s" rc audio-path)
  (matrix-bridge--deliver
   (matrix-bridge--audio-message
    sender envelope
    (if (eq rc 0)
        (let ((transcribed
               (condition-case nil
                   (string-trim
                    (or (matrix-bridge--get
                         (json-parse-string stdout :object-type 'alist
                                            :null-object nil :false-object nil)
                         'text)
                        ""))
                 (error ""))))
          (if (string-empty-p transcribed)
              "(음성 메시지, 변환 결과 비어있음)"
            (format "(음성 메시지 텍스트 변환) %s" transcribed)))
      (let ((trimmed (string-trim stderr)))
        (format "(음성 메시지, 텍스트 변환 실패: rc=%s %S)" rc
                (substring trimmed 0 (min 300 (length trimmed))))))
    audio-path human-reminder)))

(defun matrix-bridge--transcribe-audio (audio-path sender envelope human-reminder)
  "Hand AUDIO-PATH to `monocle audio transcribe' in the background via
`make-process' + `:sentinel' (see the substitution note at the top of this
section for why this replaces Python's manual poll list, and why that swap
is safe).

The `let'-bound `process-environment' below is invariant #1 (HOME-scoping):
in effect for this `make-process' call ONLY, restored to its prior value the
instant the `let' returns -- never a global `setenv'.  A test that wants to
catch a regression here should fail if someone \"fixes\" this by calling
`setenv' globally instead."
  (let* ((process-environment
          (if matrix-bridge-monocle-home
              (cons (concat "HOME=" matrix-bridge-monocle-home) process-environment)
            process-environment))
         (out-buf (generate-new-buffer " *matrix-bridge-monocle-out*"))
         (err-buf (generate-new-buffer " *matrix-bridge-monocle-err*")))
    (condition-case err
        (make-process
         :name "matrix-bridge-monocle"
         :buffer out-buf
         :stderr err-buf
         :command (list matrix-bridge-monocle-path "audio" "transcribe" audio-path)
         :noquery t
         :sentinel
         (lambda (proc _event)
           (when (memq (process-status proc) '(exit signal))
             (let ((rc (process-exit-status proc))
                   (stdout (if (buffer-live-p out-buf)
                               (with-current-buffer out-buf (buffer-string))
                             ""))
                   (stderr (if (buffer-live-p err-buf)
                               (with-current-buffer err-buf (buffer-string))
                             "")))
               (when (buffer-live-p out-buf) (kill-buffer out-buf))
               (when (buffer-live-p err-buf) (kill-buffer err-buf))
               (matrix-bridge--finish-transcription
                audio-path sender envelope human-reminder rc stdout stderr)))))
      ;; --- branch 3: monocle won't even start -------------------------------
      (error
       (when (buffer-live-p out-buf) (kill-buffer out-buf))
       (when (buffer-live-p err-buf) (kill-buffer err-buf))
       (matrix-bridge--log "audio: failed to start monocle: %S" err)
       (matrix-bridge--deliver
        (matrix-bridge--audio-message
         sender envelope (format "(음성 메시지, 텍스트 변환 시작 실패: %S)" err)
         audio-path human-reminder))))))

(defun matrix-bridge--audio-event-p (ev)
  "Non-nil when EV is an `m.audio' room message this fleet should handle --
same \"ours to deliver\" gate as `matrix-bridge-event-line' (a genuine
`m.room.message', not our own outgoing echo), narrowed to msgtype
`m.audio'.  Every other msgtype keeps going through the unchanged existing
`matrix-bridge-event-line' path in `matrix-bridge--handle'."
  (let ((content (matrix-bridge--get ev 'content)))
    (and (equal (matrix-bridge--get ev 'type) "m.room.message")
         (not (equal (matrix-bridge--get ev 'sender) matrix-bridge-self-user-id))
         (equal (matrix-bridge--get content 'msgtype) "m.audio"))))

(defun matrix-bridge--handle-audio (ev)
  "Async transcription path for an `m.audio' room-message EV, used in place
of `matrix-bridge-event-line'/`matrix-bridge--deliver' for that one msgtype
only -- every other msgtype keeps going through the unchanged existing path
in `matrix-bridge--handle'.  Mirrors audio_axis.py's
`start_audio_transcription'."
  (let* ((sender (matrix-bridge--get ev 'sender))
         (content (matrix-bridge--get ev 'content))
         (event-id (or (matrix-bridge--get ev 'event_id) ""))
         (envelope (matrix-bridge-envelope event-id content))
         (human-reminder (if (equal sender matrix-bridge-human-user-id)
                              matrix-bridge-human-reminder
                            ""))
         (body (or (matrix-bridge--get content 'body) "voice"))
         (url (or (matrix-bridge--get content 'url) ""))
         (audio-path (matrix-bridge--media-path event-id body)))
    (matrix-bridge--log "RECV [matrix · %s%s] %s"
                        (matrix-bridge-attribution sender) envelope
                        (matrix-bridge-describe content))
    (matrix-bridge--download-media
     url
     (lambda (data err)
       (cond
        ;; --- branch 1: download itself failed -----------------------------
        (err
         (matrix-bridge--log "audio download failed: %S" err)
         (matrix-bridge--deliver
          (matrix-bridge--audio-message
           sender envelope (format "(음성 메시지 다운로드 실패: %S)" err)
           nil human-reminder)))
        ;; --- branch 2: mxc url did not parse -------------------------------
        ((null data)
         (matrix-bridge--log "audio: could not parse mxc url %S" url)
         (matrix-bridge--deliver
          (matrix-bridge--audio-message
           sender envelope (format "(음성 메시지 도착 — url 형식 이상: %S)" url)
           nil human-reminder)))
        (t
         ;; Invariant #2 (write-before-invoke): the bytes hit disk here,
         ;; unconditionally, BEFORE `matrix-bridge--transcribe-audio' (which
         ;; invokes monocle) is ever called below.  By the time anything
         ;; monocle-related runs, the original is already durable -- nothing
         ;; monocle does afterwards can take it away.  No safety-net
         ;; `condition-case' around the whole flow is needed or wanted; the
         ;; ordering alone provides the guarantee.
         (let ((coding-system-for-write 'no-conversion))
           (write-region data nil audio-path nil 'silent))
         (matrix-bridge--log "audio saved: %s (%d bytes)" audio-path (length data))
         (matrix-bridge--transcribe-audio audio-path sender envelope human-reminder)))))))

;;; --- the poll loop --------------------------------------------------------
;;
;; Invariant: every path out of the callback goes through
;; `matrix-bridge--reschedule', so a single exception can never end the loop.

(defun matrix-bridge--reschedule (gen delay)
  (when (= gen matrix-bridge--generation)
    (when (timerp matrix-bridge--timer) (cancel-timer matrix-bridge--timer))
    (setq matrix-bridge--timer
          (run-at-time delay nil #'matrix-bridge--poll gen))))

(defun matrix-bridge--response-body ()
  "Decoded body of the `url-retrieve' response in the current buffer."
  (goto-char (point-min))
  (let ((start (or (and (boundp 'url-http-end-of-headers) url-http-end-of-headers)
                   (and (re-search-forward "\r?\n\r?\n" nil t) (point))
                   (point-min))))
    (decode-coding-string
     (buffer-substring-no-properties start (point-max)) 'utf-8)))

(defun matrix-bridge--response-bytes ()
  "Undecoded body bytes of the `url-retrieve' response in the current buffer.

Same header-skip as `matrix-bridge--response-body' but WITHOUT the utf-8
decode -- an audio attachment is binary, and decoding it as text would
corrupt the bytes before they ever reach disk."
  (goto-char (point-min))
  (let ((start (or (and (boundp 'url-http-end-of-headers) url-http-end-of-headers)
                   (and (re-search-forward "\r?\n\r?\n" nil t) (point))
                   (point-min))))
    (buffer-substring-no-properties start (point-max))))

(defun matrix-bridge--poll (gen)
  (when (= gen matrix-bridge--generation)
    (condition-case err
        (let* ((baseline (null matrix-bridge--since))
               (query (if baseline
                          "timeout=0"
                        (format "since=%s&timeout=%d"
                                (url-hexify-string matrix-bridge--since)
                                matrix-bridge-sync-timeout-ms)))
               (url (concat matrix-bridge-homeserver
                            "/_matrix/client/v3/sync?" query))
               (url-request-method "GET")
               (url-request-extra-headers
                (list (cons "Authorization" (concat "Bearer " matrix-bridge--token))))
               (done (list nil))
               (buf (url-retrieve
                     url
                     (lambda (status)
                       (setcar done t)
                       (let ((body (unwind-protect
                                       (matrix-bridge--response-body)
                                     (kill-buffer (current-buffer)))))
                         (matrix-bridge--handle gen status body baseline)))
                     nil t t)))
          ;; url.el has no per-request timeout: a wedged connection would
          ;; otherwise leave the loop silently waiting forever.
          (when (timerp matrix-bridge--watchdog) (cancel-timer matrix-bridge--watchdog))
          (setq matrix-bridge--watchdog
                (run-at-time (+ (/ matrix-bridge-sync-timeout-ms 1000.0) 30) nil
                             (lambda ()
                               (unless (car done)
                                 (setcar done t)
                                 (matrix-bridge--log "sync wedged, aborting request")
                                 (ignore-errors
                                   (when (buffer-live-p buf)
                                     (let ((p (get-buffer-process buf)))
                                       (when p (delete-process p)))
                                     (kill-buffer buf)))
                                 (matrix-bridge--reschedule
                                  gen matrix-bridge-retry-seconds))))))
      (error
       (matrix-bridge--log "poll error: %S, retrying in %ds"
                           err matrix-bridge-retry-seconds)
       (matrix-bridge--reschedule gen matrix-bridge-retry-seconds)))))

(defun matrix-bridge--handle (gen status body baseline)
  (when (= gen matrix-bridge--generation)
    (when (timerp matrix-bridge--watchdog) (cancel-timer matrix-bridge--watchdog))
    (let ((delay 0.5))
      (condition-case err
          (if (plist-get status :error)
              (progn
                (matrix-bridge--log "sync error: %S, retrying in %ds"
                                    (plist-get status :error)
                                    matrix-bridge-retry-seconds)
                (setq delay matrix-bridge-retry-seconds))
            (let* ((resp (json-parse-string body :object-type 'alist
                                            :null-object nil :false-object nil))
                   (next (matrix-bridge--get resp 'next_batch)))
              (if baseline
                  (matrix-bridge--log "baseline established, since=%s" next)
                (let* ((join (matrix-bridge--get
                              (matrix-bridge--get resp 'rooms) 'join))
                       (room (matrix-bridge--get
                              join (intern matrix-bridge--room-id)))
                       (events (matrix-bridge--get
                                (matrix-bridge--get room 'timeline) 'events)))
                  (dolist (ev (append events nil))
                    (if (matrix-bridge--audio-event-p ev)
                        (matrix-bridge--handle-audio ev)
                      (let ((line (matrix-bridge-event-line ev)))
                        (when line
                          (matrix-bridge--log "RECV %s" line)
                          (matrix-bridge--deliver line)))))))
              (setq matrix-bridge--since next)
              (matrix-bridge--save-since next)))
        (error
         (matrix-bridge--log "handler error: %S, retrying in %ds"
                             err matrix-bridge-retry-seconds)
         (setq delay matrix-bridge-retry-seconds)))
      (matrix-bridge--reschedule gen delay))))

;;; --- start / stop ---------------------------------------------------------

;;;###autoload
(defun matrix-bridge-start ()
  "Start the Matrix -> cc-butler relay.  Safe to call twice."
  (interactive)
  (unless matrix-bridge-self-user-id
    (error "matrix-bridge: `matrix-bridge-self-user-id' is nil -- set it to \
THIS fleet's own Matrix id before starting, or the relay cannot tell your own \
messages from a peer's and will mis-filter them"))
  (matrix-bridge-stop)
  (setq matrix-bridge--token (matrix-bridge--read-trimmed matrix-bridge-token-file)
        matrix-bridge--room-id (matrix-bridge--read-trimmed matrix-bridge-room-id-file)
        matrix-bridge--since (matrix-bridge--load-since))
  (setq matrix-bridge--generation (1+ matrix-bridge--generation))
  (matrix-bridge--log "bridge starting (gen %d, shadow=%s, since=%s)"
                      matrix-bridge--generation matrix-bridge-shadow
                      (or matrix-bridge--since "none -- will baseline"))
  (matrix-bridge--poll matrix-bridge--generation)
  (message "matrix-bridge started%s"
           (if matrix-bridge-shadow " (shadow mode)" "")))

;;;###autoload
(defun matrix-bridge-stop ()
  "Stop the relay.  No already-scheduled poll survives this."
  (interactive)
  (setq matrix-bridge--generation (1+ matrix-bridge--generation))
  (when (timerp matrix-bridge--timer) (cancel-timer matrix-bridge--timer))
  (when (timerp matrix-bridge--watchdog) (cancel-timer matrix-bridge--watchdog))
  (setq matrix-bridge--timer nil matrix-bridge--watchdog nil)
  (matrix-bridge--log "bridge stopped")
  (message "matrix-bridge stopped"))

;;; --- self-test (pure functions only, no network) --------------------------

;;;###autoload
(defun matrix-bridge-self-test ()
  "Check the envelope/describe formatting against test_bridge.py's cases."
  (interactive)
  ;; envelope: what the courier stamps on the outside
  (cl-assert (equal (matrix-bridge-envelope "$abc" '((msgtype . "m.text") (body . "hi")))
                    " · id:$abc") t)
  (cl-assert (equal (matrix-bridge-envelope
                     "$def" '((msgtype . "m.text")
                              (m.relates_to . ((rel_type . "m.thread")
                                               (event_id . "$root")))))
                    " · id:$def · thread:$root") t)
  ;; A thread reply's synthetic in_reply_to must NOT show up as a real reply.
  (cl-assert (equal (matrix-bridge-envelope
                     "$ghi" '((msgtype . "m.text")
                              (m.relates_to . ((rel_type . "m.thread")
                                               (event_id . "$root")
                                               (is_falling_back . t)
                                               (m.in_reply_to . ((event_id . "$prev")))))))
                    " · id:$ghi · thread:$root") t)
  ;; ...and a genuine reply must survive the same filter.
  (cl-assert (equal (matrix-bridge-envelope
                     "$jkl" '((msgtype . "m.text")
                              (m.relates_to . ((m.in_reply_to . ((event_id . "$tgt")))))))
                    " · id:$jkl · reply:$tgt") t)
  ;; A threaded message that is ALSO a genuine reply keeps both markings.
  (cl-assert (equal (matrix-bridge-envelope
                     "$mno" '((msgtype . "m.text")
                              (m.relates_to . ((rel_type . "m.thread")
                                               (event_id . "$root")
                                               (is_falling_back . nil)
                                               (m.in_reply_to . ((event_id . "$tgt")))))))
                    " · id:$mno · thread:$root · reply:$tgt") t)

  ;; describe: text passes through, attachments leave a claim ticket
  (cl-assert (equal (matrix-bridge-describe '((msgtype . "m.text") (body . "hello")))
                    "hello") t)
  (cl-assert (equal (matrix-bridge-describe '((msgtype . "m.notice") (body . "note")))
                    "note") t)
  (cl-assert (equal (matrix-bridge-describe
                     '((msgtype . "m.image") (body . "shot.png") (url . "mxc://x/1")
                       (info . ((mimetype . "image/png")))))
                    "[첨부 m.image · shot.png · image/png · mxc://x/1]") t)
  ;; Missing info must not crash -- the ticket just carries less.
  (cl-assert (equal (matrix-bridge-describe '((msgtype . "m.audio") (body . "voice.ogg")))
                    "[첨부 m.audio · voice.ogg]") t)

  ;; the whole line, and the two events we must drop
  ;; The human's own messages carry the reminder ...
  (cl-assert (equal (matrix-bridge-event-line
                     `((type . "m.room.message") (sender . "@jeongsoo:warmblood-lounge")
                       (event_id . "$abc") (content . ((msgtype . "m.text") (body . "hi")))))
                    (concat "[matrix · 정수님 · id:$abc] hi"
                            matrix-bridge-human-reminder)) t)
  ;; ... and nobody else's do.  Without this negative case the assertion above
  ;; would still pass if the reminder were appended unconditionally.
  (cl-assert (equal (matrix-bridge-event-line
                     `((type . "m.room.message")
                       (sender . "@butler-x600:warmblood-lounge")
                       (event_id . "$abc") (content . ((msgtype . "m.text") (body . "hi")))))
                    "[matrix · butler-x600 · id:$abc] hi") t)
  (cl-assert (equal (matrix-bridge-event-line
                     '((type . "m.room.message")
                       (sender . "@butler-macbook-m1-max:warmblood-lounge")
                       (event_id . "$abc") (content . ((msgtype . "m.text") (body . "hi")))))
                    "[matrix · butler-macbook-m1-max · id:$abc] hi") t)
  ;; Bound explicitly: with the defvar now nil, reading the global here would
  ;; make this assertion pass for the wrong reason (nil sender equals nil id).
  (let ((matrix-bridge-self-user-id "@butler-x600:warmblood-lounge"))
    (cl-assert (null (matrix-bridge-event-line
                      `((type . "m.room.message") (sender . ,matrix-bridge-self-user-id)
                        (event_id . "$abc")
                        (content . ((msgtype . "m.text") (body . "echo")))))) t))
  (cl-assert (null (matrix-bridge-event-line
                    '((type . "m.room.message") (sender . "@jeongsoo:warmblood-lounge")
                      (event_id . "$abc") (content . ())))) t)
  (cl-assert (null (matrix-bridge-event-line
                    '((type . "m.room.member") (sender . "@jeongsoo:warmblood-lounge")
                      (event_id . "$abc")
                      (content . ((msgtype . "m.text") (body . "x")))))) t)
  (message "matrix-bridge-self-test: ok"))

(provide 'matrix-bridge)
;;; matrix-bridge.el ends here
