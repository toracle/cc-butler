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

;;;; ------------------------------------------------------------------
;;;; Delta gate: unconditional-resend bug (2026-08-27) and its fix
;;;; ------------------------------------------------------------------

(defmacro cc-butler-north-star-test--with-file (content &rest body)
  "Run BODY with a live idle stub terminal (see
`cc-butler-north-star-test--with-stub-terminal') AND
`cc-butler-north-star-file' bound to a fresh temp file holding CONTENT
\(or, when CONTENT is `:absent', to a path that does not exist\)."
  (declare (indent 1))
  `(cc-butler-north-star-test--with-stub-terminal
     (let* ((cc-butler--north-star-last-sent-hash nil)
            (path (make-temp-file "cc-butler-north-star-test-"))
            (content ,content))
       (unwind-protect
           (progn
             (if (eq content :absent)
                 (delete-file path)
               (with-temp-file path (insert content)))
             (let ((cc-butler-north-star-file path))
               ,@body))
         (when (file-exists-p path) (delete-file path))))))

(ert-deftest cc-butler-north-star/fire-skips-second-tick-with-no-content-delta ()
  "THE BUG (2026-08-27): two ticks in a row with an UNCHANGED north-star
file must not both send — the first tick establishes a baseline, the
second must be gated out since nothing changed. Prior to the delta gate
this failed: `cc-butler--north-star-fire' sent on every idle tick
regardless of content, burning channel/context for nothing."
  (cc-butler-north-star-test--with-file "* goal one\n  :DOD: foo\n"
    (cc-butler--north-star-fire)
    (let ((writes-after-first (length (cc-butler-north-star-test--recorded-writes))))
      (should (> writes-after-first 0))
      (cc-butler--north-star-fire)
      (should (= writes-after-first (length (cc-butler-north-star-test--recorded-writes)))))))

(ert-deftest cc-butler-north-star/fire-sends-again-when-content-genuinely-changes ()
  "The reverse of the delta-gate test above, and the more important
direction per the task owner: a fix that swallows real content changes
along with the no-op case would be WORSE than the bug it fixes. Two
ticks with genuinely DIFFERENT content between them must both send."
  (cc-butler-north-star-test--with-file "* goal one\n  :DOD: foo\n"
    (cc-butler--north-star-fire)
    (let ((writes-after-first (length (cc-butler-north-star-test--recorded-writes))))
      (should (> writes-after-first 0))
      (with-temp-file cc-butler-north-star-file
        (insert "* goal one\n  :DOD: foo\n* goal two\n  :DOD: bar\n"))
      (cc-butler--north-star-fire)
      (should (> (length (cc-butler-north-star-test--recorded-writes)) writes-after-first)))))

(ert-deftest cc-butler-north-star/skipped-tick-does-not-record-hash ()
  "A tick skipped by the IDLE gate must not update the recorded hash — the
same pending content must still be considered unsent on the next tick
\(requirement: record only on successful send\)."
  (cc-butler-north-star-test--with-file "* goal one\n  :DOD: foo\n"
    ;; Busy on the first tick: skipped by the idle gate, nothing recorded.
    (cl-letf (((symbol-function 'cc-butler--session-last-activity)
               (lambda (_d) (float-time))))
      (cc-butler--north-star-fire)
      (should (null (cc-butler-north-star-test--recorded-writes))))
    ;; Idle again (default): the still-pending content must now go out.
    (cc-butler--north-star-fire)
    (should (cl-some (lambda (w) (eq (car w) :string))
                     (cc-butler-north-star-test--recorded-writes)))))

(ert-deftest cc-butler-north-star/missing-file-always-fires-unchanged-behavior ()
  "File-absent-on-first-run nudge behavior is intentional and unchanged by
the delta gate: with no file to hash, every idle tick still fires (the
delta gate does not apply — there is nothing to diff against, and the
butler needs the repeated nudge to go create the file)."
  (cc-butler-north-star-test--with-file :absent
    (cc-butler--north-star-fire)
    (cc-butler--north-star-fire)
    (should (= 2 (cl-count :return (cc-butler-north-star-test--recorded-writes)
                            :key #'car)))))

(ert-deftest cc-butler-north-star/check-command-bypasses-delta-gate ()
  "The manual `cc-butler-north-star-check' command must bypass the delta
gate (a human explicitly asking always gets an answer) while still
respecting the idle gate."
  (cc-butler-north-star-test--with-file "* goal one\n  :DOD: foo\n"
    (cc-butler--north-star-fire) ; establish a baseline via the timer path
    (let ((writes-after-first (length (cc-butler-north-star-test--recorded-writes))))
      (should (> writes-after-first 0))
      ;; Unchanged content — the automatic path would now skip.
      (cc-butler-north-star-check)
      (should (> (length (cc-butler-north-star-test--recorded-writes)) writes-after-first)))))

(ert-deftest cc-butler-north-star/automatic-path-stays-silent-when-delta-gated ()
  "The delta gate applies only to the AUTOMATIC (timer) path, and — like
the pre-existing idle gate on that same path — is a silent no-op there,
not a `message'. `cc-butler-north-star-check' bypasses the delta gate
entirely (requirement: a human asking explicitly always gets an answer),
so a delta-caused skip can only ever happen on the silent timer path."
  (cc-butler-north-star-test--with-file "* goal one\n  :DOD: foo\n"
    (cc-butler--north-star-fire) ; establish a baseline, idle butler
    (let (msg)
      (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (setq msg (apply #'format fmt args)))))
        (cc-butler--north-star-fire)) ; unchanged content, timer path: gated, silent
      (should (null msg)))))

(ert-deftest cc-butler-north-star/check-command-distinguishes-busy-from-no-terminal ()
  "The manual command's skip message must say WHICH gate held it back:
a busy (idle-gate) skip reads differently from a structurally-unavailable
\(no butler designated / terminal not live\) skip."
  (cc-butler-north-star-test--with-file "* goal one\n  :DOD: foo\n"
    (let (busy-msg no-terminal-msg)
      (cl-letf (((symbol-function 'cc-butler--session-last-activity)
                 (lambda (_d) (float-time)))) ; busy
        (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (setq busy-msg (apply #'format fmt args)))))
          (cc-butler-north-star-check)))
      (cl-letf (((symbol-function 'claude-code-ide--get-buffer-name)
                 (lambda (_d) "a buffer name nothing owns")))
        (cl-letf (((symbol-function 'message) (lambda (fmt &rest args) (setq no-terminal-msg (apply #'format fmt args)))))
          (cc-butler-north-star-check)))
      (should busy-msg)
      (should no-terminal-msg)
      (should-not (equal busy-msg no-terminal-msg)))))

(provide 'cc-butler-north-star-test)
;;; cc-butler-north-star-test.el ends here
