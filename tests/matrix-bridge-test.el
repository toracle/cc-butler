;;; matrix-bridge-test.el --- Tests for matrix-bridge -*- lexical-binding: t; -*-

;; Ported from `matrix-bridge-self-test' (see ../matrix-bridge.el) into ERT
;; form so `tests/run-tests.el' picks these up like every other suite in
;; this repo. Covers the pure formatting functions only -- no network.

(require 'ert)
(require 'cl-lib)
(require 'matrix-bridge)

;;;; --- envelope: what the courier stamps on the outside ---------------------

(ert-deftest matrix-bridge/envelope-plain-message-has-only-id ()
  (should (equal (matrix-bridge-envelope "$abc" '((msgtype . "m.text") (body . "hi")))
                 " · id:$abc")))

(ert-deftest matrix-bridge/envelope-threaded-message-adds-thread-id ()
  (should (equal (matrix-bridge-envelope
                  "$def" '((msgtype . "m.text")
                           (m.relates_to . ((rel_type . "m.thread")
                                            (event_id . "$root")))))
                 " · id:$def · thread:$root")))

(ert-deftest matrix-bridge/envelope-falling-back-reply-not-shown-as-reply ()
  "A thread reply carries a synthetic in_reply_to for old clients; that
must not be reported as a genuine reply."
  (should (equal (matrix-bridge-envelope
                  "$ghi" '((msgtype . "m.text")
                           (m.relates_to . ((rel_type . "m.thread")
                                            (event_id . "$root")
                                            (is_falling_back . t)
                                            (m.in_reply_to . ((event_id . "$prev")))))))
                 " · id:$ghi · thread:$root")))

(ert-deftest matrix-bridge/envelope-genuine-reply-survives-the-filter ()
  (should (equal (matrix-bridge-envelope
                  "$jkl" '((msgtype . "m.text")
                           (m.relates_to . ((m.in_reply_to . ((event_id . "$tgt")))))))
                 " · id:$jkl · reply:$tgt")))

(ert-deftest matrix-bridge/envelope-threaded-and-genuine-reply-keeps-both ()
  (should (equal (matrix-bridge-envelope
                  "$mno" '((msgtype . "m.text")
                           (m.relates_to . ((rel_type . "m.thread")
                                            (event_id . "$root")
                                            (is_falling_back . nil)
                                            (m.in_reply_to . ((event_id . "$tgt")))))))
                 " · id:$mno · thread:$root · reply:$tgt")))

;;;; --- describe: text passes through, attachments leave a claim ticket ------

