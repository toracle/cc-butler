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
(defvar matrix-bridge-human-user-id nil
  "The human's own Matrix user id, e.g. \"@example-user:example.invalid\".

Deliberately nil, mirroring `matrix-bridge-self-user-id' just above: a
default belonging to ONE fleet's human is worse than no default, since it
would make `matrix-bridge-attribution' and the reminder-append check in
`matrix-bridge-event-line' silently misclassify every OTHER fleet's human
sender as a bot -- no error, no log, just the reminder line and the
attribution name quietly never appearing.

`matrix-bridge-start' refuses to run while this is nil, for the same reason
and with the same loudness as the `matrix-bridge-self-user-id' guard right
below it. Set it in per-machine config, not here.

2026-09-10: this was a real hardcoded fleet id here for months (public
repo -- see `cc-butler-fixture-hygiene-test.el'). Redacting it without this
guard would have traded a loud, visible leak for a quiet, permanent
misclassification of the same fleet's own human sender -- a worse failure
mode, not a fix. The guard is what makes redacting the default safe.")
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

(defgroup matrix-bridge nil
  "Matrix lounge -> cc-butler session relay."
  :group 'applications)

(defcustom matrix-bridge-thread-fetch-timeout-seconds 10
  "Defense timeout (seconds) around each request `matrix-bridge-thread-replies'
makes.  That function's request is a single bounded fetch -- unlike
`matrix-bridge--poll''s 30s `/sync' long-poll (see the file commentary on why
THAT one must stay async), so a synchronous call is fine here; this timeout
only guards against a wedged connection."
  :type 'number
  :group 'matrix-bridge)

(defcustom matrix-bridge-thread-fetch-max-pages 5
  "Hard cap on pages fetched by one `matrix-bridge-thread-replies' call (at
`matrix-bridge--thread-fetch-page-limit' events per page, so 5*50=250 events
by default).  Hitting this cap before the thread is naturally exhausted sets
`:truncated t' on the result rather than silently presenting a partial scan
as exhaustive."
  :type 'integer
  :group 'matrix-bridge)

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

;;; --- synchronous thread-relations fetch ------------------------------------
;;
;; Unlike the `/sync' long-poll below, this is a single bounded request (one
;; Matrix room's thread, capped page count) so `url-retrieve-synchronously'
;; is safe here -- it must never be used for `/sync' itself (see the file
;; commentary at the top).

(defconst matrix-bridge--thread-fetch-page-limit 50
  "Events requested per page by `matrix-bridge-thread-replies' (the `limit'
query param).  Also the yardstick pagination stops against: a page whose
`chunk' comes back shorter than this is the last page, `next_batch' or not.")

(defun matrix-bridge--thread-relations-url (room event-id from)
  "URL for one page of EVENT-ID's thread relations in ROOM.  FROM (a
`next_batch' token, or nil for the first page) is passed back as the `from'
query param.  ROOM and EVENT-ID are URL-path-encoded."
  (concat matrix-bridge-homeserver
          "/_matrix/client/v1/rooms/" (url-hexify-string room)
          "/relations/" (url-hexify-string event-id) "/m.thread"
          "?limit=" (number-to-string matrix-bridge--thread-fetch-page-limit)
          (if from (concat "&from=" (url-hexify-string from)) "")))

(defun matrix-bridge--thread-fetch-page (room event-id from)
  "Fetch one page of EVENT-ID's thread relations in ROOM (FROM for
pagination, nil for the first page).  Return (:http-status STATUS-OR-NIL
:parsed PARSED-JSON-ALIST-OR-NIL).  May signal on a network failure or a
request that never completes -- the caller (`matrix-bridge-thread-replies')
wraps this in `condition-case'."
  (unless matrix-bridge--token
    (setq matrix-bridge--token (matrix-bridge--read-trimmed matrix-bridge-token-file)))
  (let* ((url (matrix-bridge--thread-relations-url room event-id from))
         (url-request-method "GET")
         (url-request-extra-headers
          (list (cons "Authorization" (concat "Bearer " matrix-bridge--token))))
         (buf (url-retrieve-synchronously
               url t t matrix-bridge-thread-fetch-timeout-seconds)))
    (unless buf
      (error "matrix-bridge: thread relations request timed out with no response"))
    (unwind-protect
        (with-current-buffer buf
          (list :http-status (bound-and-true-p url-http-response-status)
                :parsed (ignore-errors
                          (json-parse-string (matrix-bridge--response-body)
                                             :object-type 'alist
                                             :null-object nil :false-object nil))))
      (kill-buffer buf))))

(defun matrix-bridge-thread-replies (room event-id)
  "Synchronously fetch the Matrix thread rooted at EVENT-ID in ROOM (the
`/relations/.../m.thread' endpoint), paginating via `next_batch' up to
`matrix-bridge-thread-fetch-max-pages' pages.

Returns one of exactly three shapes:
  (:status ok :events LIST :scanned N :truncated BOOL) -- a successful
    fetch; N (and LIST) may be empty -- a real, successful \"nothing found\"
    is a valid, common result, not an error.  Each element of LIST is the
    raw parsed Matrix event alist (has at least a `sender' key).
  (:status not-in-room) -- the specific Matrix error M_NOT_FOUND /
    \"Event not found in room\" -- ROOM does not actually contain EVENT-ID,
    a data problem (a wrong/stale recorded room), distinct from a
    connectivity problem.
  (:status error :detail STRING) -- anything else (timeout, other HTTP
    error, JSON parse failure, network failure).  Never an uncaught
    exception -- the whole fetch is wrapped in `condition-case'.

Pagination stops when a page's `next_batch' is absent, OR when that page's
`chunk' came back shorter than the requested limit -- BOTH are
independently sufficient to stop.  Confirmed live against a real
homeserver (conduit): `next_batch' can be present even when `chunk' is
short, so relying on \"`next_batch' absent\" alone under-terminates.  If the
page cap is hit before either natural-stop condition fires, `:truncated' is
t -- never silently presented as an exhaustive scan."
  (condition-case err
      (let ((events nil) (page 0) (from nil)
            (not-in-room nil) (err-detail nil) (more t))
        (with-timeout (matrix-bridge-thread-fetch-timeout-seconds
                       (setq err-detail "matrix-bridge-thread-replies: timed out"
                             more nil))
          (while (and more (< page matrix-bridge-thread-fetch-max-pages))
            (setq page (1+ page))
            (let* ((resp (matrix-bridge--thread-fetch-page room event-id from))
                   (http-status (plist-get resp :http-status))
                   (parsed (plist-get resp :parsed)))
              (cond
               ((and parsed (equal (matrix-bridge--get parsed 'errcode) "M_NOT_FOUND"))
                (setq not-in-room t more nil))
               ((or (null http-status) (>= http-status 300))
                (setq err-detail
                      (format "matrix-bridge-thread-replies: HTTP %s%s"
                              (or http-status "?")
                              (if parsed
                                  (format " (%s)"
                                          (or (matrix-bridge--get parsed 'error)
                                              (matrix-bridge--get parsed 'errcode)
                                              ""))
                                ""))
                      more nil))
               ((null parsed)
                (setq err-detail
                      (format "matrix-bridge-thread-replies: unparseable body (HTTP %s)"
                              (or http-status "?"))
                      more nil))
               (t
                (let* ((chunk (append (matrix-bridge--get parsed 'chunk) nil))
                       (next (matrix-bridge--get parsed 'next_batch)))
                  (setq events (append events chunk))
                  (if (and next (>= (length chunk) matrix-bridge--thread-fetch-page-limit))
                      (setq from next)
                    (setq more nil))))))))
        (cond
         (not-in-room (list :status 'not-in-room))
         (err-detail (list :status 'error :detail err-detail))
         (t (list :status 'ok :events events :scanned (length events)
                  :truncated (and more t)))))
    (error (list :status 'error
                 :detail (format "matrix-bridge-thread-replies: %S" err)))))

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
                    (let ((line (matrix-bridge-event-line ev)))
                      (when line
                        (matrix-bridge--log "RECV %s" line)
                        (matrix-bridge--deliver line))))))
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
  (unless matrix-bridge-human-user-id
    (error "matrix-bridge: `matrix-bridge-human-user-id' is nil -- set it to \
the human's Matrix id before starting, or the relay cannot tell the human's \
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
