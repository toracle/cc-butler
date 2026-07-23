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
                       ((symbol-function 'cc-butler--refresh-terminal-text) #'ignore)
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
    (cl-letf (((symbol-function 'cc-butler--refresh-terminal-text) #'ignore)
              ((symbol-function 'cc-butler--read-output) (lambda (&rest _) screen))
              ((symbol-function 'claude-code-ide--get-buffer-name)
               (lambda (_d) (buffer-name (current-buffer)))))
      (with-temp-buffer
        (fmakunbound 'ghostel-cursor-point)
        (should (equal (cc-butler-compact--typed-text "d") "something"))))))

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
  (should (equal (cc-butler-compact--model-arg "Opus-4.8") "opus"))
  (should (equal (cc-butler-compact--model-arg "Sonnet-5") "sonnet"))
  (should (equal (cc-butler-compact--model-arg "claude-haiku-4-5") "haiku")))

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
    ;; A second tick while the modal is still rendering must NOT answer twice.
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
                   '("/model sonnet" "1" "/compact" "/model opus")))
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
    (should (equal (car cc-butler-compact-test--sent) "/model opus"))))

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
                   '("/model sonnet" "/model opus")))))

(ert-deftest cc-butler-compact/restore-failure-is-reported-not-swallowed ()
  "If the model does not come back, the driver finishes with an explicit
failure naming both the actual and the wanted model."
  (cc-butler-compact-test--with-session "w"
    (cc-butler-compact-session "w")
    (setq cc-butler-compact-test--model "Sonnet-5")
    (cc-butler-compact--poll "w")            ; -> /compact
    (setq cc-butler-compact-test--ctx 90000)
    (cc-butler-compact--poll "w")            ; -> /model opus
    (cc-butler-compact--set-state
     "w" :sent-time (- (float-time) (1+ cc-butler-compact-step-timeout)))
    (let ((msg (cc-butler-compact--poll "w")))
      (should (string-match-p "NOT restored" msg))
      (should (string-match-p "Sonnet-5" msg)))))

;;;; ------------------------------------------------------------------
;;;; Guards
;;;; ------------------------------------------------------------------

(ert-deftest cc-butler-compact/refuses-a-busy-session ()
  "A session that is not at a waiting point is refused: our Enter would land
in the middle of its work."
  (cc-butler-compact-test--with-session "w"
    (cl-letf (((symbol-function 'cc-butler--waiting-p) (lambda (_d) nil)))
      (should (string-match-p "busy" (cc-butler-compact--blocked-reason "w")))
      (should-error (cc-butler-compact-session "w") :type 'user-error))
    (should-not cc-butler-compact-test--sent)))

(ert-deftest cc-butler-compact/ignore-busy-skips-only-the-busy-check ()
  "The idle-waiting caller needs to test the blockers that will STILL apply
once the session goes idle, without busy masking them."
  (cc-butler-compact-test--with-session "w"
    (cl-letf (((symbol-function 'cc-butler--waiting-p) (lambda (_d) nil)))
      (should (cc-butler-compact--blocked-reason "w"))
      (should-not (cc-butler-compact--blocked-reason "w" t))
      ;; a menu is not excused by ignore-busy — waiting does not close it
      (setq cc-butler-compact-test--screen cc-butler-compact-test--modal-screen)
      (should (string-match-p "menu" (cc-butler-compact--blocked-reason "w" t))))))

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
      (cl-letf (((symbol-function 'cc-butler--waiting-p)
                 (lambda (_d) (if busy nil (float-time)))))
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
    (cl-letf (((symbol-function 'cc-butler--waiting-p) (lambda (_d) nil)))
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

;;;; ------------------------------------------------------------------
;;;; Fleet sweep
;;;; ------------------------------------------------------------------

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
                                 (t 203356)))))
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
  "One busy session must not abort the sweep; it is skipped with a reason
while the others proceed."
  (let ((cc-butler-compact-threshold 100000)
        (started nil))
    (cl-letf (((symbol-function 'cc-butler--sessions)
               (lambda () '((:dir "/busy/") (:dir "/ok/"))))
              ((symbol-function 'cc-butler-cleanup-context-for) (lambda (_d) 450000))
              ((symbol-function 'cc-butler--display-name) (lambda (d) d))
              ((symbol-function 'cc-butler--log) #'ignore)
              ((symbol-function 'cc-butler-compact--blocked-reason)
               (lambda (d) (and (equal d "/busy/") "session is busy")))
              ((symbol-function 'cc-butler-compact-session)
               (lambda (d) (push d started))))
      (cc-butler-compact-large-sessions)
      (should (equal started '("/ok/"))))))

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
  (cc-butler-compact-test--with-fleet '(("/butler/" . 514000) ("/w/" . 152000))
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

(provide 'cc-butler-compact-test)
;;; cc-butler-compact-test.el ends here
