---
name: butler-approval-is-not-completion
description: "'승인했다/지시했다'를 '됐다'로 한 단계 올려 말하지 말 것 — 진행 중은 '반영 중'으로, 완료는 실물 확인 후에만 '반영됐습니다'로; 청자는 완료로 들으면 그 위에 다음 판단을 얹는다"
metadata:
  node_type: memory
  type: feedback
---

Approving, instructing, or dispatching an action and that action being COMPLETE are
different events. When relaying status upward, do not compress them into one:
"갱신 승인해 뒀습니다"(approved, in flight) must not be relayed as "갱신돼
있습니다"(done). The listener builds their next decision on top of what they hear —
if they hear "done" about work still in flight, that decision sits on air.

**Why:** On 2026-08-09, steward reported "#1640 갱신 승인해 뒀습니다" (worker was
mid-comment via subagent) and butler relayed it to 정수님 as "갱신돼 있습니다."
The gap was 1-2 minutes and harmless that time, but it is the same shape as the
day's larger incident (sent ≠ delivered): a status silently escalated one notch
at a relay hop. The escalation is a single word, but it decides whether the
principal waits or proceeds.

**How to apply:**
- In-flight work: say "승인해서 지금 반영 중" — name it as in progress.
- Completion: say "반영됐습니다" only after the artifact itself (the issue
  comment, the merged commit, the deployed change) has been confirmed by
  someone in the chain — not from a completion self-report alone.
- When relaying another agent's status, preserve its tense; upgrading
  approved→done at a hop is the same defect as dropping "unconfirmed" from a
  claim (see [[butler-steward-relay-claims-with-their-status]], [[butler-verify-delivery]]).
- If the upgrade already went out and will become true within minutes, do not
  send a correction — that is more noise than signal; just confirm completion
  before building anything further on it.
