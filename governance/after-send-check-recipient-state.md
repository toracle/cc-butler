---
name: butler-after-send-check-recipient-state
description: "send_to_session 후에는 반드시 수신 세션의 화면(read_session_output)으로 도달을 확인한다 — 'Sent and submitted'는 전송 주장이지 도달 증거가 아니다"
metadata:
  node_type: memory
  type: feedback
---

세션에 메시지를 보낸 뒤에는 **수신 세션의 사후 상태를 화면으로 확인**한다: `read_session_output`으로 메시지가 실제로 화면/컨텍스트에 도달했는지 본다. 도달을 확인하기 전에는 위로 보고할 때 "전달했다"가 아니라 "보냈고 도달 확인 중"이라고 쓴다.

**Why:** 2026-08-11, 정수님의 결정("이번 한 번만 사용")을 스튜어드가 빌링 워커에 전달하며 슬래시 명령(`/model`)과 지시문을 같은 버스트로 보냈다. 도구는 두 번 다 "Sent and submitted"를 반환했지만 슬래시 명령 직후의 자유 텍스트는 삼켜졌고, 워커는 약 3시간을 답 대기 상태로 서 있었다. 미전달이 두 홉(steward→butler→정수님)을 타고 '완료'로 굳었다. 발견은 우연히 화면을 읽다가 CTX가 149745에서 무변화인 것을 본 것. 정수님 지시(원문): "well, then, after send-message, check after state of recipient with screen read."

**How to apply:**
- `send_to_session` 호출 직후, 같은 턴에서 `read_session_output`으로 수신 세션을 읽어 (a) 메시지 본문이 보이거나 (b) CTX가 메시지 분량만큼 증가했는지 확인한다. CTX 무변화 = 미도달의 값싼 판별기.

> ⚠️ **CTX는 지연 지표다 — 단독으로 쓰면 오탐이 난다.** (2026-08-11, 규칙 시행 첫날 스튜어드가 밟음)
> 수신 세션의 **메인 스레드가 서브에이전트를 기다리며 블록돼 있으면**, 메시지가 정상 도달했어도
> 그 세션이 아직 처리를 시작하지 않아 **CTX가 그대로**다. `monocle-envelop-encryption`에 D 재편
> 지시를 보낸 직후 CTX가 `106753`에서 무변화라 미도달로 보였으나, 화면을 더 읽어 보니 **내 메시지
> 본문이 화면에 그대로 찍혀 있었다** — 도달했고 큐에 들어가 있었을 뿐이다.
> → **판별 순서: ①화면에 본문이 보이는가(권위 있는 검사) ②그 다음 CTX.**
> CTX만 보고 미도달로 판정해 재전송하면 **같은 지시가 두 번 실행된다.** 미도달 오판의 비용은
> 단순 지연이 아니라 **중복 실행**이다. 화면 읽기 줄 수가 모자라 본문이 안 보였을 가능성도
> 배제할 것 — 판정 전에 줄 수를 늘려 다시 읽는다.
- 확인 실패 시 즉시 재전송하고, 재전송본에는 수신자에게 "이전 전달 실패였다"를 명시한다(수신자의 공백 시간이 수신자 탓으로 기록되지 않게).
- 슬래시 명령과 자유 텍스트 지시는 같은 버스트로 보내지 않는다([[butler-a-slash-command-eats-the-message-that-follows-it]] 참고). 순서를 바꿀 수 있으면 지시를 먼저.
- 관련: [[butler-verify-delivery]] (surfaced ≠ delivered — 이 원칙은 그것의 세션 계층 구체화).
