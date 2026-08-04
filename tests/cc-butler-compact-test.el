;;; cc-butler-compact-test.el --- tests for the compaction driver  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jeongsoo Park
;; SPDX-License-Identifier: MIT

;; Run alone:
;;   emacs -Q --batch -L . -l ert -l tests/cc-butler-compact-test.el \
;;         -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'cl-lib)
(require 'cc-butler-compact)

;;;; ------------------------------------------------------------------
;;;; Fixtures: canned terminal screens
;;;; ------------------------------------------------------------------

(defconst cc-butler-compact-test--idle-screen
  (string-join
   '("✻ Brewed for 3m 25s"
     ""
     "──────────────────────────────────────────────"
     "❯ "
     "──────────────────────────────────────────────"
     "  CTX:203356 20% >200k MODEL:Opus-4.8"
     "  ⏵⏵ auto mode on (shift+tab to cycle)")
   "\n")
  "An idle session sitting at an empty input box.")

(defconst cc-butler-compact-test--typed-screen
  (string-join
   '("──────────────────────────────────────────────"
     "❯ 모델 카탈로그에 sonnet-5 있는지 확인해줘"
     "──────────────────────────────────────────────"
     "  CTX:203356 20% >200k MODEL:Opus-4.8")
   "\n")
  "A session with text sitting unsubmitted in the input box.")

(defconst cc-butler-compact-test--modal-screen
  (string-join
   '("Switch model?"
     "Switching models will clear your prompt cache."
     ""
     "❯ 1. Yes, switch and clear the cache"
     "  2. No, keep the current model"
     ""
     "──────────────────────────────────────────────"
     "❯ "
     "──────────────────────────────────────────────")
   "\n")
  "The prompt-cache confirmation raised by /model.")

;;;; ------------------------------------------------------------------
;;;; Screen reading
;;;; ------------------------------------------------------------------

(ert-deftest cc-butler-compact/menu-detected-by-structure-not-wording ()
  "An open numbered menu is recognized from its 1./2. option rows, so the
detector survives re-worded (and non-English) dialogs; an ordinary screen is
not mistaken for one."
  (should (cc-butler-compact--menu-p cc-butler-compact-test--modal-screen))
  (should-not (cc-butler-compact--menu-p cc-butler-compact-test--idle-screen))
  (should-not (cc-butler-compact--menu-p cc-butler-compact-test--typed-screen))
  ;; Wording swapped out entirely — still detected.
  (should (cc-butler-compact--menu-p
           "무엇을 할까요?\n❯ 1. 예, 전환합니다\n  2. 아니오"))
  ;; Prose containing digits is not a menu.
  (should-not (cc-butler-compact--menu-p "step 1. do it\nthen finish")))

(ert-deftest cc-butler-compact/input-line-distinguishes-empty-from-typed ()
  "The text between the input-box rules is extracted with the prompt stripped;
an empty box reads as nil so an idle session is not refused."
  (should-not (cc-butler-compact--input-line cc-butler-compact-test--idle-screen))
  (should (equal (cc-butler-compact--input-line cc-butler-compact-test--typed-screen)
                 "모델 카탈로그에 sonnet-5 있는지 확인해줘"))
  (should-not (cc-butler-compact--input-line "no box here at all")))

(ert-deftest cc-butler-compact/input-line-takes-the-last-box ()
  "Scrollback holds older input boxes; the live one is the last."
  (should (equal (cc-butler-compact--input-line
                  (string-join '("─────" "❯ old prompt" "─────"
                                 "some output"
                                 "─────" "❯ current" "─────")
                               "\n"))
                 "current")))

(ert-deftest cc-butler-compact/nbsp-padded-empty-box-reads-as-empty ()
  "REGRESSION (live, 2026-07-22): Claude Code pads the prompt glyph with
U+00A0, which `string-trim' does not strip — so an empty input box trimmed
to a one-character string and EVERY idle session in the fleet was refused as
\"has unsubmitted text\"."
  (let ((nbsp-box (string-join '("─────" "❯ " "─────") "\n")))
    (should-not (cc-butler-compact--input-line nbsp-box)))
  (should (equal (cc-butler-compact--strip "❯ hello ") "hello"))
  (should (equal (cc-butler-compact--strip "❯ ") "")))

;;;; ------------------------------------------------------------------
;;;; Ghost suggestion vs real typed input, decided by the TERMINAL CURSOR
;;;; ------------------------------------------------------------------

(defmacro cc-butler-compact-test--with-screen (screen cursor-needle &rest body)
  "Run BODY with a fake terminal buffer showing SCREEN.
The terminal cursor is placed at the END of the first match of
CURSOR-NEEDLE, or at `point-max' when CURSOR-NEEDLE is nil."
  (declare (indent 2))
  `(let ((buf (generate-new-buffer " *cc-compact-screen*")))
     (unwind-protect
         (with-current-buffer buf
           (insert ,screen)
           (let ((cursor (if ,cursor-needle
                             (progn (goto-char (point-min))
                                    (search-forward ,cursor-needle) (point))
                           (point-max))))
             (cl-letf (((symbol-function 'ghostel-cursor-point) (lambda () cursor))
                       ((symbol-function 'cc-butler--refresh-terminal-text) (lambda (_b) t))
                       ((symbol-function 'claude-code-ide--get-buffer-name)
                        (lambda (_d) (buffer-name buf))))
               ,@body)))
       (kill-buffer buf))))

(ert-deftest cc-butler-compact/ghost-suggestion-is-not-pending-input ()
  "THE regression this guard exists for (live, 2026-07-23).  Claude Code
paints a dimmed suggestion into an EMPTY box; the cursor stays at the
prompt because the input buffer really is empty.  Reading the painted row
refused every session in the fleet — including the butler, the one session
the feature exists for."
  (cc-butler-compact-test--with-screen
      (string-join '("─────────────────────────"
                     "❯ 모델 카탈로그에 sonnet-5 있는지 확인해줘"
                     "─────────────────────────"
                     "  CTX:203356 MODEL:Opus-4.8")
                   "\n")
      "❯ "                              ; cursor parked right after the prompt
    (should-not (cc-butler-compact--typed-text "d"))
    (should-not (cc-butler-compact--pending-input-p "d"))))

(ert-deftest cc-butler-compact/real-typed-input-is-detected ()
  "The other half: text the operator actually typed advances the cursor past
the prompt, and must still block."
  (cc-butler-compact-test--with-screen
      (string-join '("─────────────────────────"
                     "❯ abcd"
                     "─────────────────────────")
                   "\n")
      "❯ abcd"
    (should (equal (cc-butler-compact--typed-text "d") "abcd"))
    (should (cc-butler-compact--pending-input-p "d"))))

(ert-deftest cc-butler-compact/a-typed-slash-command-still-blocks ()
  "A half-typed slash command is the most dangerous pending input there is —
our own command would be appended to it.  It must block even though Claude
Code renders it in an accent FACE, which an earlier face-based rule read as
`decorated, therefore ghost'."
  (cc-butler-compact-test--with-screen
      (string-join '("─────────────────────────"
                     "❯ /clear"
                     "─────────────────────────")
                   "\n")
      "❯ /clear"
    (should (equal (cc-butler-compact--typed-text "d") "/clear"))))

(ert-deftest cc-butler-compact/empty-box-is-empty ()
  "An empty box — prompt plus NBSP padding, cursor at the prompt — is not
pending input."
  (cc-butler-compact-test--with-screen
      (string-join '("─────────────────────────" "❯ " "─────────────────────────") "\n")
      "❯ "
    (should-not (cc-butler-compact--typed-text "d"))))

(ert-deftest cc-butler-compact/multi-line-input-is-seen-whole ()
  "A multi-line box must report everything ahead of the cursor, not just the
cursor's own row — otherwise a second line looks empty and we type into it."
  (cc-butler-compact-test--with-screen
      (string-join '("─────────────────────────"
                     "❯ first line"
                     "  second line"
                     "─────────────────────────")
                   "\n")
      "second line"
    (let ((typed (cc-butler-compact--typed-text "d")))
      (should typed)
      (should (string-match-p "first line" typed))
      (should (string-match-p "second line" typed)))))

