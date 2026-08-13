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

(defcustom cc-butler-fleet-name "monocle"
  "Identity of THIS cc-butler fleet, as opposed to some other fleet.
The governance store (`cc-butler-governance-store') is shared across
possibly-multiple cc-butler fleets — 정수님, 2026-08-13 — so anything
fleet-specific must be namespaced by this rather than assuming the
store is this fleet's alone.  No dedicated fleet-identity variable
existed before this; \"monocle\" is the closest existing identity in
config (the private topic template of that name), even though this
fleet is not monocle-exclusive (it also runs dealmatch/cc-butler work)
— it is a placeholder default, not a claim that this fleet IS monocle."
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

(defvar cc-butler--north-star-timer nil
  "Repeating timer driving `cc-butler--north-star-fire', or nil before first use.")

(defvar cc-butler--north-star-last-sent-hash nil
  "MD5 hash of `cc-butler-north-star-file' content as of the last
successfully SENT nudge, or nil.

nil deliberately means two different things at once, both resolved the
same way: (a) fresh load/reload, no send has happened yet this Emacs
session (this state is NOT persisted across reloads), and (b) not
applicable, handled separately (see the file-absent case in
`cc-butler--north-star-fire'). Either way, nil never compares equal to a
real hash, so THE FIRST TICK AFTER EVERY (RE)ARM ALWAYS FIRES ONCE. This
is a deliberate choice, not an accident of initializing to nil:

An alternative was considered — eagerly seed this variable from the
file's content at arm time (inside `cc-butler--north-star-ensure-timer'
itself, which is already re-invoked after every hot reload) so a reload
alone would never cost an extra send. That was rejected: it would treat
\"content merely observed at arm time\" as if it had been sent, with
no corresponding call to `cc-butler--send-input'. A real edit landing
between that eager read and the next tick would then be silently
swallowed — the exact failure shape requirement (1) above guards
against, just relocated to reload time instead of send time. That risk
was judged worse than the cost it would avoid.

The accepted cost is therefore: at most one avoidable nudge per (re)arm
event (module load, or a hot reload during development), a small,
BOUNDED tax — a sharp improvement over the original bug (an unbounded
avoidable nudge every single hour, forever, until manually cancelled).")

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
  (format "[North Star Check]
%s 파일을 읽고 각 활성 목표를 점검할 것. 파일이 없다면 새로 만들지 말고 즉시 멈출 것 —
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

각 활성 목표에 대해:
1. 그 목표의 DoD가 실제로 충족되었는가? (\"어려움이 있었다\"는 완료의 증거가 아니다 — governance store의 dod-vs-ultimate-goal 기준 적용.)
2. 아직이라면 막힌 지점이 있는가? manager/enabler로서 시도할 수 있는 안전한 조치를 먼저 강구할 것.
3. 판단이 불명확하면 escalate_to_butler로 정수님께 질문할 것 — 짐작으로 채우지 말 것.
4. DoD가 충족된 목표는 이 파일에서 제거하고 완료 서사를 wb-para 프로젝트 노트로 아카이브할 것 — 진행 기록은 이 파일이 아니라 프로젝트 노트에 (governance: north-star-file-holds-intent-not-progress).
원래 목표와 무관한 부수 작업(yak-shaving)에 머물러 있지는 않은지도 함께 점검할 것."
          cc-butler-north-star-file cc-butler--north-star-template))

(defun cc-butler--north-star-file-hash ()
  "MD5 of `cc-butler-north-star-file's current content, or nil if the
file does not exist yet.

Read exactly once per call, by design: the delta gate's decision and the
post-send bookkeeping must both use the SAME hash value from the SAME
read — never re-read-and-re-hash the file later (e.g. at a \"send
succeeded\" point), or a real edit landing in the gap between the
original read and that later point would be silently swallowed (the
re-read would pick up the NEW content and get recorded as
\"already sent\" even though it was never actually transmitted).
`cc-butler--send-input' is synchronous here (no async success callback)
so callers achieve this simply by calling this function once per tick
and reusing the result — see `cc-butler--north-star-fire'."
  (when (file-exists-p cc-butler-north-star-file)
    (with-temp-buffer
      (insert-file-contents cc-butler-north-star-file)
      (md5 (buffer-string)))))

(defun cc-butler--north-star-fire (&optional force)
  "Nudge the butler to self-check active North Stars against their DoD.
Mirrors `cc-butler--forward-backstop': only types into the butler's
terminal when it looks idle (`cc-butler--forward-ops-free-p'), so a
hourly housekeeping ping cannot land mid-turn and scramble whatever the
butler is actually doing.

Also gated on content: skipped when `cc-butler-north-star-file's content
is unchanged since the last successfully SENT nudge (see
`cc-butler--north-star-last-sent-hash'), unless FORCE is non-nil — used
by `cc-butler-north-star-check' so a human asking explicitly always gets
an answer. When the file does not exist yet, the delta gate does not
apply at all (there is nothing to diff against, and the file-absent
nudge is itself the useful signal — see the prompt template's
\"create it\" instructions) — this preserves the pre-existing
unconditional-fire behavior for that case unchanged.

A tick skipped by the idle gate does NOT update the recorded hash: the
same pending content is retried on the next tick.

Returns `sent' on an actual send, `skipped-idle' or `skipped-delta' when
gated, or nil when there is no live butler terminal at all (no butler
designated, or its terminal buffer is gone)."
  (when-let* ((butler cc-butler--butler)
              (buf (get-buffer (claude-code-ide--get-buffer-name butler)))
              ((buffer-live-p buf)))
    (if (not (cc-butler--forward-ops-free-p butler))
        'skipped-idle
      (let ((hash (cc-butler--north-star-file-hash)))
        (if (and (not force) hash (equal hash cc-butler--north-star-last-sent-hash))
            'skipped-delta
          (cc-butler--send-input butler (cc-butler--north-star-prompt) t)
          (when hash
            (setq cc-butler--north-star-last-sent-hash hash))
          'sent)))))

;;;###autoload
(defun cc-butler-north-star-check ()
  "Nudge the butler to self-check active North Stars against their DoD
right now, instead of waiting for the next scheduled tick.  Bypasses the
content delta gate (a human asking explicitly always gets an answer) but
still respects the idle gate the timer uses
\(`cc-butler--forward-ops-free-p'\) — a human asking explicitly still
should not get to type over the butler mid-turn.  Reports WHICH gate (if
any) held it back, since a manual call deserves an answer, not the
timer's silent no-op."
  (interactive)
  (pcase (cc-butler--north-star-fire t)
    ('sent (message "cc-butler: North Star check sent to the butler"))
    ('skipped-idle (message "cc-butler: North Star check skipped — the butler looks busy right now"))
    (_ (message "cc-butler: North Star check skipped — no butler designated, or its terminal isn't live"))))

(defun cc-butler--north-star-ensure-timer ()
  "(Re)register the North Star timer; idempotent for hot reloads."
  (when (timerp cc-butler--north-star-timer)
    (cancel-timer cc-butler--north-star-timer))
  (setq cc-butler--north-star-timer
        (run-with-timer cc-butler-north-star-interval
                         cc-butler-north-star-interval
                         #'cc-butler--north-star-fire)))

(cc-butler--north-star-ensure-timer)

(provide 'cc-butler-north-star)
;;; cc-butler-north-star.el ends here
