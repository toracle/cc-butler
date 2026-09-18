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
  ;; `matrix-bridge-human-user-id' defaults to nil (2026-09-10) -- bound
  ;; explicitly here, the same way `event-line-own-outgoing-message-is-dropped'
  ;; below binds `matrix-bridge-self-user-id', so this test does not depend on
  ;; a fleet-specific default to reach the "this IS the human" branch at all.
  (let ((matrix-bridge-human-user-id "@fake-human:example.org"))
    (should (equal (matrix-bridge-event-line
                    `((type . "m.room.message") (sender . ,matrix-bridge-human-user-id)
                      (event_id . "$abc") (content . ((msgtype . "m.text") (body . "hi")))))
                   ;; The human's own messages carry `matrix-bridge-human-reminder'.
                   ;; Built from the variable, not a copy of its wording: a reworded
                   ;; reminder must not turn this attribution test red.
                   (concat "[matrix · 정수님 · id:$abc] hi"
                           matrix-bridge-human-reminder)))))

(ert-deftest matrix-bridge/event-line-fleet-sender-shows-short-name ()
  (should (equal (matrix-bridge-event-line
                  '((type . "m.room.message")
                    (sender . "@fake-peer:example.org")
                    (event_id . "$abc") (content . ((msgtype . "m.text") (body . "hi")))))
                 "[matrix · fake-peer · id:$abc] hi")))

