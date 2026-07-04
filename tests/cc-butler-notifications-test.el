;;; cc-butler-notifications-test.el --- tests for the notify layer  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jeongsoo Park
;; SPDX-License-Identifier: MIT

(require 'ert)
(require 'cc-butler-notifications)

(ert-deftest cc-butler-notify/decision-push-fires-command ()
  "cc-butler-notify-decision runs the messenger command (e.g. Telegram) with the
decision title AND body — the active push that reaches the human when away."
  (let ((ran nil)
        (cc-butler-notify-command "send %t %b"))
    (cl-letf (((symbol-function 'start-process-shell-command)
               (lambda (_n _b cmd) (setq ran cmd) 'proc))
              ((symbol-function 'set-process-query-on-exit-flag) #'ignore)
              ((symbol-function 'cc-butler-notify-desktop) #'ignore))
      (cc-butler-notify-decision "a decision needs you" "Ship the flow?")
      (should ran)
      ;; shell-quote-argument backslash-escapes spaces, so match single tokens
      (should (string-match-p "decision" ran))
      (should (string-match-p "Ship" ran))
      (should (string-match-p "flow" ran)))))

(ert-deftest cc-butler-notify/decision-push-no-command-is-safe ()
  "With no messenger command configured, the push is a safe no-op (still tries
the desktop backend)."
  (let ((cc-butler-notify-command nil) (desktop nil))
    (cl-letf (((symbol-function 'cc-butler-notify-desktop)
               (lambda (_e) (setq desktop t))))
      (cc-butler-notify-decision "t" "b")
      (should desktop))))

(provide 'cc-butler-notifications-test)
;;; cc-butler-notifications-test.el ends here
