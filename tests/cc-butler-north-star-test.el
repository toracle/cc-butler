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
  "A butler mid-turn must not be typed into — a 2-hour housekeeping ping
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

(ert-deftest cc-butler-north-star/fire-noop-when-terminal-not-live ()
  "The butler dir is set but its terminal buffer is gone (session ended,
Emacs just restarted) — must not error, just skip."
  (cc-butler-north-star-test--with-stub-terminal
    (cl-letf (((symbol-function 'claude-code-ide--get-buffer-name)
               (lambda (_d) "a buffer name nothing owns")))
      (should (null (cc-butler--north-star-fire)))
      (should (null (cc-butler-north-star-test--recorded-writes))))))

(provide 'cc-butler-north-star-test)
;;; cc-butler-north-star-test.el ends here
