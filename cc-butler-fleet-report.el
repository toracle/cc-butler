;;; cc-butler-fleet-report.el --- daily fleet-utilization report  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jeongsoo Park
;; SPDX-License-Identifier: MIT

;; Implements design-fleet-utilization-2026-09-08.md: a daily snapshot of
;; North Star goal state + live worker fleet-status, a diff against the
;; most recent prior snapshot, and a fixed-shape report render.  See that
;; document for the rationale; this file implements it, not re-derives it.

(require 'cc-butler-session)
(require 'cc-butler-orchestrator)
(require 'cc-butler-docs)
(require 'cc-butler-north-star)
(require 'subr-x)
(require 'seq)

;;;; ------------------------------------------------------------------
;;;; North Star org parser (design §3) — READ-ONLY
;;;; ------------------------------------------------------------------
;;
;; Never calls a write-path function on the file it is given -- only
;; `insert-file-contents' into a throwaway temp buffer -- so pointing it at
;; the real, shared north-star-x600.org (the real-file probe test) cannot
;; write to it, by construction rather than by care.

(defconst cc-butler-fleet-report--unowned-markers '("무인" "미배정")
  "Clean explicit-unowned :OWNER: values -- never counted as \"annotated\"
even though they are not a bare slug either (design §0-3).")

(defun cc-butler-fleet-report--active-status-p (status-raw)
  "Non-nil when STATUS-RAW's first word is literally \"active\" (design's
:STATUS: active convention). A following dash/paren/space all count as a
word boundary, so \"active — ...\" and \"active (...\" both match; \"진행
중\" does not."
  (and (string-match-p "\\`active\\_>" (string-trim (or status-raw ""))) t))

(defun cc-butler-fleet-report--owner-slug (owner-trimmed)
  "The leading ASCII slug-like token in OWNER-TRIMMED, for matching against
worker session names -- never the raw annotated text (design §0-3)."
  (cond
   ((member owner-trimmed cc-butler-fleet-report--unowned-markers) nil)
   ((string-empty-p owner-trimmed) nil)
   ((string-match "[A-Za-z][A-Za-z0-9_-]*" owner-trimmed) (match-string 0 owner-trimmed))
   (t nil)))

(defun cc-butler-fleet-report--owner-annotated-p (owner-trimmed)
  "Non-nil when OWNER-TRIMMED is not just a bare slug or an explicit
unowned marker -- i.e. someone has annotated the :OWNER: value (design
§0-3). The machine never interprets the annotation text, only counts
that one exists."
  (and (not (string-empty-p owner-trimmed))
       (not (member owner-trimmed cc-butler-fleet-report--unowned-markers))
       (not (string-match-p "\\`[A-Za-z0-9_-]+\\'" owner-trimmed))))

(defun cc-butler-fleet-report--parse-drawer (lines)
  "LINES are the raw lines strictly between :PROPERTIES: and :END:.  Return
an alist of (PROP-NAME . VALUE), each VALUE the concatenation of its own
line plus any wrapped continuation lines (joined with a single space,
trimmed) -- property values in this file routinely wrap across lines with
no continuation marker (e.g. the OWNER value at north-star-x600.org:151-156),
so a single-line read would silently truncate exactly the annotated values
design §0-3 needs to see in full."
  (let (props cur-name cur-parts)
    (dolist (line lines)
      (if (string-match "\\`\\s-*:\\([A-Za-z_]+\\):\\s-?\\(.*\\)\\'" line)
          (progn
            (when cur-name
              (push (cons cur-name (string-trim (mapconcat #'identity (nreverse cur-parts) " ")))
                    props))
            (setq cur-name (match-string 1 line))
            (setq cur-parts (list (match-string 2 line))))
        (when cur-name (push (string-trim line) cur-parts))))
    (when cur-name
      (push (cons cur-name (string-trim (mapconcat #'identity (nreverse cur-parts) " ")))
            props))
    (nreverse props)))

(defun cc-butler-fleet-report--parse-north-star (file)
  "Parse FILE (a North Star org file, design §3) into a list of goal
plists: (:id :status :active-p :dod-text :dod-hash :owner-slug
:owner-annotated-p). Only level-1 `* ' headings become goals -- a nested
`** ' heading is body structure within a goal, not a new goal, and the
heading regexp below (`\\`\\* ') does not match it."
  (when (file-readable-p file)
    (let* ((lines (with-temp-buffer
                    (insert-file-contents file)
                    (split-string (buffer-string) "\n")))
           (n (length lines))
           (i 0)
           goals)
      (while (< i n)
        (let ((line (nth i lines)))
          (when (string-match "\\`\\* \\(.+\\)\\'" line)
            (let* ((id (string-trim (match-string 1 line)))
                   (drawer-start (1+ i))
                   props)
              (when (and (< drawer-start n)
                         (string-match-p "\\`\\s-*:PROPERTIES:\\s-*\\'" (nth drawer-start lines)))
                (let ((j (1+ drawer-start)) body)
                  (while (and (< j n)
                              (not (string-match-p "\\`\\s-*:END:\\s-*\\'" (nth j lines))))
                    (push (nth j lines) body)
                    (setq j (1+ j)))
                  (setq props (cc-butler-fleet-report--parse-drawer (nreverse body)))))
              (let* ((status-raw (or (cdr (assoc "STATUS" props)) ""))
                     (dod-raw (or (cdr (assoc "DOD" props)) ""))
                     (owner-trimmed (string-trim (or (cdr (assoc "OWNER" props)) ""))))
                (push (list :id id
                            :status status-raw
                            :active-p (cc-butler-fleet-report--active-status-p status-raw)
                            :dod-text dod-raw
                            :dod-hash (secure-hash 'md5 dod-raw)
                            :owner-slug (cc-butler-fleet-report--owner-slug owner-trimmed)
                            :owner-annotated-p (cc-butler-fleet-report--owner-annotated-p owner-trimmed))
                      goals))))
          (setq i (1+ i))))
      (nreverse goals))))

;;;; ------------------------------------------------------------------
;;;; Daily snapshot — path, write, read (design §3)
;;;; ------------------------------------------------------------------

(defcustom cc-butler-fleet-report-snapshot-subdir "fleet-snapshot/"
  "Subdirectory of the butler docs dir holding daily fleet snapshots."
  :type 'string
  :group 'cc-butler)

(defun cc-butler-fleet-report--snapshot-dir ()
  "Return the snapshot directory, or nil when no butler is designated --
mirrors `cc-butler-docs--log-dir'."
  (when-let ((docs (cc-butler-docs--docs-dir)))
    (file-name-as-directory
     (expand-file-name cc-butler-fleet-report-snapshot-subdir docs))))

(defun cc-butler-fleet-report--snapshot-file (date)
  "Return the snapshot file path for DATE (\"YYYY-MM-DD\"), or nil."
  (when-let ((dir (cc-butler-fleet-report--snapshot-dir)))
    (expand-file-name (concat date ".eld") dir)))

(defun cc-butler-fleet-report--write-snapshot (snapshot file)
  "Write SNAPSHOT (a plist, design §3) to FILE as `prin1'-readable text."
  (with-file-modes #o700 (make-directory (file-name-directory file) t))
  (with-file-modes #o600
    (write-region (concat (prin1-to-string snapshot) "\n") nil file nil 'silent))
  file)

(defun cc-butler-fleet-report--read-snapshot (file)
  "Read the snapshot plist at FILE, or nil when it does not exist."
  (when (and file (file-readable-p file))
    (with-temp-buffer
      (insert-file-contents file)
      (read (current-buffer)))))

(defun cc-butler-fleet-report--previous-snapshot-file (date)
  "Return the path of the most recent snapshot strictly before DATE
(\"YYYY-MM-DD\"), or nil when there is none -- the diff baseline (design §4)."
  (when-let ((dir (cc-butler-fleet-report--snapshot-dir)))
    (when (file-directory-p dir)
      (let ((dates (sort
                    (seq-filter
                     (lambda (d) (string< d date))
                     (mapcar #'file-name-sans-extension
                             (directory-files dir nil "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\.eld\\'")))
                    #'string>)))
        (when dates (cc-butler-fleet-report--snapshot-file (car dates)))))))

;;;; ------------------------------------------------------------------
;;;; Worker rows (design §3 / §9 — live sessions, butler+steward excluded)
;;;; ------------------------------------------------------------------

(defun cc-butler-fleet-report--worker-rows (goals)
  "Snapshot worker rows for every live session except the butler and the
steward -- those are roles, not dispatched workers (design §9). GOALS is
the current (rich) goal-plist list, used only to fill :attached-goal-id by
matching each worker's own name against a goal's `:owner-slug' -- the
machine's computation, never the worker's self-report (design §0-4)."
  (let (rows)
    (dolist (s (cc-butler--sessions))
      (let ((dir (plist-get s :dir)))
        (unless (or (equal dir cc-butler--butler) (equal dir cc-butler--steward))
          (let* ((name (cc-butler--display-name dir))
                 (fleet-status (plist-get (cc-butler--meta-get dir) :fleet-status))
                 (goal (seq-find (lambda (g) (equal (plist-get g :owner-slug) name)) goals)))
            (push (list :name name
                        :fleet-status fleet-status
                        :attached-goal-id (and goal (plist-get goal :id)))
                  rows)))))
    (nreverse rows)))

;;;; ------------------------------------------------------------------
;;;; Diff engine (design §4) + dispatch/reclassify split (design §5)
;;;; ------------------------------------------------------------------

(defconst cc-butler-fleet-report--waste-fleet-statuses '("배차 대기" "목표 소진")
  "fleet-status values §5 treats as the \"waiting to be resolved\" pair.")

(defun cc-butler-fleet-report--by-id (goals id)
  (seq-find (lambda (g) (equal (plist-get g :id) id)) goals))

(defun cc-butler-fleet-report--by-name (workers name)
  (seq-find (lambda (w) (equal (plist-get w :name) name)) workers))

(defun cc-butler-fleet-report--dispatch-entry-p (log-text name)
  "Non-nil if today's LOG-TEXT (docs/log/YYYY-MM-DD.org contents, or nil)
carries a dispatch-natured entry mentioning session NAME. `butler_log' has
no separate \"dispatch\" :kind: of its own (its kinds are
event/decision/progress/note -- see `cc-butler-tool-log'), so \"dispatch
성격\" (design §5) is a quality of the entry TEXT, not a tag: this looks
for the fleet's own dispatch vocabulary (\"배차\") co-occurring with NAME
in the same log heading, rather than inventing a new log format."
  (and log-text name
       (let ((entries (split-string log-text "^\\* " t)))
         (and (seq-some (lambda (e) (and (string-match-p (regexp-quote name) e)
                                         (string-match-p "배차" e)))
                        entries)
              t))))

(defun cc-butler-fleet-report--diff (prev curr today-log-text)
  "Compute the three \"count-moving-edit\" categories (design §4) plus the
dispatch/reclassify resolved-split (§5) between PREV and CURR snapshot
plists. PREV may be nil (no prior snapshot yet -- first run).
TODAY-LOG-TEXT is the raw text of today's docs/log/YYYY-MM-DD.org (or nil),
consulted only for the resolved-split."
  (if (null prev)
      (list :no-baseline t :goal-edits nil :worker-reclass nil :owner-changes nil)
    (let* ((prev-goals (plist-get prev :goals)) (curr-goals (plist-get curr :goals))
           (prev-workers (plist-get prev :workers)) (curr-workers (plist-get curr :workers))
           (prev-ids (mapcar (lambda (g) (plist-get g :id)) prev-goals))
           (curr-ids (mapcar (lambda (g) (plist-get g :id)) curr-goals))
           (added (seq-difference curr-ids prev-ids))
           (removed (seq-difference prev-ids curr-ids))
           (kept (seq-intersection curr-ids prev-ids))
           (dod-changed
            (seq-filter
             (lambda (id) (not (equal (plist-get (cc-butler-fleet-report--by-id prev-goals id) :dod-hash)
                                      (plist-get (cc-butler-fleet-report--by-id curr-goals id) :dod-hash))))
             kept))
           (owner-changed
            (seq-filter
             (lambda (id) (not (equal (plist-get (cc-butler-fleet-report--by-id prev-goals id) :owner-slug)
                                      (plist-get (cc-butler-fleet-report--by-id curr-goals id) :owner-slug))))
             kept))
           (prev-names (mapcar (lambda (w) (plist-get w :name)) prev-workers))
           (curr-names (mapcar (lambda (w) (plist-get w :name)) curr-workers))
           (both-names (seq-intersection curr-names prev-names))
           (reclassified
            (seq-filter
             (lambda (name)
               (not (equal (plist-get (cc-butler-fleet-report--by-name prev-workers name) :fleet-status)
                           (plist-get (cc-butler-fleet-report--by-name curr-workers name) :fleet-status))))
             both-names))
           (resolved
            (seq-filter
             (lambda (name)
               (member (plist-get (cc-butler-fleet-report--by-name prev-workers name) :fleet-status)
                       cc-butler-fleet-report--waste-fleet-statuses))
             reclassified))
           (dispatch-resolved
            (seq-filter (lambda (name) (cc-butler-fleet-report--dispatch-entry-p today-log-text name))
                        resolved))
           (reclass-resolved (seq-difference resolved dispatch-resolved)))
      (list :no-baseline nil
            :goal-edits (list :added added :removed removed :dod-changed dod-changed
                              :count (+ (length added) (length removed) (length dod-changed)))
            :worker-reclass (list :names reclassified :count (length reclassified)
                                  :dispatch-resolved (length dispatch-resolved)
                                  :reclass-resolved (length reclass-resolved))
            :owner-changes (list :ids owner-changed :count (length owner-changed))))))

;;;; ------------------------------------------------------------------
;;;; Candidate surfacing (design §0-4 / §6) — visible, never counted
;;;; ------------------------------------------------------------------
;;
;; Live-only: unlike goals/workers, this is never persisted into the
;; snapshot (design §3's minimal schema has no room for raw :status/:osc
;; text, and this signal is not one of §4's three diffed categories) --
;; recomputed fresh from `cc-butler--sessions' on every report run.

(defconst cc-butler-fleet-report--candidate-min-shared-keywords 2
  "Minimum shared keywords (see `cc-butler-fleet-report--keywords') for a
live session's :status/:osc text to surface as a candidate match against
an unowned goal's heading+DoD text (design §0-4). A guess, never proof --
tuned low deliberately since this is explicitly \"a surface for a human to
look at,\" not a precise measurement (design §9 recon note).")

(defun cc-butler-fleet-report--keywords (text)
  "Significant word tokens in TEXT for candidate matching: ASCII
alphanumeric runs (>=3 chars) or Hangul syllable runs (>=2 chars),
lowercased, deduplicated. `cc-butler-governance--keywords' is
English-only by its own docstring (that store's slugs/descriptions are
ASCII by convention); goal and worker text here is mostly Korean prose,
so this tokenizer also keeps Hangul runs rather than reusing that one."
  (let (out)
    (dolist (w (split-string (downcase (or text "")) "[^a-z0-9가-힣]+" t))
      (when (or (>= (length w) 3) (string-match-p "\\`[가-힣][가-힣]+\\'" w))
        (push w out)))
    (delete-dups (nreverse out))))

(defun cc-butler-fleet-report--candidate-names (unowned-goals sessions excluded-dirs)
  "Display-names of live SESSIONS (excluding EXCLUDED-DIRS) whose
:status/:osc text keyword-overlaps any UNOWNED-GOALS's heading+DoD text
enough to be worth a human glance -- a candidate, never asserted as fact,
never folded into any counted bucket (design §0-4/§6)."
  (let (names)
    (dolist (s sessions)
      (let ((dir (plist-get s :dir)))
        (unless (member dir excluded-dirs)
          (let ((wk (cc-butler-fleet-report--keywords
                     (concat (or (plist-get s :status) "") " " (or (plist-get s :osc) "")))))
            (when (seq-some
                   (lambda (g)
                     (>= (length (seq-intersection
                                  wk (cc-butler-fleet-report--keywords
                                      (concat (plist-get g :id) " " (plist-get g :dod-text)))))
                         cc-butler-fleet-report--candidate-min-shared-keywords))
                   unowned-goals)
              (push (cc-butler--display-name dir) names))))))
    (nreverse names)))

;;;; ------------------------------------------------------------------
;;;; Resume-condition-observable heuristic (design §0-5/§6, 2026-09-08 revision)
;;;; ------------------------------------------------------------------
;;
;; Best-effort: (a) an empty status has no resume condition to observe at
;; all; (b) a status that names only generic dispatch/steward language
;; with no specific external artifact (a PR/issue number, an explicit
;; "정수님" reference) is functionally the same -- the real condition
;; lives in the steward's head, not the session's own status (§0-5).
;; Deliberately conservative: text that names neither pattern is left
;; unflagged rather than guessed at, matching this whole feature's
;; "under-count is safe" stance (§0-4) applied to a different axis.

(defun cc-butler-fleet-report--resume-condition-unclear (status-text)
  "Return a one-line reason string when STATUS-TEXT shows no
session-observable resume condition, or nil when it looks fine."
  (let ((s (string-trim (or status-text ""))))
    (cond
     ((string-empty-p s) "재개조건 미기재")
     ((and (string-match-p "배차\\|스튜어드" s)
           (not (string-match-p "#[0-9]+\\|정수님" s)))
      "재개조건이 배차/스튜어드만 가리킴 (구체적 근거 없음)")
     (t nil))))

(defun cc-butler-fleet-report--unclear-resume-candidates (sessions excluded-dirs)
  "(NAME . REASON) pairs for every live SESSION (excluding EXCLUDED-DIRS)
whose fleet-status is neither \"도는 중\" nor \"오프라인\" and whose
free-text :status fails `cc-butler-fleet-report--resume-condition-unclear'
-- design's \"재개조건이 관측 가능하지 않은 세션\" line. Never counted,
never subtracted from any bucket -- this is the steward's own \"who I owe
a wake-up to\" list surfaced for a human, not a judgment on the session."
  (let (out)
    (dolist (s sessions)
      (let ((dir (plist-get s :dir)))
        (unless (member dir excluded-dirs)
          (let ((fs (plist-get (cc-butler--meta-get dir) :fleet-status)))
            (unless (member fs '("도는 중" "오프라인"))
              (let ((reason (cc-butler-fleet-report--resume-condition-unclear
                             (plist-get s :status))))
                (when reason (push (cons (cc-butler--display-name dir) reason) out))))))))
    (nreverse out)))

;;;; ------------------------------------------------------------------
;;;; Report renderer (design §6 — the fixed final template)
;;;; ------------------------------------------------------------------
;;
;; No free-text field anywhere (design §1-4): every 0 sits next to a fixed
;; "what's blocking it" line instead, and the two caveat paragraphs below
;; are reproduced verbatim, unconditionally, every run -- never "this time
;; everything was caught" (§6's own instruction).

(defconst cc-butler-fleet-report--caveat-1
  "⚠ 이 집계는 워커가 자기 상태를 정확히 적었다는 전제 위에 있습니다.
  «자기가 멈춘 줄 모르는 세션»은 이 집계에 «구조적으로» 안 잡힙니다.
  그리고 «세션 없이 일어난 일»도 안 잡힙니다 — 세션으로 세는 집계의 한계입니다.
  둘 다 자동화가 안 되고 따로 세야 합니다.")

(defconst cc-butler-fleet-report--caveat-2
  "⚠ 손으로 센 회차가 하나라도 섞여 있는 동안, 이 지표는 «추세»로 말하지 않습니다.")

(defun cc-butler-fleet-report--diff-section-lines (diff)
  "The \"숫자를 움직인 편집\" block's three sub-lines, given a DIFF plist
from `cc-butler-fleet-report--diff'."
  (if (plist-get diff :no-baseline)
      (list "   목표 수·완료 조건 문안 변경   N/A (기준 스냅샷 없음, 내일부터 diff)"
            "   워커 상태 재분류              N/A (기준 스냅샷 없음, 내일부터 diff)"
            "   북극성 담당 변경              N/A (기준 스냅샷 없음, 내일부터 diff)")
    (let ((edits (plist-get diff :goal-edits))
          (reclass (plist-get diff :worker-reclass))
          (owner (plist-get diff :owner-changes)))
      (list (format "   목표 수·완료 조건 문안 변경   %d건" (plist-get edits :count))
            (format "   워커 상태 재분류              %d건 (배차로 해소 %d / 재분류로 해소 %d)"
                    (plist-get reclass :count)
                    (plist-get reclass :dispatch-resolved)
                    (plist-get reclass :reclass-resolved))
            (format "   북극성 담당 변경              %d건" (plist-get owner :count))))))

(defun cc-butler-fleet-report--render (date goals workers diff candidate-names
                                             unclear-resume &optional progressed-count)
  "Render the fleet-utilization report (design §6) for DATE.
GOALS is the rich goal-plist list from `cc-butler-fleet-report--parse-north-star'.
WORKERS is the worker-row list from `cc-butler-fleet-report--worker-rows'.
DIFF is from `cc-butler-fleet-report--diff'.  CANDIDATE-NAMES and
UNCLEAR-RESUME are from the two \"참고, 안 셈\" surfacing functions.
PROGRESSED-COUNT (default 0) is the one number this device cannot compute
on its own -- \"오늘 실제로 전진한 것\" requires an actual DoD observation
(design §1 layer 2), which is a judgment call left to the caller."
  (let* ((active (seq-filter (lambda (g) (plist-get g :active-p)) goals))
         (owned (seq-filter (lambda (g) (plist-get g :owner-slug)) active))
         (annotated (seq-filter (lambda (g) (plist-get g :owner-annotated-p)) owned))
         (unowned (seq-remove (lambda (g) (plist-get g :owner-slug)) active))
         (worker-count (length workers))
         (attached (seq-filter (lambda (w) (plist-get w :attached-goal-id)) workers))
         (running (seq-filter (lambda (w) (equal (plist-get w :fleet-status) "도는 중")) workers))
         (normal-wait (seq-filter (lambda (w) (member (plist-get w :fleet-status) '("사람 대기" "사건 대기")))
                                  workers))
         (waste-wait (seq-filter (lambda (w) (member (plist-get w :fleet-status)
                                                      cc-butler-fleet-report--waste-fleet-statuses))
                                 workers)))
    (mapconcat
     #'identity
     (append
      (list (format "=== 가동률 — %s (자동 집계 | 손으로 셈) ===" date)
            ""
            (format "북극성 %d개(정본 :STATUS: active 개수)" (length active))
            (format "   오늘 실제로 전진한 것        %d   ← DoD 관측 이동만, \"배차됨/조사중\"은 0"
                    (or progressed-count 0))
            (format "   주인이 붙어 있는 것          %d   ← :OWNER: 슬러그 존재" (length owned))
            (format "     (그중 사람 주석이 붙은 것)  %d   ← 값 해석은 안 함, \"주석이 있다\"는 사실만 셈 — 담당 칸이 낡고 있다는 신호"
                    (length annotated))
            (format "   주인이 없는 것               %d   ← :OWNER: 미배정/무인" (length unowned))
            ""
            (format "워커 %d개(butler/steward 제외 라이브 세션 수)" worker-count)
            (format "   북극성에 붙어 있음           %d   ← owner-slug 일치, 자기신고 아님" (length attached))
            (format "   북극성 아닌 일               %d   ← 유지보수·사고대응·거버넌스"
                    (- worker-count (length attached)))
            (format "   도는 중                      %d" (length running))
            (format "   사람·사건 기다림 (정상)      %d" (length normal-wait))
            (format "   저희 배차 기다림             %d   ← 목표소진 포함, 순수 낭비, 유일하게 변명 없는 줄"
                    (length waste-wait))
            (format "   (참고, 안 셈) 정본에 담당 없이 실질적으로 목표를 하는 것으로 보이는 세션  %d건%s"
                    (length candidate-names)
                    (if candidate-names (concat " — " (string-join candidate-names ", ")) ""))
            "     ⇒ 위 \"북극성에 붙어 있음\"에는 포함하지 않는다. 정본을 고칠 근거로만 보인다."
            (format "   (참고, 안 셈) 재개조건이 관측 가능하지 않은 세션  %d건" (length unclear-resume))
            "     ⇒ status의 재개조건이 비었거나 \"스튜어드 배차\"처럼 남을 가리킴. 세지 않고 명단만 —"
            "       스튜어드가 깨울 책임을 진 목록이고, 길어지면 짐이 쌓이고 있다는 신호(§0-5)")
      (mapcar (lambda (p) (format "     ← %s(%s)" (car p) (cdr p))) unclear-resume)
      (list ""
            "숫자를 움직인 편집 (전일 대비, 기계 탐지 — 첫 회는 기준 스냅샷이 없어 \"분모 표기 불일치\" 자체가 초기 항목)")
      (cc-butler-fleet-report--diff-section-lines diff)
      (list ""
            cc-butler-fleet-report--caveat-1
            ""
            cc-butler-fleet-report--caveat-2))
     "\n")))

;;;; ------------------------------------------------------------------
;;;; MCP tool: generate + persist today's report (design §9)
;;;; ------------------------------------------------------------------
;;
;; Reuses `cc-butler-north-star-file' (already fleet-namespaced, already a
;; defcustom, already pinned to x600 on this machine) rather than
;; introducing a second config knob for the same path -- v1 only wires up
;; this fleet's file, per design §9.

(defun cc-butler-fleet-report--minimal-goals (goals)
  "Project rich GOALS (from `cc-butler-fleet-report--parse-north-star') down
to the persisted snapshot schema (design §3): active goals only, each
reduced to (:id :status :dod-hash :owner-slug) -- no raw DoD/owner text
kept on disk, only what the diff engine needs."
  (mapcar (lambda (g) (list :id (plist-get g :id) :status "active"
                            :dod-hash (plist-get g :dod-hash)
                            :owner-slug (plist-get g :owner-slug)))
          (seq-filter (lambda (g) (plist-get g :active-p)) goals)))

(defun cc-butler-tool-fleet-utilization-report (&optional progressed-count)
  "MCP tool: generate today's fleet-utilization report (design §6), writing
today's snapshot as a side effect (needed as tomorrow's diff baseline).
Read-only for the North Star file and prior snapshots; the only write is
today's own new snapshot file."
  (unless (cc-butler-docs--home)
    (error "No butler designated in the session manager (press `b' on a session)"))
  (unless (cc-butler-fleet-report--snapshot-dir)
    (error "No fleet-snapshot directory resolvable -- no butler designated"))
  (let* ((date (format-time-string "%Y-%m-%d"))
         (goals (cc-butler-fleet-report--parse-north-star cc-butler-north-star-file))
         (unowned-active (seq-remove (lambda (g) (plist-get g :owner-slug))
                                      (seq-filter (lambda (g) (plist-get g :active-p)) goals)))
         (sessions (cc-butler--sessions))
         (excluded (delq nil (list cc-butler--butler cc-butler--steward)))
         (workers (cc-butler-fleet-report--worker-rows goals))
         (curr (list :date date :goals (cc-butler-fleet-report--minimal-goals goals) :workers workers))
         (prev (cc-butler-fleet-report--read-snapshot
                (cc-butler-fleet-report--previous-snapshot-file date)))
         (today-log (let ((f (cc-butler-docs--log-file)))
                      (when (and f (file-readable-p f))
                        (with-temp-buffer (insert-file-contents f) (buffer-string)))))
         (diff (cc-butler-fleet-report--diff prev curr today-log))
         (candidates (cc-butler-fleet-report--candidate-names unowned-active sessions excluded))
         (unclear (cc-butler-fleet-report--unclear-resume-candidates sessions excluded))
         (report (cc-butler-fleet-report--render date goals workers diff candidates unclear
                                                  progressed-count)))
    (cc-butler-fleet-report--write-snapshot curr (cc-butler-fleet-report--snapshot-file date))
    report))

;; Idempotent (re)registration.
(setq claude-code-ide-mcp-server-tools
      (seq-remove
       (lambda (spec)
         (equal "fleet_utilization_report"
                (plist-get (claude-code-ide--normalize-tool-spec spec) :name)))
       claude-code-ide-mcp-server-tools))

(claude-code-ide-make-tool
 :function #'cc-butler-tool-fleet-utilization-report
 :name "fleet_utilization_report"
 :description "Generate today's fleet-utilization report (design-fleet-utilization-2026-09-08.md): North Star goal counts (from the org file's own :STATUS: active / :OWNER: / :DOD: properties, never self-reported), live worker fleet-status counts (butler/steward excluded), a machine diff against the most recent prior daily snapshot, and two fixed caveat paragraphs that never disappear. Writes today's own snapshot as a side effect (tomorrow's diff needs it) but never writes the North Star file or any prior snapshot. The one number this tool cannot compute itself is \"오늘 실제로 전진한 것\" (goals that actually progressed by DoD observation today, not by label) -- supply it yourself after checking the North Star file, or omit it to render 0."
 :args '((:name "progressed_count"
                :type integer
                :description "How many active goals genuinely progressed today by DoD observation (not by session label). Optional; omit to render 0 -- this tool has no way to judge DoD progress on its own."
                :optional t)))

(provide 'cc-butler-fleet-report)
;;; cc-butler-fleet-report.el ends here
