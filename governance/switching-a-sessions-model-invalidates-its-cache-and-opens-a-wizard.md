---
name: butler-switching-a-sessions-model-invalidates-its-cache-and-opens-a-wizard
description: "send_to_session으로 보낸 /model은 즉시 적용되지 않고 확인 위저드를 연다 — 캐시된 대화가 있으면. 그래서 ①여러 세션에 일괄 전송하면 위저드를 동시에 여러 개 열어놓게 되고 ②전환 자체가 프롬프트 캐시를 무효화해 다음 메시지에서 전체 히스토리를 다시 읽는다. 큰 세션을 아끼려고 바꾸면 먼저 그 크기만큼 쓴다."
metadata:
  node_type: memory
  type: feedback
---

`send_to_session`으로 `/model sonnet` 같은 모델 전환 명령을 보내면 **즉시 적용되지 않는다.**
**캐시된 대화가 있는 세션에서는 확인 위저드가 열린다:**

```
Switch model?
Your next response will be slower and use more tokens
This conversation is cached for the current model.
Switching to Sonnet 5 means the full history gets re-read on your next message.
 ❯ 1. Yes, switch to Sonnet 5
   2. No, go back
```

여기서 두 가지가 동시에 문제가 된다.

## ① 일괄 전송하면 위저드를 동시에 여러 개 열어놓게 된다

전환 명령을 여러 세션에 연달아 보내면 **그 세션들이 전부 위저드에서 멈춘다.** 그 상태에서
자유 텍스트를 보내면 **내 Enter가 위저드의 하이라이트된 항목을 누른다** —
[[butler-relay-safe-worker-decisions]]가 경고하는 바로 그 충돌인데, 이번엔 **충돌 상대를 내가
직접 9개 만들어 놓은** 형태다. `session_status`의 `blocked: an interactive menu/wizard is open`
표시가 유일한 단서였다.

**빈/신선한 세션에서는 위저드 없이 바로 적용된다.** 그래서 "아까 한 세션에서 잘 됐으니 괜찮다"가
성립하지 않는다 — 캐시가 쌓인 큰 세션에서만 뜬다. 즉 **정확히 전환할 가치가 큰 세션에서만** 뜬다.

## ② 전환은 프롬프트 캐시를 버린다 — 아끼려는 행동이 먼저 비용을 낸다

위저드 문구가 명시한다: *"the full history gets re-read on your next message."*
**147k~207k 세션을 Sonnet으로 바꾸면, 절약이 시작되기 전에 그 크기만큼의 재읽기를 한 번 낸다.**

→ 그래서 "예산이 부족하니 전부 Sonnet으로"는 **단순 적용하면 역효과가 날 수 있다.** 판단 기준:
- **리셋(예산 갱신)까지 파킹할 세션** → 전환해도 좋다. 재읽기 비용이 **다음 메시지**에 발생하므로
  **새 예산 기간으로 넘어간다.** 절약만 남는다.
- **지금 계속 일할 세션** → 재읽기 비용이 **지금** 발생한다. 남은 작업량이 세션 크기보다 작으면
  **전환이 손해다.** 그대로 두고 끝낸 뒤 전환한다.
- **작은/신선한 세션** → 재읽기가 싸고 위저드도 안 뜬다. 부담 없이 전환.

**Why:** 2026-08-11, 주간 한도 87% 소진 상황에서 정수님이 *"use sonnet for workers as possible."*
지시. 스튜어드가 9개 세션에 `/model sonnet`을 연달아 보냈고, 그 중 **5개가 위저드에서 멈췄다**
(`monocle-iros`, `dealmatch`, `monocle-paid-mcp-tool-billing`, `monocle-jarvice-1130`,
`monocle-16-scheduler`). 신선한 세션 하나(`monocle-monocle-472-image-edit`)만 위저드 없이 전환됐다.
`session_status`의 wizard 표시를 보고 알았고, 화면을 읽어 위저드 내용을 확인한 뒤 `1`을 보내
해소했다. **그 사이 어느 세션에도 자유 텍스트를 보내지 않은 것이 운이 좋았다** — 보냈으면 5개가
동시에 삼켜졌을 것이다.

**How to apply:**

1. **모델 전환은 일괄로 쏘지 말고, 보낸 뒤 `session_status`로 위저드 여부를 확인한다.**
   `blocked: an interactive menu/wizard is open`이 보이면 **아직 전환되지 않았고 세션이 멈춰 있다.**
   `MODEL` 열이 바뀌었는지까지 봐야 끝난 것이다.
2. **위저드가 열렸으면 화면을 읽어 선택지를 확인한 뒤 번호를 보낸다.** 하이라이트된 기본값을
   가정하지 않는다. 이 사례에서는 `1`이 "Yes, switch"였다.
3. **위저드가 열려 있는 동안 그 세션에 자유 텍스트를 보내지 않는다.** 삼켜진다
   ([[butler-a-slash-command-eats-the-message-that-follows-it]], [[butler-relay-safe-worker-decisions]]).
4. **전환 여부는 "이 세션이 앞으로 얼마나 더 일하는가"로 정한다.** 파킹 예정이면 전환,
   지금 마무리 중이면 끝내고 전환. **크기만 보고 "큰 세션부터 바꾸자"는 정확히 거꾸로다** —
   큰 세션일수록 재읽기 비용이 크다.
5. **고위험 산출물을 만드는 중인 세션은 예외로 남긴다.** 이 사례에서 `monocle-security`는
   정수님이 프로덕션에서 직접 실행하실 절차서를 쓰는 중이라 Opus로 뒀다.
   예산 절약은 **틀린 프로덕션 명령 한 줄보다 싸지 않다.**