(ert-deftest matrix-bridge/describe-text-passes-through ()
  (should (equal (matrix-bridge-describe '((msgtype . "m.text") (body . "hello")))
                 "hello")))

(ert-deftest matrix-bridge/describe-notice-passes-through ()
  (should (equal (matrix-bridge-describe '((msgtype . "m.notice") (body . "note")))
                 "note")))

(ert-deftest matrix-bridge/describe-image-leaves-a-claim-ticket ()
  (should (equal (matrix-bridge-describe
                  '((msgtype . "m.image") (body . "shot.png") (url . "mxc://x/1")
                    (info . ((mimetype . "image/png")))))
                 "[첨부 m.image · shot.png · image/png · mxc://x/1]")))

(ert-deftest matrix-bridge/describe-missing-info-does-not-crash ()
  (should (equal (matrix-bridge-describe '((msgtype . "m.audio") (body . "voice.ogg")))
                 "[첨부 m.audio · voice.ogg]")))

;;;; --- event-line: the whole line, and what must be dropped -----------------

(ert-deftest matrix-bridge/event-line-human-sender-shows-attribution ()
  (should (equal (matrix-bridge-event-line
                  `((type . "m.room.message") (sender . "@jeongsoo:warmblood-lounge")
                    (event_id . "$abc") (content . ((msgtype . "m.text") (body . "hi")))))
                 ;; The human's own messages carry `matrix-bridge-human-reminder'.
                 ;; Built from the variable, not a copy of its wording: a reworded
                 ;; reminder must not turn this attribution test red.
                 (concat "[matrix · 정수님 · id:$abc] hi"
                         matrix-bridge-human-reminder))))

(ert-deftest matrix-bridge/event-line-fleet-sender-shows-short-name ()
  (should (equal (matrix-bridge-event-line
                  '((type . "m.room.message")
                    (sender . "@butler-macbook-m1-max:warmblood-lounge")
                    (event_id . "$abc") (content . ((msgtype . "m.text") (body . "hi")))))
                 "[matrix · butler-macbook-m1-max · id:$abc] hi")))

(ert-deftest matrix-bridge/event-line-own-outgoing-message-is-dropped ()
  (let ((matrix-bridge-self-user-id "@butler-x600:warmblood-lounge"))
    (should-not (matrix-bridge-event-line
                 `((type . "m.room.message") (sender . ,matrix-bridge-self-user-id)
                   (event_id . "$abc")
                   (content . ((msgtype . "m.text") (body . "echo"))))))))

(ert-deftest matrix-bridge/event-line-no-msgtype-is-dropped ()
  (should-not (matrix-bridge-event-line
               '((type . "m.room.message") (sender . "@jeongsoo:warmblood-lounge")
                 (event_id . "$abc") (content . ())))))

(ert-deftest matrix-bridge/event-line-non-message-type-is-dropped ()
  (should-not (matrix-bridge-event-line
               '((type . "m.room.member") (sender . "@jeongsoo:warmblood-lounge")
                 (event_id . "$abc")
                 (content . ((msgtype . "m.text") (body . "x")))))))

;;;; --- JSON false is not Lisp nil (regression, 2026-09-05) ------------------
;; Found by replaying 248 real room events through both bridges: the Python
;; and Elisp outputs diverged on 4 events, all genuine replies inside a thread.

(ert-deftest matrix-bridge/json-false-fallback-is-a-genuine-reply ()
  "Element writes is_falling_back:false on a genuine reply inside a thread.
JSON false parses to :json-false, which is non-nil -- the naive test dropped it."
  (let ((env (matrix-bridge-envelope
              "$self"
              '((msgtype . "m.text") (body . "x")
                (m.relates_to . ((event_id . "$root")
                                 (is_falling_back . :json-false)
                                 (m.in_reply_to . ((event_id . "$target")))
                                 (rel_type . "m.thread")))))))
    (should (string-match-p "thread:\\$root" env))
    (should (string-match-p "reply:\\$target" env))))
(ert-deftest matrix-bridge/json-true-fallback-is-still-suppressed ()
  "The real fallback (is_falling_back:true) must still NOT show as a reply."
  (let ((env (matrix-bridge-envelope
              "$self"
              '((msgtype . "m.text") (body . "x")
                (m.relates_to . ((event_id . "$root")
                                 (is_falling_back . t)
                                 (m.in_reply_to . ((event_id . "$target")))
                                 (rel_type . "m.thread")))))))
    (should (string-match-p "thread:\\$root" env))
    (should-not (string-match-p "reply:" env))))

;;;; --- audio transcription (the `m.audio' axis) -----------------------------
;; Ported from audio_axis.py (macbook-m1-max's bridge.py, live-verified
;; 2026-09-06 21:14). No real network call, no real `monocle' invocation --
;; `url-retrieve' and `make-process' are mocked throughout via `cl-letf'.

(defmacro matrix-bridge-test--with-media-dir (&rest body)
  "Run BODY with `matrix-bridge-media-dir' bound to a fresh temp directory,
removed afterwards -- so these tests never touch the real, live media dir."
  (declare (indent 0))
  `(let ((matrix-bridge-media-dir (make-temp-file "matrix-bridge-test-media-" t)))
     (unwind-protect (progn ,@body)
       (delete-directory matrix-bridge-media-dir t))))

(defmacro matrix-bridge-test--capture-delivery (var &rest body)
  "Run BODY with `matrix-bridge--deliver' mocked to push its TEXT argument
onto VAR (a symbol bound to a list, most recent last) instead of really
delivering anything."
  (declare (indent 1))
  `(let (,var)
     (cl-letf (((symbol-function 'matrix-bridge--deliver)
                (lambda (text) (setq ,var (append ,var (list text))))))
       ,@body)))

;;;;; sanitize-filename / media-path: the path-traversal guard -------------

(ert-deftest matrix-bridge/sanitize-filename-strips-path-traversal ()
  "Only the slashes get replaced -- dots/dashes/underscores are in the
allowed set (matching audio_axis.py's `sanitize_filename' regex exactly),
but the result has no `/' in it, so it can never escape the media dir."
  (let ((safe (matrix-bridge--sanitize-filename "../../etc/passwd")))
    (should (equal safe ".._.._etc_passwd"))
    (should-not (string-match-p "/" safe))))

(ert-deftest matrix-bridge/sanitize-filename-keeps-safe-characters ()
  (should (equal (matrix-bridge--sanitize-filename "voice-msg_01.ogg")
                 "voice-msg_01.ogg")))

(ert-deftest matrix-bridge/media-path-has-no-directory-component-from-body ()
  (matrix-bridge-test--with-media-dir
    (let ((path (matrix-bridge--media-path "$abc" "../../etc/passwd")))
      (should (equal (file-name-directory path)
                      (file-name-as-directory matrix-bridge-media-dir)))
      (should (equal (file-name-nondirectory path) "$abc-.._.._etc_passwd"))
      (should-not (string-match-p "/" (file-name-nondirectory path))))))

;;;;; download-media: url parsing and the two non-monocle failure shapes ---

(ert-deftest matrix-bridge/download-media-bad-url-skips-the-network ()
  "An unparseable mxc:// url must not even attempt `url-retrieve'."
  (cl-letf (((symbol-function 'url-retrieve)
             (lambda (&rest _) (error "must not be called"))))
    (let (got-data got-err (called nil))
      (matrix-bridge--download-media
       "not-an-mxc-url"
       (lambda (data err) (setq called t got-data data got-err err)))
      (should called)
      (should (null got-data))
      (should (null got-err)))))

(ert-deftest matrix-bridge/download-media-network-failure-reports-err ()
  (cl-letf (((symbol-function 'url-retrieve)
             (lambda (_url cb &rest _)
               (with-temp-buffer (funcall cb '(:error (error http 404)))))))
    (let (got-data got-err)
      (matrix-bridge--download-media
       "mxc://server/abc123"
       (lambda (data err) (setq got-data data got-err err)))
      (should (null got-data))
      (should got-err))))

(ert-deftest matrix-bridge/download-media-success-returns-raw-bytes ()
  (cl-letf (((symbol-function 'url-retrieve)
             (lambda (_url cb &rest _)
               (with-temp-buffer
                 (insert "HTTP/1.1 200 OK\r\n\r\n" "raw-payload-bytes")
                 (funcall cb '())))))
    (let (got-data got-err)
      (matrix-bridge--download-media
       "mxc://server/abc123"
       (lambda (data err) (setq got-data data got-err err)))
      (should (null got-err))
      (should (equal got-data "raw-payload-bytes")))))

;;;;; handle-audio: branches 1 and 2 (download-media mocked directly) ------

(defmacro matrix-bridge-test--stub-download (data err &rest body)
  "Run BODY with `matrix-bridge--download-media' mocked to synchronously call
its callback with (DATA ERR), ignoring the mxc url given to it."
  (declare (indent 2))
  `(cl-letf (((symbol-function 'matrix-bridge--download-media)
              (lambda (_url callback) (funcall callback ,data ,err))))
     ,@body))

(ert-deftest matrix-bridge/handle-audio-download-failure-has-no-attachment ()
  (matrix-bridge-test--with-media-dir
    (matrix-bridge-test--stub-download nil "(error connection-refused)"
      (matrix-bridge-test--capture-delivery delivered
        (matrix-bridge--handle-audio
         '((type . "m.room.message") (sender . "@jeongsoo:warmblood-lounge")
           (event_id . "$abc") (content . ((msgtype . "m.audio") (body . "voice.ogg")
                                           (url . "mxc://server/x")))))
        (should (= 1 (length delivered)))
        (should (string-match-p "다운로드 실패" (car delivered)))
        (should-not (string-match-p "첨부:" (car delivered)))))))

(ert-deftest matrix-bridge/handle-audio-bad-url-has-no-attachment ()
  (matrix-bridge-test--with-media-dir
    (matrix-bridge-test--stub-download nil nil
      (matrix-bridge-test--capture-delivery delivered
        (matrix-bridge--handle-audio
         '((type . "m.room.message") (sender . "@jeongsoo:warmblood-lounge")
           (event_id . "$abc") (content . ((msgtype . "m.audio") (body . "voice.ogg")
                                           (url . "not-mxc")))))
        (should (= 1 (length delivered)))
        (should (string-match-p "url 형식 이상" (car delivered)))
        (should-not (string-match-p "첨부:" (car delivered)))))))

;;;;; invariant #2: write-before-invoke ordering ---------------------------

(ert-deftest matrix-bridge/audio-file-written-before-monocle-invoked ()
  "Even when monocle fails to start immediately, the downloaded bytes must
already be durably on disk -- this is the whole mechanism behind \"the
original survives regardless of transcription outcome\".

Deliberately checks `file-exists-p' FROM INSIDE the mocked `make-process' at
the instant it is called (`file-existed-at-invoke-time'), not just after the
whole flow settles -- checking only afterward would still pass even if the
write were moved to run AFTER the (caught, non-fatal) monocle-start failure,
since by the time a synchronous test resumes control, both steps have long
since happened either way.  Checking at the moment of the call is what makes
this test FAIL if the write is ever reordered to after the monocle call, or
skipped on this path."
  (matrix-bridge-test--with-media-dir
    (let* ((path (expand-file-name "$evt1-voice.ogg" matrix-bridge-media-dir))
           file-existed-at-invoke-time)
      (matrix-bridge-test--stub-download "raw-audio-bytes" nil
        (cl-letf (((symbol-function 'make-process)
                   (lambda (&rest _)
                     (setq file-existed-at-invoke-time (file-exists-p path))
                     (error "monocle binary not found"))))
          (matrix-bridge-test--capture-delivery delivered
            (matrix-bridge--handle-audio
             '((type . "m.room.message") (sender . "@jeongsoo:warmblood-lounge")
               (event_id . "$evt1") (content . ((msgtype . "m.audio") (body . "voice.ogg")
                                                (url . "mxc://server/x")))))
            ;; The write must have already happened BEFORE make-process ran.
            (should (eq file-existed-at-invoke-time t))
            (should (equal (with-temp-buffer
                              (insert-file-contents-literally path)
                              (buffer-string))
                            "raw-audio-bytes"))
            ;; ... and the failure message still names that same file.
            (should (= 1 (length delivered)))
            (should (string-match-p "텍스트 변환 시작 실패" (car delivered)))
            (should (string-match-p (regexp-quote (format "첨부: %s" path))
                                    (car delivered)))))))))

;;;;; invariant #1: HOME is scoped to the one make-process call ------------

(ert-deftest matrix-bridge/monocle-home-override-is-let-scoped-not-global ()
  "The HOME override must be visible ONLY inside the `make-process' call it
was built for, and gone the instant that call returns -- never a global
`setenv'.  This test FAILS if the implementation switches to
`(setenv \"HOME\" ...)' instead of `let'-binding `process-environment'."
  (let* ((matrix-bridge-monocle-home "/fake/monocle/home")
         (home-before (getenv "HOME"))
         (process-environment-before process-environment)
         env-seen-inside-call)
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest _)
                 (setq env-seen-inside-call process-environment)
                 nil)))
      (matrix-bridge--transcribe-audio "/tmp/some-audio.ogg" "@jeongsoo:warmblood-lounge"
                                       " · id:$abc" ""))
    ;; Inside the call, the override was present ...
    (should (member "HOME=/fake/monocle/home" env-seen-inside-call))
    ;; ... and outside it, both the ambient HOME and the whole
    ;; `process-environment' list are back to exactly what they were before.
    (should (equal (getenv "HOME") home-before))
    (should (equal process-environment process-environment-before))))

(ert-deftest matrix-bridge/monocle-start-failure-message-has-attachment ()
  "Branch 3: monocle fails to start -- the message must still name the file
that (by invariant #2) is already on disk by this point."
  (matrix-bridge-test--capture-delivery delivered
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest _) (error "no such file"))))
      (matrix-bridge--transcribe-audio "/tmp/audio-path.ogg" "@jeongsoo:warmblood-lounge"
                                       " · id:$abc" ""))
    (should (= 1 (length delivered)))
    (should (string-match-p "텍스트 변환 시작 실패" (car delivered)))
    (should (string-match-p "첨부: /tmp/audio-path.ogg" (car delivered)))))

;;;;; finish-transcription: branches 4, 5, 6 --------------------------------

(ert-deftest matrix-bridge/finish-transcription-nonzero-rc-has-attachment ()
  (matrix-bridge-test--capture-delivery delivered
    (matrix-bridge--finish-transcription
     "/tmp/a.ogg" "@jeongsoo:warmblood-lounge" " · id:$abc" ""
     1 "" "credentials not found")
    (should (= 1 (length delivered)))
    (should (string-match-p "텍스트 변환 실패: rc=1" (car delivered)))
    (should (string-match-p "credentials not found" (car delivered)))
    (should (string-match-p "첨부: /tmp/a.ogg" (car delivered)))))

(ert-deftest matrix-bridge/finish-transcription-empty-text-has-attachment ()
  (matrix-bridge-test--capture-delivery delivered
    (matrix-bridge--finish-transcription
     "/tmp/a.ogg" "@jeongsoo:warmblood-lounge" " · id:$abc" ""
     0 "{\"text\": \"\"}" "")
    (should (= 1 (length delivered)))
    (should (string-match-p "변환 결과 비어있음" (car delivered)))
    (should (string-match-p "첨부: /tmp/a.ogg" (car delivered)))))

(ert-deftest matrix-bridge/finish-transcription-success-delivers-text-and-attachment ()
  (matrix-bridge-test--capture-delivery delivered
    (matrix-bridge--finish-transcription
     "/tmp/a.ogg" "@jeongsoo:warmblood-lounge" " · id:$abc" ""
     0 "{\"text\": \"안녕하세요\"}" "")
    (should (= 1 (length delivered)))
    (should (string-match-p "안녕하세요" (car delivered)))
    (should (string-match-p "첨부: /tmp/a.ogg" (car delivered)))))

(ert-deftest matrix-bridge/finish-transcription-appends-human-reminder-only-for-human ()
  (matrix-bridge-test--capture-delivery delivered
    (matrix-bridge--finish-transcription
     "/tmp/a.ogg" "@jeongsoo:warmblood-lounge" " · id:$abc" matrix-bridge-human-reminder
     0 "{\"text\": \"hi\"}" "")
    (should (string-suffix-p matrix-bridge-human-reminder (car delivered)))))

(provide 'matrix-bridge-test)
;;; matrix-bridge-test.el ends here
