;;; cc-butler-matrix-bridge-test.el --- Tests for cc-butler-matrix-bridge -*- lexical-binding: t; -*-

(require 'ert)
(require 'cc-butler-matrix-bridge)

;;;; --- restart-inhibited-p (grace-period crash-loop guard, SDD §11 item 3) ---

(ert-deftest cc-butler-matrix-bridge/restart-not-inhibited-with-no-prior-start ()
  (let ((cc-butler-matrix-bridge--inhibit-restart-until nil))
    (should-not (cc-butler-matrix-bridge--restart-inhibited-p))))

(ert-deftest cc-butler-matrix-bridge/restart-inhibited-inside-grace-window ()
  (let ((cc-butler-matrix-bridge--inhibit-restart-until
         (time-add (current-time) 60)))
    (should (cc-butler-matrix-bridge--restart-inhibited-p))))

(ert-deftest cc-butler-matrix-bridge/restart-not-inhibited-after-grace-window ()
  (let ((cc-butler-matrix-bridge--inhibit-restart-until
         (time-add (current-time) -1)))
    (should-not (cc-butler-matrix-bridge--restart-inhibited-p))))

;;;; --- room-visible-in-response-p (SDD §6: read via the real endpoint) ---

(defun cc-butler-matrix-bridge-test--json (string)
  (with-temp-buffer
    (insert string)
    (goto-char (point-min))
    (json-parse-buffer :object-type 'hash-table :array-type 'list)))

(ert-deftest cc-butler-matrix-bridge/messages-strategy-room-visible-when-chunk-nonempty ()
  (should (cc-butler-matrix-bridge--room-visible-in-response-p
           'messages "!room:server"
           (cc-butler-matrix-bridge-test--json "{\"chunk\": [{\"event_id\": \"$1\"}]}"))))

(ert-deftest cc-butler-matrix-bridge/messages-strategy-room-not-visible-when-chunk-empty ()
  (should-not (cc-butler-matrix-bridge--room-visible-in-response-p
               'messages "!room:server"
               (cc-butler-matrix-bridge-test--json "{\"chunk\": []}"))))

(ert-deftest cc-butler-matrix-bridge/sync-strategy-room-visible-when-present-under-join ()
  (should (cc-butler-matrix-bridge--room-visible-in-response-p
           'sync "!room:server"
           (cc-butler-matrix-bridge-test--json
            "{\"rooms\": {\"join\": {\"!room:server\": {}}}, \"next_batch\": \"s1\"}"))))

(ert-deftest cc-butler-matrix-bridge/sync-strategy-room-not-visible-when-a-different-room-present ()
  "A regression test for a real bug caught during review: the original
implementation only checked that SOME room was present under
rooms.join, not that the TARGET room was -- so it would have falsely
reported \"reachable\" here."
  (should-not (cc-butler-matrix-bridge--room-visible-in-response-p
               'sync "!room:server"
               (cc-butler-matrix-bridge-test--json
                "{\"rooms\": {\"join\": {\"!other-room:server\": {}}}, \"next_batch\": \"s1\"}"))))

(ert-deftest cc-butler-matrix-bridge/sync-strategy-room-not-visible-when-rooms-key-absent ()
  "The exact real failure mode from SDD §6 (m1, 2026-09-04): a joined
account's initial /sync came back with no `rooms' key at all --
`account_data' and `next_batch' only."
  (should-not (cc-butler-matrix-bridge--room-visible-in-response-p
               'sync "!room:server"
               (cc-butler-matrix-bridge-test--json
                "{\"account_data\": {}, \"next_batch\": \"s1\"}"))))

;;;; --- build-process-environment fails loudly when unconfigured ---

(ert-deftest cc-butler-matrix-bridge/build-process-environment-errors-when-unconfigured ()
  (let ((cc-butler-matrix-bridge-homeserver-url nil)
        (cc-butler-matrix-bridge-self-user-id nil)
        (cc-butler-matrix-bridge-human-user-id nil))
    (should-error (cc-butler-matrix-bridge--build-process-environment))))

(ert-deftest cc-butler-matrix-bridge/build-process-environment-includes-configured-values ()
  (let ((cc-butler-matrix-bridge-homeserver-url "http://localhost:8008")
        (cc-butler-matrix-bridge-self-user-id "@butler-test:warmblood-lounge")
        (cc-butler-matrix-bridge-human-user-id "@human:warmblood-lounge")
        (cc-butler-matrix-bridge-target-session "butler")
        (cc-butler-matrix-bridge-poll-strategy 'messages))
    (cl-letf (((symbol-function 'cc-butler-matrix-bridge--token) (lambda () "tok"))
              ((symbol-function 'cc-butler-matrix-bridge--room-id) (lambda () "!r:server")))
      (let ((env (cc-butler-matrix-bridge--build-process-environment)))
        (should (member "BRIDGE_HOMESERVER=http://localhost:8008" env))
        (should (member "BRIDGE_TOKEN=tok" env))
        (should (member "BRIDGE_ROOM_ID=!r:server" env))
        (should (member "BRIDGE_POLL_STRATEGY=messages" env))))))

(provide 'cc-butler-matrix-bridge-test)
;;; cc-butler-matrix-bridge-test.el ends here
