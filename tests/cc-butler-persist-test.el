;;; cc-butler-persist-test.el --- tests for roster persistence  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jeongsoo Park
;; SPDX-License-Identifier: MIT

;;   emacs -Q --batch -L . -l ert -l cc-butler-persist-test.el \
;;     -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'cc-butler)

;;;; ---- roster survives a transiently-small live set ------------------
;;
;; Regression coverage: after an OS shutdown, `cc-butler-restore-sessions'
;; twice (2026-07-13, 2026-07-21) came back with only the handful of
;; sessions that happened to be alive at the moment the debounced save last
;; fired, instead of the full roster — because `cc-butler--save-roster'
;; overwrote the file with a bare live-session snapshot, and subprocesses
;; during a mass teardown die one at a time, not atomically.

(ert-deftest cc-butler-persist/roster-survives-partial-live-set ()
  "Saving while only a subset of a previously-full roster is live must not
shrink the persisted file down to that subset."
  (let* ((tmpdir (file-name-as-directory (make-temp-file "cc-butler-persist-test" t)))
         (cc-butler-roster-file (expand-file-name "roster.eld" tmpdir))
         (dirs (list (expand-file-name "a/" tmpdir)
                     (expand-file-name "b/" tmpdir)
                     (expand-file-name "c/" tmpdir)))
         (cc-butler--butler nil))
    (unwind-protect
        (progn
          (dolist (d dirs) (make-directory d t))
          (cl-letf (((symbol-function 'cc-butler--sessions)
                     (lambda () (mapcar (lambda (d) (list :dir d :title "" :status "" :branch ""))
                                        dirs))))
            (cc-butler--save-roster))
          (should (= 3 (length (cc-butler--load-roster))))
          ;; Live set collapses to just one session (e.g. mid-shutdown, only
          ;; the butler is still up) and the debounced save fires anyway.
          (cl-letf (((symbol-function 'cc-butler--sessions)
                     (lambda () (list (list :dir (car dirs) :title "" :status "" :branch "")))))
            (cc-butler--save-roster))
          (should (= 3 (length (cc-butler--load-roster)))))
      (delete-directory tmpdir t))))

(ert-deftest cc-butler-persist/roster-drops-record-once-directory-gone ()
  "A record is pruned once its directory is actually removed — how
`cc-butler-close-topic' retires a topic — so closed topics don't linger
forever just because the merge protects against transient live-set dips."
  (let* ((tmpdir (file-name-as-directory (make-temp-file "cc-butler-persist-test" t)))
         (cc-butler-roster-file (expand-file-name "roster.eld" tmpdir))
         (dirs (list (expand-file-name "a/" tmpdir)
                     (expand-file-name "b/" tmpdir)))
         (cc-butler--butler nil))
    (unwind-protect
        (progn
          (dolist (d dirs) (make-directory d t))
          (cl-letf (((symbol-function 'cc-butler--sessions)
                     (lambda () (mapcar (lambda (d) (list :dir d :title "" :status "" :branch ""))
                                        dirs))))
            (cc-butler--save-roster))
          (should (= 2 (length (cc-butler--load-roster))))
          (delete-directory (cadr dirs) t)
          (cl-letf (((symbol-function 'cc-butler--sessions)
                     (lambda () (list (list :dir (car dirs) :title "" :status "" :branch "")))))
            (cc-butler--save-roster))
          (should (= 1 (length (cc-butler--load-roster)))))
      (when (file-directory-p tmpdir) (delete-directory tmpdir t)))))

;;;; ---- code-review defects (2026-07-21) -------------------------------

(ert-deftest cc-butler-persist/stale-record-does-not-retain-butler-flag ()
  "A record for a session that goes stale while flagged `:butler t' must not
keep that flag — otherwise it can outrank the ACTUAL current butler on the
next `cc-butler-restore-sessions' (last-write-wins there), resurrecting the
wrong session as butler."
  (let* ((tmpdir (file-name-as-directory (make-temp-file "cc-butler-persist-test" t)))
         (cc-butler-roster-file (expand-file-name "roster.eld" tmpdir))
         (dirs (list (expand-file-name "old-butler/" tmpdir)
                     (expand-file-name "new-butler/" tmpdir))))
    (unwind-protect
        (progn
          (dolist (d dirs) (make-directory d t))
          ;; "old-butler" is live and designated butler.
          (let ((cc-butler--butler (car dirs)))
            (cl-letf (((symbol-function 'cc-butler--sessions)
                       (lambda () (list (list :dir (car dirs) :title "" :status "" :branch "")))))
              (cc-butler--save-roster)))
          (should (plist-get (car (cc-butler--load-roster)) :butler))
          ;; "old-butler" dies (directory still exists); "new-butler" comes
          ;; up live and takes over the designation.
          (let ((cc-butler--butler (cadr dirs)))
            (cl-letf (((symbol-function 'cc-butler--sessions)
                       (lambda () (list (list :dir (cadr dirs) :title "" :status "" :branch "")))))
              (cc-butler--save-roster)))
          (let* ((saved (cc-butler--load-roster))
                 (old (seq-find (lambda (r) (equal (plist-get r :dir) (car dirs))) saved))
                 (new (seq-find (lambda (r) (equal (plist-get r :dir) (cadr dirs))) saved)))
            (should old)
            (should-not (plist-get old :butler))
            (should (plist-get new :butler))))
      (delete-directory tmpdir t))))

(ert-deftest cc-butler-persist/roster-forget-removes-explicitly-retired-record ()
  "`cc-butler--roster-forget' removes a record even though its directory still
exists — the only correct way to retire a session opened on an existing
project repo, which `cc-butler-close-topic' will never delete (directory-
existence-only pruning would otherwise make such a record immortal, so a
deliberately-closed session gets resurrected on the next restore)."
  (let* ((tmpdir (file-name-as-directory (make-temp-file "cc-butler-persist-test" t)))
         (cc-butler-roster-file (expand-file-name "roster.eld" tmpdir))
         (dir (expand-file-name "existing-repo/" tmpdir))
         (cc-butler--butler nil))
    (unwind-protect
        (progn
          (make-directory dir t)
          (cl-letf (((symbol-function 'cc-butler--sessions)
                     (lambda () (list (list :dir dir :title "" :status "" :branch "")))))
            (cc-butler--save-roster))
          (should (= 1 (length (cc-butler--load-roster))))
          (cc-butler--roster-forget dir)
          (should (null (cc-butler--load-roster)))
          (should (file-directory-p dir)))
      (delete-directory tmpdir t))))

(ert-deftest cc-butler-persist/save-tolerates-malformed-persisted-record ()
  "A malformed on-disk record (not even a plist) must not wedge future saves
— `cc-butler--roster-records' reads the very file it writes, so an ill-typed
stale record used to signal an error that `cc-butler--save-roster's
`ignore-errors' silently swallowed, permanently freezing the roster."
  (let* ((tmpdir (file-name-as-directory (make-temp-file "cc-butler-persist-test" t)))
         (cc-butler-roster-file (expand-file-name "roster.eld" tmpdir))
         (dir (expand-file-name "a/" tmpdir))
         (cc-butler--butler nil))
    (unwind-protect
        (progn
          (make-directory dir t)
          ;; Hand-write a roster with a garbage record mixed in.
          (with-temp-file cc-butler-roster-file
            (prin1 (list :saved nil :sessions (list "not-a-plist" (list :status "x")))
                   (current-buffer)))
          (cl-letf (((symbol-function 'cc-butler--sessions)
                     (lambda () (list (list :dir dir :title "" :status "" :branch "")))))
            (cc-butler--save-roster))
          (let ((saved (cc-butler--load-roster)))
            (should (= 1 (length saved)))
            (should (equal dir (plist-get (car saved) :dir)))))
      (delete-directory tmpdir t))))

;;;; ---- resume path waits for launch readiness (cc-butler#8, 2026-07-21) --

(ert-deftest cc-butler-persist/resume-in-waits-for-readiness ()
  "`cc-butler--resume-in' calls `cc-butler--wait-for-session-ready' after
spawning, same as `cc-butler--launch-session' — this is the OTHER place a
`claude' process is spawned, and it is exactly the path this morning's
resumed-fleet incident went through, so it needs the same guard against
handing back a false-ready session (cc-butler#8)."
  (let (waited-for)
    (cl-letf (((symbol-function 'claude-code-ide) (lambda (&rest _) nil))
              ((symbol-function 'cc-butler--wait-for-session-ready)
               (lambda (dir) (setq waited-for dir))))
      (cc-butler--resume-in "/tmp/some-resumed-worker/"))
    (should (equal waited-for (file-name-as-directory (expand-file-name "/tmp/some-resumed-worker/"))))))

(provide 'cc-butler-persist-test)
;;; cc-butler-persist-test.el ends here
