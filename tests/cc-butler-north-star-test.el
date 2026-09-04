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

(ert-deftest cc-butler-north-star/prompt-does-not-instruct-creating-missing-file ()
  "The old wording told the butler to fabricate the file from the template
on a missing path. `cc-butler-governance-dir' is now a store shared across
multiple fleets (e.g. north-star-x600.org and north-star-macbook-m1-max.org
side by side), so a missing file almost always means the path is wrong, not
that goals were never started — creating one there risks discarding or
colliding with another fleet's real goals. That create instruction must be
gone from the prompt."
  (should-not (string-match-p (regexp-quote "새로 만들되")
                              (cc-butler--north-star-prompt))))

(ert-deftest cc-butler-north-star/prompt-instructs-stop-and-escalate-on-missing-file ()
  "In place of creating the file, the prompt must tell the butler to stop
and escalate to 정수님 via `escalate_to_butler' when the file cannot be
found, since a missing file most likely means a misresolved path rather
than an empty goal list."
  (let ((prompt (cc-butler--north-star-prompt)))
    (should (string-match-p (regexp-quote "새로 만들지 말고 즉시 멈출 것") prompt))
    (should (string-match-p (regexp-quote "escalate_to_butler로 정수님/steward에게 경로가") prompt))))

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
;;;; No content gate: every idle tick fires, unconditionally
;;;; ------------------------------------------------------------------
;;;; A delta gate here (2026-08-27 through #139's predecessor) skipped an
;;;; hourly tick whenever the file's hash matched the last SENT one. That
;;;; violated 정수님's own instruction ("매 1시간 스스로 물어라" -- self-check
;;;; every hour, period) and, per `a-change-detector-fails-two-ways-and-
;;;; you-usually-only-test-one', made the check insensitive to exactly the
;;;; kind of progress that never touches this file. Removed outright
;;;; (2026-09-04) rather than extended with more detectors -- see
;;;; `cc-butler--north-star-fire''s docstring.

(defmacro cc-butler-north-star-test--with-file (content &rest body)
  "Run BODY with a live idle stub terminal (see
`cc-butler-north-star-test--with-stub-terminal') AND
`cc-butler-north-star-file' bound to a fresh temp file holding CONTENT
\(or, when CONTENT is `:absent', to a path that does not exist\)."
  (declare (indent 1))
  `(cc-butler-north-star-test--with-stub-terminal
     (let* ((path (make-temp-file "cc-butler-north-star-test-"))
            (content ,content))
       (unwind-protect
           (progn
             (if (eq content :absent)
                 (delete-file path)
               (with-temp-file path (insert content)))
             (let ((cc-butler-north-star-file path))
               ,@body))
         (when (file-exists-p path) (delete-file path))))))

(ert-deftest cc-butler-north-star/fire-sends-on-every-idle-tick-even-with-unchanged-content ()
  "THE ACCEPTANCE CONDITION for removing the delta gate (2026-09-04): two
ticks in a row on the AUTOMATIC path (`cc-butler--north-star-fire', no
force argument -- what the hourly timer itself calls) with an UNCHANGED
north-star file must BOTH send. Before this change the second tick
returned `skipped-delta' and sent nothing -- 정수님's own instruction is
to self-check every hour, period; an unchanged file is not evidence
nothing worth checking happened, since this file records intent, not
progress."
  (cc-butler-north-star-test--with-file "* goal one\n  :DOD: foo\n"
    (should (eq 'sent (cc-butler--north-star-fire)))
    (should (eq 'sent (cc-butler--north-star-fire)))
    (should (= 2 (cl-count :return (cc-butler-north-star-test--recorded-writes)
                            :key #'car)))))

(ert-deftest cc-butler-north-star/fire-sends-again-when-content-genuinely-changes ()
  "Kept deliberately (not a delta-gate leftover): guards a DIFFERENT
failure than the one above -- a future change that overcorrects and
starts swallowing or debouncing genuinely new content, not just
unchanged content. Two ticks with different content between them must
both send; true with no content gate at all, and stays true if one is
ever reintroduced correctly."
  (cc-butler-north-star-test--with-file "* goal one\n  :DOD: foo\n"
    (cc-butler--north-star-fire)
    (let ((writes-after-first (length (cc-butler-north-star-test--recorded-writes))))
      (should (> writes-after-first 0))
      (with-temp-file cc-butler-north-star-file
        (insert "* goal one\n  :DOD: foo\n* goal two\n  :DOD: bar\n"))
      (cc-butler--north-star-fire)
      (should (> (length (cc-butler-north-star-test--recorded-writes)) writes-after-first)))))

(ert-deftest cc-butler-north-star/missing-file-always-fires ()
  "File-absent-on-first-run nudge behavior: with no file at all, every
idle tick still fires -- the butler needs the repeated nudge to go
investigate (see the prompt's stop-and-escalate instruction)."
  (cc-butler-north-star-test--with-file :absent
    (cc-butler--north-star-fire)
    (cc-butler--north-star-fire)
    (should (= 2 (cl-count :return (cc-butler-north-star-test--recorded-writes)
                            :key #'car)))))

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
      (should (eq 'skipped-unnamespaced (cc-butler--north-star-fire)))
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
