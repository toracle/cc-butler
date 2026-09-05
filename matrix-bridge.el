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
(defvar matrix-bridge-self-user-id "@butler-x600:warmblood-lounge")
(defvar matrix-bridge-human-user-id "@jeongsoo:warmblood-lounge")
(defvar matrix-bridge-sync-timeout-ms 30000)
(defvar matrix-bridge-retry-seconds 5)

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
      (format "[matrix · %s%s] %s"
              (matrix-bridge-attribution sender)
              (matrix-bridge-envelope (or (matrix-bridge--get ev 'event_id) "") content)
              (matrix-bridge-describe content)))))

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
  (cl-assert (equal (matrix-bridge-event-line
                     `((type . "m.room.message") (sender . "@jeongsoo:warmblood-lounge")
                       (event_id . "$abc") (content . ((msgtype . "m.text") (body . "hi")))))
                    "[matrix · 정수님 · id:$abc] hi") t)
  (cl-assert (equal (matrix-bridge-event-line
                     '((type . "m.room.message")
                       (sender . "@butler-macbook-m1-max:warmblood-lounge")
                       (event_id . "$abc") (content . ((msgtype . "m.text") (body . "hi")))))
                    "[matrix · butler-macbook-m1-max · id:$abc] hi") t)
  (cl-assert (null (matrix-bridge-event-line
                    `((type . "m.room.message") (sender . ,matrix-bridge-self-user-id)
                      (event_id . "$abc")
                      (content . ((msgtype . "m.text") (body . "echo")))))) t)
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
