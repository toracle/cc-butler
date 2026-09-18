;;; cc-butler-cleanup-scheduled-test.el --- tests for the scheduled idle-worker cleanup sweep  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jeongsoo Park
;; SPDX-License-Identifier: MIT

;; Covers: idle-age computation (newest TIMESTAMPED transcript row, immune
;; to a metadata-only tail bumping the file mtime, with the `:waiting'
;; fallback), candidate selection, and the consecutive-skip -> surface
;; escalation. Nothing real is sent, cleaned, or timed — `cc-butler-session-cleanup'
;; and the surface function are stubbed throughout.
;;
;;   emacs -Q --batch -L . -l ert -l tests/cc-butler-cleanup-scheduled-test.el \
;;     -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'cl-lib)
(require 'cc-butler-cleanup)
(require 'cc-butler-compact)   ; `cc-butler-compact--menu-block-reason' / `--pending-input-p'

;;;; ---- idle-age computation -------------------------------------------

(ert-deftest cc-butler-cleanup/scheduled-idle-seconds-prefers-transcript ()
  "The newest timestamped transcript row wins over the in-memory `:waiting'
timestamp."
  (cl-letf (((symbol-function 'cc-butler-cleanup--transcript-last-timestamp)
             (lambda (_dir) (- (float-time) 500)))
            ((symbol-function 'cc-butler--waiting-p)
             (lambda (_dir) (- (float-time) 999999))))
    (let ((secs (cc-butler-cleanup--scheduled-idle-seconds "/x/")))
      (should (numberp secs))
      (should (< (abs (- secs 500)) 5)))))

(ert-deftest cc-butler-cleanup/scheduled-idle-seconds-falls-back-to-waiting ()
  "With no timestamped transcript row at all, falls back to `:waiting'."
  (cl-letf (((symbol-function 'cc-butler-cleanup--transcript-last-timestamp)
             (lambda (_dir) nil))
            ((symbol-function 'cc-butler--waiting-p)
             (lambda (_dir) (- (float-time) 300))))
    (let ((secs (cc-butler-cleanup--scheduled-idle-seconds "/x/")))
      (should (numberp secs))
      (should (< (abs (- secs 300)) 5)))))

(ert-deftest cc-butler-cleanup/scheduled-idle-seconds-nil-when-unknown ()
  "Neither a timestamped row nor a `:waiting' timestamp -> unknowable, not zero."
  (cl-letf (((symbol-function 'cc-butler-cleanup--transcript-last-timestamp) (lambda (_dir) nil))
            ((symbol-function 'cc-butler--waiting-p) (lambda (_dir) nil)))
    (should (null (cc-butler-cleanup--scheduled-idle-seconds "/x/")))))

(ert-deftest cc-butler-cleanup/transcript-last-timestamp-skips-untimestamped-tail ()
  "A metadata-only tail (ai-title, mode, permission-mode, bridge-session —
none carrying a `timestamp' field) must not hide an older real timestamp
behind a fresh file mtime. Regression for the bug measured 2026-09-10:
`cc-butler--session-last-activity' (file mtime) read every one of 25 live
sessions as 0.0 days idle because such tail rows kept bumping the mtime
with zero real conversation activity, permanently silencing the sweep."
  (let* ((proj (file-name-as-directory (make-temp-file "cc-transcript" t)))
         (file (expand-file-name "session.jsonl" proj))
         (four-days-ago (format-time-string
                         "%Y-%m-%dT%H:%M:%S.000Z"
                         (time-subtract (current-time) (seconds-to-time (* 4 86400)))
                         t)))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert (format "{\"type\":\"assistant\",\"timestamp\":\"%s\"}\n" four-days-ago))
            (insert "{\"type\":\"system\",\"subtype\":\"ai-title\"}\n")
            (insert "{\"type\":\"system\",\"subtype\":\"mode\"}\n")
            (insert "{\"type\":\"system\",\"subtype\":\"permission-mode\"}\n")
            (insert "{\"type\":\"system\",\"subtype\":\"bridge-session\"}\n"))
          ;; the file's mtime is "now" (just written) -- the whole point.
          (cl-letf (((symbol-function 'cc-butler--claude-project-dir) (lambda (_dir) proj)))
            (let ((ts (cc-butler-cleanup--transcript-last-timestamp "/whatever/")))
              (should (numberp ts))
              (should (< (abs (- (- (float-time) ts) (* 4 86400))) 5)))
            (cl-letf (((symbol-function 'cc-butler--waiting-p) (lambda (_dir) (float-time))))
              (should (>= (cc-butler-cleanup--scheduled-idle-seconds "/whatever/")
                          (* 3 86400))))))
      (delete-directory proj t))))

;;;; ---- candidate selection ---------------------------------------------

(ert-deftest cc-butler-cleanup/scheduled-candidates-filters-worker-waiting-and-age ()
  "Only ordinary workers, currently WAITING, idle past the day threshold."
  (let ((cc-butler-cleanup-scheduled-idle-days 3)
        (day 86400.0))
    (cl-letf (((symbol-function 'cc-butler--sessions)
               (lambda () (list (list :dir "/a/") (list :dir "/b/")
                                 (list :dir "/c/") (list :dir "/d/"))))
              ((symbol-function 'cc-butler-cleanup--worker-p)
               (lambda (dir) (not (equal dir "/c/"))))   ; c = butler/steward
              ((symbol-function 'cc-butler--waiting-p)
               (lambda (dir) (unless (equal dir "/b/") (float-time)))) ; b = not waiting
              ((symbol-function 'cc-butler-cleanup--transcript-last-timestamp)
               (lambda (dir)
                 (- (float-time) (pcase dir
                                    ("/a/" (* 4 day))    ; over threshold
                                    ("/d/" (* 1 day))    ; under threshold
                                    (_ (* 4 day)))))))
      (should (equal (cc-butler-cleanup--scheduled-candidates) '("/a/"))))))

;;;; ---- consecutive-skip -> surface escalation ---------------------------

(defmacro cc-butler-cleanup-scheduled-test--with-fire-stubs (blocked-reason &rest body)
  "Run BODY with `cc-butler-cleanup--scheduled-fire' driven by one fake
candidate dir whose blocked-reason is BLOCKED-REASON (nil = not blocked).
Records every `cc-butler-session-cleanup' call in `sent' and every surface
call in `surfaced' (list of REASON strings, newest last)."
  (declare (indent 1))
  `(let* ((sent nil) (surfaced nil) (waiting-now t)
          (cc-butler-cleanup-scheduled-skip-limit 3)
          (cc-butler-cleanup--scheduled-skip-count (make-hash-table :test 'equal))
          (cc-butler-cleanup--scheduled-pending (make-hash-table :test 'equal))
          (cc-butler-cleanup-surface-function
           (lambda (_session reason) (push reason surfaced))))
     (cl-letf (((symbol-function 'cc-butler-cleanup--scheduled-candidates)
                (lambda () (list "/w/")))
               ((symbol-function 'cc-butler-cleanup--scheduled-blocked-reason)
                (lambda (_dir) ,blocked-reason))
               ((symbol-function 'cc-butler-cleanup--session)
                (lambda (dir) (list :dir dir :name "worker")))
               ((symbol-function 'cc-butler--display-name) (lambda (_dir) "worker"))
               ((symbol-function 'cc-butler--waiting-p) (lambda (_dir) waiting-now))
               ((symbol-function 'cc-butler--log) (lambda (&rest _) nil))
               ((symbol-function 'cc-butler-session-cleanup)
                (lambda (dir tier) (push (cons dir tier) sent))))
       ,@body)))

(ert-deftest cc-butler-cleanup/scheduled-fire-surfaces-exactly-once-at-skip-limit ()
  "A session skipped `cc-butler-cleanup-scheduled-skip-limit' times in a row
is surfaced exactly once — not before, and not again on every run after."
  (cc-butler-cleanup-scheduled-test--with-fire-stubs "an open menu is showing"
    ;; runs 1, 2: below the limit (3) -- logged, not yet surfaced.
    (cc-butler-cleanup--scheduled-fire)
    (should (= 0 (length surfaced)))
    (cc-butler-cleanup--scheduled-fire)
    (should (= 0 (length surfaced)))
    ;; run 3: hits the limit -- surfaced exactly once.
    (cc-butler-cleanup--scheduled-fire)
    (should (= 1 (length surfaced)))
    (should (string-match-p "an open menu is showing" (car surfaced)))
    ;; run 4: skip count reset after surfacing -- not surfaced again yet.
    (cc-butler-cleanup--scheduled-fire)
    (should (= 1 (length surfaced)))
    ;; never actually cleaned -- it was blocked every run.
    (should (null sent))))

(ert-deftest cc-butler-cleanup/scheduled-fire-never-surfaces-below-limit ()
  "Fewer than the limit's worth of consecutive skips never surfaces."
  (cc-butler-cleanup-scheduled-test--with-fire-stubs "no live terminal"
    (cc-butler-cleanup--scheduled-fire)
    (cc-butler-cleanup--scheduled-fire)
    (should (= 0 (length surfaced)))))

(ert-deftest cc-butler-cleanup/scheduled-fire-cleans-unblocked-and-resets-skip-count ()
  "An unblocked candidate is cleaned at tier `clear', never `delete-dir', and
any prior skip streak for it is cleared rather than carried forward."
  (cc-butler-cleanup-scheduled-test--with-fire-stubs nil
    (puthash "/w/" 2 cc-butler-cleanup--scheduled-skip-count)
    (cc-butler-cleanup--scheduled-fire)
    (should (equal sent '(("/w/" . clear))))
    (should (null (gethash "/w/" cc-butler-cleanup--scheduled-skip-count)))
    (should (gethash "/w/" cc-butler-cleanup--scheduled-pending))
    (should (null surfaced))))

;;;; ---- TOCTOU, timer mode, promote ------------------------------------------

(ert-deftest cc-butler-cleanup/scheduled-fire-rechecks-waiting-before-firing ()
  "Listed as a candidate while idle, busy by the time of firing -> nothing sent."
  (cc-butler-cleanup-scheduled-test--with-fire-stubs nil
    (setq waiting-now nil)
    (cc-butler-cleanup--scheduled-fire)
    (should (null sent))
    (should (null (gethash "/w/" cc-butler-cleanup--scheduled-pending)))))

(ert-deftest cc-butler-cleanup/scheduled-mode-enable-arms-one-timer-disable-cancels ()
  (let ((cc-butler-cleanup--scheduled-timer nil)
        (cc-butler-cleanup-scheduled-mode nil)
        (timers nil))
    (cl-letf (((symbol-function 'run-with-timer)
               (lambda (&rest _) (let ((tm (timer-create))) (push tm timers) tm)))
              ((symbol-function 'cancel-timer)
               (lambda (tm) (setq timers (delq tm timers)))))
      (cc-butler-cleanup-scheduled-mode 1)
      (cc-butler-cleanup-scheduled-mode 1)
      (should (= 1 (length timers)))
      (cc-butler-cleanup-scheduled-mode -1)
      (should (null timers))
      (should (null cc-butler-cleanup--scheduled-timer)))))

(ert-deftest cc-butler-cleanup/scheduled-ensure-timer-is-idempotent ()
  (let ((cc-butler-cleanup--scheduled-timer nil) (timers nil))
    (cl-letf (((symbol-function 'run-with-timer)
               (lambda (&rest _) (let ((tm (timer-create))) (push tm timers) tm)))
              ((symbol-function 'cancel-timer)
               (lambda (tm) (setq timers (delq tm timers)))))
      (cc-butler-cleanup--scheduled-ensure-timer)
      (cc-butler-cleanup--scheduled-ensure-timer)
      (should (= 1 (length timers)))
      (should (eq (car timers) cc-butler-cleanup--scheduled-timer)))))

(ert-deftest cc-butler-cleanup/scheduled-promote-consumes-pending-flag-once ()
  (let* ((cc-butler-cleanup--scheduled-pending (make-hash-table :test 'equal))
        (calls 0)
        (cc-butler-cleanup-promote-function (lambda (_s) (cl-incf calls) t))
        (session (list :dir "/w/" :name "worker")))
    (cl-letf (((symbol-function 'cc-butler--log) (lambda (&rest _) nil)))
      ;; not flagged -> no promote
      (cc-butler-cleanup--scheduled-promote-after-externalize session)
      (should (= 0 calls))
      (puthash "/w/" t cc-butler-cleanup--scheduled-pending)
      (cc-butler-cleanup--scheduled-promote-after-externalize session)
      (cc-butler-cleanup--scheduled-promote-after-externalize session)
      (should (= 1 calls))
      (should (null (gethash "/w/" cc-butler-cleanup--scheduled-pending))))))

(provide 'cc-butler-cleanup-scheduled-test)
;;; cc-butler-cleanup-scheduled-test.el ends here

(defun cc-butler-cleanup-test--sweep-timers ()
  "Real timers in `timer-list' whose function is the scheduled sweep."
  (cl-remove-if-not
   (lambda (tm) (eq (timer--function tm) #'cc-butler-cleanup--scheduled-fire))
   timer-list))

(ert-deftest cc-butler-cleanup/loading-file-arms-no-timer ()
  "Default-off: (re)loading the file must not arm the scheduled sweep."
  (let ((cc-butler-cleanup--scheduled-timer nil)
        (cc-butler-cleanup-scheduled-mode nil))
    (unwind-protect
        (progn
          (load (locate-library "cc-butler-cleanup.el") nil t)
          (should (null cc-butler-cleanup--scheduled-timer))
          (should (null cc-butler-cleanup-scheduled-mode))
          (should (null (cc-butler-cleanup-test--sweep-timers))))
      (cc-butler-cleanup-scheduled-mode -1))))

(ert-deftest cc-butler-cleanup/scheduled-mode-twice-leaves-one-real-timer ()
  (mapc #'cancel-timer (cc-butler-cleanup-test--sweep-timers)) ; isolate from orphans
  (let ((cc-butler-cleanup--scheduled-timer nil)
        (cc-butler-cleanup-scheduled-mode nil))
    (unwind-protect
        (progn
          (cc-butler-cleanup-scheduled-mode 1)
          (cc-butler-cleanup-scheduled-mode 1)
          (should (= 1 (length (cc-butler-cleanup-test--sweep-timers))))
          (cc-butler-cleanup-scheduled-mode -1)
          (should (null (cc-butler-cleanup-test--sweep-timers))))
      (cc-butler-cleanup-scheduled-mode -1))))

(ert-deftest cc-butler-cleanup/scheduled-dry-run-reports-and-touches-nothing ()
  (let* ((day 86400.0) (calls nil)
         (cc-butler-cleanup-scheduled-idle-days 3)
         (skip (make-hash-table :test 'equal))
         (pending (make-hash-table :test 'equal))
         (cc-butler-cleanup--scheduled-skip-count skip)
         (cc-butler-cleanup--scheduled-pending pending)
         (cc-butler-cleanup--scheduled-timer nil)
         res)
    (puthash "/k/" 2 skip) (puthash "/a/" t pending)
    (cl-letf (((symbol-function 'cc-butler--sessions)
               (lambda () (list (list :dir "/a/") (list :dir "/k/")
                                (list :dir "/y/") (list :dir "/b/"))))
              ((symbol-function 'cc-butler--display-name)
               (lambda (d) (string-trim d "/" "/")))
              ((symbol-function 'cc-butler-cleanup--worker-p) (lambda (_) t))
              ((symbol-function 'cc-butler--waiting-p)
               (lambda (d) (unless (equal d "/b/") (float-time))))
              ((symbol-function 'cc-butler-cleanup--transcript-last-timestamp)
               (lambda (d) (- (float-time) (if (equal d "/y/") day (* 4 day)))))
              ((symbol-function 'cc-butler-cleanup--scheduled-blocked-reason)
               (lambda (d) (when (equal d "/k/") "on `cc-butler-cleanup-keep'")))
              ((symbol-function 'cc-butler--send-input) (lambda (&rest a) (push a calls)))
              ((symbol-function 'cc-butler-session-cleanup) (lambda (&rest a) (push a calls))))
      (setq res (cc-butler-cleanup-scheduled-dry-run)))
    (message "DRY-RUN EXAMPLE: %S" res)
    (should (null calls))
    (should (equal (mapcar (lambda (e) (plist-get e :status)) res)
                   '(would-fire skip not-candidate not-candidate)))
    (should (equal (plist-get (nth 1 res) :reason) "on `cc-butler-cleanup-keep'"))
    (should (< 3.9 (plist-get (nth 0 res) :idle-days) 4.1))
    (should (= 1 (hash-table-count skip)))
    (should (= 2 (gethash "/k/" skip)))
    (should (eq t (gethash "/a/" pending)))
    (should (null cc-butler-cleanup--scheduled-timer))))
