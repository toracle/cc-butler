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
