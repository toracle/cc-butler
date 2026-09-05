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
                 "[matrix · 정수님 · id:$abc] hi")))

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

(provide 'matrix-bridge-test)
;;; matrix-bridge-test.el ends here
