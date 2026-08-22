;;; cc-butler-north-star.el --- periodic DoD self-check nudge for the butler -*- lexical-binding: t; -*-

;;; Commentary:

;; `governance/dod-vs-ultimate-goal.md' already states the discipline: when a
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

(defcustom cc-butler-north-star-file
  (expand-file-name "north-star.org" "~/projects/cc-butler-governance/")
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
The template is always inlined, whether or not the file exists yet: on a
missing file it is what the butler creates the first entry from (after
asking 정수님 what the actual goal is — never guessing); on an existing
file it is a standing reminder of the expected shape, since drift there
is exactly the kind of thing nobody notices until the file is unusable."
  (format "[North Star Check]
%s 파일을 읽고 각 활성 목표를 점검할 것. 파일이 아직 없다면 아래 템플릿 형식으로
새로 만들되, 실제 목표가 무엇인지 먼저 정수님께 물어볼 것 — 짐작으로 채우지 말 것.

템플릿:
%s

각 활성 목표에 대해:
1. 그 목표의 DoD가 실제로 충족되었는가? (\"어려움이 있었다\"는 완료의 증거가 아니다 — governance/dod-vs-ultimate-goal.md 기준 적용.)
2. 아직이라면 막힌 지점이 있는가? manager/enabler로서 시도할 수 있는 안전한 조치를 먼저 강구할 것.
3. 판단이 불명확하면 escalate_to_butler로 정수님께 질문할 것 — 짐작으로 채우지 말 것.
4. DoD가 충족된 목표는 이 파일에서 제거하고 완료 서사를 wb-para 프로젝트 노트로 아카이브할 것 — 진행 기록은 이 파일이 아니라 프로젝트 노트에 (governance: north-star-file-holds-intent-not-progress).
원래 목표와 무관한 부수 작업(yak-shaving)에 머물러 있지는 않은지도 함께 점검할 것."
          cc-butler-north-star-file cc-butler--north-star-template))

(defun cc-butler--north-star-fire ()
  "Nudge the butler to self-check active North Stars against their DoD.
Mirrors `cc-butler--forward-backstop': only types into the butler's
terminal when it looks idle (`cc-butler--forward-ops-free-p'), so a
hourly housekeeping ping cannot land mid-turn and scramble whatever the
butler is actually doing."
  (when-let* ((butler cc-butler--butler)
              (buf (get-buffer (claude-code-ide--get-buffer-name butler)))
              ((buffer-live-p buf))
              ((cc-butler--forward-ops-free-p butler)))
    (cc-butler--send-input butler (cc-butler--north-star-prompt) t)))

;;;###autoload
(defun cc-butler-north-star-check ()
  "Nudge the butler to self-check active North Stars against their DoD
right now, instead of waiting for the next scheduled tick.  Still
respects the same idle gate the timer uses
\(`cc-butler--forward-ops-free-p'\) — a human asking explicitly still
should not get to type over the butler mid-turn — but reports why when
that gate holds it back, since a manual call deserves an answer, not the
timer's silent no-op."
  (interactive)
  (if (cc-butler--north-star-fire)
      (message "cc-butler: North Star check sent to the butler")
    (message "cc-butler: North Star check skipped — no butler designated, its terminal isn't live, or it looks busy right now")))

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
