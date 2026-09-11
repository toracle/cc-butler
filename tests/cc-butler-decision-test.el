;;; cc-butler-decision-test.el --- BDD tests for the human decision adapter  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jeongsoo Park
;; SPDX-License-Identifier: MIT

;; Acceptance oracle for `cc-butler-decision' (the human adapter of maildir B).
;; Routing runs against B's in-memory MOCK channel (reused from
;; cc-butler-mail-test); rendering/parse/integrity are pure buffer operations.
;;
;;   emacs -Q --batch -L . -l ert -l cc-butler-decision-test.el \
;;     -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'cl-lib)
(require 'cc-butler-decision)
(require 'cc-butler-mail-test)   ; mock channel + inboxes/pokes vars

(defconst cc-butler-decision-test--msg
  '(:id "d1" :kind decision :from "worker-a" :reply-to "worker-a"
        :summary "Which auth for billing?" :needs "pick one"
        :options ((:label "Stripe" :tradeoff "lower fees")
                  (:label "Paddle" :tradeoff "handles VAT")
                  (:label "other")))
  "A representative decision message.")

(defun cc-butler-decision-test--fill (doc &optional letter other)
  "Return DOC with option LETTER ticked and OTHER written in the answer region."
  (with-temp-buffer
    (insert doc)
    (when letter
      (goto-char (point-min))
      (when (search-forward cc-butler--decision-answer-begin nil t)
        (when (re-search-forward (format "^- \\[\\( \\)\\] %c" letter) nil t)
          (replace-match "X" nil nil nil 1))))
    (when other
      (goto-char (point-min))
      (search-forward cc-butler--decision-answer-begin nil t)
      (when (re-search-forward "^Other:[ \t]*$" nil t)
        (replace-match (concat "Other: " other))))
    (buffer-string)))

;;;; ---- rendering ---------------------------------------------------

(ert-deftest cc-butler-decision/render-decision ()
  "A decision message renders an answerable doc: labelled options, a bare-checkbox
answer region, an Other line, and a routing footer."
  (let ((doc (cc-butler--decision-doc-string cc-butler-decision-test--msg)))
    (should (string-match-p "#\\+TITLE: Decision — Which auth for billing?" doc))
    (should (string-match-p "^  A\\. Stripe — lower fees$" doc))
    (should (string-match-p "^  B\\. Paddle — handles VAT$" doc))
    (should (string-match-p (regexp-quote cc-butler--decision-answer-begin) doc))
    (should (string-match-p "^- \\[ \\] A$" doc))
    (should (string-match-p "^Other: $" doc))
    (should (string-match-p "id=d1 to=worker-a" doc))))

(ert-deftest cc-butler-decision/render-note-readonly ()
  "A note message renders a read-only notification — no answer region."
  (let ((doc (cc-butler--decision-doc-string
              '(:id "n1" :kind note :from "steward" :summary "CI is green"))))
    (should (string-match-p "Notification (read-only)" doc))
    (should-not (string-match-p (regexp-quote cc-butler--decision-answer-begin) doc))))

;;;; ---- parsing / integrity -----------------------------------------

(ert-deftest cc-butler-decision/parse-selection-and-other ()
  "Parsing reads the ticked option (by its label) and the Other free-form, and
takes routing from the footer."
  (let* ((doc (cc-butler-decision-test--fill
               (cc-butler--decision-doc-string cc-butler-decision-test--msg)
               ?A "use sandbox keys"))
         (parsed (with-temp-buffer (insert doc) (cc-butler--decision-parse))))
    (should (equal '("A") (plist-get parsed :selected)))
    (should (equal "use sandbox keys" (plist-get parsed :other)))
    (should (equal "d1" (plist-get parsed :id)))
    (should (equal "worker-a" (plist-get parsed :to)))
    (should (string-match-p "Stripe" (plist-get parsed :answer)))
    (should (string-match-p "Other: use sandbox keys" (plist-get parsed :answer)))))

(ert-deftest cc-butler-decision/parse-ignores-outside-answer-region ()
  "Only the answer region is parsed — a stray tick elsewhere is not counted."
  (let* ((doc (cc-butler-decision-test--fill
               (cc-butler--decision-doc-string cc-butler-decision-test--msg) ?A))
         ;; inject a rogue ticked line BEFORE the answer region
         (tampered (replace-regexp-in-string
                    "^\\* Decision\n" "* Decision\n- [X] B\n" doc))
         (parsed (with-temp-buffer (insert tampered) (cc-butler--decision-parse))))
    (should (equal '("A") (plist-get parsed :selected)))   ; not ("B" "A")
    (should-not (member "B" (plist-get parsed :selected)))))

;;;; ---- submit routes via correlation -------------------------------

(ert-deftest cc-butler-decision/submit-routes-and-archives ()
  "Submitting a filled decision delivers the answer to the asker (correlation)
and moves the file open/ → done/."
  (let* ((cc-butler-decision-dir (make-temp-file "cc-butler-dec-test" t))
         (cc-butler-mail-test--inboxes nil)
         (cc-butler-mail-test--pokes nil)
         (cc-butler--channel (cc-butler-mail-test--mock-channel))
         (cc-butler-human-agent "정수님")
         (file (cc-butler--decision-render cc-butler-decision-test--msg)))
    (unwind-protect
        (progn
          ;; fill the file (tick A + Other) on disk, then open it
          (let ((doc (with-temp-buffer (insert-file-contents file) (buffer-string))))
            (with-temp-file file
              (insert (cc-butler-decision-test--fill doc ?A "sandbox"))))
          (let ((buf (find-file-noselect file)))
            (unwind-protect
                (with-current-buffer buf (cc-butler-decision-submit cc-butler-human-agent))
              (kill-buffer buf)))
          ;; the reply reached the asker's inbox, correlated to the decision
          (let ((r (car (cc-butler--ch-drain "worker-a"))))
            (should (eq 'reply (plist-get r :kind)))
            (should (equal "d1" (plist-get r :in-reply-to)))
            (should (equal "정수님" (plist-get r :from)))
            (should (string-match-p "Stripe" (plist-get r :body)))
            (should (string-match-p "sandbox" (plist-get r :body))))
          ;; the file moved open/ → done/
          (should (null (directory-files (cc-butler--decision-open-dir) nil "\\`[^.].*\\.org\\'")))
          (should (= 1 (length (directory-files (cc-butler--decision-done-dir) nil "\\`[^.].*\\.org\\'")))))
      (delete-directory cc-butler-decision-dir t))))

