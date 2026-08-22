;;; cc-butler-north-star-test.el --- tests for cc-butler-north-star.el -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'cc-butler-north-star)

(defvar cc-butler-north-star-test--writes nil
  "Terminal writes recorded by `cc-butler-north-star-test--with-stub-terminal'.
Newest first.")

(defmacro cc-butler-north-star-test--with-stub-terminal (&rest body)
  "Run BODY with session \"/butler/\" backed by a stub terminal, idle by
default (`cc-butler--forward-ops-free-p' true) — the same shape as
`cc-butler-orchestrator-test--with-forward-fixture', but self-contained so
this file does not depend on load order against another test file."
  (declare (indent 0))
  `(let* ((cc-butler-north-star-test--writes nil)
          (cc-butler--butler "/butler/")
          (cc-butler-north-star-file "/tmp/north-star-test-fleet.org")
          (cc-butler-forward-idle-threshold 60)
          (cc-butler-submit-delay 0.01)
          (cc-butler-session-io-timeout 5)
          (term-buf (get-buffer-create " *ccb-north-star-test-term*")))
     (unwind-protect
         (cl-letf (((symbol-function 'claude-code-ide--get-buffer-name)
                    (lambda (_d) (buffer-name term-buf)))
                   ((symbol-function 'cc-butler--display-name) (lambda (d) d))
                   ((symbol-function 'cc-butler--session-last-activity)
                    (lambda (_d) (- (float-time) 120))) ; idle by default
                   ((symbol-function 'claude-code-ide--terminal-send-string)
                    (lambda (s) (push (list :string s) cc-butler-north-star-test--writes)))
                   ((symbol-function 'claude-code-ide--terminal-send-return)
                    (lambda () (push (list :return) cc-butler-north-star-test--writes))))
           ,@body)
       (when (buffer-live-p term-buf) (kill-buffer term-buf)))))

(defun cc-butler-north-star-test--recorded-writes ()
  (reverse cc-butler-north-star-test--writes))

(ert-deftest cc-butler-north-star/prompt-names-the-file ()
  "The nudge must point at the actual configured file, not a hardcoded
path — the file's location is user-configurable via defcustom."
  (let ((cc-butler-north-star-file "/tmp/wherever/north-star.org"))
    (should (string-match-p (regexp-quote cc-butler-north-star-file)
                            (cc-butler--north-star-prompt)))))

(ert-deftest cc-butler-north-star/prompt-always-inlines-the-template ()
  "The entry-shape template must ride along in the nudge itself — the
butler needs it to create the file correctly on the very first run,
before it has ever opened `cc-butler-north-star-file', and the same
inlined copy still guards against silent format drift once the file
already exists."
  (let ((prompt (cc-butler--north-star-prompt)))
    (should (string-match-p (regexp-quote ":DOD:") prompt))
    (should (string-match-p (regexp-quote ":PROPERTIES:") prompt))))

(ert-deftest cc-butler-north-star/fire-sends-when-butler-idle ()
  "An idle butler gets typed-and-submitted, mirroring
`cc-butler--forward-backstop''s own idle gate."
  (cc-butler-north-star-test--with-stub-terminal
    (cc-butler--north-star-fire)
    (should (equal '(:return) (car (last (cc-butler-north-star-test--recorded-writes)))))
    (should (cl-some (lambda (w) (eq (car w) :string))
                     (cc-butler-north-star-test--recorded-writes)))))

(ert-deftest cc-butler-north-star/fire-noop-when-butler-busy ()
  "A butler mid-turn must not be typed into — an hourly housekeeping ping
landing mid-generation could scramble whatever it is doing."
  (cc-butler-north-star-test--with-stub-terminal
    (cl-letf (((symbol-function 'cc-butler--session-last-activity)
               (lambda (_d) (float-time)))) ; just wrote, i.e. busy
      (cc-butler--north-star-fire)
      (should (null (cc-butler-north-star-test--recorded-writes))))))

(ert-deftest cc-butler-north-star/fire-noop-when-no-butler-designated ()
  "No butler set yet (fresh fleet, nobody has run `cc-butler-set-butler')
must be a quiet no-op, not an error from a nil dir."
  (cc-butler-north-star-test--with-stub-terminal
    (let ((cc-butler--butler nil))
      (should (null (cc-butler--north-star-fire)))
      (should (null (cc-butler-north-star-test--recorded-writes))))))

(ert-deftest cc-butler-north-star/check-command-reports-success ()
  "The interactive command delegates to `cc-butler--north-star-fire' and
tells the caller what happened — unlike the timer's silent no-op, a human
asking explicitly deserves an answer either way."
  (cc-butler-north-star-test--with-stub-terminal
    (let (msg)
      (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (setq msg (apply #'format fmt args)))))
        (cc-butler-north-star-check))
      (should (string-match-p "sent to the butler" msg)))))

(ert-deftest cc-butler-north-star/check-command-reports-when-skipped ()
  "A busy butler must still get a message back, not silence — the whole
point of a manual call is the human wants to know it actually happened."
  (cc-butler-north-star-test--with-stub-terminal
    (cl-letf (((symbol-function 'cc-butler--session-last-activity)
               (lambda (_d) (float-time))))
      (let (msg)
        (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (setq msg (apply #'format fmt args)))))
          (cc-butler-north-star-check))
        (should (string-match-p "skipped" msg))))))

(ert-deftest cc-butler-north-star/fire-noop-when-terminal-not-live ()
  "The butler dir is set but its terminal buffer is gone (session ended,
Emacs just restarted) — must not error, just skip."
  (cc-butler-north-star-test--with-stub-terminal
    (cl-letf (((symbol-function 'claude-code-ide--get-buffer-name)
               (lambda (_d) "a buffer name nothing owns")))
      (should (null (cc-butler--north-star-fire)))
      (should (null (cc-butler-north-star-test--recorded-writes))))))

(ert-deftest cc-butler-north-star/namespaced-p-rejects-generic-basename ()
  "The generic, un-overridden basename \"north-star.org\" must read as
not-namespaced regardless of directory — that basename colliding across
fleets sharing the governance directory is exactly the bug this guards
against."
  (should (null (let ((cc-butler-north-star-file "/tmp/wherever/north-star.org"))
                  (cc-butler--north-star-file-namespaced-p))))
  (should (null (let ((cc-butler-north-star-file "~/projects/cc-butler-governance/north-star.org"))
                  (cc-butler--north-star-file-namespaced-p)))))

(ert-deftest cc-butler-north-star/namespaced-p-accepts-fleet-specific-basename ()
  "A fleet-specific basename like the two already in production
(north-star-macbook-m1-max.org, north-star-x600.org) must read as
namespaced."
  (should (let ((cc-butler-north-star-file "/tmp/north-star-macbook-m1-max.org"))
            (cc-butler--north-star-file-namespaced-p))))

(ert-deftest cc-butler-north-star/fire-refuses-generic-basename-before-idle-check ()
  "Even when the butler is idle and every other fixture condition is
fine, an unnamespaced `cc-butler-north-star-file' must block the send —
this proves the new guard is checked FIRST, ahead of the existing
idle/liveness `when-let*' chain, not layered on after it."
  (cc-butler-north-star-test--with-stub-terminal
    (let ((cc-butler-north-star-file "/tmp/wherever/north-star.org"))
      (should (null (cc-butler--north-star-fire)))
      (should (null (cc-butler-north-star-test--recorded-writes))))))

(ert-deftest cc-butler-north-star/ensure-timer-refuses-to-arm-generic-basename ()
  "A misconfigured fleet must not even get a permanently-no-op timer
sitting in `timer-list' — better to have no timer at all than one that
looks armed but can never fire anything useful."
  (let ((cc-butler-north-star-file "/tmp/wherever/north-star.org")
        (cc-butler--north-star-timer nil))
    (cc-butler--north-star-ensure-timer)
    (should (null cc-butler--north-star-timer))))

(ert-deftest cc-butler-north-star/check-command-reports-when-blocked-by-generic-basename ()
  "`cc-butler-north-star-check' must not error and must still report via
`message' when blocked by the new guard, same as any other reason the
manual command can't send — the human asking explicitly still deserves
an answer."
  (cc-butler-north-star-test--with-stub-terminal
    (let ((cc-butler-north-star-file "/tmp/wherever/north-star.org")
          msg)
      (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (setq msg (apply #'format fmt args)))))
        (cc-butler-north-star-check))
      (should (string-match-p "skipped" msg))
      (should (null (cc-butler-north-star-test--recorded-writes))))))

(provide 'cc-butler-north-star-test)
;;; cc-butler-north-star-test.el ends here
