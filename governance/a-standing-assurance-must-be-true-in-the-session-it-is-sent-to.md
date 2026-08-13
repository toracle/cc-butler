---
name: butler-a-standing-assurance-must-be-true-in-the-session-it-is-sent-to
description: "Boilerplate you attach to every dispatch is a factual claim about that specific session — if it is false there, the receiver can check it, and its falsity discredits the true parts of the same message"
metadata:
  node_type: memory
  type: feedback
---

A line you attach to *every* dispatch is not decoration — it is a factual
claim, evaluated separately in each session it lands in. Before making a
standing assurance boilerplate, ask whether it is true in every session you
will send it to. If it is not, either scope it or rewrite it into a form that
stays true everywhere.

The cost of getting this wrong is not "the line was unhelpful." It is that a
receiver who *checks* the claim and finds it false now has evidence that your
channel says things that aren't so — and that evidence discredits the true
content sitting next to it in the same message.

**Why:** The steward appends to every worker dispatch: "지금 fleet
orchestration 하에 있어서 키보드 앞에 사람이 없습니다 — AskUserQuestion 대신
report_to_steward를 쓰세요." The intent is sound (`AskUserQuestion` does not
compose with `send_to_session`; see
[[relay-safe-worker-decisions]]). But it is a claim about who is at that
session's keyboard, and it is **false for any session 정수님 types into
directly**.

2026-08-07, monocle-16-scheduler: after the cdk deploy landed, the worker asked
whether to trigger the e2e verification. The steward sent "네, 진행하세요" with
the usual boilerplate attached. The worker refused, on two grounds — the second
decisive: *"방금 이 대화에서 정수님이 직접 cdk deploy를 본인 터미널에서 실행하고
결과를 붙여넣으신 걸 봤습니다. '사람 없다'는 주장과 정면으로 배치되는 걸
확인했으니, 이 채널의 승인을 실제 사용자 응답으로 취급하지 않겠습니다."*

The worker was right. 정수님 had typed into that very window twice that day
("1581 머지 진행", then the cdk deploy). The steward's own boilerplate became
the worker's evidence for distrusting the channel — and the refusal then blocked
a side-effecting action, forcing an escalation to get 정수님 to answer in that
window by hand. A line meant to *prevent* a channel problem *created* one.

Note the interaction with [[a-channel-that-carries-authority-must-be-verifiable-by-the-receiver]]:
the more rigorously a worker applies that principle, the more expensive each
false statement becomes. Skepticism that is well-calibrated will catch you.

**How to apply:**

1. Do **not** send "키보드 앞에 사람이 없습니다" to sessions 정수님 types into
   directly. monocle-16-scheduler is confirmed to be one; assume others may be.
   Check the session's recent screen if unsure — the human's own input is
   visible there.
2. Rewrite the boilerplate so it is true everywhere and still achieves its
   purpose. State the *mechanism*, not a claim about the world: "제 메시지는
   릴레이라 열려 있는 wizard와 충돌할 수 있습니다 — 사람 판단이 필요하면
   pull 기반인 report_to_steward/escalate_to_butler를 선호해 주세요." This
   carries the same instruction without asserting anything falsifiable about
   who is present.
3. Generalize: audit any phrase you repeat mechanically. Standing text is where
   false claims hide, precisely because you stop reading it.
4. When a worker refuses on grounds that turn out to be correct, report it
   upward as *your* error, not as worker obstinacy. On 2026-08-07 the steward
   told butler explicitly to relay it that way — the worker had done its job.