(ert-deftest cc-butler-compact/cursor-outside-a-box-falls-back-to-the-screen ()
  "If the cursor is not inside an input box — a dialog owns the screen — we
must not conclude the box is empty.  Fail safe, back to the painted row."
  (let ((screen (string-join '("❯ 1. yes" "  2. no" "─────" "❯ leftover" "─────") "\n")))
    (cc-butler-compact-test--with-screen screen "1. yes"
      (cl-letf (((symbol-function 'cc-butler--read-output) (lambda (&rest _) screen)))
        (should (equal (cc-butler-compact--typed-text "d") "leftover"))))))

(ert-deftest cc-butler-compact/no-cursor-backend-falls-back-to-the-screen ()
  "On a terminal backend with no readable cursor, degrade to the old painted
row check rather than assuming empty."
  (let ((screen (string-join '("─────" "❯ something" "─────") "\n")))
    (cl-letf (((symbol-function 'cc-butler--refresh-terminal-text) (lambda (_b) t))
              ((symbol-function 'cc-butler--read-output) (lambda (&rest _) screen))
              ((symbol-function 'claude-code-ide--get-buffer-name)
               (lambda (_d) (buffer-name (current-buffer)))))
      (with-temp-buffer
        (fmakunbound 'ghostel-cursor-point)
        (should (equal (cc-butler-compact--typed-text "d") "something"))))))

(ert-deftest cc-butler-compact/unknown-cursor-is-treated-as-real-input ()
  "FAIL-SAFE DIRECTION, compaction guard — the deliberate OPPOSITE of
`cc-butler-orchestrator/redaction-unknown-cursor-redacts-and-says-so'.
Both call sites ask `cc-butler--input-state' the same question and get the
same UNKNOWN back; this one resolves it toward REAL INPUT and refuses to
compact, because typing over a sentence a human is composing corrupts their
input and submits something neither of us wrote, while a skipped compaction
costs one sweep.  The read side resolves it the other way, because showing a
suggestion as real input is how it becomes a false instruction.  That is why
the shared predicate reports three outcomes instead of a boolean."
  (let ((screen (string-join '("─────" "❯ half-typed sentence" "─────") "\n")))
    (cl-letf (((symbol-function 'cc-butler--refresh-terminal-text) (lambda (_b) t))
              ((symbol-function 'cc-butler--read-output) (lambda (&rest _) screen))
              ((symbol-function 'claude-code-ide--get-buffer-name)
               (lambda (_d) (buffer-name (current-buffer))))
              ((symbol-function 'ghostel-cursor-point) (lambda () nil)))
      (with-temp-buffer
        (insert screen)
        (should (equal (cc-butler-compact--typed-text "d") "half-typed sentence"))
        (should (cc-butler-compact--pending-input-p "d"))))))

(ert-deftest cc-butler-compact/prose-numbered-lists-are-not-menus ()
  "REGRESSION (live, 2026-07-22): reading 40 lines pulls in scrollback, and
Claude writes numbered lists constantly.  Without the selection caret, a
transcript full of `1.'/`2.' rows read as an open dialog and blocked every
session.  A real menu always marks the highlighted option."
  (should-not (cc-butler-compact--menu-p
               "여기 옵션들:\n1. 첫번째 방법\n2. 두번째 방법\n계속할까요"))
  (should-not (cc-butler-compact--menu-p
               "Plan:\n  1. read the file\n  2. edit it\n  3. run tests"))
  ;; The caret makes it a live dialog.
  (should (cc-butler-compact--menu-p
           "Plan:\n❯ 1. read the file\n  2. edit it")))

(ert-deftest cc-butler-compact/menu-detection-ignores-scrollback ()
  "Only the bottom of the screen is a live dialog; an old menu scrolled far
up is history, not something waiting on a keypress."
  (let ((old (concat "❯ 1. an old answered menu\n  2. the other option\n"
                     (mapconcat #'identity (make-list 40 "output line") "\n")
                     "\n─────\n❯ \n─────")))
    (should-not (cc-butler-compact--menu-p old))))

;;;; ------------------------------------------------------------------
;;;; Model naming
;;;; ------------------------------------------------------------------

(ert-deftest cc-butler-compact/model-arg-maps-display-name-to-alias ()
  "A statusline MODEL: tag is a display name, not a /model argument; it must
be mapped back to the family alias before it can restore anything."
  (should (equal (cc-butler-compact--model-arg "Opus-4.8") "claude-opus-4-8"))
  (should (equal (cc-butler-compact--model-arg "Sonnet-5") "claude-sonnet-5"))
  (should (equal (cc-butler-compact--model-arg "claude-haiku-4-5") "claude-haiku-4-5")))

(ert-deftest cc-butler-compact/unnameable-model-yields-nil ()
  "An unrecognized model returns nil so the caller refuses to switch at all —
better an uncompacted session than one stranded on the wrong model."
  (should-not (cc-butler-compact--model-arg "?"))
  (should-not (cc-butler-compact--model-arg nil))
  (should-not (cc-butler-compact--model-arg "Some-Future-Model")))

(ert-deftest cc-butler-compact/model-is-p-compares-case-insensitively ()
  "The switch is confirmed by matching the statusline tag against the /model
argument that was sent."
  (should (cc-butler-compact--model-is-p "Sonnet-5" "sonnet"))
  (should (cc-butler-compact--model-is-p "Opus-4.8" "opus"))
  (should-not (cc-butler-compact--model-is-p "Opus-4.8" "sonnet"))
  (should-not (cc-butler-compact--model-is-p nil "sonnet")))

;;;; ------------------------------------------------------------------
;;;; The state machine, driven by hand
;;;; ------------------------------------------------------------------

(defvar cc-butler-compact-test--sent nil)
(defvar cc-butler-compact-test--screen "")
(defvar cc-butler-compact-test--model "Opus-4.8")
(defvar cc-butler-compact-test--ctx 400000)

(defmacro cc-butler-compact-test--with-session (dir &rest body)
  "Run BODY with DIR presented as an idle, live, compactable session."
  (declare (indent 1))
  `(let ((cc-butler-compact--inhibit-timers t)
         (cc-butler-compact--state (make-hash-table :test 'equal))
         (cc-butler-compact--pending (make-hash-table :test 'equal))
         (cc-butler-compact-test--sent nil)
         (cc-butler-compact-test--screen cc-butler-compact-test--idle-screen)
         (cc-butler-compact-test--model "Opus-4.8")
         (cc-butler-compact-test--ctx 400000))
     (cl-letf (((symbol-function 'cc-butler--display-name) (lambda (d) d))
               ((symbol-function 'cc-butler--waiting-p) (lambda (_d) (float-time)))
               ;; idle by transcript activity: newest write is ancient, so the
               ;; real `cc-butler--transcript-idle-p' reports idle without any
               ;; filesystem access.  Busy tests override this to a fresh time.
               ((symbol-function 'cc-butler--session-last-activity)
                (lambda (_d) (- (float-time) 100000)))
               ((symbol-function 'cc-butler--log) #'ignore)
               ((symbol-function 'cc-butler--maybe-refresh) #'ignore)
               ((symbol-function 'claude-code-ide--get-buffer-name)
                (lambda (_d) "*cc-butler-compact-test*"))
               ((symbol-function 'cc-butler--read-output)
                (lambda (_d &optional _n) cc-butler-compact-test--screen))
               ((symbol-function 'cc-butler-compact--pending-input-p)
                (lambda (d) (and (cc-butler-compact--input-line
                                  (cc-butler--read-output d 40))
                                 t)))
               ((symbol-function 'cc-butler-compact--model-now)
                (lambda (_d) cc-butler-compact-test--model))
               ((symbol-function 'cc-butler-compact--context-now)
                (lambda (_d) cc-butler-compact-test--ctx))
               ((symbol-function 'cc-butler-cleanup-context-for)
                (lambda (_d) cc-butler-compact-test--ctx))
               ((symbol-function 'cc-butler--send-input)
                (lambda (_d text &optional _s)
                  (push text cc-butler-compact-test--sent) t)))
       (get-buffer-create "*cc-butler-compact-test*")
       ,@body)))

(defun cc-butler-compact-test--sent-in-order ()
  "Everything sent so far, oldest first."
  (reverse cc-butler-compact-test--sent))

(ert-deftest cc-butler-compact/full-flow-switch-modal-compact-restore ()
  "The whole dance: /model sonnet, answer the modal, /compact, and put the
original model back — four separate submissions, each gated on an observed
state change rather than on elapsed time."
  (cc-butler-compact-test--with-session "w"
    (cc-butler-compact-session "w")
    (should (equal (cc-butler-compact-test--sent-in-order) '("/model sonnet")))
    ;; The confirmation modal comes up.
    (setq cc-butler-compact-test--screen cc-butler-compact-test--modal-screen)
    (cc-butler-compact--poll "w")
    (should (equal (cc-butler-compact-test--sent-in-order)
                   '("/model sonnet" "1")))
    ;; A second tick while the modal is still rendering must NOT answer twice:
    ;; the screen is a frame, and the modal may already be gone.
    (cc-butler-compact--poll "w")
    (should (equal (cc-butler-compact-test--sent-in-order)
                   '("/model sonnet" "1")))
    ;; The switch lands.
    (setq cc-butler-compact-test--model "Sonnet-5"
          cc-butler-compact-test--screen cc-butler-compact-test--idle-screen)
    (cc-butler-compact--poll "w")
    (should (equal (cc-butler-compact-test--sent-in-order)
                   '("/model sonnet" "1" "/compact")))
    ;; Context has not dropped yet — keep waiting, send nothing.
    (cc-butler-compact--poll "w")
    (should (equal (length cc-butler-compact-test--sent) 3))
    ;; Context drops: compaction happened.
    (setq cc-butler-compact-test--ctx 90000)
    (cc-butler-compact--poll "w")
    (should (equal (cc-butler-compact-test--sent-in-order)
                   '("/model sonnet" "1" "/compact" "/model claude-opus-4-8")))
    ;; Original model returns; the machine finishes and releases the lock.
    (setq cc-butler-compact-test--model "Opus-4.8")
    (cc-butler-compact--poll "w")
    (should-not (cc-butler-compact--active-p "w"))))

(ert-deftest cc-butler-compact/flow-without-modal ()
  "When /model switches with no confirmation, the driver proceeds straight to
/compact — the modal is optional, not assumed."
  (cc-butler-compact-test--with-session "w"
    (cc-butler-compact-session "w")
    (setq cc-butler-compact-test--model "Sonnet-5")
    (cc-butler-compact--poll "w")
    (should (equal (cc-butler-compact-test--sent-in-order)
                   '("/model sonnet" "/compact")))))

(ert-deftest cc-butler-compact/already-on-target-model-skips-switch ()
  "A session already on the compaction model is neither switched nor
restored — it just compacts."
  (cc-butler-compact-test--with-session "w"
    (setq cc-butler-compact-test--model "Sonnet-5")
    (cc-butler-compact-session "w")
    (should (equal (cc-butler-compact-test--sent-in-order) '("/compact")))
    (setq cc-butler-compact-test--ctx 90000)
    (cc-butler-compact--poll "w")
    (should (equal (cc-butler-compact-test--sent-in-order) '("/compact")))
    (should-not (cc-butler-compact--active-p "w"))))

(ert-deftest cc-butler-compact/model-restored-even-when-compaction-times-out ()
  "A compaction that never visibly finishes still gets the model put back —
the restore is unconditional, because a session left on the cheap model is a
silent downgrade nobody notices."
  (cc-butler-compact-test--with-session "w"
    (cc-butler-compact-session "w")
    (setq cc-butler-compact-test--model "Sonnet-5")
    (cc-butler-compact--poll "w")            ; -> /compact
    ;; Pretend the compact was sent long ago and context never moved.
    (cc-butler-compact--set-state
     "w" :sent-time (- (float-time) (1+ cc-butler-compact-timeout)))
    (cc-butler-compact--poll "w")
    (should (equal (car cc-butler-compact-test--sent) "/model claude-opus-4-8"))))

(ert-deftest cc-butler-compact/switch-timeout-with-model-unchanged-just-aborts ()
  "A switch that never happened needs no restore: the session is still on its
original model, so /compact is never sent and nothing further is typed."
  (cc-butler-compact-test--with-session "w"
    (cc-butler-compact-session "w")
    (cc-butler-compact--set-state
     "w" :sent-time (- (float-time) (1+ cc-butler-compact-step-timeout)))
    (let ((msg (cc-butler-compact--poll "w")))
      (should (string-match-p "timed out" msg)))
    (should (equal (cc-butler-compact-test--sent-in-order) '("/model sonnet")))
    (should-not (cc-butler-compact--active-p "w"))))

(ert-deftest cc-butler-compact/switch-timeout-with-model-changed-still-restores ()
  "If the switch landed but was not observed in time, the abort path must
still put the original model back — a half-completed switch is exactly the
state that would otherwise strand a session on the cheap model."
  (cc-butler-compact-test--with-session "w"
    (cc-butler-compact-session "w")
    (setq cc-butler-compact-test--model "Sonnet-5")
    (cc-butler-compact--set-state
     "w" :sent-time (- (float-time) (1+ cc-butler-compact-step-timeout)))
    ;; The switch is visible to the abort path but was not seen before the
    ;; clock expired.
    (cl-letf* ((real (symbol-function 'cc-butler-compact--model-now))
               (first t)
               ((symbol-function 'cc-butler-compact--model-now)
                (lambda (d) (if first (progn (setq first nil) "Opus-4.8")
                              (funcall real d)))))
      (cc-butler-compact--poll "w"))
    (should (equal (cc-butler-compact-test--sent-in-order)
                   '("/model sonnet" "/model claude-opus-4-8")))))

(ert-deftest cc-butler-compact/restore-failure-is-reported-not-swallowed ()
  "If the model does not come back, the driver finishes with an explicit
failure naming both the actual and the wanted model."
  (cc-butler-compact-test--with-session "w"
    (cc-butler-compact-session "w")
    (setq cc-butler-compact-test--model "Sonnet-5")
    (cc-butler-compact--poll "w")            ; -> /compact
    (setq cc-butler-compact-test--ctx 90000)
    (cc-butler-compact--poll "w")            ; -> /model opus
    ;; the exact id times out -> falls back to the family rather than giving up
    (cc-butler-compact--set-state
     "w" :sent-time (- (float-time) (1+ cc-butler-compact-step-timeout)))
    (should (null (cc-butler-compact--poll "w")))
    (should (equal "opus" (plist-get (gethash "w" cc-butler-compact--state) :orig-arg)))
    ;; only once every candidate is spent is the failure reported
    (cc-butler-compact--set-state
     "w" :phase 'restoring
     :sent-time (- (float-time) (1+ cc-butler-compact-step-timeout)))
    (let ((msg (cc-butler-compact--poll "w")))
      (should (string-match-p "NOT restored" msg))
      (should (string-match-p "Sonnet-5" msg)))))

(ert-deftest cc-butler-compact/send-failure-on-the-initial-switch-releases-the-lock ()
  "A `cc-butler--send-input' failure (e.g. the 8s session-io-timeout firing on
a wedged terminal) while sending the very first `/model' switch must not
leave the compaction lock held forever with no timer left to ever revisit
it — cc-butler#18's investigation found exactly this: `--step' set the state
BEFORE the send, and an unguarded send that throws skips
`--schedule-poll' entirely, so the session was compactable-never-again until
a full Emacs restart.  The session must come back compactable, and the
failure must be visible in the log, not silently swallowed."
  (cc-butler-compact-test--with-session "w"
    (let (logged)
      (cl-letf (((symbol-function 'cc-butler--send-input)
                 (lambda (&rest _)
                   (error "Timed out sending input to session w after 8s")))
                ((symbol-function 'cc-butler--log)
                 (lambda (fmt &rest args) (push (apply #'format fmt args) logged))))
        (ignore-errors (cc-butler-compact-session "w")))
      (should-not (cc-butler-compact--active-p "w"))
      (should-not (cc-butler-compact--blocked-reason "w"))
      (should (cl-some (lambda (l) (string-match-p "send failed" l)) logged)))))

(ert-deftest cc-butler-compact/send-failure-answering-the-switch-modal-releases-the-lock ()
  "The same failure mode, one step later: the switch modal is on screen and
answering it (\"1\") is what throws.  This send is NOT routed through
`--step' — it is a second, inline `cc-butler--send-input' call inside
`--poll-switch' — so it needs its own guard, not just one at the top."
  (cc-butler-compact-test--with-session "w"
    (cc-butler-compact-session "w")
    (setq cc-butler-compact-test--screen cc-butler-compact-test--modal-screen)
    (let (logged)
      (cl-letf (((symbol-function 'cc-butler--send-input)
                 (lambda (&rest _)
                   (error "Timed out sending input to session w after 8s")))
                ((symbol-function 'cc-butler--log)
                 (lambda (fmt &rest args) (push (apply #'format fmt args) logged))))
        (ignore-errors (cc-butler-compact--poll "w")))
      (should-not (cc-butler-compact--active-p "w"))
      (should (cl-some (lambda (l) (string-match-p "send failed" l)) logged)))))

;;;; ------------------------------------------------------------------
;;;; Operator escape: cc-butler-compact-reset
;;;; ------------------------------------------------------------------

(ert-deftest cc-butler-compact/reset-clears-a-stuck-state-without-restarting-emacs ()
  "The last-resort escape: even a state this test cannot explain how it got
stuck (not just the two send-failure paths above) must be clearable without
a full Emacs restart."
  (cc-butler-compact-test--with-session "w"
    (cc-butler-compact--set-state "w" :phase 'switching :sent-time (float-time))
    (should (cc-butler-compact--active-p "w"))
    (should (cc-butler-compact-reset "w"))
    (should-not (cc-butler-compact--active-p "w"))
    (should-not (cc-butler-compact--blocked-reason "w"))))

(ert-deftest cc-butler-compact/reset-on-a-clean-session-is-a-noop ()
  "Resetting a session with nothing in flight does nothing and reports nil,
not an error."
  (cc-butler-compact-test--with-session "w"
    (should-not (cc-butler-compact-reset "w"))))

;;;; ------------------------------------------------------------------
;;;; Orphaned-state self-heal
;;;; ------------------------------------------------------------------

(ert-deftest cc-butler-compact/stale-timerless-idle-state-is-auto-reaped ()
  "A state entry with no live timer, old beyond `cc-butler-compact-state-max-age',
sitting on an idle buffer with no menu and nothing pending — the exact shape
a lost-timer send failure leaves behind — is treated as orphaned and
released the next time anything asks."
  (cc-butler-compact-test--with-session "w"
    (cc-butler-compact--set-state
     "w" :phase 'switching
     :sent-time (- (float-time) (1+ cc-butler-compact-state-max-age)))
    ;; No :timer key at all — exactly what a send failure before
    ;; `--schedule-poll' leaves behind.
    (should (cc-butler-compact--orphaned-p "w" (gethash "w" cc-butler-compact--state)))
    (should-not (cc-butler-compact--active-p "w"))))

(ert-deftest cc-butler-compact/genuinely-in-flight-compaction-is-never-reaped-by-age-alone ()
  "The critical negative case: a compaction that is actually still running —
a live timer scheduled — must NOT be reaped merely because it has been
running a long time.  Reaping this would double-fire the driver on a
session already mid-dance."
  (cc-butler-compact-test--with-session "w"
    (cc-butler-compact-session "w")
    ;; Old enough that the timerless heuristic alone would look orphaned...
    (cc-butler-compact--set-state
     "w" :sent-time (- (float-time) (1+ cc-butler-compact-state-max-age)))
    ;; ...but a poll is still scheduled and watching it (a real timer in
    ;; production; under `cc-butler-compact--inhibit-timers' its placeholder).
    (should (plist-get (gethash "w" cc-butler-compact--state) :timer))
    (should-not (cc-butler-compact--orphaned-p "w" (gethash "w" cc-butler-compact--state)))
    (should (cc-butler-compact--active-p "w"))))

(ert-deftest cc-butler-compact/stale-but-mid-menu-state-is-never-reaped ()
  "Old and timerless is not enough on its own either: if the buffer shows a
menu open (the driver may simply be slow to poll it, or — in production —
this state is exactly what the send-or-fail fix now prevents from
persisting) the buffer cross-check refuses to call it abandoned."
  (cc-butler-compact-test--with-session "w"
    (setq cc-butler-compact-test--screen cc-butler-compact-test--modal-screen)
    (cc-butler-compact--set-state
     "w" :phase 'switching
     :sent-time (- (float-time) (1+ cc-butler-compact-state-max-age)))
    (should-not (cc-butler-compact--orphaned-p "w" (gethash "w" cc-butler-compact--state)))
    (should (cc-butler-compact--active-p "w"))))

;;;; ------------------------------------------------------------------
;;;; The restore modal — the 2026-07-23 freeze
;;;; ------------------------------------------------------------------

;; Switching back to the original model raises the SAME confirmation modal as
;; switching away.  On 2026-07-23 a live compaction of this very session left
;; it parked on that modal for two and a half hours.  The restore phase did
;; have a modal branch, so the failure was never "no handling" — it was that
;; the modal arrived outside the window anything was watching.  These cover
;; the three separate defects that produced it.

(ert-deftest cc-butler-compact/restore-modal-is-answered ()
  "The confirmation modal on the way BACK is answered, exactly as the one on
the way out.  Both switches raise it; only one of them used to survive it."
  (cc-butler-compact-test--with-session "w"
    (cc-butler-compact-session "w")
    (setq cc-butler-compact-test--model "Sonnet-5")
    (cc-butler-compact--poll "w")            ; -> /compact
    (setq cc-butler-compact-test--ctx 90000)
    (cc-butler-compact--poll "w")            ; -> /model opus
    (should (equal (car cc-butler-compact-test--sent) "/model claude-opus-4-8"))
    ;; Restoring raises the modal too.
    (setq cc-butler-compact-test--screen cc-butler-compact-test--modal-screen)
    (cc-butler-compact--poll "w")
    (should (equal (cc-butler-compact-test--sent-in-order)
                   '("/model sonnet" "/compact" "/model claude-opus-4-8" "1")))
    ;; Answered, the switch lands and the machine finishes cleanly.
    (setq cc-butler-compact-test--model "Opus-4.8"
          cc-butler-compact-test--screen cc-butler-compact-test--idle-screen)
    (cc-butler-compact--poll "w")
    (should-not (cc-butler-compact--active-p "w"))))

(ert-deftest cc-butler-compact/restore-modal-is-retried-after-a-cooldown ()
  "One answer can land before the modal has finished rendering and select
nothing.  A latch would then never try again — which is how a session ends
up sitting on a dialog nobody answers.  Retry, but only after the cooldown,
so a stale frame cannot draw a stray answer onto the screen behind it."
  (cc-butler-compact-test--with-session "w"
    (cc-butler-compact-session "w")
    (setq cc-butler-compact-test--model "Sonnet-5")
    (cc-butler-compact--poll "w")
    (setq cc-butler-compact-test--ctx 90000)
    (cc-butler-compact--poll "w")            ; -> /model opus
    (setq cc-butler-compact-test--screen cc-butler-compact-test--modal-screen)
    (cc-butler-compact--poll "w")            ; answer #1
    (should (equal (car cc-butler-compact-test--sent) "1"))
    ;; Immediately after: no second answer, the frame may simply be stale.
    (cc-butler-compact--poll "w")
    (should (equal (length cc-butler-compact-test--sent) 4))
    ;; Cooldown elapses and the modal is still genuinely up: answer again.
    (cc-butler-compact--set-state
     "w" :answered-at (- (float-time) (1+ (cc-butler-compact--answer-cooldown))))
    (cc-butler-compact--poll "w")
    (should (equal (cc-butler-compact-test--sent-in-order)
                   '("/model sonnet" "/compact" "/model claude-opus-4-8" "1" "1")))))

(ert-deftest cc-butler-compact/restore-is-held-until-the-session-is-idle ()
  "REGRESSION (2026-07-23): the compact phase gave up watching while /compact
was STILL RUNNING and typed /model opus into a busy session.  The modal
appeared long after the restore step's own 90s clock had expired, so nothing
was polling by the time it came up.  The restore must not be typed at all
until the session is at a waiting point."
  (cc-butler-compact-test--with-session "w"
    (cc-butler-compact-session "w")
    (setq cc-butler-compact-test--model "Sonnet-5")
    (cc-butler-compact--poll "w")            ; -> /compact
    ;; /compact overruns its timeout and the session is still working.
    (cl-letf (((symbol-function 'cc-butler--waiting-p) (lambda (_d) nil)))
      (cc-butler-compact--set-state
       "w" :sent-time (- (float-time) (1+ cc-butler-compact-timeout)))
      (cc-butler-compact--poll "w")
      ;; Nothing typed: the restore is held, not fired into a busy session.
      (should (equal (cc-butler-compact-test--sent-in-order)
                     '("/model sonnet" "/compact")))
      (should (cc-butler-compact--active-p "w"))
      (cc-butler-compact--poll "w")
      (should (equal (length cc-butler-compact-test--sent) 2)))
    ;; The turn ends; now the restore goes out, inside a watched window.
    (cc-butler-compact--poll "w")
    (should (equal (cc-butler-compact-test--sent-in-order)
                   '("/model sonnet" "/compact" "/model claude-opus-4-8")))))

(ert-deftest cc-butler-compact/held-restore-still-gives-up-eventually ()
  "Holding for idle must not become its own way to hang: a session that never
reaches a waiting point ends the compaction with an explicit failure."
  (cc-butler-compact-test--with-session "w"
    (cc-butler-compact-session "w")
    (setq cc-butler-compact-test--model "Sonnet-5")
    (cc-butler-compact--poll "w")
    (cl-letf (((symbol-function 'cc-butler--waiting-p) (lambda (_d) nil)))
      (cc-butler-compact--set-state
       "w" :sent-time (- (float-time) (1+ cc-butler-compact-timeout)))
      (cc-butler-compact--poll "w")          ; -> held in restore-wait
      (cc-butler-compact--set-state
       "w" :sent-time (- (float-time) (1+ cc-butler-compact-timeout)))
      (let ((msg (cc-butler-compact--poll "w")))
        (should (string-match-p "NOT restored" msg))
        (should (string-match-p "waiting point" msg)))
      (should-not (cc-butler-compact--active-p "w")))))

(ert-deftest cc-butler-compact/never-walks-away-from-a-standing-modal ()
  "REGRESSION (2026-07-23): giving up is recoverable; abandoning a session
parked on a modal the driver itself opened is not — that session is stopped
dead until a human notices.  Every terminating path clears the screen first."
  (cc-butler-compact-test--with-session "w"
    (cc-butler-compact-session "w")
    (setq cc-butler-compact-test--model "Sonnet-5")
    (cc-butler-compact--poll "w")            ; -> /compact
    (setq cc-butler-compact-test--ctx 90000)
    (cc-butler-compact--poll "w")            ; -> /model opus
    ;; The restore times out with the modal still standing.
    (setq cc-butler-compact-test--screen cc-butler-compact-test--modal-screen)
    (cc-butler-compact--set-state
     "w" :answers cc-butler-compact-modal-answers  ; retries exhausted
     ;; last remaining candidate, so this timeout terminates rather than
     ;; falling back — the terminating path is what this test is about
     :orig-args '("claude-opus-4-8")
     :sent-time (- (float-time) (1+ cc-butler-compact-step-timeout)))
    (let ((msg (cc-butler-compact--poll "w")))
      (should (string-match-p "NOT restored" msg)))
    ;; It still cleared the dialog on the way out.
    (should (equal (car cc-butler-compact-test--sent) "1"))
    (should-not (cc-butler-compact--active-p "w"))))

;;;; ------------------------------------------------------------------
;;;; The restore that never submitted — the 2026-07-23 residual race
;;;; ------------------------------------------------------------------

;; Typing and submitting are two terminal writes with a gap between them.  A
;; worker notification arriving in that gap starts the session's turn, so the
;; Return lands on a session no longer sitting at its input box.  The command
;; stays typed but unsubmitted: the session is stranded on the cheap model,
;; and the stale text waits in the box to prepend itself to the next dispatch.
;; #15 fixed the modal; this is the send underneath it.

(defmacro cc-butler-compact-test--with-unsubmitted (text &rest body)
  "Run BODY with TEXT sitting unsubmitted in the session's input box."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'cc-butler-compact--typed-text)
              (lambda (_d) ,text))
             ((symbol-function 'cc-butler-compact--send-raw)
              (lambda (_d s) (push (concat "RAW:" s) cc-butler-compact-test--sent) t))
             ((symbol-function 'cc-butler-compact--send-return)
              (lambda (_d) (push "RETURN" cc-butler-compact-test--sent) t)))
     ,@body))

(defun cc-butler-compact-test--to-restore (dir)
  "Drive DIR to the point where /model opus has just been sent."
  (cc-butler-compact-session dir)
  (setq cc-butler-compact-test--model "Sonnet-5")
  (cc-butler-compact--poll dir)            ; -> /compact
  (setq cc-butler-compact-test--ctx 90000)
  (cc-butler-compact--poll dir))           ; -> /model opus

(ert-deftest cc-butler-compact/unsubmitted-restore-is-resent ()
  "REGRESSION (2026-07-23): the restore was typed but the Return was lost to a
notification, leaving the session on the cheap model with the command sitting
in its box.  Waiting cannot fix it — nothing is in flight — so it must be
sent again once the session is idle."
  (cc-butler-compact-test--with-session "w"
    (cc-butler-compact-test--to-restore "w")
    (should (equal (car cc-butler-compact-test--sent) "/model claude-opus-4-8"))
    (cc-butler-compact-test--with-unsubmitted "/model claude-opus-4-8"
      ;; Seen sitting there: back to waiting for idle rather than timing out.
      (cc-butler-compact--poll "w")
      (should (cc-butler-compact--active-p "w"))
      (should (equal (plist-get (gethash "w" cc-butler-compact--state) :phase)
                     'restore-wait))
      ;; Idle again — the text is already there, so only the Return is needed.
      (cc-butler-compact--poll "w")
      (should (equal (car cc-butler-compact-test--sent) "RETURN")))))

(ert-deftest cc-butler-compact/an-already-typed-restore-is-not-typed-twice ()
  "Retyping a command that is already in the box appends to it and produces
`/model opus/model opus'.  The text is right; only the Return was lost."
  (cc-butler-compact-test--with-session "w"
    (cc-butler-compact-test--to-restore "w")
    (cc-butler-compact-test--with-unsubmitted "/model claude-opus-4-8"
      (cc-butler-compact--poll "w")        ; -> restore-wait
      (cc-butler-compact--poll "w")        ; -> submit
      (should (= 1 (seq-count (lambda (s) (equal s "/model claude-opus-4-8"))
                              cc-butler-compact-test--sent)))
      (should (equal (cc-butler-compact-test--sent-in-order)
                     '("/model sonnet" "/compact" "/model claude-opus-4-8" "RETURN"))))))

(ert-deftest cc-butler-compact/unsubmitted-restore-retries-are-bounded ()
  "Re-sending is bounded in the same spirit as the modal retry: a send that
never takes must end as an explicit failure, not an endless loop."
  (cc-butler-compact-test--with-session "w"
    (cc-butler-compact-test--to-restore "w")
    (cc-butler-compact-test--with-unsubmitted "/model claude-opus-4-8"
      (let ((msg nil))
        (dotimes (_ (* 2 (1+ cc-butler-compact-restore-retries)))
          (when (cc-butler-compact--active-p "w")
            (setq msg (or (cc-butler-compact--poll "w") msg))))
        (should-not (cc-butler-compact--active-p "w"))
        (should (string-match-p "never submitted" msg))
        (should (string-match-p "NOT restored" msg))))))

(ert-deftest cc-butler-compact/self-left-text-is-cleared-on-every-exit ()
  "The input-box analogue of #15's ensure-no-modal.  An abandoned `/model
opus' does not fail quietly — it waits in the box and prepends itself to
whatever is dispatched next, which is how a compaction failure becomes a
corrupted instruction to an unrelated session later."
  (cc-butler-compact-test--with-session "w"
    (cc-butler-compact-test--to-restore "w")
    (cc-butler-compact-test--with-unsubmitted "/model claude-opus-4-8"
      (cc-butler-compact--set-state
       "w" :restore-tries cc-butler-compact-restore-retries)
      (cc-butler-compact--poll "w")        ; retries exhausted -> finish
      (should-not (cc-butler-compact--active-p "w"))
      ;; C-u went out on the way past.
      (should (member "RAW:\C-u" cc-butler-compact-test--sent)))))

(ert-deftest cc-butler-compact/operator-input-is-never-cleared ()
  "The clear only ever removes OUR text.  Genuinely typed operator input is
the thing this driver exists to protect; touching it would be worse than any
failure it is cleaning up after."
  (cc-butler-compact-test--with-session "w"
    (cc-butler-compact-test--to-restore "w")
    (cc-butler-compact-test--with-unsubmitted "please stop and check the logs"
      (let ((st (gethash "w" cc-butler-compact--state)))
        (should-not (cc-butler-compact--own-input "w" st))
        (should-not (cc-butler-compact--clear-own-input "w" st)))
      (cc-butler-compact--set-state
       "w" :orig-args '("claude-opus-4-8")   ; last candidate -> this ends it
       :sent-time (- (float-time) (1+ cc-butler-compact-step-timeout)))
      (cc-butler-compact--poll "w")        ; times out and finishes
      (should-not (cc-butler-compact--active-p "w"))
      (should-not (member "RAW:\C-u" cc-butler-compact-test--sent)))))

(ert-deftest cc-butler-compact/a-partial-send-still-counts-as-ours ()
  "The interruption can land partway through the string, not only between the
string and the Return, so a prefix of what we sent is still ours to clean."
  (cc-butler-compact-test--with-session "w"
    (cc-butler-compact-test--to-restore "w")
    (cc-butler-compact-test--with-unsubmitted "/model claude-op"
      (let ((st (gethash "w" cc-butler-compact--state)))
        (should (equal (cc-butler-compact--own-input "w" st) "/model claude-op"))))))

;;;; ------------------------------------------------------------------
;;;; Guards
;;;; ------------------------------------------------------------------

(ert-deftest cc-butler-compact/refuses-a-busy-session ()
  "A session whose transcript is active within the idle window is refused: our
Enter would land in the middle of its work."
  (cc-butler-compact-test--with-session "w"
    (cl-letf (((symbol-function 'cc-butler--session-last-activity)
               (lambda (_d) (float-time))))   ; wrote just now -> busy
      (should (string-match-p "busy" (cc-butler-compact--blocked-reason "w")))
      (should-error (cc-butler-compact-session "w") :type 'user-error))
    (should-not cc-butler-compact-test--sent)))

(ert-deftest cc-butler-compact/ignore-busy-skips-only-the-busy-check ()
  "The idle-waiting caller needs to test the blockers that will STILL apply
once the session goes idle, without busy masking them."
  (cc-butler-compact-test--with-session "w"
    (cl-letf (((symbol-function 'cc-butler--session-last-activity)
               (lambda (_d) (float-time))))   ; transcript fresh -> busy
      (should (cc-butler-compact--blocked-reason "w"))
      (should-not (cc-butler-compact--blocked-reason "w" t))
      ;; a menu is not excused by ignore-busy — idling does not close it
      (setq cc-butler-compact-test--screen cc-butler-compact-test--modal-screen)
      (should (string-match-p "menu" (cc-butler-compact--blocked-reason "w" t))))))

;;;; ------------------------------------------------------------------
;;;; P2: the busy gate is transcript activity, not the waiting flag
;;;; ------------------------------------------------------------------

(ert-deftest cc-butler-compact/idle-by-transcript-is-compactable ()
  "Repro A (fails under the old waiting-flag gate): the notification flag says
NOT waiting, but the newest transcript write was 900s ago (> the 600s idle
window), so the session is genuinely idle and compactable.  The old gate keyed
on the flag and would have refused it as busy."
  (cc-butler-compact-test--with-session "w"
    (let ((cc-butler-idle-threshold 600))
      (cl-letf (((symbol-function 'cc-butler--waiting-p) (lambda (_d) nil))
                ((symbol-function 'cc-butler--session-last-activity)
                 (lambda (_d) (- (float-time) 900))))
        (should (null (cc-butler-compact--blocked-reason "w")))))))

(ert-deftest cc-butler-compact/fresh-transcript-is-busy-despite-idle-flag ()
  "Repro B (fails under the old gate): the waiting flag says idle, but a
transcript was written 5s ago.  The transcript gate correctly reports busy;
the old flag gate would have called it idle and compacted underneath it — the
exact defect."
  (cc-butler-compact-test--with-session "w"
    (let ((cc-butler-idle-threshold 600))
      (cl-letf (((symbol-function 'cc-butler--waiting-p) (lambda (_d) (float-time)))
                ((symbol-function 'cc-butler--session-last-activity)
                 (lambda (_d) (- (float-time) 5))))
        (should (string-match-p "busy" (cc-butler-compact--blocked-reason "w")))))))

(ert-deftest cc-butler-compact/live-subagent-keeps-session-busy ()
  "Repro C: the main transcript may be cold while a sub-agent is still writing.
`cc-butler--session-last-activity' returns the MAX over both, so a fresh
sub-agent write (modelled here as a fresh last-activity) keeps the session busy
even with the waiting flag set idle."
  (cc-butler-compact-test--with-session "w"
    (let ((cc-butler-idle-threshold 600))
      (cl-letf (((symbol-function 'cc-butler--waiting-p) (lambda (_d) (float-time)))
                ((symbol-function 'cc-butler--session-last-activity)
                 (lambda (_d) (- (float-time) 3))))   ; fresh sub-agent write
        (should (string-match-p "busy" (cc-butler-compact--blocked-reason "w")))))))

;;;; ------------------------------------------------------------------
;;;; Self-compaction: the butler must be able to target ITSELF
;;;; ------------------------------------------------------------------

(ert-deftest cc-butler-compact/busy-session-is-queued-not-refused ()
  "A session can only call a tool from inside its own turn, and a session
inside its own turn is busy — so refusing busy made self-compaction
structurally impossible.  Busy now queues instead of refusing, and nothing
is typed while it waits."
  (cc-butler-compact-test--with-session "w"
    (cl-letf (((symbol-function 'cc-butler--waiting-p) (lambda (_d) nil)))
      (should (eq (cc-butler-compact-session-when-idle "w") 'queued))
      (should-not cc-butler-compact-test--sent)
      (should (cc-butler-compact-waiting-p "w")))))

(ert-deftest cc-butler-compact/idle-session-starts-immediately ()
  "Nothing is deferred when the target is already idle."
  (cc-butler-compact-test--with-session "w"
    (should (eq (cc-butler-compact-session-when-idle "w") 'started))
    (should (equal (cc-butler-compact-test--sent-in-order) '("/model sonnet")))
    (should-not (cc-butler-compact-waiting-p "w"))))

(ert-deftest cc-butler-compact/queued-compaction-starts-once-idle ()
  "The queued compaction begins on its own the moment the turn ends."
  (cc-butler-compact-test--with-session "w"
    (let ((busy t))
      ;; "mid-turn" now means an active transcript (the gate the driver uses).
      (cl-letf (((symbol-function 'cc-butler--session-last-activity)
                 (lambda (_d) (if busy (float-time) (- (float-time) 100000)))))
        (cc-butler-compact-session-when-idle "w")
        ;; still mid-turn: poll changes nothing
        (cc-butler-compact--idle-poll "w" (+ (float-time) 600))
        (should-not cc-butler-compact-test--sent)
        ;; turn ends
        (setq busy nil)
        (cc-butler-compact--idle-poll "w" (+ (float-time) 600))
        (should (equal (cc-butler-compact-test--sent-in-order) '("/model sonnet")))))))

(ert-deftest cc-butler-compact/queued-compaction-gives-up-at-the-deadline ()
  "A session that never goes idle must not leave a timer running forever —
and must still have had nothing typed into it."
  (cc-butler-compact-test--with-session "w"
    (cl-letf (((symbol-function 'cc-butler--waiting-p) (lambda (_d) nil)))
      (cc-butler-compact-session-when-idle "w")
      (cc-butler-compact--idle-poll "w" (- (float-time) 1))
      (should-not cc-butler-compact-test--sent)
      (should-not (cc-butler-compact-waiting-p "w")))))

(ert-deftest cc-butler-compact/a-throwing-idle-poll-keeps-the-compaction-queued ()
  "REGRESSION (2026-07-31): the poll drops the queue entry FIRST and only then
asks whether it is safe to start.  When that question signalled — as it did on
a dedicated window — the re-queue below was never reached, so the compaction
vanished outright: no retry, no deadline message, and `waiting-p' went false,
so it stopped even showing as queued.  A destructive step taken before the
thing it feeds has succeeded, the same shape as draining a queue before its
delivery is assembled.

Failing to determine safety is also not permission to proceed: the gate errs
toward BUSY everywhere else, and compaction is destructive."
  (cc-butler-compact-test--with-session "w"
    (cl-letf (((symbol-function 'cc-butler--waiting-p) (lambda (_d) nil)))
      (cc-butler-compact-session-when-idle "w")
      (should (cc-butler-compact-waiting-p "w"))
      (cl-letf (((symbol-function 'cc-butler-compact--blocked-reason)
                 (lambda (&rest _) (error "window trouble"))))
        (cc-butler-compact--idle-poll "w" (+ (float-time) 600)))
      (should (cc-butler-compact-waiting-p "w"))   ; still queued, will retry
      (should-not cc-butler-compact-test--sent))))  ; and did not start blind

(ert-deftest cc-butler-compact/the-safety-probe-survives-a-dedicated-window ()
  "The compaction probe reads the session's screen, so it inherited the
window-borrow failure verbatim — observed 2026-07-31 under exactly these two
conditions at once.  Guarded here as well as at the source: this is the path
that was seen to break, and it reaches the borrow through a different caller
than `read_session_output' does."
  (let ((buf (get-buffer-create " *ccb-compact-probe*"))
        (listbuf (get-buffer-create " *ccb-compact-list*")))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (split-window (selected-window) nil 'right)
          (set-window-buffer (selected-window) listbuf)
          (set-window-dedicated-p (selected-window) t)
          (with-current-buffer buf
            (setq-local ghostel--term 'fake-term)
            (insert "a screen\n"))
          (should-not (get-buffer-window-list buf nil t))
          (cl-letf (((symbol-function 'ghostel--redraw) (lambda (&rest _) t))
                    ((symbol-function 'claude-code-ide--get-buffer-name)
                     (lambda (&rest _) (buffer-name buf))))
            ;; the assertion is that this RETURNS rather than signalling
            (should-not (cc-butler-compact--typed-text "d"))))
      (kill-buffer buf)
      (kill-buffer listbuf))))

(ert-deftest cc-butler-compact/queueing-still-refuses-what-waiting-cannot-fix ()
  "An open menu or genuinely typed input is refused up front rather than
queued — idling does not clear either, so queueing would just defer a
failure by half an hour."
  (cc-butler-compact-test--with-session "w"
    (cl-letf (((symbol-function 'cc-butler--waiting-p) (lambda (_d) nil)))
      (setq cc-butler-compact-test--screen cc-butler-compact-test--modal-screen)
      (should-error (cc-butler-compact-session-when-idle "w") :type 'user-error)
      (should-not (cc-butler-compact-waiting-p "w")))))

(ert-deftest cc-butler-compact/queued-compaction-can-be-cancelled ()
  "A queued compaction is cancellable before it types anything."
  (cc-butler-compact-test--with-session "w"
    ;; busy = active transcript, so a stray idle-poll after cancel keeps waiting
    ;; rather than starting and typing.
    (cl-letf (((symbol-function 'cc-butler--session-last-activity)
               (lambda (_d) (float-time))))
      (cc-butler-compact-session-when-idle "w")
      (should (cc-butler-compact-cancel "w"))
      (should-not (cc-butler-compact-waiting-p "w"))
      (cc-butler-compact--idle-poll "w" (+ (float-time) 600))
      (should-not cc-butler-compact-test--sent))))

(ert-deftest cc-butler-compact/refuses-when-a-menu-is-open ()
  "An open wizard/menu is refused — the submit-Enter would answer it."
  (cc-butler-compact-test--with-session "w"
    (setq cc-butler-compact-test--screen cc-butler-compact-test--modal-screen)
    (should (string-match-p "menu" (cc-butler-compact--blocked-reason "w")))
    (should-error (cc-butler-compact-session "w") :type 'user-error)
    (should-not cc-butler-compact-test--sent)))

(ert-deftest cc-butler-compact/refuses-when-text-is-pending-in-the-input-box ()
  "Unsubmitted text would be concatenated with our slash command, producing
neither prompt."
  (cc-butler-compact-test--with-session "w"
    (setq cc-butler-compact-test--screen cc-butler-compact-test--typed-screen)
    (should (string-match-p "unsubmitted" (cc-butler-compact--blocked-reason "w")))
    (should-error (cc-butler-compact-session "w") :type 'user-error)
    (should-not cc-butler-compact-test--sent)))

(ert-deftest cc-butler-compact/refuses-an-unrestorable-model ()
  "With no readable model there is no way back, so the switch never happens."
  (cc-butler-compact-test--with-session "w"
    (setq cc-butler-compact-test--model "?")
    (should-error (cc-butler-compact-session "w") :type 'user-error)
    (should-not cc-butler-compact-test--sent)))

(ert-deftest cc-butler-compact/refuses-a-second-concurrent-compaction ()
  "The in-flight state is a lock: a second compaction cannot race the first."
  (cc-butler-compact-test--with-session "w"
    (cc-butler-compact-session "w")
    (should (string-match-p "already in flight"
                            (cc-butler-compact--blocked-reason "w")))
    (should-error (cc-butler-compact-session "w") :type 'user-error)
    (should (equal (length cc-butler-compact-test--sent) 1))))

(ert-deftest cc-butler-compact/ignore-busy-arg-starts-through-a-busy-session ()
  "cc-butler-compact-session's optional IGNORE-BUSY threads straight into
`cc-butler-compact--blocked-reason' -- the bypass the sweep and the force
path both rely on to act on a session whose idle window never comes (an
attention hook re-arming it every turn, e.g.), rather than waiting for
something that will not happen."
  (cc-butler-compact-test--with-session "w"
    (cl-letf (((symbol-function 'cc-butler--session-last-activity)
               (lambda (_d) (float-time))))   ; wrote just now -> busy
      (should-error (cc-butler-compact-session "w") :type 'user-error)
      (should-not cc-butler-compact-test--sent)
      (cc-butler-compact-session "w" t)
      (should cc-butler-compact-test--sent)
      (should (cc-butler-compact--active-p "w")))))

(ert-deftest cc-butler-compact/ignore-busy-does-not-open-the-menu-guard ()
  "IGNORE-BUSY excuses only busy.  An open menu still refuses outright even
while forcing through a busy session -- Enter would still answer a wizard
neither of us intended to answer, and idling (or forcing) never closes it."
  (cc-butler-compact-test--with-session "w"
    (setq cc-butler-compact-test--screen cc-butler-compact-test--modal-screen)
    (should-error (cc-butler-compact-session "w" t) :type 'user-error)
    (should-not cc-butler-compact-test--sent)))

;;;; ------------------------------------------------------------------
;;;; Fleet sweep
;;;; ------------------------------------------------------------------

;;;; ------------------------------------------------------------------
;;;; P3: percentage-first hybrid threshold
;;;; ------------------------------------------------------------------

(ert-deftest cc-butler-compact/over-threshold-37pct-not-flagged ()
  "A session at 37%% of its window is NOT a candidate even when its absolute
token count (371538) is well past the old 300k floor: the percentage is the
honest signal across differently-sized windows."
  (let ((cc-butler-compact-threshold-fraction 0.60))
    (cl-letf (((symbol-function 'cc-butler-compact--statusline-fields-now)
               (lambda (_d) (list :ctx 371538 :pct 37 :model "Opus-4.8"))))
      (should-not (cc-butler-compact--over-threshold-p "/d/")))))

(ert-deftest cc-butler-compact/over-threshold-65pct-flagged ()
  "At 65%% (>= the 0.60 fraction) the session is a candidate."
  (let ((cc-butler-compact-threshold-fraction 0.60))
    (cl-letf (((symbol-function 'cc-butler-compact--statusline-fields-now)
               (lambda (_d) (list :ctx 130000 :pct 65 :model "Opus-4.8"))))
      (should (cc-butler-compact--over-threshold-p "/d/")))))

(ert-deftest cc-butler-compact/over-threshold-falls-back-to-ctx-when-no-pct ()
  "With no percentage on the statusline, fall back to CTX against the window:
just over window*fraction is a candidate, just under is not."
  (let ((cc-butler-compact-threshold-fraction 0.60)
        (cc-butler-cleanup-context-window 200000))   ; * 0.60 = 120000
    (cl-letf (((symbol-function 'cc-butler-compact--statusline-fields-now)
               (lambda (_d) (list :ctx nil :pct nil :model "Opus-4.8"))))
      (cl-letf (((symbol-function 'cc-butler-cleanup-context-for) (lambda (_d) 130000)))
        (should (cc-butler-compact--over-threshold-p "/d/")))
      (cl-letf (((symbol-function 'cc-butler-cleanup-context-for) (lambda (_d) 110000)))
        (should-not (cc-butler-compact--over-threshold-p "/d/"))))))

(ert-deftest cc-butler-compact/over-threshold-is-window-adaptive ()
  "The SAME ctx yields opposite verdicts under different context windows —
the point of a fraction rather than an absolute floor."
  (let ((cc-butler-compact-threshold-fraction 0.60))
    (cl-letf (((symbol-function 'cc-butler-compact--statusline-fields-now)
               (lambda (_d) (list :ctx nil :pct nil :model "m")))
              ((symbol-function 'cc-butler-cleanup-context-for) (lambda (_d) 150000)))
      (let ((cc-butler-cleanup-context-window 200000))   ; *0.6 = 120000 -> over
        (should (cc-butler-compact--over-threshold-p "/d/")))
      (let ((cc-butler-cleanup-context-window 300000))   ; *0.6 = 180000 -> under
        (should-not (cc-butler-compact--over-threshold-p "/d/"))))))

(ert-deftest cc-butler-compact/candidates-use-percentage-not-absolute ()
  "The sweep gate is the percentage: a session at 37%% is not swept even though
its 371538 tokens exceed the old absolute 300k threshold (which would have
listed it)."
  (let ((cc-butler-compact-threshold-fraction 0.60)
        (cc-butler-compact-threshold 300000))
    (cl-letf (((symbol-function 'cc-butler--sessions) (lambda () '((:dir "/d/"))))
              ((symbol-function 'cc-butler-compact--statusline-fields-now)
               (lambda (_d) (list :ctx 371538 :pct 37 :model "Opus-4.8")))
              ((symbol-function 'cc-butler-cleanup-context-for) (lambda (_d) 371538)))
      (should (null (cc-butler-compact-candidates))))))

(ert-deftest cc-butler-compact/sweep-includes-butler-and-steward ()
  "The whole point: the butler and steward are candidates like anyone else.
Excluding them would leave the largest context in the fleet untouchable."
  (let ((cc-butler-compact-threshold 300000)
        (cc-butler--butler "/b/") (cc-butler--steward "/s/"))
    (cl-letf (((symbol-function 'cc-butler--sessions)
               (lambda () '((:dir "/b/") (:dir "/s/") (:dir "/w/"))))
              ((symbol-function 'cc-butler-cleanup-context-for)
               (lambda (d) (cond ((equal d "/b/") 471792)
                                 ((equal d "/s/") 361689)
                                 (t 90000)))))   ; worker well under the fraction
      (should (equal (cc-butler-compact-candidates) '("/b/" "/s/"))))))

(ert-deftest cc-butler-compact/sweep-orders-largest-first ()
  "Biggest context first, so a sweep interrupted partway did the work that
mattered most."
  (let ((cc-butler-compact-threshold 100000))
    (cl-letf (((symbol-function 'cc-butler--sessions)
               (lambda () '((:dir "/a/") (:dir "/b/") (:dir "/c/"))))
              ((symbol-function 'cc-butler-cleanup-context-for)
               (lambda (d) (cond ((equal d "/a/") 150000)
                                 ((equal d "/b/") 450000)
                                 (t 250000)))))
      (should (equal (cc-butler-compact-candidates) '("/b/" "/c/" "/a/"))))))

(ert-deftest cc-butler-compact/sweep-ignores-unreadable-context ()
  "A session whose statusline reports nothing is not a candidate — an unknown
size is not an excuse to act."
  (let ((cc-butler-compact-threshold 100000))
    (cl-letf (((symbol-function 'cc-butler--sessions)
               (lambda () '((:dir "/a/") (:dir "/b/"))))
              ((symbol-function 'cc-butler-cleanup-context-for)
               (lambda (d) (if (equal d "/a/") nil 450000))))
      (should (equal (cc-butler-compact-candidates) '("/b/"))))))

(ert-deftest cc-butler-compact/sweep-skips-blocked-sessions-without-stopping ()
  "One menu-blocked session must not abort the sweep; it is skipped with a
reason while the others proceed.  (Busy is deliberately NOT the example
here any more -- see `cc-butler-compact/sweep-ignores-busy-since-candidates-
are-already-over-threshold' -- since the sweep now ignores busy.)"
  (let ((cc-butler-compact-threshold 100000)
        (started nil))
    (cl-letf (((symbol-function 'cc-butler--sessions)
               (lambda () '((:dir "/blocked/") (:dir "/ok/"))))
              ((symbol-function 'cc-butler-cleanup-context-for) (lambda (_d) 450000))
              ((symbol-function 'cc-butler--display-name) (lambda (d) d))
              ((symbol-function 'cc-butler--log) #'ignore)
              ((symbol-function 'cc-butler-compact--blocked-reason)
               (lambda (d &optional _ignore-busy)
                 (and (equal d "/blocked/") "an interactive menu/wizard is open")))
              ((symbol-function 'cc-butler-compact-session)
               (lambda (d &optional _ignore-busy) (push d started))))
      (cc-butler-compact-large-sessions)
      (should (equal started '("/ok/"))))))

(ert-deftest cc-butler-compact/sweep-ignores-busy-since-candidates-are-already-over-threshold ()
  "Every dir here is over the compaction threshold by construction
\(`cc-butler-compact-candidates'); waiting for busy to resolve does not make an
over-threshold session safer -- it just means a session whose idle window
never comes (an attention hook re-arming it every turn) never gets compacted
and dies of its own size regardless.  The sweep must pass ignore-busy to both
the guard check and the start call."
  (let ((cc-butler-compact-threshold 100000)
        (started nil))
    (cl-letf (((symbol-function 'cc-butler--sessions)
               (lambda () '((:dir "/busy/"))))
              ((symbol-function 'cc-butler-cleanup-context-for) (lambda (_d) 450000))
              ((symbol-function 'cc-butler--display-name) (lambda (d) d))
              ((symbol-function 'cc-butler--log) #'ignore)
              ((symbol-function 'cc-butler-compact--blocked-reason)
               (lambda (d &optional ignore-busy)
                 (and (equal d "/busy/") (not ignore-busy)
                      "session is busy — transcript active within the idle window")))
              ((symbol-function 'cc-butler-compact-session)
               (lambda (d &optional ignore-busy) (when ignore-busy (push d started)))))
      (cc-butler-compact-large-sessions)
      (should (equal started '("/busy/"))))))

;;;; ------------------------------------------------------------------
;;;; MCP tools
;;;; ------------------------------------------------------------------

(ert-deftest cc-butler-compact/status-tool-reports-context-and-model ()
  "session_status exists because list_claude_sessions gives the model but not
the context size, and scraping the terminal for it proved unreliable.  Every
row must therefore carry a size, a model, and why it can or cannot compact."
  (let ((cc-butler-compact-threshold 300000))
    (cl-letf (((symbol-function 'cc-butler--sessions)
               (lambda () '((:dir "/butler/") (:dir "/w/"))))
              ((symbol-function 'cc-butler--display-name)
               (lambda (d) (if (equal d "/butler/") "butler" "worker")))
              ((symbol-function 'cc-butler-cleanup-context-for)
               (lambda (d) (if (equal d "/butler/") 480466 152222)))
              ((symbol-function 'cc-butler-cleanup-model-for) (lambda (_d) "Opus-4.8"))
              ((symbol-function 'cc-butler--waiting-p) (lambda (_d) (float-time)))
              ((symbol-function 'cc-butler-compact--blocked-reason) (lambda (_d) nil)))
      (let ((out (cc-butler-tool-session-status)))
        (should (string-match-p "butler" out))
        (should (string-match-p "480k" out))
        (should (string-match-p "152k" out))
        (should (string-match-p "Opus-4.8" out))
        ;; the butler is over, the worker is not
        (should (string-match-p "OVER THRESHOLD" out))))))

(ert-deftest cc-butler-compact/status-tool-surfaces-the-blocking-reason ()
  "A session that cannot be compacted says why, so the caller does not retry
blindly."
  (cl-letf (((symbol-function 'cc-butler--sessions) (lambda () '((:dir "/w/"))))
            ((symbol-function 'cc-butler--display-name) (lambda (_d) "worker"))
            ((symbol-function 'cc-butler-cleanup-context-for) (lambda (_d) 400000))
            ((symbol-function 'cc-butler-cleanup-model-for) (lambda (_d) "Opus-4.8"))
            ((symbol-function 'cc-butler--waiting-p) (lambda (_d) nil))
            ((symbol-function 'cc-butler-compact--blocked-reason)
             (lambda (_d) "session is busy")))
    (let ((out (cc-butler-tool-session-status)))
      (should (string-match-p "running" out))
      (should (string-match-p "session is busy" out)))))

(ert-deftest cc-butler-compact/status-tool-marks-unknown-context ()
  "A session with no statusline reports `?' rather than a fabricated number."
  (cl-letf (((symbol-function 'cc-butler--sessions) (lambda () '((:dir "/w/"))))
            ((symbol-function 'cc-butler--display-name) (lambda (_d) "worker"))
            ((symbol-function 'cc-butler-cleanup-context-for) (lambda (_d) nil))
            ((symbol-function 'cc-butler-cleanup-model-for) (lambda (_d) nil))
            ((symbol-function 'cc-butler--waiting-p) (lambda (_d) nil))
            ((symbol-function 'cc-butler-compact--blocked-reason) (lambda (_d) nil)))
    (should (string-match-p "?" (cc-butler-tool-session-status)))))

(ert-deftest cc-butler-compact/compact-tool-resolves-a-session-by-name ()
  "compact_session takes the name the LLM already has, not a directory."
  (let (target)
    (cl-letf (((symbol-function 'cc-butler--dir-by-name)
               (lambda (n) (and (equal n "worker") "/w/")))
              ((symbol-function 'cc-butler-compact-session-when-idle)
               (lambda (d) (setq target d) 'started)))
      (should (string-match-p "started" (cc-butler-tool-compact-session "worker")))
      (should (equal target "/w/")))))

(ert-deftest cc-butler-compact/compact-tool-explains-a-queued-self-call ()
  "Calling compact_session on yourself returns QUEUED, and the message has to
tell the caller what to do about it — finish the turn — or it reads as a
failure and gets retried forever."
  (cl-letf (((symbol-function 'cc-butler--dir-by-name) (lambda (_n) "/b/"))
            ((symbol-function 'cc-butler-compact-session-when-idle)
             (lambda (_d) 'queued)))
    (let ((out (cc-butler-tool-compact-session "butler")))
      (should (string-match-p "QUEUED" out))
      (should (string-match-p "finish your turn" out)))))

(ert-deftest cc-butler-compact/compact-tool-force-bypasses-the-idle-wait ()
  "force=t is the operator's explicit \"do it now\": it must call
cc-butler-compact-session directly with ignore-busy, bypassing
cc-butler-compact-session-when-idle's queue-and-wait entirely -- that queue
is exactly what fails to resolve when a session's idle window keeps being
reset by something other than itself (a notification hook, e.g.)."
  (let (called-when-idle target ignore-busy-arg)
    (cl-letf (((symbol-function 'cc-butler--dir-by-name) (lambda (_n) "/w/"))
              ((symbol-function 'cc-butler-compact-session-when-idle)
               (lambda (_d) (setq called-when-idle t) 'started))
              ((symbol-function 'cc-butler-compact-session)
               (lambda (d &optional ib) (setq target d ignore-busy-arg ib))))
      (let ((out (cc-butler-tool-compact-session "worker" t)))
        (should-not called-when-idle)
        (should (equal target "/w/"))
        (should ignore-busy-arg)
        (should (string-match-p "FORCED" out))))))

(ert-deftest cc-butler-compact/compact-tool-errors-on-unknown-name ()
  "An unknown name is an error pointing at the tool that lists valid ones —
never a silent no-op that reads as success."
  (cl-letf (((symbol-function 'cc-butler--dir-by-name) (lambda (_n) nil)))
    (let ((err (should-error (cc-butler-tool-compact-session "ghost") :type 'error)))
      (should (string-match-p "session_status" (error-message-string err))))))

(ert-deftest cc-butler-compact/sweep-tool-says-so-when-nothing-started ()
  "An empty sweep must not read as work done."
  (cl-letf (((symbol-function 'cc-butler-compact-large-sessions) (lambda () nil)))
    (should (string-match-p "Nothing started" (cc-butler-tool-compact-large-sessions))))
  (cl-letf (((symbol-function 'cc-butler-compact-large-sessions) (lambda () '("/b/")))
            ((symbol-function 'cc-butler--display-name) (lambda (_d) "butler")))
    (should (string-match-p "butler" (cc-butler-tool-compact-large-sessions)))))

;;;; ------------------------------------------------------------------
;;;; Fleet monitor: elisp reports, the steward decides
;;;; ------------------------------------------------------------------

(defmacro cc-butler-compact-test--with-fleet (sizes &rest body)
  "Run BODY with a fake fleet: SIZES is an alist of (NAME . CONTEXT)."
  (declare (indent 1))
  `(let ((cc-butler-compact-threshold 300000)
         (cc-butler-compact--last-report nil)
         (cc-butler--inbox nil)
         (cc-butler--steward "/steward/"))
     (cl-letf (((symbol-function 'cc-butler--sessions)
                (lambda () (mapcar (lambda (c) (list :dir (car c))) ,sizes)))
               ((symbol-function 'cc-butler-cleanup-context-for)
                (lambda (d) (alist-get d ,sizes nil nil #'equal)))
               ((symbol-function 'cc-butler--display-name) (lambda (d) d))
               ((symbol-function 'cc-butler--ops-dir) (lambda () "/steward/"))
               ((symbol-function 'cc-butler--log) #'ignore)
               ((symbol-function 'cc-butler-compact--blocked-reason)
                (lambda (_d &optional _i) nil))
               ((symbol-function 'cc-butler-compact-waiting-p) (lambda (_d) nil)))
       ,@body)))

(ert-deftest cc-butler-compact/fleet-summary-lists-only-what-is-over ()
  "The report is arithmetic — over the threshold or not — and says what the
steward can do about each one."
  (cc-butler-compact-test--with-fleet '(("/butler/" . 514000) ("/w/" . 90000))
    (let ((out (cc-butler-compact-fleet-summary)))
      (should (string-match-p "/butler/" out))
      (should (string-match-p "514k" out))
      (should-not (string-match-p "/w/" out))
      (should (string-match-p "ready: compact_session now" out)))))

(ert-deftest cc-butler-compact/fleet-summary-is-nil-when-nothing-is-over ()
  "Silence when there is nothing to say — this runs on every steward turn."
  (cc-butler-compact-test--with-fleet '(("/w/" . 10000))
    (should-not (cc-butler-compact-fleet-summary))))

(ert-deftest cc-butler-compact/fleet-summary-distinguishes-busy-from-blocked ()
  "A mid-turn session is actionable (compact_session queues it); a session
with a menu open is not.  Collapsing the two would make the steward wait on
something that will never clear itself."
  (cc-butler-compact-test--with-fleet '(("/b/" . 514000))
    (cl-letf (((symbol-function 'cc-butler-compact--blocked-reason)
               (lambda (_d &optional _i) "session is busy — not at a safe waiting point")))
      (should (string-match-p "queues it" (cc-butler-compact-fleet-summary))))
    (cl-letf (((symbol-function 'cc-butler-compact--blocked-reason)
               (lambda (_d &optional _i) "an interactive menu/wizard is open")))
      (should (string-match-p "menu" (cc-butler-compact-fleet-summary))))))

(ert-deftest cc-butler-compact/monitor-notifies-and-queues ()
  "By default the steward is TOLD, not left to ask: the report is typed in
and submitted, and also queued so it survives if typing was refused."
  (cc-butler-compact-test--with-fleet '(("/butler/" . 514000))
    (let (sent)
      (cl-letf (((symbol-function 'cc-butler--send-input)
                 (lambda (dir text &optional submit)
                   (push (list dir text submit) sent))))
        (cc-butler-compact--monitor-scan)
        ;; queued
        (should (= (length cc-butler--inbox) 1))
        (should (string-match-p "/butler/" (plist-get (car cc-butler--inbox) :body)))
        ;; and delivered into the steward, submitted
        (should (= (length sent) 1))
        (should (equal (nth 0 (car sent)) "/steward/"))
        (should (nth 2 (car sent)))
        (should (string-match-p "/butler/" (nth 1 (car sent))))))))

(ert-deftest cc-butler-compact/monitor-report-carries-the-remedies ()
  "A report that says only \"this is too big\" leaves the reader to remember
what may be done — including that a FINISHED worker should be closed rather
than compacted, which is the part that gets forgotten."
  (cc-butler-compact-test--with-fleet '(("/butler/" . 514000))
    (let ((out (cc-butler-compact-fleet-summary)))
      (should (string-match-p "compact_session" out))
      (should (string-match-p "compact_large_sessions" out))
      (should (string-match-p "close_topic" out)))))

(ert-deftest cc-butler-compact/monitor-can-be-set-to-queue-only ()
  "`nil' notify keeps the old non-intrusive behaviour available."
  (cc-butler-compact-test--with-fleet '(("/butler/" . 514000))
    (let ((cc-butler-compact-monitor-notify nil) sent)
      (cl-letf (((symbol-function 'cc-butler--send-input)
                 (lambda (&rest a) (push a sent))))
        (cc-butler-compact--monitor-scan)
        (should cc-butler--inbox)
        (should-not sent)))))

(ert-deftest cc-butler-compact/monitor-does-nothing-without-an-ops-session ()
  "With no butler and no steward there is nobody to tell, so the scan must
not queue reports that will be drained by whoever starts up next."
  (cc-butler-compact-test--with-fleet '(("/butler/" . 514000))
    (cl-letf (((symbol-function 'cc-butler--ops-dir) (lambda () nil)))
      (cc-butler-compact--monitor-scan)
      (should-not cc-butler--inbox))))

(ert-deftest cc-butler-compact/monitor-does-not-repeat-an-unchanged-fleet ()
  "A standing situation must not be restated every scan, or the steward
learns to ignore it."
  (cc-butler-compact-test--with-fleet '(("/butler/" . 514000))
    (cc-butler-compact--monitor-scan)
    (cc-butler-compact--monitor-scan)
    (cc-butler-compact--monitor-scan)
    (should (= (length cc-butler--inbox) 1))))

(ert-deftest cc-butler-compact/monitor-reports-again-when-the-set-changes ()
  "A newly-over session is news even if an old one was already reported."
  (let ((fleet '(("/butler/" . 514000))))
    (cc-butler-compact-test--with-fleet fleet
      (cc-butler-compact--monitor-scan)
      (should (= (length cc-butler--inbox) 1))
      (cl-letf (((symbol-function 'cc-butler--sessions)
                 (lambda () '((:dir "/butler/") (:dir "/steward2/"))))
                ((symbol-function 'cc-butler-cleanup-context-for)
                 (lambda (_d) 514000)))
        (cc-butler-compact--monitor-scan)
        (should (= (length cc-butler--inbox) 2))))))

(ert-deftest cc-butler-compact/monitor-says-nothing-when-fleet-is-healthy ()
  "No candidates, no message — and the memory resets so a recurrence is
reported fresh rather than suppressed as a repeat."
  (cc-butler-compact-test--with-fleet '(("/w/" . 10000))
    (setq cc-butler-compact--last-report (cons '("/w/") (float-time)))
    (cc-butler-compact--monitor-scan)
    (should-not cc-butler--inbox)
    (should-not cc-butler-compact--last-report)))

(ert-deftest cc-butler-compact/monitor-notify-respects-the-compaction-guard ()
  "If it is not safe to type a slash command at the steward, it is not safe
to type a report at it either — same guard, no exceptions.  The queued copy
still gets through, so a blocked steward is not left uninformed."
  (cc-butler-compact-test--with-fleet '(("/butler/" . 514000))
    (let ((cc-butler-compact-monitor-notify 'submit) sent)
      (cl-letf (((symbol-function 'cc-butler--send-input)
                 (lambda (&rest a) (push a sent)))
                ((symbol-function 'cc-butler-compact--blocked-reason)
                 (lambda (_d &optional _i) "unsubmitted text is sitting in the input box")))
        (cc-butler-compact--monitor-scan)
        (should cc-butler--inbox)        ; still reported to the queue
        (should-not sent)))))            ; but nothing typed

;;;; ------------------------------------------------------------------
;;;; Restoring a model without a closed list of families
;;;; ------------------------------------------------------------------

;; The allowlist was opus/sonnet/haiku.  The installed CLI already ships `fable'
;; as a family and a `claude-mythos-5' whose family has no alias at all, so the
;; day a new family breaks compaction has already passed — it just has not been
;; run here yet.  Derive the argument from the tag instead of matching a list.

(ert-deftest cc-butler-compact/model-args-derives-the-exact-id-then-the-family ()
  "Best first: the exact model, then the family as a fallback."
  (should (equal '("claude-opus-4-8" "opus")
                 (cc-butler-compact--model-args "Opus-4.8")))
  (should (equal '("claude-sonnet-5" "sonnet")
                 (cc-butler-compact--model-args "Sonnet-5"))))

(ert-deftest cc-butler-compact/model-args-handles-families-it-has-never-heard-of ()
  "The point of dropping the list: a family nobody hardcoded still resolves.
`mythos' has no bare alias in the CLI, so the family candidate will not work —
but the exact id will, and it is tried first."
  (should (equal '("claude-fable-5" "fable")
                 (cc-butler-compact--model-args "Fable-5")))
  (should (equal '("claude-mythos-5" "mythos")
                 (cc-butler-compact--model-args "Mythos-5"))))

(ert-deftest cc-butler-compact/model-args-passes-an-id-shaped-tag-through ()
  "The statusline emits `display_name' OR `id'; both shapes must resolve."
  (should (equal '("claude-sonnet-5" "sonnet")
                 (cc-butler-compact--model-args "claude-sonnet-5")))
  (should (equal '("claude-haiku-4-5" "haiku")
                 (cc-butler-compact--model-args "Haiku-4-5"))))

(ert-deftest cc-butler-compact/model-args-unversioned-tag-uses-the-family-only ()
  "A tag with no version (observed: a bare \"Opus\") cannot name an exact model
— `claude-opus' is not an id — so do not offer it as a candidate."
  (should (equal '("opus") (cc-butler-compact--model-args "Opus")))
  (should (null (cc-butler-compact--model-args nil)))
  (should (null (cc-butler-compact--model-args ""))))

(ert-deftest cc-butler-compact/model-args-handles-a-spaced-display-name ()
  "A tag can carry SPACES, not just collapsed punctuation.  The statusline
collapses `Opus 4.8' to `Opus-4.8', but a transcript `/model' confirmation
reports the display name verbatim — `Opus 5' — and that is the higher-priority
source, since it catches a switch the screen missed.  Splitting on dots alone
would yield `claude-opus 5', which `/model' rejects; the driver would fall back
to `opus 5', which it also rejects, and the session would be left on the cheap
compaction model — the exact outcome this file exists to prevent."
  (should (equal '("claude-opus-5" "opus")
                 (cc-butler-compact--model-args "Opus 5")))
  (should (equal '("claude-opus-4-8" "opus")
                 (cc-butler-compact--model-args "Opus 4.8")))
  ;; the collapsed forms keep working unchanged
  (should (equal '("claude-opus-4-8" "opus")
                 (cc-butler-compact--model-args "Opus-4.8"))))

(ert-deftest cc-butler-compact/model-args-covers-every-observed-tag ()
  "Regression floor: every MODEL: tag actually seen in the wild must resolve.
All of these work today via the family list; none may stop working."
  (dolist (tag '("Opus-4.8" "Opus-5" "Sonnet-5" "claude-sonnet-5"
                 "claude-opus-4-8" "Opus" "Haiku-4-5" "Sonnet"))
    (should (cc-butler-compact--model-args tag))
    (should (cc-butler-compact--model-arg tag))))

(ert-deftest cc-butler-compact/model-is-p-compares-in-the-same-space ()
  "THE quiet breakage.  The landing check substring-matched the argument inside
the tag, which worked only because the argument was a bare family.  With an
exact id as the argument, `claude-opus-4-8' does not appear inside `Opus-4.8',
so a restore that SUCCEEDED would never be confirmed and would time out."
  (should (cc-butler-compact--model-is-p "Opus-4.8" "claude-opus-4-8"))
  (should (cc-butler-compact--model-is-p "claude-opus-4-8" "claude-opus-4-8")))

(ert-deftest cc-butler-compact/model-is-p-still-accepts-a-family-alias ()
  "The fallback argument is a bare family, and it must still confirm — this is
also how the switch TO the cheap model is detected."
  (should (cc-butler-compact--model-is-p "Sonnet-5" "sonnet"))
  (should (cc-butler-compact--model-is-p "claude-sonnet-5" "sonnet")))

(ert-deftest cc-butler-compact/model-is-p-does-not-confuse-versions ()
  "An exact argument must not be satisfied by a different model of the same
family — that is precisely the silent version drift being removed."
  (should-not (cc-butler-compact--model-is-p "Opus-5" "claude-opus-4-8"))
  (should-not (cc-butler-compact--model-is-p "Sonnet-5" "opus")))

(ert-deftest cc-butler-compact/restore-falls-back-to-the-family-on-timeout ()
  "If the exact id is refused the model simply does not change, and the session
would sit on the cheap model — the silent downgrade this is meant to prevent.
When the exact candidate times out, move to the family and try again rather
than giving up."
  (let ((cc-butler-compact--state (make-hash-table :test 'equal))
        (cc-butler-compact-step-timeout 0)
        (finished nil))
    (cl-letf (((symbol-function 'cc-butler--display-name) (lambda (_d) "s"))
              ((symbol-function 'cc-butler--log) #'ignore)
              ((symbol-function 'cc-butler-compact--schedule-poll) #'ignore)
              ((symbol-function 'cc-butler-compact--answer-modal) (lambda (&rest _) nil))
              ((symbol-function 'cc-butler-compact--own-input) (lambda (&rest _) nil))
              ((symbol-function 'cc-butler-compact--model-now) (lambda (_d) "Sonnet-5"))
              ((symbol-function 'cc-butler-compact--finish)
               (lambda (&rest args) (setq finished args))))
      (cc-butler-compact--set-state "/d/" :orig-args '("claude-opus-4-8" "opus")
                                    :orig-arg "claude-opus-4-8")
      (cc-butler-compact--poll-restore
       "/d/" (gethash "/d/" cc-butler-compact--state) 0)
      ;; not given up on: moved to the family candidate
      (should (null finished))
      (let ((st (gethash "/d/" cc-butler-compact--state)))
        (should (equal "opus" (plist-get st :orig-arg)))
        (should (equal '("opus") (plist-get st :orig-args))))
      ;; with the last candidate exhausted it does report failure
      (cc-butler-compact--poll-restore
       "/d/" (gethash "/d/" cc-butler-compact--state) 0)
      (should finished))))

(ert-deftest cc-butler-compact/fallback-log-does-not-assert-rejection ()
  "All we have observed at this point is that the model change was not
detected within the step timeout — not that the id was refused (a live
investigation on 2026-08-04 found the same wording driving readers to
assume rejection before the alternative, a slow-to-render confirmation
modal, had been ruled out).  The logged message must describe what was
observed, not what caused it."
  (let ((cc-butler-compact--state (make-hash-table :test 'equal))
        (cc-butler-compact-step-timeout 0)
        (logged nil))
    (cl-letf (((symbol-function 'cc-butler--display-name) (lambda (_d) "s"))
              ((symbol-function 'cc-butler--log)
               (lambda (fmt &rest args) (setq logged (apply #'format fmt args))))
              ((symbol-function 'cc-butler-compact--schedule-poll) #'ignore)
              ((symbol-function 'cc-butler-compact--answer-modal) (lambda (&rest _) nil))
              ((symbol-function 'cc-butler-compact--own-input) (lambda (&rest _) nil))
              ((symbol-function 'cc-butler-compact--model-now) (lambda (_d) "Sonnet-5"))
              ((symbol-function 'cc-butler-compact--finish) #'ignore))
      (cc-butler-compact--set-state "/d/" :orig-args '("claude-opus-4-8" "opus")
                                    :orig-arg "claude-opus-4-8")
      (cc-butler-compact--poll-restore
       "/d/" (gethash "/d/" cc-butler-compact--state) 0)
      (should logged)
      (should-not (string-match-p "did not land" logged))
      (should (string-match-p "not observed to take effect" logged)))))
;;;; Two callers, two freshness policies
;;;; ------------------------------------------------------------------

(ert-deftest cc-butler-compact/model-now-still-bypasses-the-cache ()
  "GUARD -- do not \"fix\" this away.  The polling loop asks repeatedly whether
the `/model' switch has landed, and it polls faster than the cache TTL, so it
MUST see the screen and not a remembered value.  This contract is the reason
the pre-flight read had to become a separate caller instead."
  (let ((cc-butler-cleanup--model-cache (make-hash-table :test 'equal))
        (calls 0))
    (puthash "/d/" (cons (float-time) "Stale-Model") cc-butler-cleanup--model-cache)
    (let ((cc-butler-cleanup-model-function
           (lambda (_s) (setq calls (1+ calls)) "Opus-5")))
      ;; even though a fresh cache entry exists, the screen is re-read
      (should (equal "Opus-5" (cc-butler-compact--model-now "/d/")))
      (should (= 1 calls)))))

(ert-deftest cc-butler-compact/restore-model-falls-back-to-transcript ()
  "Cases 1-4: the screen cannot say (mid-turn, just restarted, or a window too
narrow to render MODEL:).  The pre-flight read wants AVAILABILITY, so it falls
through to the transcript rather than refusing."
  (let ((cc-butler-cleanup--model-cache (make-hash-table :test 'equal))
        (cc-butler-cleanup-model-function (lambda (_s) nil)))   ; screen blank
    (cl-letf (((symbol-function 'cc-butler--transcript-model)
               (lambda (_d) "claude-opus-5")))
      (should (equal "claude-opus-5"
                     (cc-butler-compact--model-for-restore "/d/")))
      ;; and it resolves to something /model actually accepts.  The expected
      ;; value is now the EXACT id rather than the family alias: restoring by
      ;; family silently moved a session to whatever was newest in it, and the
      ;; derivation was changed to name the model the session was actually on.
      (should (equal "claude-opus-5"
                     (cc-butler-compact--model-arg
                      (cc-butler-compact--model-for-restore "/d/")))))))

(ert-deftest cc-butler-compact/restore-model-prefers-the-screen ()
  "The screen is the freshest truth when it is legible; the transcript is the
floor beneath it, not a replacement for it."
  (let ((cc-butler-cleanup--model-cache (make-hash-table :test 'equal))
        (cc-butler-cleanup-model-function (lambda (_s) "Sonnet-5")))
    (cl-letf (((symbol-function 'cc-butler--transcript-model)
               (lambda (_d) "claude-opus-5")))
      (should (equal "Sonnet-5" (cc-butler-compact--model-for-restore "/d/"))))))

(ert-deftest cc-butler-compact/restore-model-uses-last-known-as-floor ()
  "Screen blank AND no transcript signal: the cached last-known value is better
than refusing.  With nothing at all, nil -- the driver then refuses, which is
the behaviour we want to keep for a genuinely unknown model."
  (let ((cc-butler-cleanup--model-cache (make-hash-table :test 'equal))
        (cc-butler-cleanup-model-function (lambda (_s) nil)))
    (cl-letf (((symbol-function 'cc-butler--transcript-model) (lambda (_d) nil)))
      ;; a value was known once, before the window narrowed
      (puthash "/d/" (cons (float-time) "Opus-4.8") cc-butler-cleanup--model-cache)
      (should (equal "Opus-4.8" (cc-butler-compact--model-for-restore "/d/")))
      ;; nothing ever known -> nil -> the driver refuses
      (clrhash cc-butler-cleanup--model-cache)
      (should (null (cc-butler-compact--model-for-restore "/e/"))))))

(provide 'cc-butler-compact-test)
;;; cc-butler-compact-test.el ends here