(ert-deftest matrix-bridge/event-line-own-outgoing-message-is-dropped ()
  (let ((matrix-bridge-self-user-id "@fake-self:example.org"))
    (should-not (matrix-bridge-event-line
                 `((type . "m.room.message") (sender . ,matrix-bridge-self-user-id)
                   (event_id . "$abc")
                   (content . ((msgtype . "m.text") (body . "echo"))))))))

(ert-deftest matrix-bridge/event-line-no-msgtype-is-dropped ()
  (should-not (matrix-bridge-event-line
               '((type . "m.room.message") (sender . "@fake-human:example.org")
                 (event_id . "$abc") (content . ())))))

(ert-deftest matrix-bridge/event-line-non-message-type-is-dropped ()
  (should-not (matrix-bridge-event-line
               '((type . "m.room.member") (sender . "@fake-human:example.org")
                 (event_id . "$abc")
                 (content . ((msgtype . "m.text") (body . "x")))))))

;;;; --- matrix-bridge-start: refuses to run with either identity nil ---------
;; Both guards are the very first thing `matrix-bridge-start' does, before
;; any file I/O (token/room-id files) or network call -- so calling it with
;; the OTHER identity var set to a fake, non-nil value isolates exactly the
;; guard under test without touching anything real.

(ert-deftest matrix-bridge/start-refuses-when-self-user-id-nil ()
  (let ((matrix-bridge-self-user-id nil)
        (matrix-bridge-human-user-id "@fake-human:example.org"))
    (should-error (matrix-bridge-start))))

(ert-deftest matrix-bridge/start-refuses-when-human-user-id-nil ()
  "`matrix-bridge-human-user-id' defaults to nil (2026-09-10, this fleet's
own id was a hardcoded leak before). Without this guard, starting the relay
in that state would not error -- it would silently misclassify the human's
every message as a stranger's (see `matrix-bridge-attribution' /
`matrix-bridge-event-line'), the same failure mode PR #175 already removed
for `matrix-bridge-self-user-id'."
  (let ((matrix-bridge-self-user-id "@fake-self:example.org")
        (matrix-bridge-human-user-id nil))
    (should-error (matrix-bridge-start))))

;;;; --- matrix-bridge--deliver: never inject with a nil identity var ---------
;; `matrix-bridge-start' only guards its OWN call site. Two other paths reach
;; live (non-shadow) delivery without ever calling it: a hot-reload of an
;; already-running daemon (`emacs-startup-hook' does not fire again, and
;; `defvar' does not touch an already-bound variable, so a var that was never
;; bound before the reload stays nil straight through it), and
;; `matrix-bridge-shadow' being flipped to nil directly (documented at the top
;; of matrix-bridge.el as the way to "go live" -- it does not route through
;; `matrix-bridge-start' either). `matrix-bridge--deliver' is the one function
;; every real delivery must pass through regardless of which path reached it,
;; so that is where this guards -- not by refusing to run (this is deep in an
;; async poll loop; throwing here risks taking the whole loop down over one
;; bad message), but by falling back to the existing shadow path, the same
;; graceful degradation already used two clauses below for "injection isn't
;; available at all".

(defmacro matrix-bridge-test--with-fake-injector (injected-var &rest body)
  "Run BODY with `cc-butler--send-input'/`cc-butler--dir-by-name' stubbed so
`matrix-bridge--deliver' believes real injection is available, setting
INJECTED-VAR (a symbol, already `let'-bound by the caller) to t if the stub
is actually called. Restores whatever these two symbols were bound to
before (fboundp or not) -- they are real `cc-butler.el' functions that may
already be loaded by the rest of the suite, so this must not leave them
permanently unbound or permanently stubbed for later tests."
  (declare (indent 1))
  `(let* ((send-was-bound (fboundp 'cc-butler--send-input))
          (send-orig (and send-was-bound (symbol-function 'cc-butler--send-input)))
          (dir-was-bound (fboundp 'cc-butler--dir-by-name))
          (dir-orig (and dir-was-bound (symbol-function 'cc-butler--dir-by-name))))
     (fset 'cc-butler--send-input (lambda (&rest _) (setq ,injected-var t)))
     (fset 'cc-butler--dir-by-name (lambda (&rest _) "fake-dir"))
     (unwind-protect
         (progn ,@body)
       (if send-was-bound (fset 'cc-butler--send-input send-orig)
         (fmakunbound 'cc-butler--send-input))
       (if dir-was-bound (fset 'cc-butler--dir-by-name dir-orig)
         (fmakunbound 'cc-butler--dir-by-name)))))

(ert-deftest matrix-bridge/deliver-shadows-instead-of-injecting-when-self-id-nil ()
  (let ((matrix-bridge-shadow nil)
        (matrix-bridge-self-user-id nil)
        (matrix-bridge-human-user-id "@fake-human:example.org")
        (injected nil))
    (matrix-bridge-test--with-fake-injector injected
      (matrix-bridge--deliver "some text")
      (should-not injected))))

(ert-deftest matrix-bridge/deliver-shadows-instead-of-injecting-when-human-id-nil ()
  (let ((matrix-bridge-shadow nil)
        (matrix-bridge-self-user-id "@fake-self:example.org")
        (matrix-bridge-human-user-id nil)
        (injected nil))
    (matrix-bridge-test--with-fake-injector injected
      (matrix-bridge--deliver "some text")
      (should-not injected))))

(ert-deftest matrix-bridge/deliver-injects-normally-when-both-ids-set ()
  "The guard above must not block ordinary non-shadow delivery -- only a nil
identity var should divert to shadow, not the presence of the guard itself."
  (let ((matrix-bridge-shadow nil)
        (matrix-bridge-self-user-id "@fake-self:example.org")
        (matrix-bridge-human-user-id "@fake-human:example.org")
        (injected nil))
    (matrix-bridge-test--with-fake-injector injected
      (matrix-bridge--deliver "some text")
      (should injected))))

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

;;;;; sanitize-filename / media-path: shared by the audio and image/file ---
;;;;; axes -- the path-traversal guard --------------------------------------

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

(ert-deftest matrix-bridge/sanitize-filename-caps-length ()
  (let ((long (make-string 500 ?a)))
    (should (= (length (matrix-bridge--sanitize-filename long)) 100))))

(ert-deftest matrix-bridge/sanitize-filename-nil-body-does-not-crash ()
  (should (equal (matrix-bridge--sanitize-filename nil) "")))

(ert-deftest matrix-bridge/media-path-has-no-directory-component-from-body ()
  (matrix-bridge-test--with-media-dir
    (let ((path (matrix-bridge--media-path "$abc" "../../etc/passwd")))
      (should (equal (file-name-directory path)
                      (file-name-as-directory matrix-bridge-media-dir)))
      (should (equal (file-name-nondirectory path) "$abc-.._.._etc_passwd"))
      (should-not (string-match-p "/" (file-name-nondirectory path))))))

(ert-deftest matrix-bridge/media-path-creates-media-dir-if-missing ()
  "The kept half of the audio/media dedupe: `--media-path' lazily creates
`matrix-bridge-media-dir' (audio's prior behavior) rather than leaving that
to each caller (media's prior behavior) -- see the commit message for why."
  (let* ((parent (make-temp-file "matrix-bridge-test-media-parent-" t))
         (matrix-bridge-media-dir (expand-file-name "nested/media" parent)))
    (unwind-protect
        (progn
          (should-not (file-directory-p matrix-bridge-media-dir))
          (matrix-bridge--media-path "$abc" "voice.ogg")
          (should (file-directory-p matrix-bridge-media-dir)))
      (delete-directory parent t))))

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
  (let ((matrix-bridge-human-user-id "@fake-human:example.org"))
    (matrix-bridge-test--with-media-dir
      (matrix-bridge-test--stub-download nil "(error connection-refused)"
        (matrix-bridge-test--capture-delivery delivered
          (matrix-bridge--handle-audio
           `((type . "m.room.message") (sender . ,matrix-bridge-human-user-id)
             (event_id . "$abc") (content . ((msgtype . "m.audio") (body . "voice.ogg")
                                             (url . "mxc://server/x")))))
          (should (= 1 (length delivered)))
          (should (string-match-p "다운로드 실패" (car delivered)))
          (should-not (string-match-p "첨부:" (car delivered))))))))

(ert-deftest matrix-bridge/handle-audio-bad-url-has-no-attachment ()
  (let ((matrix-bridge-human-user-id "@fake-human:example.org"))
    (matrix-bridge-test--with-media-dir
      (matrix-bridge-test--stub-download nil nil
        (matrix-bridge-test--capture-delivery delivered
          (matrix-bridge--handle-audio
           `((type . "m.room.message") (sender . ,matrix-bridge-human-user-id)
             (event_id . "$abc") (content . ((msgtype . "m.audio") (body . "voice.ogg")
                                             (url . "not-mxc")))))
          (should (= 1 (length delivered)))
          (should (string-match-p "url 형식 이상" (car delivered)))
          (should-not (string-match-p "첨부:" (car delivered))))))))

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
  (let ((matrix-bridge-human-user-id "@fake-human:example.org"))
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
               `((type . "m.room.message") (sender . ,matrix-bridge-human-user-id)
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
                                      (car delivered))))))))))

;;;;; invariant #1: HOME is scoped to the one make-process call ------------

(ert-deftest matrix-bridge/monocle-home-override-is-let-scoped-not-global ()
  "The HOME override must be visible ONLY inside the `make-process' call it
was built for, and gone the instant that call returns -- never a global
`setenv'.  This test FAILS if the implementation switches to
`(setenv \"HOME\" ...)' instead of `let'-binding `process-environment'."
  (let* ((matrix-bridge-monocle-home "/fake/monocle/home")
         (matrix-bridge-human-user-id "@fake-human:example.org")
         (home-before (getenv "HOME"))
         (process-environment-before process-environment)
         env-seen-inside-call)
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest _)
                 (setq env-seen-inside-call process-environment)
                 nil)))
      (matrix-bridge--transcribe-audio "/tmp/some-audio.ogg" matrix-bridge-human-user-id
                                       "$abc" nil))
    ;; Inside the call, the override was present ...
    (should (member "HOME=/fake/monocle/home" env-seen-inside-call))
    ;; ... and outside it, both the ambient HOME and the whole
    ;; `process-environment' list are back to exactly what they were before.
    (should (equal (getenv "HOME") home-before))
    (should (equal process-environment process-environment-before))))

(ert-deftest matrix-bridge/monocle-start-failure-message-has-attachment ()
  "Branch 3: monocle fails to start -- the message must still name the file
that (by invariant #2) is already on disk by this point."
  (let ((matrix-bridge-human-user-id "@fake-human:example.org"))
    (matrix-bridge-test--capture-delivery delivered
      (cl-letf (((symbol-function 'make-process)
                 (lambda (&rest _) (error "no such file"))))
        (matrix-bridge--transcribe-audio "/tmp/audio-path.ogg" matrix-bridge-human-user-id
                                         "$abc" nil))
      (should (= 1 (length delivered)))
      (should (string-match-p "텍스트 변환 시작 실패" (car delivered)))
      (should (string-match-p "첨부: /tmp/audio-path.ogg" (car delivered))))))

;;;;; finish-transcription: branches 4, 5, 6 --------------------------------

(ert-deftest matrix-bridge/finish-transcription-nonzero-rc-has-attachment ()
  (let ((matrix-bridge-human-user-id "@fake-human:example.org"))
    (matrix-bridge-test--capture-delivery delivered
      (matrix-bridge--finish-transcription
       "/tmp/a.ogg" matrix-bridge-human-user-id "$abc" nil
       1 "" "credentials not found")
      (should (= 1 (length delivered)))
      (should (string-match-p "텍스트 변환 실패: rc=1" (car delivered)))
      (should (string-match-p "credentials not found" (car delivered)))
      (should (string-match-p "첨부: /tmp/a.ogg" (car delivered))))))

(ert-deftest matrix-bridge/finish-transcription-empty-text-has-attachment ()
  (let ((matrix-bridge-human-user-id "@fake-human:example.org"))
    (matrix-bridge-test--capture-delivery delivered
      (matrix-bridge--finish-transcription
       "/tmp/a.ogg" matrix-bridge-human-user-id "$abc" nil
       0 "{\"text\": \"\"}" "")
      (should (= 1 (length delivered)))
      (should (string-match-p "변환 결과 비어있음" (car delivered)))
      (should (string-match-p "첨부: /tmp/a.ogg" (car delivered))))))

(ert-deftest matrix-bridge/finish-transcription-success-delivers-text-and-attachment ()
  (let ((matrix-bridge-human-user-id "@fake-human:example.org"))
    (matrix-bridge-test--capture-delivery delivered
      (matrix-bridge--finish-transcription
       "/tmp/a.ogg" matrix-bridge-human-user-id "$abc" nil
       0 "{\"text\": \"안녕하세요\"}" "")
      (should (= 1 (length delivered)))
      (should (string-match-p "안녕하세요" (car delivered)))
      (should (string-match-p "첨부: /tmp/a.ogg" (car delivered))))))

(ert-deftest matrix-bridge/finish-transcription-appends-human-reminder-only-for-human ()
  "The human-reminder suffix now comes from `matrix-bridge--format-line',
derived from SENDER -- no longer a param `--finish-transcription' is handed
directly.  Covered as a positive/negative pair, same pattern as
`matrix-bridge/event-line-human-sender-shows-attribution' /
`-fleet-sender-shows-short-name'."
  (let ((matrix-bridge-human-user-id "@fake-human:example.org"))
    (matrix-bridge-test--capture-delivery delivered
      (matrix-bridge--finish-transcription
       "/tmp/a.ogg" matrix-bridge-human-user-id "$abc" nil
       0 "{\"text\": \"hi\"}" "")
      (should (string-suffix-p matrix-bridge-human-reminder (car delivered))))))

(ert-deftest matrix-bridge/finish-transcription-no-reminder-for-non-human-sender ()
  (let ((matrix-bridge-human-user-id "@fake-human:example.org"))
    (matrix-bridge-test--capture-delivery delivered
      (matrix-bridge--finish-transcription
       "/tmp/a.ogg" "@fake-peer:example.org" "$abc" nil
       0 "{\"text\": \"hi\"}" "")
      (should-not (string-suffix-p matrix-bridge-human-reminder (car delivered))))))

;;;; --- media (m.image/m.file axis) -- ported from m1's independent branch --

;;;;; parse-mxc: url splitting --------------------------------------------

(ert-deftest matrix-bridge/parse-mxc-splits-server-and-media-id ()
  (should (equal (matrix-bridge--parse-mxc "mxc://example.org/abc123")
                 '("example.org" . "abc123"))))

(ert-deftest matrix-bridge/parse-mxc-rejects-non-mxc-url ()
  (should-not (matrix-bridge--parse-mxc "https://example.com/x")))

(ert-deftest matrix-bridge/parse-mxc-rejects-nil ()
  (should-not (matrix-bridge--parse-mxc nil)))

;;;;; media-event-p: which events trigger an async fetch -------------------

(ert-deftest matrix-bridge/media-event-p-true-for-image ()
  (should (matrix-bridge--media-event-p
           '((type . "m.room.message") (sender . "@fake-human:example.org")
             (content . ((msgtype . "m.image")))))))

(ert-deftest matrix-bridge/media-event-p-true-for-file ()
  (should (matrix-bridge--media-event-p
           '((type . "m.room.message") (sender . "@fake-human:example.org")
             (content . ((msgtype . "m.file")))))))

(ert-deftest matrix-bridge/media-event-p-false-for-text ()
  (should-not (matrix-bridge--media-event-p
               '((type . "m.room.message") (sender . "@fake-human:example.org")
                 (content . ((msgtype . "m.text")))))))

(ert-deftest matrix-bridge/media-event-p-false-for-own-outgoing ()
  (let ((matrix-bridge-self-user-id "@fake-self:example.org"))
    (should-not (matrix-bridge--media-event-p
                 `((type . "m.room.message") (sender . ,matrix-bridge-self-user-id)
                   (content . ((msgtype . "m.image"))))))))

;;;; --- sending (m.image; inert, nothing calls this yet) ---------------------
;;;; Ported from m1's independent branch, alongside the media axis it sends.

;;;;; mime-from-extension ----------------------------------------------------

(ert-deftest matrix-bridge/mime-from-extension-known-types ()
  (should (equal (matrix-bridge--mime-from-extension "shot.png") "image/png"))
  (should (equal (matrix-bridge--mime-from-extension "shot.JPG") "image/jpeg"))
  (should (equal (matrix-bridge--mime-from-extension "shot.jpeg") "image/jpeg"))
  (should (equal (matrix-bridge--mime-from-extension "shot.gif") "image/gif"))
  (should (equal (matrix-bridge--mime-from-extension "shot.webp") "image/webp")))

(ert-deftest matrix-bridge/mime-from-extension-unknown-type-is-nil ()
  (should-not (matrix-bridge--mime-from-extension "notes.txt")))

;;;;; image-send-payload: pure JSON payload shape ---------------------------

(ert-deftest matrix-bridge/image-payload-plain-has-no-relation ()
  (should (equal (matrix-bridge--image-send-payload
                  "shot.png" "mxc://x/1" "image/png" 123 nil nil)
                 '((msgtype . "m.image") (body . "shot.png") (url . "mxc://x/1")
                   (info . ((mimetype . "image/png") (size . 123)))))))

(ert-deftest matrix-bridge/image-payload-reply-only ()
  (should (equal (matrix-bridge--image-send-payload
                  "shot.png" "mxc://x/1" "image/png" 123 nil "$tgt")
                 '((m.relates_to . ((m.in_reply_to . ((event_id . "$tgt")))))
                   (msgtype . "m.image") (body . "shot.png") (url . "mxc://x/1")
                   (info . ((mimetype . "image/png") (size . 123)))))))

(ert-deftest matrix-bridge/image-payload-thread-root-only-replies-to-itself ()
  "Matches post-to-lounge.sh's thread-fallback convention: a thread-root
with no explicit reply-to still carries an m.in_reply_to to the root."
  (should (equal (matrix-bridge--image-send-payload
                  "shot.png" "mxc://x/1" "image/png" 123 "$root" nil)
                 '((m.relates_to . ((rel_type . "m.thread") (event_id . "$root")
                                    (m.in_reply_to . ((event_id . "$root")))))
                   (msgtype . "m.image") (body . "shot.png") (url . "mxc://x/1")
                   (info . ((mimetype . "image/png") (size . 123)))))))

(ert-deftest matrix-bridge/image-payload-thread-root-and-reply ()
  (should (equal (matrix-bridge--image-send-payload
                  "shot.png" "mxc://x/1" "image/png" 123 "$root" "$tgt")
                 '((m.relates_to . ((rel_type . "m.thread") (event_id . "$root")
                                    (m.in_reply_to . ((event_id . "$tgt")))))
                   (msgtype . "m.image") (body . "shot.png") (url . "mxc://x/1")
                   (info . ((mimetype . "image/png") (size . 123)))))))

;;;; --- poison event: one malformed event must not stall the since-cursor ----
;; A signal escaping the per-event dispatch skips `(setq matrix-bridge--since
;; next)', so the same /sync batch is re-fetched and re-delivered forever.

(ert-deftest matrix-bridge/malformed-audio-event-does-not-stall-since-cursor ()
  "An m.audio event with a non-string `url' (5) must not abort the batch:
the event after it is still delivered, `since' advances, and it is saved."
  (matrix-bridge-test--with-media-dir
    (let* ((matrix-bridge-self-user-id "@fake-self:example.org")
           (matrix-bridge-human-user-id "@fake-human:example.org")
           (matrix-bridge--room-id "!fake-room:example.org")
           (matrix-bridge--since "s1")
           (saved nil)
           (body (concat
                  "{\"next_batch\":\"s2\",\"rooms\":{\"join\":{\"!fake-room:example.org\":"
                  "{\"timeline\":{\"events\":["
                  "{\"type\":\"m.room.message\",\"sender\":\"@fake-peer:example.org\","
                  "\"event_id\":\"$bad\",\"content\":{\"msgtype\":\"m.audio\","
                  "\"body\":\"v.ogg\",\"url\":5}},"
                  "{\"type\":\"m.room.message\",\"sender\":\"@fake-peer:example.org\","
                  "\"event_id\":\"$good\",\"content\":{\"msgtype\":\"m.text\","
                  "\"body\":\"still delivered\"}}]}}}}}")))
      (cl-letf (((symbol-function 'matrix-bridge--save-since)
                 (lambda (tok) (setq saved tok)))
                ((symbol-function 'matrix-bridge--reschedule) #'ignore))
        (matrix-bridge-test--capture-delivery delivered
          (matrix-bridge--handle matrix-bridge--generation nil body nil)
          (should (equal matrix-bridge--since "s2"))
          (should (equal saved "s2"))
          (should (cl-some (lambda (d) (string-match-p "still delivered" d)) delivered)))))))

;;;; --- matrix-bridge-thread-replies: synchronous thread fetch ---------------
;;
;; No real network call anywhere here -- every test stubs
;; `matrix-bridge--thread-fetch-page' (the one function that actually calls
;; `url-retrieve-synchronously'), so the pagination/classification logic in
;; `matrix-bridge-thread-replies' runs against canned responses only.  All
;; ids below are synthetic (`!fake-room:example.org', `$fake-event-N').

(defmacro matrix-bridge-test--with-fetch-page-stub (responses &rest body)
  "Run BODY with `matrix-bridge--thread-fetch-page' stubbed to return the
next element of RESPONSES (a list of plists) on each call, in order.  Binds
`matrix-bridge-test--fetch-page-calls' to the number of calls made, visible
to BODY."
  (declare (indent 1))
  `(let ((responses-left (copy-sequence ,responses))
         (matrix-bridge-test--fetch-page-calls 0))
     (cl-letf (((symbol-function 'matrix-bridge--thread-fetch-page)
                (lambda (&rest _args)
                  (setq matrix-bridge-test--fetch-page-calls
                        (1+ matrix-bridge-test--fetch-page-calls))
                  (let ((r (car responses-left)))
                    (setq responses-left (cdr responses-left))
                    r))))
       ,@body)))

(defun matrix-bridge-test--full-page (n)
  "N synthetic events, one page's worth (for a full `chunk')."
  (let (evs)
    (dotimes (i n) (push `((sender . ,(format "@fake-user-%d:example.org" i))) evs))
    (nreverse evs)))

(ert-deftest matrix-bridge/thread-replies-empty-thread-is-a-real-ok ()
  "A successful fetch that finds nothing is `:status ok', N=0 -- not an error."
  (matrix-bridge-test--with-fetch-page-stub
      (list (list :http-status 200 :parsed '((chunk . []))))
    (let ((r (matrix-bridge-thread-replies "!fake-room:example.org" "$fake-event-1")))
      (should (eq 'ok (plist-get r :status)))
      (should (= 0 (plist-get r :scanned)))
      (should (null (plist-get r :events)))
      (should-not (plist-get r :truncated))
      (should (= 1 matrix-bridge-test--fetch-page-calls)))))

(ert-deftest matrix-bridge/thread-replies-paginates-across-next-batch ()
  "Two pages: page 1 is full (limit-sized) with `next_batch', page 2 is
short with no `next_batch' -- both pages' events are accumulated."
  (matrix-bridge-test--with-fetch-page-stub
      (list (list :http-status 200
                   :parsed `((chunk . ,(matrix-bridge-test--full-page
                                        matrix-bridge--thread-fetch-page-limit))
                             (next_batch . "page2token")))
            (list :http-status 200
                   :parsed '((chunk . (((sender . "@fake-user-x:example.org")))))))
    (let ((r (matrix-bridge-thread-replies "!fake-room:example.org" "$fake-event-1")))
      (should (eq 'ok (plist-get r :status)))
      (should (= (1+ matrix-bridge--thread-fetch-page-limit) (plist-get r :scanned)))
      (should-not (plist-get r :truncated))
      (should (= 2 matrix-bridge-test--fetch-page-calls)))))

(ert-deftest matrix-bridge/thread-replies-stops-on-short-chunk-even-with-next-batch ()
  "Counterintuitive real behavior (observed live against conduit): a page's
`next_batch' can be present even though its `chunk' came back shorter than
the requested limit.  Pagination must stop there anyway -- relying on
\"`next_batch' absent\" alone would wrongly fetch a second, needless page."
  (matrix-bridge-test--with-fetch-page-stub
      (list (list :http-status 200
                   :parsed '((chunk . (((sender . "@fake-user-1:example.org"))))
                             (next_batch . "page2token"))))
    (let ((r (matrix-bridge-thread-replies "!fake-room:example.org" "$fake-event-1")))
      (should (eq 'ok (plist-get r :status)))
      (should (= 1 (plist-get r :scanned)))
      (should-not (plist-get r :truncated))
      ;; Only ONE call -- a naive "stop only when next_batch is absent"
      ;; implementation would have made a second, needless call here.
      (should (= 1 matrix-bridge-test--fetch-page-calls)))))

(ert-deftest matrix-bridge/thread-replies-page-cap-sets-truncated ()
  "Hitting the page cap before natural exhaustion sets `:truncated t' --
never silently presenting a partial scan as exhaustive."
  (let ((matrix-bridge-thread-fetch-max-pages 2)
        (full-chunk (matrix-bridge-test--full-page matrix-bridge--thread-fetch-page-limit)))
    (matrix-bridge-test--with-fetch-page-stub
        (list (list :http-status 200 :parsed `((chunk . ,full-chunk) (next_batch . "t1")))
              (list :http-status 200 :parsed `((chunk . ,full-chunk) (next_batch . "t2")))
              (list :http-status 200 :parsed `((chunk . ,full-chunk) (next_batch . "t3"))))
      (let ((r (matrix-bridge-thread-replies "!fake-room:example.org" "$fake-event-1")))
        (should (eq 'ok (plist-get r :status)))
        (should (plist-get r :truncated))
        ;; Cap is 2 -- the stub's 3rd response must never be consumed.
        (should (= 2 matrix-bridge-test--fetch-page-calls))))))

(ert-deftest matrix-bridge/thread-replies-not-in-room-on-m-not-found ()
  "The specific Matrix M_NOT_FOUND error (wrong/stale recorded room) is
reported distinctly from a generic error."
  (matrix-bridge-test--with-fetch-page-stub
      (list (list :http-status 404
                   :parsed '((errcode . "M_NOT_FOUND") (error . "Event not found in room"))))
    (let ((r (matrix-bridge-thread-replies "!fake-room:example.org" "$fake-event-1")))
      (should (eq 'not-in-room (plist-get r :status))))))

(ert-deftest matrix-bridge/thread-replies-unparseable-body-is-status-error-not-ok ()
  "HTTP 200 with a body that fails to parse (`:parsed' nil, since
`matrix-bridge--thread-fetch-page' parses via `ignore-errors') must be
`:status error' -- NOT `:status ok :scanned 0'.  Before this guard, a
parse failure fell through to the success branch with an empty chunk and
absent next_batch, producing exactly the indistinguishable-0 this whole
check's `:detail' contract exists to prevent: a caller cannot tell
\"checked, found nothing\" apart from \"the body never parsed at all\"."
  (matrix-bridge-test--with-fetch-page-stub
      (list (list :http-status 200 :parsed nil))
    (let ((r (matrix-bridge-thread-replies "!fake-room:example.org" "$fake-event-1")))
      (should-not (eq 'ok (plist-get r :status)))
      (should (eq 'error (plist-get r :status)))
      (should (stringp (plist-get r :detail))))))

(ert-deftest matrix-bridge/thread-replies-generic-http-error-is-status-error ()
  (matrix-bridge-test--with-fetch-page-stub
      (list (list :http-status 500 :parsed '((errcode . "M_UNKNOWN") (error . "boom"))))
    (let ((r (matrix-bridge-thread-replies "!fake-room:example.org" "$fake-event-1")))
      (should (eq 'error (plist-get r :status)))
      (should (stringp (plist-get r :detail))))))

(ert-deftest matrix-bridge/thread-replies-underlying-exception-never-escapes ()
  "A network failure (the underlying fetch signals) must never escape as an
uncaught exception -- it becomes `:status error' instead."
  (matrix-bridge-test--with-fetch-page-stub
      (list 'unused)  ; response is never reached; the stub below signals instead
    (cl-letf (((symbol-function 'matrix-bridge--thread-fetch-page)
               (lambda (&rest _) (error "simulated network failure"))))
      (let ((r (matrix-bridge-thread-replies "!fake-room:example.org" "$fake-event-1")))
        (should (eq 'error (plist-get r :status)))
        (should (stringp (plist-get r :detail)))))))

(provide 'matrix-bridge-test)
;;; matrix-bridge-test.el ends here
