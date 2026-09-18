;;; cc-butler-north-star.el --- periodic DoD self-check nudge for the butler -*- lexical-binding: t; -*-

;;; Commentary:

;; `dod-vs-ultimate-goal' in the governance store already states the discipline: when a
;; session reports "done" or stalls out, judge it against its ULTIMATE goal,
;; not against how much effort went in — difficulty is not evidence of
;; completion.  Until now nothing made the butler actually apply that
;; discipline on a schedule; it depended on the butler happening to think of
;; it.  This module is the mechanical trigger: a repeating timer that types a
;; self-check prompt into the butler's own terminal, pointing it at
;; `cc-butler-north-star-file' (a human/butler-maintained list of active
;; goals and their Definition of Done).
;;
;; Deliberately thin: this file does not parse or understand
;; `cc-butler-north-star-file' at all.  Reading it and judging whether each
;; goal's DoD is actually met is the butler's job (an LLM judgment call);
;; Emacs Lisp's only job is deciding *when* to ask, and asking safely (see
;; `cc-butler--north-star-fire').

;;; Code:

(require 'cc-butler-orchestrator)
(require 'cc-butler-governance)

(defcustom cc-butler-fleet-name "x600"
  "Identity of THIS cc-butler fleet, as opposed to some other fleet.
The governance store (`cc-butler-governance-store') is shared across
possibly-multiple cc-butler fleets — 정수님, 2026-08-13 — so anything
fleet-specific must be namespaced by this rather than assuming the
store is this fleet's alone.  Named per MACHINE/INSTANCE (this one is
the Desk Mini X600), not per client project: an earlier \"monocle\"
default was wrong for exactly the reason this variable exists — other
fleets ALSO work on monocle, so a project name can't distinguish
fleets; 정수님's own words, 2026-08-13, independently reaching the
same conclusion this docstring already flagged."
  :type 'string
  :group 'cc-butler)

(defcustom cc-butler-north-star-file
  (expand-file-name (format "north-star-%s.org" cc-butler-fleet-name)
                     (cc-butler-governance-store))
  "Org file listing active goals and their Definition of Done.
This default lives in the private governance store, not the public
`toracle/cc-butler' checkout — goal descriptions routinely name real
projects and people, the same reason the governance store itself was
moved out of a public repo. NOTE (2026-08-13): governance principles now
live in a shared org vault (multiple cc-butler fleets merge into one
principle store there), but North Star goals do NOT merge — each fleet's
active goals are that fleet's own. A fleet that migrates its principles
into the shared vault should therefore pin this variable explicitly
(e.g. in custom.el, NOT by editing this default) to a
fleet-namespaced filename inside that vault, such as
\"north-star-<fleet-id>.org\", so it sits alongside other fleets' files
without colliding. This default value is intentionally left pointing at
the private local store — see the live pin for what a given machine
actually uses; do not infer the running value from this default."
  :type 'file
  :group 'cc-butler)

(defcustom cc-butler-north-star-interval (* 1 60 60)
  "Seconds between North Star self-check nudges to the butler."
  :type 'number
  :group 'cc-butler)

(defcustom cc-butler-north-star-session nil
  "Working-dir of the session that receives North Star nudges, or nil.
nil (the default) preserves today's behaviour exactly: nudges go to the
designated butler (`cc-butler--butler'). When set to a session's
working-dir string, nudges go to that session instead of the butler —
e.g. a dedicated session whose only job is North Star upkeep, so it is
idle between ticks by construction and `cc-butler--forward-ops-free-p'
goes back to being a genuine idle check rather than a starvation mode
against a butler that is busy on every hourly tick.

Not rebound by `reload_butler_code': reloading loads this defcustom's
definition but leaves an already-set value alone, same as any other
defcustom — setting a value is a separate act from loading the code
that defines it."
  :type '(choice (const :tag "Butler (default)" nil) string)
  :group 'cc-butler)

(defvar cc-butler--north-star-timer nil
  "Repeating timer driving `cc-butler--north-star-fire', or nil before first use.")

(defun cc-butler--north-star-file-namespaced-p (&optional file)
  "Non-nil unless FILE (default `cc-butler-north-star-file') is still the
generic, un-overridden basename \"north-star.org\" — the collision risk
once `cc-butler-governance-dir' is a directory shared by more than one
fleet. FILE lets `cc-butler-self-check--north-star-file' check an
arbitrary path instead of only the currently configured one."
  (not (equal (file-name-nondirectory (or file cc-butler-north-star-file))
              "north-star.org")))

(defun cc-butler--north-star-warn-not-namespaced ()
  "Loudly warn that `cc-butler-north-star-file' needs a fleet-specific
override, with the exact fix inline — a message that scrolls past in
*Messages* is not enough for a misconfiguration this easy to miss, and
the next person to hit this should not have to go spelunking for the fix."
  (display-warning
   'cc-butler-north-star
   "cc-butler-north-star-file is still the generic \"north-star.org\" — refusing to run the North Star check.

Set a fleet-specific override in THIS MACHINE's local custom.el (never
committed anywhere — this is per-machine, not shared with other fleets):

  (with-eval-after-load 'cc-butler-north-star
    (setq cc-butler-north-star-file
          (expand-file-name \"north-star-<your-fleet-id>.org\" cc-butler-governance-dir)))

Convention: one file per machine/fleet, named after the machine — the two
that already exist are north-star-macbook-m1-max.org and
north-star-x600.org. Pick a similarly descriptive <your-fleet-id> for
this machine.

Then apply it live: `(load custom-file)', and re-arm with
`(cc-butler--north-star-ensure-timer)' or just `M-x cc-butler-north-star-check'."
   :warning))

(defconst cc-butler--north-star-template "\
* 목표 이름
  :PROPERTIES:
  :STATUS: active
  :DOD: 확인 가능한 한 문장 — 누구에게도 묻지 않고 예/아니오로 답할 수 있는,
        구체적이고 관찰 가능한 완료 조건.
  :END:

  자유 텍스트: 왜 이 목표가 존재하는지, \"어려움이 있었다\"가 왜 이 목표에서는
  완료의 증거가 아닌지, 관련 세션/PR/이슈 링크."
  "The North Star entry shape, embedded directly in every nudge — not just
referenced by path — so the butler can create/extend the file correctly
even on the very first run, before it has ever opened it.")

(defun cc-butler--north-star-prompt ()
  "Build the nudge text sent to the butler's terminal.
The template is always inlined, whether or not the file exists yet, but its
role differs by case: on an existing file it is a standing reminder of the
expected shape, since drift there is exactly the kind of thing nobody
notices until the file is unusable. On a missing file the prompt does NOT
tell the butler to create it — `cc-butler-governance-dir' is a directory
shared across multiple fleets (e.g. `north-star-x600.org' and
`north-star-macbook-m1-max.org' side by side), so a missing file almost
always means `cc-butler-north-star-file' resolved to the wrong path, not
that goals were never started; creating a new file there risks silently
discarding another fleet's real goal history, or colliding with it
outright. Instead the prompt tells the butler to stop and escalate to
정수님 — never guessing, never fabricating a fresh file."
  (format "[North Star Refresh]
%s 파일을 읽고 각 활성 목표의 서술이 실제 세계 상태와 일치하는지 대조할 것. 파일이 없다면 새로 만들지 말고 즉시 멈출 것 —
cc-butler-governance-dir는 여러 fleet이 함께 쓰는 저장소로, north-star-x600.org와
north-star-macbook-m1-max.org처럼 서로 다른 fleet의 목표 파일이 나란히 존재한다.
이런 상황에서 파일이 \"없다\"는 것은 대개 목표가 아직 없다는 뜻이 아니라 경로가
잘못 설정되었다는 뜻이다. 여기서 새로 만들면 다른 fleet의 실제 목표/판단 이력을
빈 파일로 조용히 덮어써 유실시키거나, 잘못된 경로가 다른 fleet의 디렉터리와 겹쳐
그 fleet의 파일을 침범할 수 있다. escalate_to_butler로 정수님/steward에게 경로가
잘못된 것 같다고 보고할 것 — 짐작으로 채우거나 새로 만들지 말 것.

아래 템플릿은 경로가 올바른 실제 파일이라면 각 항목이 어떤 모양이어야 하는지
보여주는 참고 기준이지, 지금 새 파일을 만들라는 뜻이 아니다:
%s

활성 목표 수는 이 파일에서 매 틱 다시 셀 것 — 최상위 헤딩 수에서 `:STATUS: 🔵 이관`으로
표시된 것을 뺀 값. 다른 델리미터를 쓰지 말 것. 헤딩이 사라졌다면 그 목표는 (거의 언제나)
프로젝트 노트로 아카이브된 것이지 유실된 것이 아니다. 여기서 찾을 수 없는 목표를
절대로 다시 만들거나 되살리지 말 것 — 맵을 세계에 맞추는 것이지, 사람이 의도적으로
아카이브한 것을 맵이 세계 위에 덮어쓰는 게 아니다.

각 활성 목표에 대해, 이 파일 자체가 아니라 실제 세계(워커 세션 상태, 머지 여부, PR 상태)를
조회해서 서술과 대조할 것 — 이 파일을 읽고 이 파일이 최신인지 판단하는 것은 순환논리이며,
바로 이 세션이 만들어진 이유다. 필요한 조회는 서브에이전트로 위임할 것 — 이 세션은
영구히 살아있으므로, 조회 결과를 메인 스레드 컨텍스트에 틱마다 누적하지 말고 그 틱
안에서만 쓸 것.

목표는 제목으로만 지칭할 것 — 이 파일의 최상위 헤딩엔 번호가 없고, 과거 라운지
스레드의 고정 번호와 혼동해선 안 된다(정수님 09-08 기록: 파일 순서로 번호를 매기다
⑨번째부터 틀림).

⚠ 이 파일은 여러 세션이 공유하는 vault 안에 있고, 그 vault엔 세션 Stop마다
`pull --rebase --autostash`를 도는 wb-para 훅이 걸려 있다 — 09-16에 stale autostash를
잘못 재적용해 거버넌스 노트 열두 개를 UU 상태로 남긴 전례가 있다. 델타를 커밋한
뒤에는 커밋 명령이 0을 반환했다는 것만으로 그 쓰기가 살아남았다고 가정하지 말고
반드시 다시 읽어 실제로 반영됐는지 확인할 것.

대조 결과 변경이 있으면 그 델타만 파일에 반영할 것. DoD가 충족된 목표는 헤딩·드로어를
지우고 `# ✅ ...아카이브` 한 줄 + wb-para 프로젝트 노트 링크로 치환할 것 — 진행 서사는
이 파일이 아니라 프로젝트 노트에 (governance: north-star-file-holds-intent-not-progress).

알림 (파일에 실제 변경이 반영됐을 때만): 이번 틱의 산출물은 파일 쓰기 하나가 아니라
[파일 쓰기 + 알림 전송] 둘이다. 이번 틱에서 아무것도 바뀌지 않았다면 알림은 보내지
말 것 — 정기 점검이 매번 울리면 알림의 의미가 사라진다. 실제로 델타를 반영했을 때만,
`butlers` 방의 기존 '북극성' 스레드 안에(최상위 아님) 무엇이 바뀌었는지 두세 줄로
요약해 보내고, 지도 페이지(`1-projects/🤵 cc-butler 함대/x600/📋 x600 한눈에.md`,
wj.warmblood.kr에서 서빙, 경로는 퍼센트 인코딩)로 클릭 가능한 링크를 붙일 것.
@멘션은 달지 말 것. 이 전송에는 반드시 ROOM_ID를 명시적으로 넘길 것 — 전송 함수가
성공을 반환했다는 것을 전달됐다는 증거로 삼지 말 것(오늘 밤 butler가 잘못된 방의
스레드 루트에 쓰려다 post-to-lounge.sh가 거부한 사례가 있었다 — 그 가드가 항상
실수를 잡아줄 거라고 가정하지 말 것).

파일 쓰기와 알림 전송은 서로 독립적으로 실패할 수 있는 별개의 산출물이다. 이번 틱을
\"완료\"로 뭉뚱그려 보고하지 말고 둘의 성공/실패를 각각 따로 밝힐 것 — 파일은 썼는데
알림이 안 갔을 수도, 알림은 갔는데 파일 쓰기가 (위의 rebase 훅 때문에) 조용히
유실됐을 수도 있다. 어느 쪽이든, 세계로부터 관측한 사실을 담거나 \"무엇에 닿지
못했는지\"를 그 표현 그대로 말할 것 — 둘 다 됐다고 확인되지 않은 이상 \"완료\"라고
말하지 말 것.

⛔ \"변경이 없어 보이니 이번 틱엔 커밋하지 않는다\"는 맞다(알림도 마찬가지로 보내지
않는다). \"변경이 없어 보이니 이번 틱엔 조회 자체를 생략한다\"는 절대 안 된다 —
전자는 이번 틱의 결과이고, 후자는 예전에 제거된 '파일 해시 불변이면 통째로
스킵'하던 게이트가 다른 얼굴로 돌아오는 것이다. 매 틱 반드시 조회부터 실행하고,
조회 후 반영할 델타가 없을 때만 커밋과 알림을 생략한다.

판단이 불명확하면 escalate_to_butler로 정수님께 질문할 것 — 짐작으로 채우지 말 것."
          cc-butler-north-star-file cc-butler--north-star-template))

(defun cc-butler--north-star-fire ()
  "Nudge the target session (`cc-butler-north-star-session', or the
butler when nil) to self-check active North Stars against their DoD.
Mirrors `cc-butler--forward-backstop': only types into the target's
terminal when it looks idle (`cc-butler--forward-ops-free-p'), so an
hourly housekeeping ping cannot land mid-turn and scramble whatever the
target is actually doing.  Also refuses outright if `cc-butler-north-star-file'
is still unnamespaced (see `cc-butler--north-star-file-namespaced-p') —
this is the one gate that protects the manual `cc-butler-north-star-check'
path too, since that command calls straight into this function.

No content gate: 정수님's own instruction is to self-check every hour,
period. A prior version skipped the hourly nudge whenever the file's
hash matched the last successfully sent one -- but this file records
INTENT, not progress (see `north-star-file-holds-intent-not-progress'),
so an unchanged file is not evidence that nothing worth checking
happened; that gate silently zeroed the check's sensitivity to real
worker progress that never touches this file at all (see governance's
`a-change-detector-fails-two-ways-and-you-usually-only-test-one').
Removed outright rather than extended with more detectors (new
decision-mail or cross-session-message signals) -- the run-every-hour
instruction is already fully satisfied by having no content gate, and
the per-tick context cost is the butler's own to manage in the check
prompt, not this function's problem to solve by filtering ticks.

Returns `sent' on an actual send, `skipped-idle' when gated,
`skipped-unnamespaced' when the file path guard refuses, or nil when
there is no live butler terminal at all (no butler designated, or its
terminal buffer is gone)."
  (if (not (cc-butler--north-star-file-namespaced-p))
      (progn (cc-butler--north-star-warn-not-namespaced) 'skipped-unnamespaced)
    (when-let* ((butler (or cc-butler-north-star-session cc-butler--butler))
                (buf (get-buffer (claude-code-ide--get-buffer-name butler)))
                ((buffer-live-p buf)))
      (if (not (cc-butler--forward-ops-free-p butler))
          'skipped-idle
        (cc-butler--send-input butler (cc-butler--north-star-prompt) t)
        'sent))))

;;;###autoload
(defun cc-butler-north-star-check ()
  "Nudge the butler to self-check active North Stars against their DoD
right now, instead of waiting for the next scheduled tick.  Respects the
same idle gate the timer uses (`cc-butler--forward-ops-free-p') — a
human asking explicitly still should not get to type over the butler
mid-turn.  Reports WHICH gate (if any) held it back, since a manual
call deserves an answer, not the timer's silent no-op."
  (interactive)
  (pcase (cc-butler--north-star-fire)
    ('sent (message "cc-butler: North Star check sent to the butler"))
    ('skipped-idle (message "cc-butler: North Star check skipped — the butler looks busy right now"))
    ('skipped-unnamespaced (message "cc-butler: North Star check skipped — cc-butler-north-star-file is unnamespaced, see *Warnings*"))
    (_ (message "cc-butler: North Star check skipped — no butler designated, or its terminal isn't live"))))

(defun cc-butler--north-star-ensure-timer ()
  "(Re)register the North Star timer; idempotent for hot reloads.
Refuses to arm at all when `cc-butler-north-star-file' is still the
generic \"north-star.org\" basename — see `cc-butler--north-star-warn-not-namespaced'
for the fix.  A timer that would just fire into a permanent no-op is
worse than no timer: it looks armed in `timer-list' while doing nothing,
which is its own kind of silent failure."
  (if (not (cc-butler--north-star-file-namespaced-p))
      (cc-butler--north-star-warn-not-namespaced)
    (when (timerp cc-butler--north-star-timer)
      (cancel-timer cc-butler--north-star-timer))
    (setq cc-butler--north-star-timer
          (run-with-timer cc-butler-north-star-interval
                           cc-butler-north-star-interval
                           #'cc-butler--north-star-fire))))

(cc-butler--north-star-ensure-timer)

(provide 'cc-butler-north-star)
;;; cc-butler-north-star.el ends here
