---
name: butler-a-tools-warning-threshold-is-not-the-systems-limit
description: "A monitoring tool's stated threshold is its own policy setting, not the system's limit — cc-butler's 'Threshold: 300k' was read as the model ceiling for a whole day while the statusline percentages showed the real window was ~1M, causing a healthy session to be written off as frozen"
metadata:
  node_type: memory
  type: feedback
---

모니터링 도구가 찍어주는 임계값은 **그 도구의 정책 설정**이지 시스템의 한계가 아니다.
그런데 도구가 그것만 보여주면 읽는 쪽은 **그것을 분모로 삼는다** — 그리고 분모를 확인하지 않는다.

**Why:** 2026-08-11, cc-butler `session_status`는 각 세션의 컨텍스트 크기를 찍고 하단에
`Threshold: 300k`를 붙인다. 그리고 컨텍스트 알림은 *"1 session(s) over 300k"*라고 경고한다.
steward는 하루 종일 300k를 **모델의 천장**으로 읽었다.

실제로는 각 세션 상태줄이 **퍼센트를 같이 찍고 있었다**:
```
monocle-jarvice-1130 : CTX=331382  33%
monocle-jarvice-978  : CTX=297448  30%
steward (압축 직후)  : CTX=76358    8%
```
**331k가 33% → 실제 창은 약 1M.** `Threshold: 300k`는 cc-butler가 압축을 걸 시점을 정한
**자체 정책값**이었다. 증거는 내내 화면에 있었고, 아무도 나눠보지 않았다.

이 잘못된 분모 위에서 내린 실제 결정들:
- **`monocle-jarvice-978`을 "동결(FREEZE), 말 걸지 말 것 — 다음 메시지가 천장을 칠 수 있다"로 처리**하고
  디스크 파일 4개로만 접근하기로 했다. 실제로는 **30%, 여유 700k**였고 그 세션은 #1707 원 리뷰 맥락을
  들고 있는 유일한 세션이었다. **멀쩡한 자산을 죽은 것으로 취급했다.**
- butler 압축을 force로 걸며 **"282k = 천장 18k 전"**을 근거 중 하나로 댔다. 282k는 약 28%였다.
  (행동 자체는 옳았다 — butler 본인이 요청했고 큐가 실제로 발화하지 않고 있었다. **틀린 건 근거 하나였다.**
  옳은 행동을 틀린 이유로 하면, 다음번 비슷한 상황에서 그 이유가 혼자 돌아온다.)
- 컨텍스트를 아끼려 여러 번 서둘러 판단했다.

가장 뼈아픈 부분: **`a-threshold-is-not-a-cliff-check-the-denominator`가 이미 이 저장소에 있었다.**
원칙을 보유한 채로 하루 종일 적용하지 않았다. 원칙은 검색해서 꺼내 쓰는 것이 아니라 **신호를 볼 때
발화해야** 하는데, 도구가 권위 있는 숫자를 던져주자 그 발화가 일어나지 않았다.

**How to apply:**
1. **도구가 임계값을 주면 "이건 정책값인가 물리적 한계인가"를 먼저 묻는다.** 대개 정책값이다.
   한계라면 도구가 보통 퍼센트나 비율로 말해준다.
2. **분모를 한 번은 직접 확인한다.** 여기서는 나눗셈 한 번이면 됐다(331382 ÷ 0.33). 하루가 걸릴 일이 아니었다.
3. **"임계값 초과"를 "고장 임박"으로 번역하지 않는다.** 정책 임계값을 넘는 건 대개 *비용·지연·캐시*
   문제이지 **죽음이 아니다.** 작업 중단 비용이 최적화 이득보다 크면 미뤄도 된다.
4. **어떤 자원을 "죽었다/못 쓴다"로 분류하기 전에 그 판정의 근거 숫자를 검산한다.**
   자산을 죽은 것으로 오분류하는 비용은 조용하고 크다 — 아무도 다시 확인하지 않기 때문이다.
5. **옳은 행동을 여러 근거로 정당화했다면, 나중에 그중 하나가 틀렸음을 알았을 때 그것만 따로 철회한다.**
   결론이 맞았다는 이유로 틀린 근거를 남겨두지 않는다.
