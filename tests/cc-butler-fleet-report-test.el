;;; cc-butler-fleet-report-test.el --- tests for the fleet-utilization report  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jeongsoo Park
;; SPDX-License-Identifier: MIT

;;   emacs -Q --batch -L . -l ert -l tests/cc-butler-fleet-report-test.el \
;;     -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'cl-lib)
(require 'cc-butler)
(require 'cc-butler-fleet-report)

;;;; ------------------------------------------------------------------
;;;; North Star org parser
;;;; ------------------------------------------------------------------

(defmacro cc-butler-fleet-report-test--with-org-file (content &rest body)
  "Write CONTENT to a temp file, bind it to `file', run BODY, then delete it."
  (declare (indent 1))
  `(let ((file (make-temp-file "fleet-report-nstar" nil ".org" ,content)))
     (unwind-protect (progn ,@body)
       (delete-file file))))

(defconst cc-butler-fleet-report-test--sample-org
  "* 스케줄 실행의 헤들리스 완주
  :PROPERTIES:
  :OWNER: monocle-16-scheduler
  :STATUS: active — ★ 오너 실사용 관측 확보(2026-08-24)
          두 번째 줄까지 이어지는 상태 문안.
  :DOD: 스테이징 monocle에서 스케줄 실행이 조용히 거짓 성공 처리되지 않는다.
  :END:

  자유 텍스트 본문, 파싱 대상 아님.

* DB-MCP 툴서버 기반 동작
  :PROPERTIES:
  :OWNER: 🔴 **명목상 monocle-ms365-mcp — 실질 «휴면»** 〔09-08 03:1x 실측〕. 그 세션은
          다른 축에 파킹돼 있다.
  :STATUS: active (2026-08-25 신설)
  :DOD: DB-MCP 쿼리 실행이 툴서버를 경유해 동작한다.
  :END:

* D365 Dataverse 커스텀 MCP 연결
  :PROPERTIES:
  :OWNER: 미배정
  :STATUS: active (2026-08-25 신설)
  :DOD: D365 커스텀 MCP 서버가 실제 Dataverse 환경에 연결된다.
  :END:

** 하위 헤딩(목표 아님, 무시되어야 함)
  :PROPERTIES:
  :OWNER: not-a-goal
  :STATUS: active
  :DOD: 이건 목표가 아니다.
  :END:

* django tenant admin 타임아웃 완결 (stark)
  :PROPERTIES:
  :OWNER: steward (집행 중)
  :STATUS: 진행 중 — prd 504 축
  :DOD: 미확정.
  :END:
"
  "A synthetic North Star org fixture covering: a multi-line active
STATUS + multi-line OWNER annotation (case ①), an annotated-owner case
(②), an explicit unowned marker (③), a nested `** ' subheading that must
NOT be parsed as its own goal, and a non-active STATUS (④, excluded from
the active count).")

(ert-deftest cc-butler-fleet-report/parses-goal-ids-and-active-flag ()
  (cc-butler-fleet-report-test--with-org-file cc-butler-fleet-report-test--sample-org
    (let ((goals (cc-butler-fleet-report--parse-north-star file)))
      ;; the nested "** " heading must not become a 5th goal
      (should (= 4 (length goals)))
      (should (equal '("스케줄 실행의 헤들리스 완주" "DB-MCP 툴서버 기반 동작"
                        "D365 Dataverse 커스텀 MCP 연결" "django tenant admin 타임아웃 완결 (stark)")
                     (mapcar (lambda (g) (plist-get g :id)) goals)))
      (should (equal '(t t t nil) (mapcar (lambda (g) (plist-get g :active-p)) goals))))))

(ert-deftest cc-butler-fleet-report/multiline-status-still-detected-active ()
  (cc-butler-fleet-report-test--with-org-file cc-butler-fleet-report-test--sample-org
    (let* ((goals (cc-butler-fleet-report--parse-north-star file))
           (g (car goals)))
      (should (plist-get g :active-p)))))

(ert-deftest cc-butler-fleet-report/owner-slug-bare-slug ()
  (cc-butler-fleet-report-test--with-org-file cc-butler-fleet-report-test--sample-org
    (let* ((goals (cc-butler-fleet-report--parse-north-star file))
           (g (car goals)))
      (should (equal "monocle-16-scheduler" (plist-get g :owner-slug)))
      (should-not (plist-get g :owner-annotated-p)))))

(ert-deftest cc-butler-fleet-report/owner-slug-extracted-from-annotated-value ()
  "The leading slug-like token is pulled out for matching even when the
:OWNER: value is heavily human-annotated, and the annotation itself is
flagged (counted, not interpreted) -- design §0-3."
  (cc-butler-fleet-report-test--with-org-file cc-butler-fleet-report-test--sample-org
    (let* ((goals (cc-butler-fleet-report--parse-north-star file))
           (g (nth 1 goals)))
      (should (equal "monocle-ms365-mcp" (plist-get g :owner-slug)))
      (should (plist-get g :owner-annotated-p)))))

(ert-deftest cc-butler-fleet-report/owner-unassigned-marker-is-not-annotated ()
  "미배정/무인 are clean explicit-unowned markers, not annotations."
  (cc-butler-fleet-report-test--with-org-file cc-butler-fleet-report-test--sample-org
    (let* ((goals (cc-butler-fleet-report--parse-north-star file))
           (g (nth 2 goals)))
      (should-not (plist-get g :owner-slug))
      (should-not (plist-get g :owner-annotated-p)))))

(ert-deftest cc-butler-fleet-report/dod-hash-is-stable-md5-of-dod-text ()
  (cc-butler-fleet-report-test--with-org-file cc-butler-fleet-report-test--sample-org
    (let* ((goals (cc-butler-fleet-report--parse-north-star file))
           (g (car goals)))
      (should (equal (secure-hash 'md5 "스테이징 monocle에서 스케줄 실행이 조용히 거짓 성공 처리되지 않는다.")
                     (plist-get g :dod-hash))))))

;;;; ------------------------------------------------------------------
;;;; Real-file probe (READ-ONLY BY CONSTRUCTION)
;;;; ------------------------------------------------------------------
;;
;; Only ever calls `cc-butler-fleet-report--parse-north-star', which itself
;; only ever calls `insert-file-contents' -- no write-path function is
;; reachable from this test, verified by inspection of the parser above.

(ert-deftest cc-butler-fleet-report/real-north-star-file-parses-without-error ()
  (let ((real (expand-file-name
               "north-star-x600.org"
               "~/obsidian/warmble-jumble/3-resources/cc-butler-governance/")))
    (skip-unless (file-readable-p real))
    (let ((before (with-temp-buffer (insert-file-contents real) (buffer-string)))
          (goals (cc-butler-fleet-report--parse-north-star real))
          (after (with-temp-buffer (insert-file-contents real) (buffer-string))))
      (should (equal before after))         ; untouched by parsing
      (should (> (length goals) 0))
      (should (seq-some (lambda (g) (plist-get g :active-p)) goals))
      (dolist (g goals)
        (should (plist-get g :id))
        (should (plist-get g :dod-hash))))))

;;;; ------------------------------------------------------------------
;;;; Snapshot path + read/write (design §3)
;;;; ------------------------------------------------------------------

(defmacro cc-butler-fleet-report-test--with-butler-home (&rest body)
  "Bind `cc-butler--butler' to a fresh temp dir for BODY, cleaned up after."
  (declare (indent 0))
  `(let* ((home (file-name-as-directory (make-temp-file "fleet-report-home" t)))
          (cc-butler--butler home))
     (unwind-protect (progn ,@body)
       (delete-directory home t))))

(ert-deftest cc-butler-fleet-report/snapshot-file-path-under-docs-fleet-snapshot ()
  (cc-butler-fleet-report-test--with-butler-home
    (should (equal (expand-file-name "docs/fleet-snapshot/2026-09-08.eld" home)
                   (cc-butler-fleet-report--snapshot-file "2026-09-08")))))

(ert-deftest cc-butler-fleet-report/write-then-read-snapshot-roundtrips ()
  (cc-butler-fleet-report-test--with-butler-home
    (let ((snap (list :date "2026-09-08"
                       :goals (list (list :id "g1" :status "active" :dod-hash "abc" :owner-slug "foo"))
                       :workers (list (list :name "foo" :fleet-status "도는 중" :attached-goal-id "g1")))))
      (cc-butler-fleet-report--write-snapshot snap (cc-butler-fleet-report--snapshot-file "2026-09-08"))
      (should (equal snap (cc-butler-fleet-report--read-snapshot
                            (cc-butler-fleet-report--snapshot-file "2026-09-08")))))))

(ert-deftest cc-butler-fleet-report/read-missing-snapshot-is-nil-not-error ()
  (cc-butler-fleet-report-test--with-butler-home
    (should-not (cc-butler-fleet-report--read-snapshot
                 (cc-butler-fleet-report--snapshot-file "2099-01-01")))))

(ert-deftest cc-butler-fleet-report/previous-snapshot-picks-most-recent-strictly-before ()
  (cc-butler-fleet-report-test--with-butler-home
    (dolist (d '("2026-09-05" "2026-09-06" "2026-09-08"))
      (cc-butler-fleet-report--write-snapshot (list :date d) (cc-butler-fleet-report--snapshot-file d)))
    (should (equal (cc-butler-fleet-report--snapshot-file "2026-09-06")
                   (cc-butler-fleet-report--previous-snapshot-file "2026-09-08")))
    (should-not (cc-butler-fleet-report--previous-snapshot-file "2026-09-05"))))

;;;; ------------------------------------------------------------------
;;;; Worker rows (design §3 / §9 — excludes butler + steward)
;;;; ------------------------------------------------------------------

(ert-deftest cc-butler-fleet-report/worker-rows-excludes-butler-and-steward ()
  (cc-butler-fleet-report-test--with-butler-home
    (let ((cc-butler--steward "/steward/"))
      (cl-letf (((symbol-function 'cc-butler--sessions)
                 (lambda () (list (list :dir home :status "" :osc "")
                                  (list :dir "/steward/" :status "" :osc "")
                                  (list :dir "/worker-a/" :status "" :osc ""))))
                ((symbol-function 'cc-butler--display-name)
                 (lambda (dir) (file-name-nondirectory (directory-file-name dir))))
                ((symbol-function 'cc-butler--meta-get) (lambda (_dir) nil)))
        (let ((rows (cc-butler-fleet-report--worker-rows nil)))
          (should (= 1 (length rows)))
          (should (equal "worker-a" (plist-get (car rows) :name))))))))

(ert-deftest cc-butler-fleet-report/worker-rows-fills-attached-goal-id-from-owner-slug ()
  "Matching is by owner-slug == worker name, computed by the machine -- never
the worker's own self-report (design §0-4)."
  (cc-butler-fleet-report-test--with-butler-home
    (let ((cc-butler--steward nil)
          (goals (list (list :id "goal-1" :owner-slug "worker-a")
                       (list :id "goal-2" :owner-slug "someone-else"))))
      (cl-letf (((symbol-function 'cc-butler--sessions)
                 (lambda () (list (list :dir "/worker-a/" :status "" :osc ""))))
                ((symbol-function 'cc-butler--display-name)
                 (lambda (dir) (file-name-nondirectory (directory-file-name dir))))
                ((symbol-function 'cc-butler--meta-get)
                 (lambda (_dir) (list :fleet-status "도는 중"))))
        (let ((rows (cc-butler-fleet-report--worker-rows goals)))
          (should (equal "goal-1" (plist-get (car rows) :attached-goal-id)))
          (should (equal "도는 중" (plist-get (car rows) :fleet-status))))))))

;;;; ------------------------------------------------------------------
;;;; Diff engine (design §4) + dispatch/reclassify split (design §5)
;;;; ------------------------------------------------------------------

(defun cc-butler-fleet-report-test--snap (goals workers)
  (list :date "x" :goals goals :workers workers))

(ert-deftest cc-butler-fleet-report/diff-no-baseline-flags-first-run ()
  (let ((d (cc-butler-fleet-report--diff nil (cc-butler-fleet-report-test--snap nil nil) nil)))
    (should (plist-get d :no-baseline))))

(ert-deftest cc-butler-fleet-report/diff-detects-goal-id-added-and-removed ()
  (let* ((prev (cc-butler-fleet-report-test--snap
                (list (list :id "g1" :dod-hash "h1" :owner-slug "a")
                      (list :id "g2" :dod-hash "h2" :owner-slug "b"))
                nil))
         (curr (cc-butler-fleet-report-test--snap
                (list (list :id "g1" :dod-hash "h1" :owner-slug "a")
                      (list :id "g3" :dod-hash "h3" :owner-slug "c"))
                nil))
         (d (cc-butler-fleet-report--diff prev curr nil))
         (edits (plist-get d :goal-edits)))
    (should (equal '("g3") (plist-get edits :added)))
    (should (equal '("g2") (plist-get edits :removed)))
    (should (= 2 (plist-get edits :count)))))

(ert-deftest cc-butler-fleet-report/diff-detects-dod-hash-change-on-kept-id ()
  (let* ((prev (cc-butler-fleet-report-test--snap
                (list (list :id "g1" :dod-hash "h1" :owner-slug "a")) nil))
         (curr (cc-butler-fleet-report-test--snap
                (list (list :id "g1" :dod-hash "h1-changed" :owner-slug "a")) nil))
         (d (cc-butler-fleet-report--diff prev curr nil))
         (edits (plist-get d :goal-edits)))
    (should (equal '("g1") (plist-get edits :dod-changed)))
    (should (= 1 (plist-get edits :count)))))

(ert-deftest cc-butler-fleet-report/diff-detects-owner-slug-change ()
  (let* ((prev (cc-butler-fleet-report-test--snap
                (list (list :id "g1" :dod-hash "h1" :owner-slug "a")) nil))
         (curr (cc-butler-fleet-report-test--snap
                (list (list :id "g1" :dod-hash "h1" :owner-slug "b")) nil))
         (d (cc-butler-fleet-report--diff prev curr nil)))
    (should (equal '("g1") (plist-get (plist-get d :owner-changes) :ids)))
    (should (= 1 (plist-get (plist-get d :owner-changes) :count)))))

(ert-deftest cc-butler-fleet-report/diff-detects-worker-fleet-status-reclassification ()
  (let* ((prev (cc-butler-fleet-report-test--snap
                nil (list (list :name "w1" :fleet-status "배차 대기" :attached-goal-id nil)
                          (list :name "w2" :fleet-status "도는 중" :attached-goal-id nil))))
         (curr (cc-butler-fleet-report-test--snap
                nil (list (list :name "w1" :fleet-status "도는 중" :attached-goal-id nil)
                          (list :name "w2" :fleet-status "도는 중" :attached-goal-id nil))))
         (d (cc-butler-fleet-report--diff prev curr nil)))
    (should (equal '("w1") (plist-get (plist-get d :worker-reclass) :names)))
    (should (= 1 (plist-get (plist-get d :worker-reclass) :count)))))

(ert-deftest cc-butler-fleet-report/diff-resolved-split-dispatch-vs-reclassify ()
  "A worker leaving 배차 대기/목표 소진 is \"배차로 해소\" when today's log has a
dispatch-natured entry naming it, else \"재분류로 해소\" (design §5)."
  (let* ((prev (cc-butler-fleet-report-test--snap
                nil (list (list :name "w1" :fleet-status "배차 대기" :attached-goal-id nil)
                          (list :name "w2" :fleet-status "목표 소진" :attached-goal-id nil))))
         (curr (cc-butler-fleet-report-test--snap
                nil (list (list :name "w1" :fleet-status "도는 중" :attached-goal-id nil)
                          (list :name "w2" :fleet-status "도는 중" :attached-goal-id nil))))
         (log "* [2026-09-08 Mon 09:00] w1에게 새 배차 :progress:\n  이어서 진행.\n")
         (d (cc-butler-fleet-report--diff prev curr log))
         (reclass (plist-get d :worker-reclass)))
    (should (= 1 (plist-get reclass :dispatch-resolved)))
    (should (= 1 (plist-get reclass :reclass-resolved)))))

;;;; ------------------------------------------------------------------
;;;; Candidate surfacing (design §0-4 / §6) — visible, never counted
;;;; ------------------------------------------------------------------

(ert-deftest cc-butler-fleet-report/candidate-names-flags-keyword-overlap-with-unowned-goal ()
  (let* ((goal (list :id "엑셀 파일 소비" :dod-text "org-mode tbl로 변환한다"))
         (sessions (list (list :dir "/a/" :status "" :osc "◐ 실무 엑셀 org-tbl 변환 중")
                         (list :dir "/b/" :status "전혀 다른 일" :osc ""))))
    (cl-letf (((symbol-function 'cc-butler--display-name)
               (lambda (dir) (file-name-nondirectory (directory-file-name dir)))))
      (let ((names (cc-butler-fleet-report--candidate-names (list goal) sessions nil)))
        (should (member "a" names))
        (should-not (member "b" names))))))

(ert-deftest cc-butler-fleet-report/candidate-names-empty-when-no-unowned-goals ()
  (let ((sessions (list (list :dir "/a/" :status "엑셀 org-tbl 변환" :osc ""))))
    (cl-letf (((symbol-function 'cc-butler--display-name)
               (lambda (dir) (file-name-nondirectory (directory-file-name dir)))))
      (should-not (cc-butler-fleet-report--candidate-names nil sessions nil)))))

;;;; ------------------------------------------------------------------
;;;; Resume-condition-observable heuristic (design §0-5/§6 revision)
;;;; ------------------------------------------------------------------

(ert-deftest cc-butler-fleet-report/resume-condition-flags-empty-status ()
  (should (cc-butler-fleet-report--resume-condition-unclear "")))

(ert-deftest cc-butler-fleet-report/resume-condition-flags-generic-dispatch-only ()
  (should (cc-butler-fleet-report--resume-condition-unclear "스튜어드 새 배차만 있으면 재개")))

(ert-deftest cc-butler-fleet-report/resume-condition-clear-with-specific-artifact ()
  (should-not (cc-butler-fleet-report--resume-condition-unclear "PR #1883 머지 대기"))
  (should-not (cc-butler-fleet-report--resume-condition-unclear "정수님 확인 대기")))

(ert-deftest cc-butler-fleet-report/unclear-resume-candidates-excludes-running-and-offline ()
  (let ((sessions (list (list :dir "/a/" :status "" :osc "")           ; running -> excluded
                        (list :dir "/b/" :status "" :osc ""))))       ; waiting, empty status -> flagged
    (cl-letf (((symbol-function 'cc-butler--display-name)
               (lambda (dir) (file-name-nondirectory (directory-file-name dir))))
              ((symbol-function 'cc-butler--meta-get)
               (lambda (dir) (if (equal dir "/a/")
                                 (list :fleet-status "도는 중")
                               (list :fleet-status "배차 대기")))))
      (let ((flagged (cc-butler-fleet-report--unclear-resume-candidates sessions nil)))
        (should (= 1 (length flagged)))
        (should (equal "b" (car (car flagged))))))))

;;;; ------------------------------------------------------------------
;;;; Report renderer (design §6) — exact template match
;;;; ------------------------------------------------------------------

(ert-deftest cc-butler-fleet-report/render-matches-fixed-template-exactly ()
  (let* ((goals (list (list :id "g1" :active-p t :owner-slug "a" :owner-annotated-p nil)
                      (list :id "g2" :active-p t :owner-slug "b" :owner-annotated-p t)
                      (list :id "g3" :active-p t :owner-slug nil :owner-annotated-p nil)
                      (list :id "g4" :active-p nil :owner-slug "c" :owner-annotated-p nil)))
         (workers (list (list :name "w1" :fleet-status "도는 중" :attached-goal-id "g1")
                        (list :name "w2" :fleet-status "사람 대기" :attached-goal-id nil)
                        (list :name "w3" :fleet-status "배차 대기" :attached-goal-id nil)
                        (list :name "w4" :fleet-status "목표 소진" :attached-goal-id nil)))
         (diff (list :no-baseline nil
                     :goal-edits (list :count 2)
                     :worker-reclass (list :count 1 :dispatch-resolved 1 :reclass-resolved 0)
                     :owner-changes (list :count 3)))
         ;; built with `referencing the variable', not a pasted copy of its
         ;; wording (CLAUDE.md's own rule for output that embeds a
         ;; configurable/fixed string) -- rewording a caveat should not
         ;; turn this test red for the wrong reason.
         (expected
          (string-join
           (list "=== 가동률 — 2026-09-08 (자동 집계 | 손으로 셈) ==="
                 ""
                 "북극성 3개(정본 :STATUS: active 개수)"
                 "   오늘 실제로 전진한 것        5   ← DoD 관측 이동만, \"배차됨/조사중\"은 0"
                 "   주인이 붙어 있는 것          2   ← :OWNER: 슬러그 존재"
                 "     (그중 사람 주석이 붙은 것)  1   ← 값 해석은 안 함, \"주석이 있다\"는 사실만 셈 — 담당 칸이 낡고 있다는 신호"
                 "   주인이 없는 것               1   ← :OWNER: 미배정/무인"
                 ""
                 "워커 4개(butler/steward 제외 라이브 세션 수)"
                 "   북극성에 붙어 있음           1   ← owner-slug 일치, 자기신고 아님"
                 "   북극성 아닌 일               3   ← 유지보수·사고대응·거버넌스"
                 "   도는 중                      1"
                 "   사람·사건 기다림 (정상)      1"
                 "   저희 배차 기다림             2   ← 목표소진 포함, 순수 낭비, 유일하게 변명 없는 줄"
                 "   (참고, 안 셈) 정본에 담당 없이 실질적으로 목표를 하는 것으로 보이는 세션  1건 — cand-x"
                 "     ⇒ 위 \"북극성에 붙어 있음\"에는 포함하지 않는다. 정본을 고칠 근거로만 보인다."
                 "   (참고, 안 셈) 재개조건이 관측 가능하지 않은 세션  1건"
                 "     ⇒ status의 재개조건이 비었거나 \"스튜어드 배차\"처럼 남을 가리킴. 세지 않고 명단만 —"
                 "       스튜어드가 깨울 책임을 진 목록이고, 길어지면 짐이 쌓이고 있다는 신호(§0-5)"
                 "     ← w2(재개조건 미기재)"
                 ""
                 "숫자를 움직인 편집 (전일 대비, 기계 탐지 — 첫 회는 기준 스냅샷이 없어 \"분모 표기 불일치\" 자체가 초기 항목)"
                 "   목표 수·완료 조건 문안 변경   2건"
                 "   워커 상태 재분류              1건 (배차로 해소 1 / 재분류로 해소 0)"
                 "   북극성 담당 변경              3건"
                 ""
                 cc-butler-fleet-report--caveat-1
                 ""
                 cc-butler-fleet-report--caveat-2)
           "\n")))
    (should (equal expected
                   (cc-butler-fleet-report--render
                    "2026-09-08" goals workers diff '("cand-x")
                    '(("w2" . "재개조건 미기재")) 5)))))

(ert-deftest cc-butler-fleet-report/render-caveats-are-verbatim-and-fixed ()
  "The two caveat blocks (design §6) never soften or disappear -- present in
every render regardless of inputs, word for word."
  (let ((out (cc-butler-fleet-report--render "2026-09-08" nil nil
                                              (list :no-baseline t) nil nil)))
    (should (string-match-p (regexp-quote cc-butler-fleet-report--caveat-1) out))
    (should (string-match-p (regexp-quote cc-butler-fleet-report--caveat-2) out))
    (should (string-match-p "«자기가 멈춘 줄 모르는 세션»" out))
    (should (string-match-p "«추세»로 말하지 않습니다" out))))

(ert-deftest cc-butler-fleet-report/render-omits-progressed-count-defaults-to-zero ()
  (let ((out (cc-butler-fleet-report--render "2026-09-08" nil nil
                                              (list :no-baseline t) nil nil)))
    (should (string-match-p "오늘 실제로 전진한 것        0" out))))

;;;; ------------------------------------------------------------------
;;;; MCP tool wiring
;;;; ------------------------------------------------------------------

(ert-deftest cc-butler-fleet-report/tool-writes-todays-snapshot-and-returns-report ()
  (cc-butler-fleet-report-test--with-butler-home
    (cc-butler-fleet-report-test--with-org-file cc-butler-fleet-report-test--sample-org
      (let ((cc-butler-north-star-file file)
            (cc-butler--steward nil))
        (cl-letf (((symbol-function 'cc-butler--sessions)
                   (lambda () (list (list :dir "/worker-a/" :status "" :osc ""))))
                  ((symbol-function 'cc-butler--display-name)
                   (lambda (dir) (file-name-nondirectory (directory-file-name dir))))
                  ((symbol-function 'cc-butler--meta-get) (lambda (_dir) nil)))
          (let* ((today (format-time-string "%Y-%m-%d"))
                 (out (cc-butler-tool-fleet-utilization-report)))
            (should (string-match-p "가동률" out))
            (should (string-match-p "북극성 3개" out))    ; 3 active goals in the fixture
            (should (file-exists-p (cc-butler-fleet-report--snapshot-file today)))
            (let ((snap (cc-butler-fleet-report--read-snapshot
                         (cc-butler-fleet-report--snapshot-file today))))
              (should (= 3 (length (plist-get snap :goals))))
              (should (= 1 (length (plist-get snap :workers)))))))))))

(ert-deftest cc-butler-fleet-report/tool-uses-prior-snapshot-as-diff-baseline ()
  (cc-butler-fleet-report-test--with-butler-home
    (cc-butler-fleet-report-test--with-org-file cc-butler-fleet-report-test--sample-org
      (let ((cc-butler-north-star-file file)
            (cc-butler--steward nil)
            (yesterday (format-time-string
                        "%Y-%m-%d" (time-subtract (current-time) (days-to-time 1)))))
        (cc-butler-fleet-report--write-snapshot
         (list :date yesterday :goals nil :workers nil)
         (cc-butler-fleet-report--snapshot-file yesterday))
        (cl-letf (((symbol-function 'cc-butler--sessions)
                   (lambda () (list (list :dir "/worker-a/" :status "" :osc ""))))
                  ((symbol-function 'cc-butler--display-name)
                   (lambda (dir) (file-name-nondirectory (directory-file-name dir))))
                  ((symbol-function 'cc-butler--meta-get) (lambda (_dir) nil)))
          (let ((out (cc-butler-tool-fleet-utilization-report)))
            ;; a real baseline exists -> no "기준 스냅샷 없음"
            (should-not (string-match-p "기준 스냅샷 없음" out))))))))

(provide 'cc-butler-fleet-report-test)
;;; cc-butler-fleet-report-test.el ends here
