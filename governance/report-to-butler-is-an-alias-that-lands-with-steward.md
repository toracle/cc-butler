---
name: butler-report-to-butler-is-an-alias-that-lands-with-steward
description: "report_to_butler is a deprecated alias that delivers to the STEWARD inbox — so a worker the butler dispatched directly still reports to the steward, and the butler waits for a report that will never arrive unless the steward relays it"
metadata:
  node_type: memory
  type: feedback
---

`report_to_butler`는 **버틀러에게 가지 않는다.** steward 인박스로 떨어지는 deprecated alias다.
따라서 **버틀러가 워커를 직접 배정했더라도 그 워커의 보고는 steward에게 온다.** steward가 릴레이하지
않으면 버틀러는 영영 오지 않을 보고를 기다린다.

이게 조용히 실패하는 이유는 양쪽 다 자기가 옳다고 믿기 때문이다:
- **워커**는 "`report_to_butler`를 불렀으니 버틀러가 받았다"고 화면에 적고 유휴로 들어간다.
- **버틀러**는 "내가 직접 배정했으니 보고도 내게 온다"고 가정하고 기다린다.
- **steward**는 자기 인박스에 뜬 보고를 보고 "버틀러가 직접 수령했겠지, 나는 참고 사본을 받은 것"이라
  읽는다 — 워커가 실제로 그렇게 써 보내기 때문이다.

세 관점이 전부 일관되게 틀려서, **아무도 이상하다고 느끼지 않는 상태로 보고가 증발한다.**

**Why:** 2026-08-11, jarvice v0.141.0..main 갭 리뷰. 버틀러가 steward를 우회해 1130에 직접 배정했고,
1130은 4개 태스크를 마친 뒤 `report_to_butler`로 보고했다고 알렸다. steward는 그 말을 그대로 믿고
핸드오프 파일에 "butler가 직접 수령"이라고 적었다. 그런데 1130의 화면에 그 자신이 남긴 한 줄이 있었다 —
*"reported to the fleet via report_to_steward (the report_to_butler tool is a deprecated alias that lands
there anyway)"*. 즉 **워커가 자기 입으로 진실을 말해줬는데 요약 문장만 읽었으면 놓쳤을 자리였다.**
그 보고에는 태그 커팅 전 사람 승인이 필요한 항목(`ADMIN_BYPASSES_ACCESS_POLICY = True`가 저자
본인이 "미결정"이라 표시한 채 배포)이 들어 있었다. steward가 `escalate_to_butler`로 올려 해소했다.

이건 [[butler-verify-delivery]]의 정확한 재발이다 — 다만 이번엔 내가 보낸 것의 도착이 아니라
**남이 보냈다고 말한 것의 도착**을 안 믿어야 하는 방향이었다. "전송했다"는 발신자의 주장이지
수신의 증거가 아니라는 점은 같다.

**How to apply:**

1. **버틀러가 워커를 직접 배정했더라도, 그 워커의 보고는 steward 인박스로 온다고 가정한다.**
   내 인박스에 뜬 보고를 "참고 사본"으로 취급하지 않는다 — **그게 원본일 가능성이 높다.**
2. **워커가 "버틀러에게 보고했습니다"라고 말하면 그 말을 수신의 증거로 쓰지 않는다.** 워커는
   자기가 부른 도구가 어디로 가는지 모른다. 릴레이 책임을 지려면 **내가 릴레이하거나, 버틀러가
   실제로 받았음을 확인하거나** 둘 중 하나다. 확인이 애매하면 **중복 릴레이가 누락보다 싸다.**
3. **릴레이는 `escalate_to_butler`로 한다** — pull 기반이라 버틀러 세션에 열린 프롬프트/위저드와
   충돌하지 않는다([[butler-relay-safe-worker-decisions]]). 위 사례에서 버틀러 세션엔 permission
   프롬프트가 열려 있었고 정수님이 입력창에 라이브로 타이핑 중이었다 — `send_to_session`이었으면
   내 Enter가 그 프롬프트를 눌렀을 것이다.
4. **워커 보고는 요약 줄만 읽지 말고 화면도 본다.** 이 건의 결정적 단서는 보고 본문이 아니라
   워커가 자기 화면에 부연으로 남긴 괄호 한 줄이었다.
