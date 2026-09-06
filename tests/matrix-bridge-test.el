;;; matrix-bridge-test.el --- Tests for matrix-bridge -*- lexical-binding: t; -*-

;; Ported from `matrix-bridge-self-test' (see ../matrix-bridge.el) into ERT
;; form so `tests/run-tests.el' picks these up like every other suite in
;; this repo. Covers the pure formatting functions only -- no network.

(require 'ert)
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

;;;; --- media: filename sanitization (path-traversal guard) ------------------

(ert-deftest matrix-bridge/sanitize-filename-strips-traversal-characters ()
  (should (equal (matrix-bridge--sanitize-filename "../../etc/passwd")
                 ".._.._etc_passwd")))

(ert-deftest matrix-bridge/sanitize-filename-keeps-safe-characters ()
  (should (equal (matrix-bridge--sanitize-filename "shot-01.png")
                 "shot-01.png")))

(ert-deftest matrix-bridge/sanitize-filename-caps-length ()
  (let ((long (make-string 500 ?a)))
    (should (= (length (matrix-bridge--sanitize-filename long)) 100))))

(ert-deftest matrix-bridge/sanitize-filename-nil-body-does-not-crash ()
  (should (equal (matrix-bridge--sanitize-filename nil) "")))

;;;; --- media: mxc URL parsing -------------------------------------------------

(ert-deftest matrix-bridge/parse-mxc-splits-server-and-media-id ()
  (should (equal (matrix-bridge--parse-mxc "mxc://warmblood-lounge/abc123")
                 '("warmblood-lounge" . "abc123"))))

(ert-deftest matrix-bridge/parse-mxc-rejects-non-mxc-url ()
  (should-not (matrix-bridge--parse-mxc "https://example.com/x")))

(ert-deftest matrix-bridge/parse-mxc-rejects-nil ()
  (should-not (matrix-bridge--parse-mxc nil)))

;;;; --- send: MIME type from extension ----------------------------------------

(ert-deftest matrix-bridge/mime-from-extension-known-types ()
  (should (equal (matrix-bridge--mime-from-extension "shot.png") "image/png"))
  (should (equal (matrix-bridge--mime-from-extension "shot.JPG") "image/jpeg"))
  (should (equal (matrix-bridge--mime-from-extension "shot.jpeg") "image/jpeg"))
  (should (equal (matrix-bridge--mime-from-extension "shot.gif") "image/gif"))
  (should (equal (matrix-bridge--mime-from-extension "shot.webp") "image/webp")))

(ert-deftest matrix-bridge/mime-from-extension-unknown-type-is-nil ()
  (should-not (matrix-bridge--mime-from-extension "notes.txt")))

;;;; --- send: image message payload shape --------------------------------------

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

;;;; --- media: which events trigger an async fetch -----------------------------

(ert-deftest matrix-bridge/media-event-p-true-for-image ()
  (should (matrix-bridge--media-event-p
           '((type . "m.room.message") (sender . "@jeongsoo:warmblood-lounge")
             (content . ((msgtype . "m.image")))))))

(ert-deftest matrix-bridge/media-event-p-true-for-file ()
  (should (matrix-bridge--media-event-p
           '((type . "m.room.message") (sender . "@jeongsoo:warmblood-lounge")
             (content . ((msgtype . "m.file")))))))

(ert-deftest matrix-bridge/media-event-p-false-for-text ()
  (should-not (matrix-bridge--media-event-p
               '((type . "m.room.message") (sender . "@jeongsoo:warmblood-lounge")
                 (content . ((msgtype . "m.text")))))))

(ert-deftest matrix-bridge/media-event-p-false-for-own-outgoing ()
  (let ((matrix-bridge-self-user-id "@butler-x600:warmblood-lounge"))
    (should-not (matrix-bridge--media-event-p
                 `((type . "m.room.message") (sender . ,matrix-bridge-self-user-id)
                   (content . ((msgtype . "m.image"))))))))

(provide 'matrix-bridge-test)
;;; matrix-bridge-test.el ends here