(ert-deftest cc-butler-decision/submit-refuses-empty ()
  "An un-answered (half-written) decision does not route — no leak."
  (let* ((cc-butler-mail-test--inboxes nil)
         (cc-butler--channel (cc-butler-mail-test--mock-channel))
         (doc (cc-butler--decision-doc-string cc-butler-decision-test--msg)))
    (with-temp-buffer
      (insert doc)
      (should-error (cc-butler-decision-submit cc-butler-human-agent) :type 'user-error))
    (should (null (cc-butler--ch-drain "worker-a")))))

(ert-deftest cc-butler-decision/submit-refuses-note ()
  "A note (no answer region) is not submittable."
  (with-temp-buffer
    (insert (cc-butler--decision-doc-string
             '(:id "n1" :kind note :from "steward" :summary "CI green")))
    (should-error (cc-butler-decision-submit cc-butler-human-agent) :type 'user-error)))

;;;; ---- ACTOR: required, explicit, never defaults to 정수님 -----------
;;
;; Bug (2026-09-10, mail log 20260910T112559-991-2980): a worker called
;; `cc-butler-decision-mark-read' via a raw elisp funcall (steward had
;; authorized this for two self-declared non-decisions), and the resulting
;; message landed `:from "정수님"' — a read-receipt he never sent, on an item
;; he never touched.  Both this function and `cc-butler-decision-submit' used
;; to hard-code `:from cc-butler-human-agent' unconditionally: ANY caller,
;; human keypress or programmatic funcall alike, got attributed to him.  The
;; fix threads an explicit ACTOR argument through instead of inferring one:
;; a bare keybinding/M-x/hydra dispatch supplies his identity via the
;; `interactive' spec (see the docstring); any other caller must identify
;; itself.  No actor at all refuses outright rather than guessing — it never
;; leans toward "it's the human".

(ert-deftest cc-butler-decision/submit-refuses-with-no-actor ()
  "A caller that supplies no ACTOR at all is refused before any mutation — it
must never silently become 정수님's answer.  RED against the pre-fix code:
the un-guarded `cc-butler-decision-submit' hard-coded `:from
cc-butler-human-agent' and would have sent the fabricated reply here."
  (let* ((cc-butler-mail-test--inboxes nil)
         (cc-butler--channel (cc-butler-mail-test--mock-channel))
         (doc (cc-butler-decision-test--fill
               (cc-butler--decision-doc-string cc-butler-decision-test--msg)
               ?A "sandbox")))
    (with-temp-buffer
      (insert doc)
      (should-error (cc-butler-decision-submit) :type 'user-error))
    ;; no fabricated reply reached the asker
    (should (null (cc-butler--ch-drain "worker-a")))))

(ert-deftest cc-butler-decision/submit-honors-explicit-non-human-actor ()
  "A programmatic caller that identifies ITSELF (not 정수님) is honest, not
forbidden — the bug was silent misattribution, not programmatic use itself."
  (let* ((cc-butler-decision-dir (make-temp-file "cc-butler-dec-test" t))
         (cc-butler-mail-test--inboxes nil)
         (cc-butler--channel (cc-butler-mail-test--mock-channel))
         (file (cc-butler--decision-render cc-butler-decision-test--msg)))
    (unwind-protect
        (progn
          (let ((doc (with-temp-buffer (insert-file-contents file) (buffer-string))))
            (with-temp-file file
              (insert (cc-butler-decision-test--fill doc ?A "sandbox"))))
          (let ((buf (find-file-noselect file)))
            (unwind-protect
                (with-current-buffer buf (cc-butler-decision-submit "worker-x"))
              (kill-buffer buf)))
          (let ((r (car (cc-butler--ch-drain "worker-a"))))
            (should (equal "worker-x" (plist-get r :from)))))
      (delete-directory cc-butler-decision-dir t))))

(ert-deftest cc-butler-decision/submit-interactive-dispatch-supplies-human-identity ()
  "A genuine interactive dispatch (`call-interactively', matching what a real
keybinding/M-x invocation does) supplies 정수님's identity automatically via
the `interactive' spec, with NO argument at the call site — the legitimate
path keeps working exactly as before the fix."
  (let* ((cc-butler-decision-dir (make-temp-file "cc-butler-dec-test" t))
         (cc-butler-mail-test--inboxes nil)
         (cc-butler--channel (cc-butler-mail-test--mock-channel))
         (cc-butler-human-agent "정수님")
         (file (cc-butler--decision-render cc-butler-decision-test--msg)))
    (unwind-protect
        (progn
          (let ((doc (with-temp-buffer (insert-file-contents file) (buffer-string))))
            (with-temp-file file
              (insert (cc-butler-decision-test--fill doc ?A "sandbox"))))
          (let ((buf (find-file-noselect file)))
            (unwind-protect
                (with-current-buffer buf (call-interactively #'cc-butler-decision-submit))
              (kill-buffer buf)))
          (let ((r (car (cc-butler--ch-drain "worker-a"))))
            (should (equal "정수님" (plist-get r :from)))))
      (delete-directory cc-butler-decision-dir t))))

;;;; ---- arrival-render layer (Emacs-native, arrival-driven) ---------

(defmacro cc-butler-decision-test--with-arrival (&rest body)
  "Fresh temp mail + decision dirs, file adapter, no auto-display."
  (declare (indent 0))
  `(let* ((cc-butler-mail-dir (make-temp-file "cc-butler-arr-mail" t))
          (cc-butler-decision-dir (make-temp-file "cc-butler-arr-dec" t))
          (cc-butler--channel nil)                 ; real file adapter
          (cc-butler-human-agent "정수님")
          (cc-butler-decision-auto-display nil)
          (cc-butler--decision-indicator ""))
     (unwind-protect (progn ,@body)
       (delete-directory cc-butler-mail-dir t)
       (delete-directory cc-butler-decision-dir t))))

(ert-deftest cc-butler-decision/arrival-renders-and-indicates ()
  "A decision ARRIVING in 정수님's inbox renders to open/ and sets the mode-line
indicator — driven by arrival, with no agent turn involved."
  (cc-butler-decision-test--with-arrival
    (cc-butler--mail-file-deliver
     "정수님" '(:id "d9" :kind decision :from "worker-a" :reply-to "worker-a"
                 :summary "ship it?" :options ("yes" "no")))
    (let ((n (cc-butler--decision-on-arrival)))     ; the watcher's callback, called directly
      (should (= 1 n))
      (should (= 1 (length (directory-files (cc-butler--decision-open-dir) nil "\\`[^.].*\\.org\\'"))))
      (should (= 0 (length (directory-files (cc-butler--decision-done-dir) nil "\\`[^.].*\\.org\\'"))))
      (should (equal " ⚖1" cc-butler--decision-indicator)))))

(ert-deftest cc-butler-decision/arrival-note-to-open-unread ()
  "§③ (read-receipt): a note arrival renders to open/ as UNREAD (read-only),
same physical location as a decision — it stays visible until `r' closes
it (moves to done/). It is NOT counted by the ⚖ indicator: a note needs
no answer, so counting it would reproduce the exact backlog-inflation
bug the indicator's age display exists to surface — see the governance
note titled escalate-to-butler-is-decision-only-a-notification-sent-through-it-never-closes."
  (cc-butler-decision-test--with-arrival
    (cc-butler--mail-file-deliver
     "정수님" '(:id "n9" :kind note :from "steward" :summary "CI is green"))
    (let ((n (cc-butler--decision-on-arrival)))
      (should (= 1 n))
      (should (= 1 (length (directory-files (cc-butler--decision-open-dir) nil "\\`[^.].*\\.org\\'"))))
      (should (= 0 (length (directory-files (cc-butler--decision-done-dir) nil "\\`[^.].*\\.org\\'"))))
      (should (equal "" cc-butler--decision-indicator)))))

;;;; ---- note/relay kind is excluded from the answer-required count ----
;;;; stark PR #71 (escalate_to_butler kind routing) shipped a description
;;;; claiming a note lands "straight in done/ -- never sitting in the
;;;; answer-required open/ queue".  Tracing the actual render/ingest path
;;;; shows every kind lands in open/ identically; only a manual `r' moves
;;;; it to done/.  These tests pin the MEASURED behavior end to end
;;;; (actual file location, not a rendered string or a stub), and pin the
;;;; fix that keeps the ⚖ count/backlog line answer-required-only despite
;;;; that shared open/ location.

(ert-deftest cc-butler-decision/file-kind-from-filename ()
  "`cc-butler--decision-file-kind' classifies from the filename suffix
alone; a plain `ID.org' (every file written before kind existed, and
every real decision since) is `decision'."
  (should (eq 'decision (cc-butler--decision-file-kind "20260813T120000-111-0001.org")))
  (should (eq 'note (cc-butler--decision-file-kind "20260813T120000-111-0001.note.org")))
  (should (eq 'relay (cc-butler--decision-file-kind "20260813T120000-111-0001.relay.org")))
  (should (eq 'briefing (cc-butler--decision-file-kind "20260813T120000-111-0001.briefing.org"))))

(ert-deftest cc-butler-decision/render-encodes-kind-in-filename ()
  "`cc-butler--decision-render' writes a plain `ID.org' for a decision
(unchanged, so every pre-existing file/caller stays valid) and a
`ID.KIND.org' for anything else."
  (cc-butler-decision-test--with-arrival
    (should (equal "abc123.org"
                    (file-name-nondirectory
                     (cc-butler--decision-render '(:id "abc123" :summary "hi")))))
    (should (equal "abc456.note.org"
                    (file-name-nondirectory
                     (cc-butler--decision-render '(:id "abc456" :kind note :summary "hi")))))))

(ert-deftest cc-butler-decision/create-path-note-lands-in-open-not-done ()
  "KIND `note', all the way from `cc-butler-decision-create' through
arrival rendering, lands the actual FILE in open/ -- not done/ -- same
as a decision; only a manual `r' (`cc-butler-decision-mark-read') moves
it to done/.  This is the measured behavior PR #71's description got
backwards; unlike `create-path-kind-note-renders-readonly' (which only
checks a plist/string), this asserts the real directory."
  (cc-butler-decision-test--with-arrival
    (cl-letf (((symbol-function 'cc-butler--display-name)
               (lambda (d) (if (equal d "/worker/") "worker-a" d))))
      (cc-butler-decision-create "/worker/" "FYI: retracting my earlier hypothesis" nil nil 'note)
      (should (= 1 (cc-butler--decision-on-arrival)))
      (should (= 1 (length (directory-files (cc-butler--decision-open-dir) nil
                                             cc-butler--decision-org-re))))
      (should (= 0 (length (directory-files (cc-butler--decision-done-dir) nil
                                             cc-butler--decision-org-re)))))))

(ert-deftest cc-butler-decision/open-files-and-oldest-excludes-non-decision-kinds ()
  "Given open/ holds one `decision' and one `note' (both physically
present, per the test above), the answer-required count from
`cc-butler--decision-open-files-and-oldest' -- what feeds both the ⚖
indicator and the pending_decisions backlog line -- is 1, not 2."
  (cc-butler-decision-test--with-arrival
    (cl-letf (((symbol-function 'cc-butler--display-name) (lambda (d) d)))
      (cc-butler-decision-create "/worker/" "please decide X" nil nil 'decision)
      (cc-butler-decision-create "/worker/" "FYI: status update" nil nil 'note)
      (cc-butler--decision-on-arrival)
      (should (= 2 (length (directory-files (cc-butler--decision-open-dir) nil
                                             cc-butler--decision-org-re))))
      (should (= 1 (length (car (cc-butler--decision-open-files-and-oldest))))))))

(ert-deftest cc-butler-decision/open-files-excludes-non-decision-kinds ()
  "Given open/ holds one `decision' and one `note' (both physically
present), `cc-butler--decision-open-files' -- what feeds `n'/`p'
navigation (`cc-butler--decision-move') -- lists only the decision, so
manual navigation never lands on a document with no answer region to
respond to."
  (cc-butler-decision-test--with-arrival
    (cl-letf (((symbol-function 'cc-butler--display-name) (lambda (d) d)))
      (cc-butler-decision-create "/worker/" "please decide X" nil nil 'decision)
      (cc-butler-decision-create "/worker/" "FYI: status update" nil nil 'note)
      (cc-butler--decision-on-arrival)
      (should (= 2 (length (directory-files (cc-butler--decision-open-dir) nil
                                             cc-butler--decision-org-re))))
      (let ((files (cc-butler--decision-open-files)))
        (should (= 1 (length files)))
        (should (eq 'decision (cc-butler--decision-file-kind (car files))))))))

;;;; ---- filename/body :Kind: drift (issue: demoted decision still
;;;; counted) -- a real decision demoted to a note (body `:Kind:'
;;;; rewritten to `note', title left alone) keeps its plain `ID.org'
;;;; filename, since only `cc-butler--decision-render' writes the
;;;; `.note.org' suffix and nothing in this repo rewrites an existing
;;;; file's `:Kind:' without also re-rendering (and thus renaming) it.
;;;; `cc-butler--decision-file-kind' (filename-only) can't see this, so
;;;; the ⚖ count keeps a closed item alive.  These tests seed the file
;;;; directly (as the drift itself would produce it), never through
;;;; `cc-butler-decision-create' + arrival, since that path always keeps
;;;; filename and body `:Kind:' in lockstep.

(ert-deftest cc-butler-decision/open-files-and-oldest-excludes-body-demoted-note ()
  "Given open/ holds a plain `ID.org' file whose FILENAME says nothing
(so the cheap filename filter alone would count it as a decision) but
whose BODY `:Kind:' property says `note' -- the exact shape of the 3
real files miscounted in production (20260908T112948-991-2536.org and
siblings) -- `cc-butler--decision-open-files-and-oldest' does not count
it."
  (cc-butler-decision-test--with-arrival
    (let ((id (format-time-string "%Y%m%dT%H%M%S-991-drift")))
      (with-temp-file (expand-file-name (format "%s.org" id) (cc-butler--decision-open-dir))
        (insert ":PROPERTIES:\n:Kind: note\n:END:\n"
                "#+TITLE: Decision — [발신 말 것 · demoted]\n\n"
                "* Notification (read-only)\ndemoted body\n")))
    (should (= 0 (length (car (cc-butler--decision-open-files-and-oldest)))))))

(ert-deftest cc-butler-decision/open-files-and-oldest-still-counts-genuine-decision ()
  "Independent negative control: a file whose body `:Kind:' really is
`decision' (unrelated to the demoted-note case above -- a fresh
fixture, not the one just fixed) is still counted, so the drift check
doesn't overcorrect into swallowing real open decisions."
  (cc-butler-decision-test--with-arrival
    (let ((id (format-time-string "%Y%m%dT%H%M%S-991-genuine")))
      (with-temp-file (expand-file-name (format "%s.org" id) (cc-butler--decision-open-dir))
        (insert ":PROPERTIES:\n:Kind: decision\n:END:\n"
                "#+TITLE: Decision — genuine\n\n"
                "* Decision\nreal open decision\n")))
    (should (= 1 (length (car (cc-butler--decision-open-files-and-oldest)))))))

(ert-deftest cc-butler-decision/open-files-and-oldest-still-excludes-note-suffix-filename ()
  "Unaffected by the drift check: an ordinary `.note.org' filename is
still excluded by the cheap filename filter alone (never even reaches
the body check)."
  (cc-butler-decision-test--with-arrival
    (let ((id (format-time-string "%Y%m%dT%H%M%S-991-plainnote")))
      (with-temp-file (expand-file-name (format "%s.note.org" id) (cc-butler--decision-open-dir))
        (insert ":PROPERTIES:\n:Kind: note\n:END:\n"
                "#+TITLE: Note — plain\n\n"
                "* Notification (read-only)\nplain note\n")))
    (should (= 0 (length (car (cc-butler--decision-open-files-and-oldest)))))))

(ert-deftest cc-butler-decision/answer-next-skips-note-lands-on-decision ()
  "Given open/ holds a `note' created BEFORE a `decision' (so the note sorts
first by filename/arrival order), `cc-butler-decision-answer-next' opens
the DECISION file, not the note -- \"go to the next thing that needs an
answer\" must never land on a document with no answer region."
  (cc-butler-decision-test--with-arrival
    (cl-letf (((symbol-function 'cc-butler--display-name) (lambda (d) d)))
      (cc-butler-decision-create "/worker/" "FYI: status update" nil nil 'note)
      (cc-butler-decision-create "/worker/" "please decide X" nil nil 'decision)
      (cc-butler--decision-on-arrival)
      (let ((create-lockfiles nil) (buf nil))
        (unwind-protect
            (progn
              (cc-butler-decision-answer-next)
              (setq buf (current-buffer))
              (should (eq 'decision (cc-butler--decision-file-kind (buffer-file-name))))
              (should (string-match-p "please decide X" (buffer-string))))
          (when (and buf (buffer-live-p buf)) (kill-buffer buf)))))))

;;;; ---- open/ backlog staleness (count + oldest age) ------------------
;;;; The existing arrival tests above use fake ids ("d9"/"n9") that don't
;;;; match the timestamp format, so they never exercise the age-parsing
;;;; path at all -- `oldest' stays nil and the indicator degrades to the
;;;; old bare-count string.  These tests use real `cc-butler--mail-id'-
;;;; shaped filenames specifically to hit that path.

(ert-deftest cc-butler-decision/file-time-parses-real-id ()
  "A real id's leading timestamp parses to the matching float-time."
  (should (equal (cc-butler--decision-file-time "20260704T145334-1585617-0019.org")
                  (float-time (encode-time 0 53 14 4 7 2026)))))

(ert-deftest cc-butler-decision/file-time-nil-for-non-timestamp-name ()
  "A filename not starting with the id timestamp shape (e.g. a test's
hand-picked short id) returns nil, not a wrong guess."
  (should (null (cc-butler--decision-file-time "d9.org")))
  (should (null (cc-butler--decision-file-time "not-a-decision-file.org"))))

(ert-deftest cc-butler-decision/format-age-boundaries ()
  "Minutes under an hour, hours under a day, days at and beyond."
  (should (equal "1m" (cc-butler--decision-format-age 1)))     ; rounds up, never \"0m\"
  (should (equal "5m" (cc-butler--decision-format-age 300)))
  (should (equal "2h" (cc-butler--decision-format-age 7200)))
  (should (equal "41d" (cc-butler--decision-format-age (* 41 86400)))))

(ert-deftest cc-butler-decision/indicator-shows-oldest-age-for-real-timestamp ()
  "Given an open/ file with a real id timestamp, Then the mode-line
indicator appends its age -- the whole point of PR's enrichment, and
the one path the fake-id arrival tests above cannot reach."
  (cc-butler-decision-test--with-arrival
    (let* ((old-time (- (float-time) (* 3 86400)))
           (id (format-time-string "%Y%m%dT%H%M%S-test-0001" old-time)))
      (with-temp-file (expand-file-name (format "%s.org" id) (cc-butler--decision-open-dir))
        (insert "* Decision\nplaceholder\n"))
      (cc-butler--decision-update-indicator)
      (should (equal " ⚖1 (oldest 3d)" cc-butler--decision-indicator)))))

(ert-deftest cc-butler-decision/indicator-omits-age-when-no-timestamp-parses ()
  "Given open/ files whose names don't carry a parseable timestamp
(mirrors the existing fake-id arrival tests), Then the indicator falls
back to the bare count -- no crash, no fabricated age."
  (cc-butler-decision-test--with-arrival
    (with-temp-file (expand-file-name "d9.org" (cc-butler--decision-open-dir))
      (insert "* Decision\nplaceholder\n"))
    (cc-butler--decision-update-indicator)
    (should (equal " ⚖1" cc-butler--decision-indicator))))

(ert-deftest cc-butler-decision/backlog-line-nil-when-open-dir-empty ()
  "No open/ files -> no backlog line, not an empty-but-truthy string."
  (cc-butler-decision-test--with-arrival
    (should (null (cc-butler--decision-open-backlog-line)))))

(ert-deftest cc-butler-decision/backlog-line-reports-count-and-oldest-age ()
  "Given two 미발신 (never delivered) open/ files of different ages, Then the
backlog line reports the total count, splits into the 미발신/답변대기
buckets, and names the OLDER not-sent file's age -- not the newer one's."
  (cc-butler-decision-test--with-arrival
    (let ((older (- (float-time) (* 10 86400)))
          (newer (- (float-time) 3600)))
      (dolist (pair (list (cons older "0001") (cons newer "0002")))
        (with-temp-file (expand-file-name
                         (format "%s-test-%s.org"
                                 (format-time-string "%Y%m%dT%H%M%S" (car pair))
                                 (cdr pair))
                         (cc-butler--decision-open-dir))
          (insert "* Decision\nplaceholder\n"))))
    (let ((line (cc-butler--decision-open-backlog-line)))
      (should (string-match-p "\\`⚖ 2 decision(s)" line))
      (should (string-match-p "미발신 2" line))
      (should (string-match-p "oldest 10d" line))
      (should (string-match-p "답변대기 0" line)))))

;;;; ---- 미발신/답변대기 buckets (:Delivered-to-matrix: signal) --------
;;;; A bare count reads the same regardless of whose turn it is. These
;;;; tests exercise the delivered-vs-not-delivered split that fixes that:
;;;; the deliverer writes a real Matrix event id into `:Delivered-to-matrix:'
;;;; only when delivery actually happened -- see
;;;; `cc-butler--decision-delivered-to-matrix-p' for why absence must always
;;;; read as "not sent", never the reverse.

(defun cc-butler-decision-test--seed-decision (id-suffix &optional delivered title time)
  "Write a `:Kind: decision' open/ file with optional :Delivered-to-matrix:
property and #+TITLE:.  TIME (a float-time) controls the id's timestamp,
default now."
  (with-temp-file (expand-file-name
                    (format "%s-991-%s.org"
                            (format-time-string "%Y%m%dT%H%M%S" (or time (float-time)))
                            id-suffix)
                    (cc-butler--decision-open-dir))
    (insert ":PROPERTIES:\n:Kind: decision\n"
            (if delivered ":Delivered-to-matrix: $fakeEventId1234567890\n" "")
            ":END:\n"
            (if title (format "#+TITLE: %s\n" title) "")
            "\n* Decision\nplaceholder\n")))

(ert-deftest cc-butler-decision/delivered-to-matrix-lands-in-awaiting-reply ()
  "A file WITH `:Delivered-to-matrix:' lands in 답변대기, never 미발신."
  (cc-butler-decision-test--with-arrival
    (cc-butler-decision-test--seed-decision "delivered" t)
    (let ((line (cc-butler--decision-open-backlog-line)))
      (should (string-match-p "미발신 0" line))
      (should (string-match-p "답변대기 1" line)))))

(ert-deftest cc-butler-decision/delivered-to-matrix-indented-verification-block-lands-in-awaiting-reply ()
  "Synthetic fixture reproducing a shape actually observed in a real
butler-written `* 발신됨' heading -- `:Delivered-to-matrix:'/`:Room:'/
`:Verified:' lines indented 2 spaces, not at column 0.  Values below are
synthetic (`EXAMPLE-...', `example.invalid') on purpose: this fixture
once carried the real room id, event id, and escalation text of an
actual delivered decision, in this PUBLIC repo -- keep it synthetic no
matter how tempting fidelity is (2026-09-10 fix).  Must land in
답변대기, never 미발신.  This is the exact shape steward found two real
delivered files misread as 미발신 because the old regex only matched
column 0."
  (cc-butler-decision-test--with-arrival
    (with-temp-file (expand-file-name
                      (format "%s-991-2593.org"
                              (format-time-string "%Y%m%dT%H%M%S"))
                      (cc-butler--decision-open-dir))
      (insert ":PROPERTIES:\n:Kind: decision\n:END:\n"
              "#+TITLE: EXAMPLE 합성 안건 제목 — 실물 아님\n\n"
              "* 발신됨 — butler, 2026-09-09 13:5x\n"
              "  :Delivered-to-matrix: $EXAMPLE-EVENT-ID\n"
              "  :Room: !EXAMPLE-ROOM:example.invalid (example)\n"
              "  :Subject: EXAMPLE 합성 안건 제목 — 실물 escalation 아님\n"
              "  :Verified: m.mentions=@EXAMPLE-USER:example.invalid [확인] · 방 귀속 /messages [확인] · 최상위 새 스레드 [확인]\n"
              "  ⚠ EXAMPLE synthetic annotation line, not real escalation text.\n"))
    (let ((line (cc-butler--decision-open-backlog-line)))
      (should (string-match-p "미발신 0" line))
      (should (string-match-p "답변대기 1" line)))))

(ert-deftest cc-butler-decision/no-property-lands-in-not-sent ()
  "A file WITHOUT `:Delivered-to-matrix:' lands in 미발신."
  (cc-butler-decision-test--with-arrival
    (cc-butler-decision-test--seed-decision "notsent" nil)
    (let ((line (cc-butler--decision-open-backlog-line)))
      (should (string-match-p "미발신 1" line))
      (should (string-match-p "답변대기 0" line)))))

(ert-deftest cc-butler-decision/note-suffix-excluded-from-both-buckets ()
  "A `.note.org' filename is excluded from both buckets entirely -- this is
just `cc-butler--decision-open-files-and-oldest' still doing its existing
job; the new bucketing must not break it."
  (cc-butler-decision-test--with-arrival
    (let ((id (format-time-string "%Y%m%dT%H%M%S-991-anote")))
      (with-temp-file (expand-file-name (format "%s.note.org" id) (cc-butler--decision-open-dir))
        (insert ":PROPERTIES:\n:Kind: note\n:END:\n#+TITLE: Note\n\n* Notification\nhi\n")))
    (should (null (cc-butler--decision-open-backlog-line)))))

(ert-deftest cc-butler-decision/delivered-file-independent-negative-control ()
  "Independent negative control (a fresh fixture, not reused from the
no-property test above): a file that verifiably HAS
`:Delivered-to-matrix:' must NOT be counted in 미발신 -- assert the
backlog line's 답변대기 count is exactly 1 when only this file exists."
  (cc-butler-decision-test--with-arrival
    (cc-butler-decision-test--seed-decision "controlfile" t "독립 대조군")
    (let ((line (cc-butler--decision-open-backlog-line)))
      (should (string-match-p "\\`⚖ 1 decision(s)" line))
      (should (string-match-p "답변대기 1" line))
      (should-not (string-match-p "미발신 [1-9]" line)))))

(ert-deftest cc-butler-decision/format-mismatch-suspect-flagged-in-backlog-line ()
  "A file where the strict classifier finds nothing (lands in 미발신) but
the loose `cc-butler--decision-file-mentions-delivery-p' probe fires --
the bare phrase \"Delivered-to-matrix\" shows up in prose, not in the
strict `^[ \t]*:Delivered-to-matrix: ' shape -- gets its own `⚠ 형식
불일치 의심' clause instead of being silently trusted as 미발신 with no
signal at all. This is the exact failure shape steward flagged: a
wrongly-미발신 file with no hand-written checkpoint has nothing else to
catch it."
  (cc-butler-decision-test--with-arrival
    (with-temp-file (expand-file-name
                      (format "%s-991-mismatch.org" (format-time-string "%Y%m%dT%H%M%S"))
                      (cc-butler--decision-open-dir))
      (insert ":PROPERTIES:\n:Kind: decision\n:END:\n"
              "#+TITLE: 형식 불일치 의심 사례\n\n"
              "* Decision\n"
              "⇒ 잡은 방법: 파일의 Delivered-to-matrix 부재 확인 (콜론 없이 본문에만 등장)\n"))
    (let ((line (cc-butler--decision-open-backlog-line)))
      (should (string-match-p "미발신 1" line))
      (should (string-match-p "⚠ 형식 불일치 의심 1건" line)))))

(ert-deftest cc-butler-decision/no-mismatch-warning-when-strict-classifier-already-matched ()
  "A normally-delivered file (strict AND loose both match) produces NO
format-mismatch warning -- the clause fires only on strict-absent +
loose-present, never merely because the loose probe also happens to
match a genuinely-delivered file."
  (cc-butler-decision-test--with-arrival
    (cc-butler-decision-test--seed-decision "normal" t)
    (let ((line (cc-butler--decision-open-backlog-line)))
      (should (string-match-p "답변대기 1" line))
      (should-not (string-match-p "형식 불일치" line)))))

(ert-deftest cc-butler-decision/not-sent-oldest-title-names-older-not-newer ()
  "Two 미발신 files of different synthetic ages, each with a #+TITLE:.  The
backlog line's oldest-title clause names the OLDER file's title, not the
newer one's, and truncates a long title to 40 chars + an ellipsis."
  (cc-butler-decision-test--with-arrival
    (let ((older (- (float-time) (* 5 86400)))
          (newer (- (float-time) 3600))
          (long-title (make-string 60 ?가)))
      (cc-butler-decision-test--seed-decision "older" nil long-title older)
      (cc-butler-decision-test--seed-decision "newer" nil "짧은 제목" newer))
    (let ((line (cc-butler--decision-open-backlog-line)))
      (should (string-match-p "미발신 2" line))
      (should (string-match-p (regexp-quote (concat (make-string 40 ?가) "…")) line))
      (should-not (string-match-p "짧은 제목" line)))))

(ert-deftest cc-butler-decision/not-sent-oldest-title-falls-back-when-missing ()
  "A 미발신 file with no #+TITLE: line shows 제목 없음 in the oldest-title
clause, not an error."
  (cc-butler-decision-test--with-arrival
    (cc-butler-decision-test--seed-decision "notitle" nil)
    (let ((line (cc-butler--decision-open-backlog-line)))
      (should (string-match-p "미발신 1" line))
      (should (string-match-p "제목 없음" line)))))

;;;; ---- unit-level tests for the two new file-reading helpers --------

(ert-deftest cc-butler-decision/delivered-to-matrix-p-true-when-present ()
  (let ((f (make-temp-file "cc-butler-dtm")))
    (unwind-protect
        (progn
          (with-temp-file f
            (insert ":PROPERTIES:\n:Delivered-to-matrix: $abc123\n:END:\n"))
          (should (cc-butler--decision-delivered-to-matrix-p f)))
      (delete-file f))))

(ert-deftest cc-butler-decision/delivered-to-matrix-p-true-when-indented-in-verification-block ()
  "Synthetic fixture reproducing a shape actually observed in a real
butler-written file: the property sits 2 spaces in, under a `* 발신됨'
heading, not at column 0 under `:PROPERTIES:'.  Values below are
synthetic (`EXAMPLE-...', `example.invalid') on purpose: this fixture
once carried the real room id, event id, and escalation text of an
actual delivered decision, in this PUBLIC repo -- keep it synthetic no
matter how tempting fidelity is (2026-09-10 fix).  The old
`\"^:Delivered-to-matrix: \"' regex missed this shape entirely."
  (let ((f (make-temp-file "cc-butler-dtm")))
    (unwind-protect
        (progn
          (with-temp-file f
            (insert "* 발신됨 — butler, 2026-09-09 13:5x\n"
                    "  :Delivered-to-matrix: $EXAMPLE-EVENT-ID\n"
                    "  :Room: !EXAMPLE-ROOM:example.invalid (example)\n"
                    "  :Subject: EXAMPLE 합성 안건 제목 — 실물 escalation 아님\n"
                    "  :Verified: m.mentions=@EXAMPLE-USER:example.invalid [확인] · 방 귀속 /messages [확인] · 최상위 새 스레드 [확인]\n"
                    "  ⚠ EXAMPLE synthetic annotation line, not real escalation text.\n"))
          (should (cc-butler--decision-delivered-to-matrix-p f)))
      (delete-file f))))

(ert-deftest cc-butler-decision/delivered-to-matrix-p-false-when-absent ()
  (let ((f (make-temp-file "cc-butler-dtm")))
    (unwind-protect
        (progn
          (with-temp-file f
            (insert ":PROPERTIES:\n:Kind: decision\n:END:\n"))
          (should-not (cc-butler--decision-delivered-to-matrix-p f)))
      (delete-file f))))

(ert-deftest cc-butler-decision/file-title-reads-and-truncates ()
  (let ((f (make-temp-file "cc-butler-title")))
    (unwind-protect
        (progn
          (with-temp-file f
            (insert (format "#+TITLE: %s\n" (make-string 50 ?a))))
          (should (equal (concat (make-string 40 ?a) "…")
                         (cc-butler--decision-file-title f))))
      (delete-file f))))

(ert-deftest cc-butler-decision/file-title-fallback-no-title-line ()
  (let ((f (make-temp-file "cc-butler-title")))
    (unwind-protect
        (progn
          (with-temp-file f (insert "* Decision\nno title here\n"))
          (should (equal "제목 없음" (cc-butler--decision-file-title f))))
      (delete-file f))))

;;;; ---- value-capturing readers: event id + room (queue-room thread activity) --
;;;; `:Delivered-to-matrix:' now also captures ITS OWN VALUE (an extended
;;;; regex, not a second parallel one); `:Room:' is a fresh reader following
;;;; the identical dual-shape (flat vs. indented-under-heading) approach.
;;;; Every id below is synthetic.

(ert-deftest cc-butler-decision/delivered-to-matrix-event-id-flat-shape ()
  (let ((f (make-temp-file "cc-butler-dtm-id")))
    (unwind-protect
        (progn
          (with-temp-file f
            (insert ":PROPERTIES:\n:Delivered-to-matrix: $fake-event-1\n:END:\n"))
          (should (equal "$fake-event-1"
                         (cc-butler--decision-delivered-to-matrix-event-id f))))
      (delete-file f))))

(ert-deftest cc-butler-decision/delivered-to-matrix-event-id-indented-shape ()
  (let ((f (make-temp-file "cc-butler-dtm-id")))
    (unwind-protect
        (progn
          (with-temp-file f
            (insert "* 발신됨 — butler, synthetic\n"
                    "  :Delivered-to-matrix: $fake-event-2\n"
                    "  :Room: !fake-room:example.org (test)\n"))
          (should (equal "$fake-event-2"
                         (cc-butler--decision-delivered-to-matrix-event-id f))))
      (delete-file f))))

(ert-deftest cc-butler-decision/delivered-to-matrix-event-id-nil-when-absent ()
  (let ((f (make-temp-file "cc-butler-dtm-id")))
    (unwind-protect
        (progn
          (with-temp-file f (insert ":PROPERTIES:\n:Kind: decision\n:END:\n"))
          (should (null (cc-butler--decision-delivered-to-matrix-event-id f))))
      (delete-file f))))

(ert-deftest cc-butler-decision/room-id-flat-shape ()
  (let ((f (make-temp-file "cc-butler-room")))
    (unwind-protect
        (progn
          (with-temp-file f
            (insert ":PROPERTIES:\n:Room: !fake-room:example.org\n:END:\n"))
          (should (equal "!fake-room:example.org" (cc-butler--decision-room-id f))))
      (delete-file f))))

(ert-deftest cc-butler-decision/room-id-indented-shape-strips-trailing-label ()
  "Same dual-shape approach as `:Delivered-to-matrix:'.  A real `:Room:'
value is followed by a human-readable room label in parens -- the reader
must return only the room id, not the whole line."
  (let ((f (make-temp-file "cc-butler-room")))
    (unwind-protect
        (progn
          (with-temp-file f
            (insert "* 발신됨 — butler, synthetic\n"
                    "  :Delivered-to-matrix: $fake-event-3\n"
                    "  :Room: !fake-room:example.org (butlers)\n"))
          (should (equal "!fake-room:example.org" (cc-butler--decision-room-id f))))
      (delete-file f))))

(ert-deftest cc-butler-decision/room-id-nil-when-absent ()
  "A real, confirmed-live gap: some files have `:Delivered-to-matrix:' but
no `:Room:' at all -- this reader must return nil cleanly, never guess or
default to any room."
  (let ((f (make-temp-file "cc-butler-room")))
    (unwind-protect
        (progn
          (with-temp-file f
            (insert ":PROPERTIES:\n:Delivered-to-matrix: $fake-event-4\n:END:\n"))
          (should (null (cc-butler--decision-room-id f))))
      (delete-file f))))

;;;; ---- 2026-09-11 fix: event-id first-token parity + `:Delivered-room:'/
;;;; `:Delivered-thread:' (queue-room-thread-activity check 9 hardening) ----
;;;; Every id below is synthetic.

(ert-deftest cc-butler-decision/delivered-to-matrix-event-id-strips-trailing-annotation ()
  "A real `:Delivered-to-matrix:' value can carry a trailing human-readable
annotation in parens, same shape `:Room:' already handles -- before this
fix, the event-id reader alone took the WHOLE trimmed value, so the
annotation rode along as part of the id fed to Matrix.  Live 2026-09-11
this produced a false M_NOT_FOUND (`not-in-room') for a delivery that was
actually in the right room -- the id just never matched."
  (let ((f (make-temp-file "cc-butler-dtm-id")))
    (unwind-protect
        (progn
          (with-temp-file f
            (insert ":PROPERTIES:\n:Delivered-to-matrix: $fake-event-5  (요약, 최상위)\n:END:\n"))
          (should (equal "$fake-event-5"
                         (cc-butler--decision-delivered-to-matrix-event-id f))))
      (delete-file f))))

(ert-deftest cc-butler-decision/delivered-room-id-flat-shape ()
  (let ((f (make-temp-file "cc-butler-delivered-room")))
    (unwind-protect
        (progn
          (with-temp-file f
            (insert ":PROPERTIES:\n:Delivered-room: !fake-room-2:example.org\n:END:\n"))
          (should (equal "!fake-room-2:example.org"
                         (cc-butler--decision-delivered-room-id f))))
      (delete-file f))))

(ert-deftest cc-butler-decision/delivered-room-id-indented-shape-strips-trailing-label ()
  (let ((f (make-temp-file "cc-butler-delivered-room")))
    (unwind-protect
        (progn
          (with-temp-file f
            (insert "* 발신됨 — butler, synthetic\n"
                    "  :Delivered-to-matrix: $fake-event-6\n"
                    "  :Delivered-room: !fake-room-3:example.org (butlers)\n"))
          (should (equal "!fake-room-3:example.org"
                         (cc-butler--decision-delivered-room-id f))))
      (delete-file f))))

(ert-deftest cc-butler-decision/delivery-room-only-room-property ()
  (let ((f (make-temp-file "cc-butler-delivery-room")))
    (unwind-protect
        (progn
          (with-temp-file f
            (insert ":PROPERTIES:\n:Room: !fake-room-4:example.org\n:END:\n"))
          (should (equal "!fake-room-4:example.org"
                         (cc-butler--decision-delivery-room f))))
      (delete-file f))))

(ert-deftest cc-butler-decision/delivery-room-only-delivered-room-property ()
  "The fix must not depend on any backfill of `:Room:' -- a file carrying
ONLY `:Delivered-room:' (the newer-convention shape) must resolve on its
own."
  (let ((f (make-temp-file "cc-butler-delivery-room")))
    (unwind-protect
        (progn
          (with-temp-file f
            (insert ":PROPERTIES:\n:Delivered-room: !fake-room-5:example.org\n:END:\n"))
          (should (equal "!fake-room-5:example.org"
                         (cc-butler--decision-delivery-room f))))
      (delete-file f))))

(ert-deftest cc-butler-decision/delivery-room-both-properties-agree ()
  (let ((f (make-temp-file "cc-butler-delivery-room")))
    (unwind-protect
        (progn
          (with-temp-file f
            (insert ":PROPERTIES:\n:Room: !fake-room-6:example.org\n"
                    ":Delivered-room: !fake-room-6:example.org\n:END:\n"))
          (should (equal "!fake-room-6:example.org"
                         (cc-butler--decision-delivery-room f))))
      (delete-file f))))

(ert-deftest cc-butler-decision/delivery-room-both-properties-disagree-is-conflict ()
  "Both properties present and naming DIFFERENT rooms is not decidable from
the file alone -- must return the `conflict' sentinel, never silently pick
either value."
  (let ((f (make-temp-file "cc-butler-delivery-room")))
    (unwind-protect
        (progn
          (with-temp-file f
            (insert ":PROPERTIES:\n:Room: !fake-room-7:example.org\n"
                    ":Delivered-room: !fake-room-8:example.org\n:END:\n"))
          (should (eq 'conflict (cc-butler--decision-delivery-room f))))
      (delete-file f))))

(ert-deftest cc-butler-decision/delivery-room-nil-when-neither-present ()
  (let ((f (make-temp-file "cc-butler-delivery-room")))
    (unwind-protect
        (progn
          (with-temp-file f
            (insert ":PROPERTIES:\n:Delivered-to-matrix: $fake-event-7\n:END:\n"))
          (should (null (cc-butler--decision-delivery-room f))))
      (delete-file f))))

(ert-deftest cc-butler-decision/delivered-thread-id-strips-trailing-detail ()
  (let ((f (make-temp-file "cc-butler-delivered-thread")))
    (unwind-protect
        (progn
          (with-temp-file f
            (insert "* 발신됨 — butler, synthetic\n"
                    "  :Delivered-to-matrix: $fake-event-root\n"
                    "  :Delivered-thread: $fake-event-root (요약=루트, 상세는 $fake-event-detail)\n"))
          (should (equal "$fake-event-root"
                         (cc-butler--decision-delivered-thread-id f))))
      (delete-file f))))

(ert-deftest cc-butler-decision/delivered-thread-id-nil-when-absent ()
  (let ((f (make-temp-file "cc-butler-delivered-thread")))
    (unwind-protect
        (progn
          (with-temp-file f
            (insert ":PROPERTIES:\n:Delivered-to-matrix: $fake-event-8\n:END:\n"))
          (should (null (cc-butler--decision-delivered-thread-id f))))
      (delete-file f))))

(ert-deftest cc-butler-decision/thread-root-event-id-prefers-delivered-thread ()
  "The whole point: when `:Delivered-to-matrix:' records a LEAF reply and
`:Delivered-thread:' records the actual root, thread-activity fetches must
use the root, not the leaf -- `/relations' only returns replies attached
to the event it is called on, and a human reply attaches to the root."
  (let ((f (make-temp-file "cc-butler-thread-root")))
    (unwind-protect
        (progn
          (with-temp-file f
            (insert "* 발신됨 — butler, synthetic\n"
                    "  :Delivered-to-matrix: $fake-event-leaf\n"
                    "  :Delivered-thread: $fake-event-root\n"))
          (should (equal "$fake-event-root"
                         (cc-butler--decision-thread-root-event-id f))))
      (delete-file f))))

(ert-deftest cc-butler-decision/thread-root-event-id-falls-back-to-delivered-to-matrix ()
  "Shape B has no `:Delivered-thread:' at all, and a delivery whose own
event IS the thread root has no need of one -- both fall back cleanly."
  (let ((f (make-temp-file "cc-butler-thread-root")))
    (unwind-protect
        (progn
          (with-temp-file f
            (insert ":PROPERTIES:\n:Delivered-to-matrix: $fake-event-9\n:END:\n"))
          (should (equal "$fake-event-9"
                         (cc-butler--decision-thread-root-event-id f))))
      (delete-file f))))

;;;; ---- 2026-09-11 fix: `:Delivery-held-until:' -- deliberate delivery
;;;; holds escape check 9's no-delivery age FAIL -----------------------

(ert-deftest cc-butler-decision/delivery-held-until-with-reason ()
  (let ((f (make-temp-file "cc-butler-held")))
    (unwind-protect
        (progn
          (with-temp-file f
            (insert ":PROPERTIES:\n:Delivery-held-until: 2026-09-11 09:00 daylight hours\n:END:\n"))
          (let ((held (cc-butler--decision-delivery-held-until f)))
            (should held)
            (should (equal "daylight hours" (cdr held)))
            (should (= (float-time (encode-time 0 0 9 11 9 2026)) (car held)))))
      (delete-file f))))

(ert-deftest cc-butler-decision/delivery-held-until-no-reason ()
  (let ((f (make-temp-file "cc-butler-held")))
    (unwind-protect
        (progn
          (with-temp-file f
            (insert ":PROPERTIES:\n:Delivery-held-until: 2026-09-11 09:00\n:END:\n"))
          (let ((held (cc-butler--decision-delivery-held-until f)))
            (should held)
            (should (null (cdr held)))))
      (delete-file f))))

(ert-deftest cc-butler-decision/delivery-held-until-indented-shape ()
  (let ((f (make-temp-file "cc-butler-held")))
    (unwind-protect
        (progn
          (with-temp-file f
            (insert "* 발신됨 — butler, synthetic\n"
                    "  :Delivered-to-matrix: $fake-event-10\n"
                    "  :Delivery-held-until: 2026-09-11 09:00 synthetic reason\n"))
          (should (cc-butler--decision-delivery-held-until f)))
      (delete-file f))))

(ert-deftest cc-butler-decision/delivery-held-until-nil-when-absent ()
  (let ((f (make-temp-file "cc-butler-held")))
    (unwind-protect
        (progn
          (with-temp-file f
            (insert ":PROPERTIES:\n:Delivered-to-matrix: $fake-event-11\n:END:\n"))
          (should (null (cc-butler--decision-delivery-held-until f))))
      (delete-file f))))

(ert-deftest cc-butler-decision/delivery-held-until-nil-when-malformed-date ()
  "Garbled digits (not a real calendar date) must fail to parse, not be
guessed at -- malformed and absent are deliberately indistinguishable to
callers."
  (let ((f (make-temp-file "cc-butler-held")))
    (unwind-protect
        (progn
          (with-temp-file f
            (insert ":PROPERTIES:\n:Delivery-held-until: not-a-date reason\n:END:\n"))
          (should (null (cc-butler--decision-delivery-held-until f))))
      (delete-file f))))

(ert-deftest cc-butler-decision/delivery-held-until-nil-when-missing-time-part ()
  "Date only, no `HH:MM' -- also malformed, must not parse."
  (let ((f (make-temp-file "cc-butler-held")))
    (unwind-protect
        (progn
          (with-temp-file f
            (insert ":PROPERTIES:\n:Delivery-held-until: 2026-09-11 daylight hours\n:END:\n"))
          (should (null (cc-butler--decision-delivery-held-until f))))
      (delete-file f))))

;;;; ---- create-path (escalate :options) + full flow -----------------

(ert-deftest cc-butler-decision/parse-options ()
  "Options string parses into (:label :tradeoff), tradeoff optional, blanks dropped."
  (let ((opts (cc-butler--decision-parse-options "Stripe — lower fees\nPaddle\n  \nother — misc")))
    (should (= 3 (length opts)))
    (should (equal "Stripe" (plist-get (nth 0 opts) :label)))
    (should (equal "lower fees" (plist-get (nth 0 opts) :tradeoff)))
    (should (equal "Paddle" (plist-get (nth 1 opts) :label)))
    (should (null (plist-get (nth 1 opts) :tradeoff)))
    (should (equal "other" (plist-get (nth 2 opts) :label)))))

(ert-deftest cc-butler-decision/create-path-to-human-inbox ()
  "The escalate create-path delivers a decision (parsed options + return path to
the escalator) into 정수님's inbox."
  (cc-butler-decision-test--with-arrival
    (cl-letf (((symbol-function 'cc-butler--display-name)
               (lambda (d) (if (equal d "/worker/") "worker-a" d))))
      (let ((id (cc-butler-decision-create
                 "/worker/" "which auth?" "pick one"
                 (cc-butler--decision-parse-options "Stripe — lower fees\nPaddle — handles VAT"))))
        (let ((m (car (cc-butler--ch-drain cc-butler-human-agent))))
          (should (eq 'decision (plist-get m :kind)))
          (should (equal id (plist-get m :id)))
          (should (equal "worker-a" (plist-get m :from)))
          (should (equal "worker-a" (plist-get m :reply-to)))   ; answer returns to escalator
          (should (equal "which auth?" (plist-get m :summary)))
          (let ((opts (plist-get m :options)))
            (should (= 2 (length opts)))
            (should (equal "Stripe" (plist-get (car opts) :label)))
            (should (equal "lower fees" (plist-get (car opts) :tradeoff)))))))))

(ert-deftest cc-butler-decision/create-path-kind-defaults-to-decision ()
  "Omitting KIND entirely still delivers a `decision' -- the pre-existing
callers of `cc-butler-decision-create' (before this parameter existed)
must not change behavior."
  (cc-butler-decision-test--with-arrival
    (cl-letf (((symbol-function 'cc-butler--display-name)
               (lambda (d) (if (equal d "/worker/") "worker-a" d))))
      (cc-butler-decision-create "/worker/" "ship?" nil nil)
      (should (eq 'decision (plist-get (car (cc-butler--ch-drain cc-butler-human-agent)) :kind))))))

(ert-deftest cc-butler-decision/create-path-kind-note-renders-readonly ()
  "KIND `note' delivers as a read-only notification through the SAME
pipeline a decision uses, and it renders with no answer region -- the
whole point of adding this parameter rather than inventing new
rendering."
  (cc-butler-decision-test--with-arrival
    (cl-letf (((symbol-function 'cc-butler--display-name)
               (lambda (d) (if (equal d "/worker/") "worker-a" d))))
      (cc-butler-decision-create "/worker/" "FYI: retracting my earlier hypothesis" nil nil 'note)
      (let ((m (car (cc-butler--ch-drain cc-butler-human-agent))))
        (should (eq 'note (plist-get m :kind)))
        (let ((doc (cc-butler--decision-doc-string m)))
          (should (string-match-p "Notification (read-only)" doc))
          (should-not (string-match-p (regexp-quote cc-butler--decision-answer-begin) doc)))))))

(ert-deftest cc-butler-decision/create-path-no-session-uses-sender-label ()
  "A caller with no live session at all (FROM-DIR nil -- e.g. a timer-driven
escalation with no MCP session context to derive a sender from, such as
the self-check module's automatic FAILING/RECOVERED notifications) must
still render an identifiable `:From:' when it supplies SENDER-LABEL
explicitly, instead of the bare `?' a nil FROM-DIR would otherwise
produce with nothing to name the sender."
  (cc-butler-decision-test--with-arrival
    (cc-butler-decision-create
     nil "cc-butler self-check: `x' started FAILING" nil nil
     'note "cc-butler (self-check)")
    (let ((m (car (cc-butler--ch-drain cc-butler-human-agent))))
      (should (equal "cc-butler (self-check)" (plist-get m :from)))
      (let ((doc (cc-butler--decision-doc-string m)))
        (should (string-match-p "^:From: cc-butler (self-check)$" doc))
        (should-not (string-match-p "^:From: \\?$" doc))))))

(ert-deftest cc-butler-decision/full-flow-create-to-route ()
  "End to end: create → arrival render → answer + submit → routed back to the
escalator via correlation."
  (cc-butler-decision-test--with-arrival
    (cl-letf (((symbol-function 'cc-butler--display-name)
               (lambda (d) (if (equal d "/worker/") "worker-a" d))))
      (let ((id (cc-butler-decision-create
                 "/worker/" "ship?" nil
                 (cc-butler--decision-parse-options "yes — now\nno — wait"))))
        (should (= 1 (cc-butler--decision-on-arrival)))
        (let* ((file (car (directory-files (cc-butler--decision-open-dir) t
                                           cc-butler--decision-org-re)))
               (doc (with-temp-buffer (insert-file-contents file) (buffer-string))))
          (with-temp-file file (insert (cc-butler-decision-test--fill doc ?A "asap")))
          (let ((buf (find-file-noselect file)))
            (unwind-protect (with-current-buffer buf (cc-butler-decision-submit cc-butler-human-agent))
              (kill-buffer buf))))
        (let ((r (car (cc-butler--ch-drain "worker-a"))))
          (should (eq 'reply (plist-get r :kind)))
          (should (equal id (plist-get r :in-reply-to)))
          (should (string-match-p "yes" (plist-get r :body)))
          (should (string-match-p "asap" (plist-get r :body))))))))

;;;; ---- dedup / supersede (item 2) ----------------------------------

(ert-deftest cc-butler-decision/dedup-supersedes-open ()
  "Re-escalating the same topic supersedes the open doc (no duplicate); the
superseded doc reflects the new content."
  (cc-butler-decision-test--with-arrival
    (cc-butler--mail-file-deliver "정수님"
      '(:id "a1" :kind decision :from "steward" :reply-to "steward"
            :summary "Which auth?" :options ("Stripe")))
    (should (= 1 (cc-butler--decision-on-arrival)))
    (should (= 1 (length (directory-files (cc-butler--decision-open-dir) nil cc-butler--decision-org-re))))
    (cc-butler--mail-file-deliver "정수님"
      '(:id "a2" :kind decision :from "steward" :reply-to "steward"
            :summary "Which auth?" :options ("Stripe" "Paddle")))
    (should (= 1 (cc-butler--decision-on-arrival)))       ; superseded, still surfaced
    (should (= 1 (length (directory-files (cc-butler--decision-open-dir) nil cc-butler--decision-org-re))))
    (let ((file (car (directory-files (cc-butler--decision-open-dir) t cc-butler--decision-org-re))))
      (should (string-match-p "Paddle" (with-temp-buffer (insert-file-contents file) (buffer-string)))))))

(ert-deftest cc-butler-decision/dedup-keeps-in-progress-answer ()
  "A re-escalation does NOT clobber an open doc 정수님 is already answering."
  (cc-butler-decision-test--with-arrival
    (cc-butler--mail-file-deliver "정수님"
      '(:id "b1" :kind decision :from "steward" :reply-to "steward"
            :summary "Ship?" :options ("yes" "no")))
    (cc-butler--decision-on-arrival)
    (let* ((file (car (directory-files (cc-butler--decision-open-dir) t cc-butler--decision-org-re)))
           (doc (with-temp-buffer (insert-file-contents file) (buffer-string))))
      (with-temp-file file (insert (cc-butler-decision-test--fill doc ?A))))
    (cc-butler--mail-file-deliver "정수님"
      '(:id "b2" :kind decision :from "steward" :reply-to "steward"
            :summary "Ship?" :options ("yes" "no" "maybe")))
    (should (= 0 (cc-butler--decision-on-arrival)))        ; kept, not surfaced anew
    (should (= 1 (length (directory-files (cc-butler--decision-open-dir) nil cc-butler--decision-org-re))))
    (let ((content (with-temp-buffer
                     (insert-file-contents
                      (car (directory-files (cc-butler--decision-open-dir) t cc-butler--decision-org-re)))
                     (buffer-string))))
      (should (string-match-p "\\[X\\] A" content))         ; 정수님's tick preserved
      (should-not (string-match-p "maybe" content)))))       ; not superseded

(ert-deftest cc-butler-decision/dedup-skips-answered ()
  "An already-answered topic is not resurfaced by a re-escalation."
  (cc-butler-decision-test--with-arrival
    (cl-letf (((symbol-function 'cc-butler--display-name) (lambda (d) d)))
      (cc-butler--mail-file-deliver "정수님"
        '(:id "c1" :kind decision :from "steward" :reply-to "steward"
              :summary "Deploy?" :options ("yes" "no")))
      (cc-butler--decision-on-arrival)
      (let* ((file (car (directory-files (cc-butler--decision-open-dir) t cc-butler--decision-org-re)))
             (doc (with-temp-buffer (insert-file-contents file) (buffer-string)))
             (create-lockfiles nil) (kill-buffer-query-functions nil))
        (with-temp-file file (insert (cc-butler-decision-test--fill doc ?A "go")))
        (let ((buf (find-file-noselect file)))
          (unwind-protect (with-current-buffer buf (cc-butler-decision-submit cc-butler-human-agent))
            (ignore-errors (kill-buffer buf)))))
      (should (= 0 (length (directory-files (cc-butler--decision-open-dir) nil cc-butler--decision-org-re))))
      (should (= 1 (length (directory-files (cc-butler--decision-done-dir) nil cc-butler--decision-org-re))))
      (cc-butler--mail-file-deliver "정수님"
        '(:id "c2" :kind decision :from "steward" :reply-to "steward"
              :summary "Deploy?" :options ("yes" "no")))
      (should (= 0 (cc-butler--decision-on-arrival)))        ; skipped
      (should (= 0 (length (directory-files (cc-butler--decision-open-dir) nil cc-butler--decision-org-re)))))))

;;;; ---- manual refresh (`cc-butler-decision-answer-next' path) ------

(ert-deftest cc-butler-decision/refresh-dedups-by-topic ()
  "`cc-butler-decision-refresh' (the manual answer-next path) dedups by topic
the same way arrival does.  Regression: this path used to call
`cc-butler--decision-render' directly with no dedup, so two same-topic
messages queued before a single refresh left duplicate open docs behind."
  (cc-butler-decision-test--with-arrival
    (cc-butler--mail-file-deliver "정수님"
      '(:id "r1" :kind decision :from "steward" :reply-to "steward"
            :summary "Which auth?" :options ("Stripe")))
    (cc-butler--mail-file-deliver "정수님"
      '(:id "r2" :kind decision :from "steward" :reply-to "steward"
            :summary "Which auth?" :options ("Stripe" "Paddle")))
    ;; Both drain in one pass: r1 surfaces new, r2 supersedes it — 2 surfacing
    ;; events (same counting convention as `cc-butler--decision-on-arrival'),
    ;; but the point of this test is the invariant below: only ONE file
    ;; survives in open/, not two.
    (should (= 2 (cc-butler-decision-refresh)))
    (should (= 1 (length (directory-files (cc-butler--decision-open-dir) nil cc-butler--decision-org-re))))
    (let ((file (car (directory-files (cc-butler--decision-open-dir) t cc-butler--decision-org-re))))
      (should (string-match-p "Paddle" (with-temp-buffer (insert-file-contents file) (buffer-string)))))))

(ert-deftest cc-butler-decision/refresh-skips-already-answered-topic ()
  "A topic already answered and archived is not resurrected by refresh.
Regression: without dedup, an answered decision that got re-escalated would
reappear in open/ looking like it never cleared."
  (cc-butler-decision-test--with-arrival
    (cl-letf (((symbol-function 'cc-butler--display-name) (lambda (d) d)))
      (cc-butler--mail-file-deliver "정수님"
        '(:id "s1" :kind decision :from "steward" :reply-to "steward"
              :summary "Deploy?" :options ("yes" "no")))
      (cc-butler-decision-refresh)
      (let* ((file (car (directory-files (cc-butler--decision-open-dir) t cc-butler--decision-org-re)))
             (doc (with-temp-buffer (insert-file-contents file) (buffer-string)))
             (create-lockfiles nil) (kill-buffer-query-functions nil))
        (with-temp-file file (insert (cc-butler-decision-test--fill doc ?A "go")))
        (let ((buf (find-file-noselect file)))
          (unwind-protect (with-current-buffer buf (cc-butler-decision-submit cc-butler-human-agent))
            (ignore-errors (kill-buffer buf)))))
      (cc-butler--mail-file-deliver "정수님"
        '(:id "s2" :kind decision :from "steward" :reply-to "steward"
              :summary "Deploy?" :options ("yes" "no")))
      (should (= 0 (cc-butler-decision-refresh)))
      (should (= 0 (length (directory-files (cc-butler--decision-open-dir) nil cc-butler--decision-org-re)))))))

;;;; ---- read-receipt (`r') ------------------------------------------

(defun cc-butler-decision-test--open-first ()
  "Open the first open/ decision doc in a buffer (no lock files)."
  (let* ((file (car (directory-files (cc-butler--decision-open-dir) t cc-butler--decision-org-re)))
         (create-lockfiles nil))
    (find-file-noselect file)))

(ert-deftest cc-butler-decision/mark-read-note-closes-and-receipts ()
  "`r' on a note: sends a `read' receipt to the sender (correlation) and closes
it (open/ → done/); the indicator decrements."
  (cc-butler-decision-test--with-arrival
    (cl-letf (((symbol-function 'cc-butler--display-name) (lambda (d) d)))
      (cc-butler--mail-file-deliver "정수님"
        '(:id "n1" :kind note :from "steward" :reply-to "steward" :summary "CI green"))
      (cc-butler--decision-on-arrival)
      (let ((buf (cc-butler-decision-test--open-first))
            (kill-buffer-query-functions nil))
        (unwind-protect (with-current-buffer buf (cc-butler-decision-mark-read cc-butler-human-agent))
          (ignore-errors (kill-buffer buf))))
      (let ((r (car (cc-butler--ch-drain "steward"))))
        (should (eq 'read (plist-get r :kind)))
        (should (equal "n1" (plist-get r :in-reply-to)))
        (should (equal "정수님" (plist-get r :from))))
      (should (= 0 (length (directory-files (cc-butler--decision-open-dir) nil cc-butler--decision-org-re))))
      (should (= 1 (length (directory-files (cc-butler--decision-done-dir) nil cc-butler--decision-org-re))))
      (should (equal "" cc-butler--decision-indicator)))))

(ert-deftest cc-butler-decision/mark-read-decision-stays-open ()
  "`r' on a decision: sends a read-receipt but KEEPS it in open/ — only C-c C-c
closes a decision (correctness: an unanswered decision is never lost)."
  (cc-butler-decision-test--with-arrival
    (cl-letf (((symbol-function 'cc-butler--display-name) (lambda (d) d)))
      (cc-butler--mail-file-deliver "정수님"
        '(:id "d1" :kind decision :from "worker-a" :reply-to "worker-a"
              :summary "ship?" :options ("yes" "no")))
      (cc-butler--decision-on-arrival)
      (let ((buf (cc-butler-decision-test--open-first))
            (kill-buffer-query-functions nil))
        (unwind-protect (with-current-buffer buf (cc-butler-decision-mark-read cc-butler-human-agent))
          (ignore-errors (kill-buffer buf))))
      (let ((r (car (cc-butler--ch-drain "worker-a"))))
        (should (eq 'read (plist-get r :kind)))
        (should (equal "d1" (plist-get r :in-reply-to))))
      (should (= 1 (length (directory-files (cc-butler--decision-open-dir) nil cc-butler--decision-org-re))))
      (should (= 0 (length (directory-files (cc-butler--decision-done-dir) nil cc-butler--decision-org-re)))))))

(ert-deftest cc-butler-decision/mark-read-plain-doc-local-only ()
  "`r' on a document with no routing footer sends NO receipt (local read only)."
  (cc-butler-decision-test--with-arrival
    (with-temp-buffer
      (insert "#+TITLE: Dashboard\n* Status\nall green\n")   ; no sender footer
      (cc-butler-decision-mark-read cc-butler-human-agent)
      (should (null (cc-butler--ch-drain "steward")))
      (should (null (cc-butler--ch-drain "worker-a"))))))

(ert-deftest cc-butler-decision/mark-read-refuses-with-no-actor ()
  "A caller that supplies no ACTOR at all is refused before any mutation — the
exact shape of the 2026-09-10 bug: a worker's plain funcall must not
silently become a read-receipt attributed to 정수님.  RED against the
pre-fix code, which hard-coded `:from cc-butler-human-agent' here.  Also
confirms the guard fires before ANY mutation -- the note is neither
receipted nor archived."
  (cc-butler-decision-test--with-arrival
    (cl-letf (((symbol-function 'cc-butler--display-name) (lambda (d) d)))
      (cc-butler--mail-file-deliver "정수님"
        '(:id "n3" :kind note :from "steward" :reply-to "steward"
              :summary "읽기만 하셔도 됩니다 — 새 결정 아니고"))
      (cc-butler--decision-on-arrival)
      (let ((buf (cc-butler-decision-test--open-first))
            (kill-buffer-query-functions nil))
        (unwind-protect
            (with-current-buffer buf
              (should-error (cc-butler-decision-mark-read) :type 'user-error))
          (ignore-errors (kill-buffer buf))))
      ;; no fabricated read-receipt reached steward
      (should (null (cc-butler--ch-drain "steward")))
      ;; refused before any mutation: still open, not archived
      (should (= 1 (length (directory-files (cc-butler--decision-open-dir) nil cc-butler--decision-org-re))))
      (should (= 0 (length (directory-files (cc-butler--decision-done-dir) nil cc-butler--decision-org-re)))))))

(ert-deftest cc-butler-decision/mark-read-honors-explicit-non-human-actor ()
  "A worker that identifies itself explicitly is honest, not forbidden."
  (cc-butler-decision-test--with-arrival
    (cl-letf (((symbol-function 'cc-butler--display-name) (lambda (d) d)))
      (cc-butler--mail-file-deliver "정수님"
        '(:id "n4" :kind note :from "steward" :reply-to "steward" :summary "CI green"))
      (cc-butler--decision-on-arrival)
      (let ((buf (cc-butler-decision-test--open-first))
            (kill-buffer-query-functions nil))
        (unwind-protect (with-current-buffer buf (cc-butler-decision-mark-read "worker-x"))
          (ignore-errors (kill-buffer buf))))
      (let ((r (car (cc-butler--ch-drain "steward"))))
        (should (equal "worker-x" (plist-get r :from)))))))

(ert-deftest cc-butler-decision/mark-read-interactive-dispatch-supplies-human-identity ()
  "A genuine interactive dispatch (`call-interactively') supplies 정수님's
identity automatically via the `interactive' spec, with NO argument at the
call site."
  (cc-butler-decision-test--with-arrival
    (cl-letf (((symbol-function 'cc-butler--display-name) (lambda (d) d)))
      (cc-butler--mail-file-deliver "정수님"
        '(:id "n5" :kind note :from "steward" :reply-to "steward" :summary "CI green"))
      (cc-butler--decision-on-arrival)
      (let ((buf (cc-butler-decision-test--open-first))
            (kill-buffer-query-functions nil))
        (unwind-protect (with-current-buffer buf (call-interactively #'cc-butler-decision-mark-read))
          (ignore-errors (kill-buffer buf))))
      (let ((r (car (cc-butler--ch-drain "steward"))))
        (should (equal "정수님" (plist-get r :from)))))))

;;;; ---- reply notification (poke the escalator, never the butler) ---

(ert-deftest cc-butler-decision/notify-recipient-pokes-non-butler-only ()
  "Delivering an answer wakes the escalator to drain pending_events, but never
the butler (its box stays clean) and never a bad target."
  (let (poked)
    (cl-letf (((symbol-function 'cc-butler--mail-butler-agent) (lambda () "butler"))
              ((symbol-function 'cc-butler--dir-by-name) (lambda (n) (concat "/dir/" n)))
              ((symbol-function 'cc-butler--send-input)
               (lambda (dir &rest _) (push dir poked))))
      (cc-butler--decision-notify-recipient "steward")
      (cc-butler--decision-notify-recipient "butler")   ; skipped (butler)
      (cc-butler--decision-notify-recipient "?")         ; skipped (bad target)
      (should (equal '("/dir/steward") poked)))))

(ert-deftest cc-butler-decision/envelope-header-at-top ()
  "Polish (2): the envelope is an org PROPERTIES drawer (From/To/When/Kind/Re) at
the top of the file, before #+TITLE — the document's own properties, not an
example block."
  (let ((doc (cc-butler--decision-doc-string
              '(:id "20260704T171521-1-0054" :kind decision :from "steward"
                    :reply-to "steward" :summary "test decision" :options ("a")))))
    (should (string-match-p "^:PROPERTIES:$" doc))
    (should (string-match-p "^:From: steward$" doc))
    (should (string-match-p "^:To: 정수님$" doc))
    (should (string-match-p "^:When: 2026-07-04 17:15$" doc))
    (should (string-match-p "^:Kind: decision" doc))
    (should (string-match-p "^:END:$" doc))
    (should-not (string-match-p "begin_example" doc))
    ;; the PROPERTIES drawer is at BOB, before the TITLE (file-level properties)
    (should (< (string-match ":PROPERTIES:" doc) (string-match "#\\+TITLE:" doc)))))

(ert-deftest cc-butler-decision/envelope-from-origin-and-via ()
  "C: From = the ORIGIN (:origin), never the last relayer; Via carries the path."
  (let ((doc (cc-butler--decision-doc-string
              '(:id "20260704T1900-1-1" :kind decision :from "steward" :origin "worker-a"
                    :via ("worker-a" "steward") :reply-to "steward"
                    :summary "x" :options ("a")))))
    (should (string-match-p "^:From: worker-a$" doc))            ; origin, not steward
    (should (string-match-p "^:Via: worker-a → steward$" doc))
    (should-not (string-match-p "^:From: steward$" doc))))

(ert-deftest cc-butler-decision/envelope-fallback-is-descriptive-not-bare-question-mark ()
  "A message with genuinely no sender info at all (:origin and :from both
absent -- e.g. a future caller that forgot to supply one) must not render
the bare `?' fallback, which gives a reader zero signal that anything is
missing at all and could pass for a rendering bug or truncation. The
general fallback must name itself explicitly instead, so both a human
reader and a future maintainer grepping for it can tell this is a system
default meaning nobody supplied a sender."
  (let ((doc (cc-butler--decision-doc-string
              '(:id "x1" :kind note :summary "no sender at all"))))
    (should-not (string-match-p "^:From: \\?$" doc))
    (should (string-match-p "^:From: cc-butler (unidentified sender)$" doc))))

(ert-deftest cc-butler-decision/briefing-renders-readonly ()
  "C: a briefing (up-direction deliverable) renders read-only — Kind=briefing, no
answer region (reply is optional via c)."
  (let ((doc (cc-butler--decision-doc-string
              '(:id "20260704T1901-1-1" :kind briefing :from "worker-a"
                    :origin "worker-a" :summary "shipped feature X"))))
    (should (string-match-p "Briefing" doc))
    (should (string-match-p "^:Kind: briefing" doc))
    (should (string-match-p "shipped feature X" doc))
    (should-not (string-match-p (regexp-quote cc-butler--decision-answer-begin) doc))))

(ert-deftest cc-butler-decision/briefing-create-delivers-up ()
  "C: cc-butler-briefing-create delivers a briefing UP to 정수님's inbox with
From=worker (origin) and the relay-path in :via."
  (let ((cc-butler-mail-dir (make-temp-file "cc-brief" t))
        (cc-butler--channel nil)
        (cc-butler-human-agent "정수님"))
    (unwind-protect
        (cl-letf (((symbol-function 'cc-butler--display-name) (lambda (d) d)))
          (cc-butler-briefing-create "worker-a" "shipped X" '("worker-a" "steward"))
          (let ((m (car (cc-butler--ch-drain "정수님"))))
            (should m)
            (should (eq 'briefing (plist-get m :kind)))
            (should (equal "worker-a" (plist-get m :origin)))
            (should (equal '("worker-a" "steward") (plist-get m :via)))))
      (delete-directory cc-butler-mail-dir t))))

;;;; ---- doc-view operations + hydra (item 3) ------------------------

(ert-deftest cc-butler-decision/confirm-adds-answer-region-to-note ()
  "`c' on a read-only note adds an answer region so it can be replied to."
  (with-temp-buffer
    (insert (cc-butler--decision-doc-string
             '(:id "n1" :kind note :from "steward" :reply-to "steward" :summary "FYI")))
    (should-not (cc-butler--decision-answer-bounds))
    (cc-butler-decision-confirm)
    (should (cc-butler--decision-answer-bounds))))

(ert-deftest cc-butler-decision/keys-bound ()
  "The unified scheme + hydra are bound in the decision keymap."
  (dolist (k '("r" "c" "k" "n" "p" "g" "q" "?"))
    (should (commandp (lookup-key cc-butler-decision-mode-map k))))
  ;; v = reopen (cross-module; assert the binding symbol, not commandp)
  (should (eq (lookup-key cc-butler-decision-mode-map "v") #'cc-butler-doc-reopen))
  ;; surface model (b): the reader is answer-only — n/p move the cursor, they do
  ;; NOT navigate decisions (that was the n-leak source)
  (should (eq (lookup-key cc-butler-decision-mode-map "n") #'next-line))
  (should (eq (lookup-key cc-butler-decision-mode-map "p") #'previous-line))
  ;; polish (1): u returns to the inbox list from the reader
  (should (eq (lookup-key cc-butler-decision-mode-map "u") #'cc-butler-decision-to-inbox))
  ;; polish (3): C-c C-c is the conventional submit in the compose buffer
  (should (eq (lookup-key cc-butler-compose-mode-map (kbd "C-c C-c"))
              #'cc-butler-decision-compose-commit))
  (should (eq (lookup-key cc-butler-decision-mode-map "r") #'cc-butler-decision-mark-read))
  (should (eq (lookup-key cc-butler-decision-mode-map "?") #'cc-butler-decision-hydra/body))
  (should (fboundp 'cc-butler-decision-hydra/body)))

;;;; ---- compose safety (data-loss guard) ----------------------------

(ert-deftest cc-butler-decision/compose-region-types-command-letters ()
  "In the answer region the bare command letters TYPE (self-insert), so an
answer containing r/c/k/… is never eaten as a command (data-loss guard);
outside, in the read-only decision text, they remain commands."
  (with-temp-buffer
    (insert (cc-butler--decision-doc-string cc-butler-decision-test--msg))
    (cc-butler-decision-mode 1)
    (let ((bounds (cc-butler--decision-answer-bounds)))
      (should bounds)
      (should (eq #'self-insert-command (key-binding "k" nil nil (car bounds))))
      (should (eq #'self-insert-command (key-binding "r" nil nil (car bounds))))
      (should (eq #'self-insert-command (key-binding "q" nil nil (car bounds))))
      ;; C-c C-c still submits from inside the answer region
      (should (eq #'cc-butler-decision-submit (key-binding (kbd "C-c C-c") nil nil (car bounds))))
      ;; outside the region, the letters are commands
      (should (eq #'cc-butler-decision-quit (key-binding "k" nil nil (point-min)))))))

(ert-deftest cc-butler-decision/mode-line-signals-mode ()
  "Guarantee 7 visibility: the lighter shows compose when point is in the answer
region, command otherwise — so the current mode is always visible."
  (with-temp-buffer
    (insert (cc-butler--decision-doc-string cc-butler-decision-test--msg))
    (cc-butler-decision-mode 1)
    (let ((b (cc-butler--decision-answer-bounds)))
      (goto-char (car b))
      (should (string-match-p "compose" (cc-butler--decision-mode-lighter)))
      (goto-char (point-min))
      (should (string-match-p "cmd" (cc-butler--decision-mode-lighter))))))

(ert-deftest cc-butler-decision/compose-commit-writes-back-and-sends ()
  "Dedicated-buffer compose (4b): committing writes the composed answer back into
the decision's answer region AND sends it (record + channel push) in one step;
the doc is archived out of the queue.  Faithful: assert the routed reply + state."
  (cc-butler-decision-test--with-arrival
    (cl-letf (((symbol-function 'cc-butler--display-name) (lambda (d) d)))
      (cc-butler--decision-render
       '(:id "cc1" :kind decision :from "worker-a" :reply-to "worker-a"
             :summary "ship?" :options ("yes" "no")))
      (let* ((file (car (directory-files (cc-butler--decision-open-dir) t cc-butler--decision-org-re)))
             (create-lockfiles nil) (kill-buffer-query-functions nil)
             (src (find-file-noselect file)))
        (with-current-buffer src (cc-butler-decision-mode 1))
        (let* ((bounds (with-current-buffer src (cc-butler--decision-answer-bounds)))
               (content (with-current-buffer src
                          (buffer-substring-no-properties (car bounds) (cdr bounds))))
               (composed (with-temp-buffer
                           (insert content)
                           (goto-char (point-min))
                           (when (re-search-forward "^- \\[ \\] A" nil t) (replace-match "- [X] A"))
                           (goto-char (point-min))
                           (when (re-search-forward "^Other:[ \t]*$" nil t) (replace-match "Other: compose-ok"))
                           (buffer-string))))
          (cc-butler--compose-writeback src composed)
          (with-current-buffer src (cc-butler-decision-submit cc-butler-human-agent))
          (ignore-errors (kill-buffer src)))
        (let ((r (car (cc-butler--ch-drain "worker-a"))))
          (should (eq 'reply (plist-get r :kind)))
          (should (string-match-p "yes" (plist-get r :body)))
          (should (string-match-p "compose-ok" (plist-get r :body))))
        (should (= 0 (length (directory-files (cc-butler--decision-open-dir) nil cc-butler--decision-org-re))))))))

(ert-deftest cc-butler-decision/answer-ccs-the-butler ()
  "Butler coherence: 정수님's answer routes DIRECT to the asker AND CCs a terse
receipt to the butler (visibility, not a routing hop)."
  (let ((cc-butler-decision-dir (make-temp-file "cc-cc" t))
        (cc-butler-mail-dir (make-temp-file "cc-ccm" t))
        (cc-butler--channel nil)
        (cc-butler-human-agent "정수님"))
    (unwind-protect
        (cl-letf (((symbol-function 'cc-butler--display-name) (lambda (d) d))
                  ((symbol-function 'cc-butler--mail-butler-agent) (lambda () "butler"))
                  ((symbol-function 'cc-butler--decision-notify-recipient) #'ignore))
          (cc-butler--decision-render
           '(:id "cc1" :kind decision :from "worker-a" :reply-to "worker-a"
                 :summary "ship?" :options ("yes" "no")))
          (let* ((file (car (directory-files (cc-butler--decision-open-dir) t cc-butler--decision-org-re)))
                 (create-lockfiles nil) (kill-buffer-query-functions nil)
                 (src (find-file-noselect file)))
            (with-current-buffer src (cc-butler-decision-mode 1))
            (let* ((bounds (with-current-buffer src (cc-butler--decision-answer-bounds)))
                   (content (with-current-buffer src
                              (buffer-substring-no-properties (car bounds) (cdr bounds))))
                   (composed (with-temp-buffer (insert content) (goto-char (point-min))
                               (when (re-search-forward "^- \\[ \\] A" nil t) (replace-match "- [X] A"))
                               (buffer-string))))
              (cc-butler--compose-writeback src composed)
              (with-current-buffer src (cc-butler-decision-submit cc-butler-human-agent))
              (ignore-errors (kill-buffer src))))
          (should (cc-butler--ch-drain "worker-a"))          ; asker got the direct reply
          (let ((b (car (cc-butler--ch-drain "butler"))))    ; butler got a receipt CC
            (should b)
            (should (eq 'receipt (plist-get b :kind)))
            (should (string-match-p "정수님 answered" (plist-get b :body)))))
      (delete-directory cc-butler-decision-dir t)
      (delete-directory cc-butler-mail-dir t))))

(ert-deftest cc-butler-decision/arrival-ccs-the-butler ()
  "Butler coherence: a decision arriving in 정수님's inbox CCs a pending receipt
to the butler so it knows what awaits 정수님."
  (let ((cc-butler-decision-dir (make-temp-file "cc-ar" t))
        (cc-butler-mail-dir (make-temp-file "cc-arm" t))
        (cc-butler--channel nil)
        (cc-butler-decision-auto-display nil)
        (cc-butler-human-agent "정수님"))
    (unwind-protect
        (cl-letf (((symbol-function 'cc-butler--mail-butler-agent) (lambda () "butler")))
          (cc-butler--ch-deliver
           "정수님" '(:id "a1" :kind decision :from "s" :reply-to "s" :summary "ship it?"))
          (cc-butler--decision-on-arrival)
          (let ((b (car (cc-butler--ch-drain "butler"))))
            (should b)
            (should (string-match-p "Pending for 정수님" (plist-get b :body)))
            (should (string-match-p "ship it?" (plist-get b :body)))))
      (delete-directory cc-butler-decision-dir t)
      (delete-directory cc-butler-mail-dir t))))

(ert-deftest cc-butler-decision/arrival-pushes-notification ()
  "Butler-away root fix: a decision ARRIVING actively PUSHES a notification (the
always-on daemon's job) carrying the decision summary — not just a passive badge
that a sleeping butler agent can't surface."
  (let ((cc-butler-decision-dir (make-temp-file "cc-push" t))
        (cc-butler-mail-dir (make-temp-file "cc-pushm" t))
        (cc-butler--channel nil)
        (cc-butler-decision-auto-display nil)
        (cc-butler-human-agent "정수님")
        (pushed nil))
    (unwind-protect
        (cl-letf (((symbol-function 'cc-butler--mail-butler-agent) (lambda () "butler"))
                  ((symbol-function 'cc-butler-notify-decision)
                   (lambda (title body) (setq pushed (cons title body)))))
          (cc-butler--ch-deliver
           "정수님" '(:id "p1" :kind decision :from "s" :reply-to "s"
                      :summary "Ship the flow to staging?"))
          (cc-butler--decision-on-arrival)
          (should pushed)
          (should (string-match-p "Ship the flow to staging" (cdr pushed))))
      (delete-directory cc-butler-decision-dir t)
      (delete-directory cc-butler-mail-dir t))))

;;;; ---- demo (staged, isolated, reversible) -------------------------

(ert-deftest cc-butler-decision/demo-roundtrip ()
  "The staged demo renders a decision + indicator; submitting routes the answer
and auto-restores every setting (nothing leaks)."
  (let ((orig-mail cc-butler-mail-dir)
        (orig-dec cc-butler-decision-dir)
        (orig-human cc-butler-human-agent)
        (cc-butler-message-transport 'in-memory)
        (cc-butler--decision-watch nil)
        (cc-butler--channel nil)
        (cc-butler-decision-auto-display nil))   ; no side-window in batch
    (unwind-protect
        (progn
          (cc-butler-decision-demo)
          (should cc-butler--decision-demo-state)
          ;; §③: the demo delivers a decision AND a note — both land in open/,
          ;; but only the decision is answer-required, so the ⚖ count is 1, not 2.
          (should (= 2 (length (directory-files (cc-butler--decision-open-dir) nil "\\`[^.].*\\.org\\'"))))
          (should (string-match-p "⚖1" cc-butler--decision-indicator))
          ;; the decision (demo-1) sorts before the note (demo-note); answer it
          (let* ((file (car (directory-files (cc-butler--decision-open-dir) t "\\`[^.].*\\.org\\'")))
                 (doc (with-temp-buffer (insert-file-contents file) (buffer-string)))
                 (kill-buffer-query-functions nil))
            ;; drop any buffer the demo's display opened (stale), then fill fresh
            (when-let ((b (get-file-buffer file))) (kill-buffer b))
            (with-temp-file file
              (insert (cc-butler-decision-test--fill doc ?A "sandbox")))
            (let ((buf (find-file-noselect file)))
              (unwind-protect (with-current-buffer buf (cc-butler-decision-submit cc-butler-human-agent))
                (kill-buffer buf))))
          ;; the after-submit hook fired demo-result → demo-end restored settings
          (should (null cc-butler--decision-demo-state))
          (should (equal orig-mail cc-butler-mail-dir))
          (should (equal orig-dec cc-butler-decision-dir)))
      (when cc-butler--decision-demo-state (cc-butler-decision-demo-end))
      (setq cc-butler-mail-dir orig-mail
            cc-butler-decision-dir orig-dec
            cc-butler-human-agent orig-human))))

;;;; ---- close-with-reason: reuse without fabricating an answer -------
;;
;; `cc-butler-decision-close-with-reason' closes a Kind=decision item through a
;; channel OTHER than a real `C-c C-c' answer, for one of four reasons (①-④,
;; see its docstring), without ever fabricating a "정수님 answered: ..."
;; message under his identity.  No mock channel is needed here — unlike
;; `cc-butler-decision-submit', this function never delivers anything; it only
;; annotates the file and (for three of the four reasons) archives it.

(defmacro cc-butler-decision-test--with-file (msg &rest body)
  "Render MSG to open/ under a fresh, throwaway `cc-butler-decision-dir'; run
BODY with `file' bound to its path and as the current buffer (`buf'
visiting it), then clean up."
  (declare (indent 1))
  `(let* ((cc-butler-decision-dir (make-temp-file "cc-butler-dec-test" t))
          (file (cc-butler--decision-render ,msg))
          (buf (find-file-noselect file)))
     (unwind-protect
         (with-current-buffer buf ,@body)
       (when (buffer-live-p buf) (kill-buffer buf))
       (delete-directory cc-butler-decision-dir t))))

(ert-deftest cc-butler-decision/close-with-reason-archiving-reasons-archive-and-exclude ()
  "Each of the three archiving reasons (`answered', `not-a-question',
`our-side') actually archives open/ → done/, and the backlog counter
\(`cc-butler--decision-open-files-and-oldest') excludes the result -- the
SAME way an answered decision or a read note already disappears from the
backlog today -- with no fabricated answer sent anywhere."
  (dolist (reason '(answered not-a-question our-side))
    (cc-butler-decision-test--with-file cc-butler-decision-test--msg
      (cl-letf (((symbol-function 'cc-butler--log) #'ignore))
        (cc-butler-decision-close-with-reason reason (format "evidence for %s" reason)))
      (should (null (car (cc-butler--decision-open-files-and-oldest))))
      (should (= 1 (length (directory-files (cc-butler--decision-done-dir)
                                            nil "\\`[^.].*\\.org\\'")))))))

(ert-deftest cc-butler-decision/close-with-reason-pending-evidence-stays-open-and-counted ()
  "REASON `pending-evidence' must NOT look closed: this is the trap the steward
explicitly flagged.  The file stays in open/, still `decision'-kind by
filename, and `cc-butler--decision-open-files-and-oldest' STILL counts it --
hiding \"we don't know\" as \"done\" would recreate the exact fake-backlog
bug this function exists to close, in a worse form."
  (cc-butler-decision-test--with-file cc-butler-decision-test--msg
    (cl-letf (((symbol-function 'cc-butler--log) #'ignore))
      (cc-butler-decision-close-with-reason
       'pending-evidence "answer may be in an untranscribed voice message"))
    (let ((files (car (cc-butler--decision-open-files-and-oldest))))
      (should (= 1 (length files)))
      (should (equal (file-name-nondirectory file) (car files))))
    (should (= 1 (length (directory-files (cc-butler--decision-open-dir)
                                          nil "\\`[^.].*\\.org\\'"))))
    (should (null (directory-files (cc-butler--decision-done-dir)
                                   nil "\\`[^.].*\\.org\\'")))))

(ert-deftest cc-butler-decision/close-with-reason-note-text-survives-archived ()
  "The reason+note are actually readable in the archived file's content, in
the `stale/INDEX.md' reconciliation-comment shape -- not thrown away."
  (cc-butler-decision-test--with-file cc-butler-decision-test--msg
    (cl-letf (((symbol-function 'cc-butler--log) #'ignore))
      (cc-butler-decision-close-with-reason 'our-side "item 2907 replaced this one"))
    (let* ((done-file (car (directory-files (cc-butler--decision-done-dir) t
                                            "\\`[^.].*\\.org\\'")))
           (content (with-temp-buffer (insert-file-contents done-file) (buffer-string))))
      (should (string-match-p "item 2907 replaced this one" content))
      (should (string-match-p "our-side" content))
      (should (string-match-p "# --- reconciled:" content))
      (should (string-match-p "# done —" content)))))

(ert-deftest cc-butler-decision/close-with-reason-note-text-survives-pending ()
  "Same for `pending-evidence' -- the note is written even though nothing
archives, and it is marked distinctly (no `# done —' line: it isn't done)."
  (cc-butler-decision-test--with-file cc-butler-decision-test--msg
    (cl-letf (((symbol-function 'cc-butler--log) #'ignore))
      (cc-butler-decision-close-with-reason 'pending-evidence "voice message untranscribed"))
    (let ((content (buffer-string)))
      (should (string-match-p "voice message untranscribed" content))
      (should (string-match-p "# --- pending-evidence:" content))
      (should-not (string-match-p "# done —" content)))))

(ert-deftest cc-butler-decision/close-with-reason-refuses-bad-reason ()
  "An invalid REASON symbol is refused before any mutation -- no comment
inserted, nothing archived."
  (cc-butler-decision-test--with-file cc-butler-decision-test--msg
    (should-error (cc-butler-decision-close-with-reason 'maybe "some note"))
    (should (= 1 (length (directory-files (cc-butler--decision-open-dir)
                                          nil "\\`[^.].*\\.org\\'"))))
    (should (null (directory-files (cc-butler--decision-done-dir)
                                   nil "\\`[^.].*\\.org\\'")))
    (should-not (string-match-p "reconciled\\|pending-evidence" (buffer-string)))))

(ert-deftest cc-butler-decision/close-with-reason-refuses-empty-note ()
  "An empty/blank NOTE is refused -- closing needs evidence, not a bare reason
-- and nothing is mutated."
  (cc-butler-decision-test--with-file cc-butler-decision-test--msg
    (should-error (cc-butler-decision-close-with-reason 'answered "   "))
    (should (= 1 (length (directory-files (cc-butler--decision-open-dir)
                                          nil "\\`[^.].*\\.org\\'"))))
    (should (null (directory-files (cc-butler--decision-done-dir)
                                   nil "\\`[^.].*\\.org\\'")))))

(ert-deftest cc-butler-decision/close-with-reason-refuses-missing-file ()
  "Refuses cleanly when the buffer isn't visiting an existing decision-queue
file."
  (with-temp-buffer
    (should-error (cc-butler-decision-close-with-reason 'answered "evidence"))))

(provide 'cc-butler-decision-test)
;;; cc-butler-decision-test.el ends here
