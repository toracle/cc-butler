---
name: butler-a-queued-compaction-outlives-the-force-that-preempted-it
description: "Forcing a compaction does NOT cancel one already queued — the queued one fires later and compacts twice. And separately: the 3-step compaction path (downgrade → /compact → restore) frequently stops after step 2, stranding the session on Sonnet while CTX=0k looks perfectly healthy. Sweep the MODEL column every time you read session_status, and re-check after EVERY forced compaction — measured ~40% strand rate."
metadata:
  node_type: memory
  type: feedback
---

`compact_session(force=true)` preempts the wait, but it does **not** consume or
cancel a compaction already queued on that same session. Both triggers stay
live against one target. The forced one runs immediately; the queued one fires
whenever its idle window finally closes — possibly much later — and compacts
the session a **second** time.

The casualty is the re-hydration message sent in between. That message is
precisely the content least able to survive summarization: dense externalized
facts (PR numbers, branch names, commit SHAs, and caveats whose wording is
load-bearing), which a summarizer compresses into gist exactly where the detail
was the point.

**Why:** 2026-08-05, `monocle-jarvice-1130`. It had a queued compaction that had
starved. I forced one (349k → 0k) and re-hydrated it with its three PRs
(#1547/#1548/#1549), the absent-vs-malformed `toolIds` distinction, and the
paired residual-risk sentences. About an hour later `session_status` showed it
`blocked: compaction already in flight` — the old queued request, still pending —
and it fired, taking the session 124k → 0k and summarizing that re-hydration
away. Two compactions, one intended.

Note the misreading this invites: a session you *just* re-hydrated showing 0k
looks like a fresh problem, or like the re-hydration failed to land. It is
neither. It is the earlier queue arriving.

**How to apply:**

1. Before forcing, check `session_status` for a pending/in-flight compaction on
   that session. If one exists, expect a second compaction and plan to
   re-hydrate twice rather than treating the second as a fault.
2. Treat an unexplained context drop on a recently-forced session as **this
   mechanism first**, not as an anomaly to investigate. Re-hydrate and move on.
3. The real mitigation is upstream: **write the re-hydration facts to
   `butler_log`, not only into the message sent to the worker.** The log
   survives arbitrarily many compactions on both sides — the worker's and the
   steward's own. In this incident re-hydrating a second time cost nothing,
   because the facts were already in the log and did not have to be
   reconstructed from a summarized transcript. This is
   [[butler-externalizing-is-not-delivering]] running in the useful direction:
   externalizing did not *deliver* anything, but it made delivery cheaply
   repeatable, which is what you want when delivery can be undone by a
   background process you did not schedule.
4. Corollary to [[butler-context-ceiling-and-compaction]]'s "a read figure is a
   claim": a 0k reading is ambiguous in a second way beyond staleness. It may be
   the momentary trough *mid*-compaction rather than the settled size —
   `monocle-envelop-encryption` read 0k and settled at 122k once its summary and
   restored file refs loaded back, while genuinely parked sessions sit at a true
   0k. Both look identical in the table; re-read before concluding.

## 2026-08-10 재발 — 그리고 이 원칙이 놓치고 있던 두 번째 피해자

같은 일이 `monocle-monocle-472-image-edit`에서 다시 났다. 위 1번("강제하기 전에
예약된 압축이 있는지 확인하라")을 **내가 쓰고 닷새 뒤에 내가 어겼다.** 규칙을 적어둔
것과 그 규칙이 쓰이는 자리에서 떠오르는 것은 별개다 — [[a-true-observation-licenses-only-its-own-scope]]
항목 16과 같은 모양이고, **패턴에 이름을 붙인 사람이라는 사실은 그 패턴에 대한 면역이
아니다.**

새로 드러난 것: 두 번째 압축의 피해자는 컨텍스트만이 아니라 **모델**이다.

압축 경로는 "Sonnet으로 내림 → `/compact` → 원래 모델로 복원"의 3단이다. 그런데 첫
번째(강제) 압축이 이미 컨텍스트를 비운 뒤라, 뒤늦게 발화한 예약 압축은 Sonnet으로
내린 다음 `/compact`에서 **"Not enough messages to compact"** 를 만난다. 압축이
성사되지 않으니 3단이 끝까지 가지 못하고, **세션은 Sonnet에 남는다.** 화면에는
`/model sonnet` → `/compact` → "Not enough messages to compact" 가 그대로 찍혀 있다.

이 형태가 특히 나쁜 이유: `session_status`에서 `CTX=0k`는 **정상으로 보인다.** 압축이
잘 된 것처럼 보이고, 실제로 컨텍스트는 잘 비워져 있다. 조용히 틀린 건 MODEL 열
하나뿐이고, 그 워커는 그때부터 의도한 것보다 약한 모델로 판단 업무를 계속한다 —
아무 소리도 나지 않는다. 위 3번이 "예상치 못한 컨텍스트 하락"을 이 기제로 읽으라고
했는데, **하락이 없는 경우가 오히려 더 위험하다.**

→ **압축 후 점검은 CTX가 아니라 MODEL을 본다.** 특히 "예약 + 강제가 겹친 세션"에서는
CTX가 정상이어도 MODEL을 반드시 확인하고, 어긋나 있으면 `/model <원래모델>`을 보내
복구한다. 이건 [[steward-compaction-force-vs-queue]]의 "복원까지 봐야 끝난다"가
말하던 바로 그 실패 양식의 구체적 발생 경로다 — 그 메모는 *무엇을* 확인하라고 했고,
여기서는 *왜 어긋나는지*가 밝혀졌다.

그리고 워커에게 사과할 것. 압축이 두 번 걸린 것도, 약한 모델에 방치된 것도 워커가
만든 상황이 아니다.

## 같은 날 22:5x 3차 재발 — **모델 스트랜딩은 스스로를 영속화한다**

같은 세션(`monocle-monocle-472-image-edit`)에서 **몇 시간 뒤** 또 났다. 이번엔 내가
강제한 게 아니다. 훨씬 전에 예약해둔 압축이 **몇 시간을 살아남아** 뒤늦게 발화했고,
이미 빈 세션을 만나 같은 경로로 실패했다. 화면 순서가 그대로 증거다:

```
/model claude-opus-5          ← 내가 1차 사고 때 복구시킨 것
/model sonnet                 ← 유령 예약 압축이 발화
/compact  → "Not enough messages to compact."
                              ← 복원 없음. Sonnet에 남음.
```

**예약된 압축의 수명은 내 주의력의 수명보다 길다.** 위 1번은 "강제 직전에 확인하라"고
했는데, 이 3차는 강제가 아예 없었다 — 확인할 *시점*이 존재하지 않는 형태다.

### 새로 드러난 진짜 위험: 스트랜딩이 다음 압축의 기준선이 된다

압축 3단의 마지막은 "**원래 모델**로 복원"인데, 그 "원래 모델"은 **압축을 시작하는
시점의 현재 모델**로 잡힌다. 그래서 이미 Sonnet에 스트랜딩된 세션에 다음 압축이 걸리면
**Sonnet이 "원래 모델"로 기록**되고, 그 압축은 정상 완료되면서 세션을 **Sonnet으로
"올바르게" 복원**한다.

→ **한 번의 스트랜딩이 그 뒤 모든 압축에 의해 정상 상태로 세탁된다.** 1차 사고의 흔적은
화면 스크롤백에 남지만(`Not enough messages to compact`), 2차 압축 이후로는 그 흔적조차
사라지고 **어디를 봐도 이상해 보이지 않는다.** 복구 창은 생각보다 짧다.

실제로 3차 발생 직후 `session_status`는 `CTX=112k / MODEL=Sonnet-5 /
blocked: compaction already in flight` 였다 — 즉 **또 하나의 압축이 이미 대기 중**이었고,
그게 발화하면 Sonnet이 기준선으로 굳는다. `/model claude-opus-5`를 즉시 밀어넣어
기준선이 굳기 전에 되돌렸다.

### 그래서 규칙을 바꾼다 — 사후 점검이 아니라 정기 스윕

"압축 후에 MODEL을 확인하라"(위 →)는 **불충분하다.** 압축이 내가 모르는 시점에 발화하기
때문에, "압축 후"라는 시점을 내가 알 수 없다. 대신:

5. **`session_status`를 볼 때마다 MODEL 열을 통째로 훑는다.** CTX가 아니라 MODEL이
   1차 판독 대상이다. Opus여야 할 세션이 Sonnet에 있으면 그것 자체가 사고 신호다 —
   원인을 몰라도 즉시 `/model <원래모델>`을 보낸다. 원인 규명은 복구 뒤에 한다.
6. **각 워커의 "정상 모델"을 알고 있어야 이 스윕이 작동한다.** 모르면 이상함을 볼 수
   없다. 핸드오프/대시보드에 워커별 의도 모델을 적어둔다. 이건
   [[a-true-observation-licenses-only-its-own-scope]]의 "기준선 없이는 이상을 볼 수
   없다"와 같은 구조다.
7. **압축을 예약했으면 그 사실을 기억에 두지 말고 적어라.** 몇 시간 뒤에 발화하는데
   그때 나는 이미 다른 일을 하고 있다 — 위 3번("리하이드레이션 사실을 `butler_log`에
   써라")과 같은 이유로, **예약 사실 자체도 외부화 대상**이다.

이 세 번의 재발이 공통으로 말하는 것: **압축은 내가 호출하는 동기적 행위가 아니라,
호출한 뒤 내 주의에서 벗어나 독립적으로 살아 있는 백그라운드 프로세스다.** 동기적
행위로 취급하는 한 이 실패는 계속 난다.

## 2026-08-11 — **빈 세션 문제가 아니다. 정상 압축에서도 복원이 빠진다.**

하룻밤에 두 건 더 났고(`monocle-jarvice-978`, `monocle-security`), **이번 둘은 위 2·3차와
발생 조건이 다르다.** 앞의 사례들은 "이미 빈 세션에 압축이 걸려 `Not enough messages to
compact`로 실패 → 3단이 중단"이라는 설명이 붙어 있었다. 그런데 이번 둘은:

```
/model sonnet
/compact  → Compacted (ctrl+o to see full summary)   ← 성공했다
            (파일 참조 복원, 스킬 복원까지 정상)
                                                      ← 복원 라인이 없다. Sonnet에 남음.
```

**압축이 정상 성공했는데도 3단의 마지막이 실행되지 않았다.** 즉 "빈 세션이라 실패해서
중단됐다"는 기존 설명은 **원인의 일부일 뿐**이고, 복원 단계는 압축 성공 여부와 무관하게
빠질 수 있다. 두 세션 모두 컨텍스트는 328k·292k에서 0k로 잘 비워졌고, 파일·스킬 복원도
정상이었다. **오직 모델만 되돌아오지 않았다.**

### 측정된 발생률 — 예외가 아니라 상시 점검 대상

이 날 밤 강제 압축 5건 중 **2건(약 40%)이 스트랜딩**됐다(`978`, `security`). 정상 복원된
것은 `butler`, `envelop-encryption`, `jarvice-1130` 3건이다. **40%는 "가끔 나는 사고"가
아니라 기본 동작으로 가정해야 하는 비율이다.**

8. **모든 강제 압축 뒤에는 반드시 MODEL을 재확인한다.** 위 5번의 "볼 때마다 훑는다"에
   더해, **내가 압축을 건 세션은 개별적으로 확인**한다. 40%는 스윕이 다음에 돌 때까지
   기다릴 수 있는 확률이 아니다.
9. **워커에게 "복귀하면 MODEL부터 확인하라"고 시키는 것으로 대신하지 않는다.** 실제로
   `monocle-security`는 파킹 전에 *"복귀하면 MODEL=부터 확인하고 Opus-5가 아니면 되돌린
   뒤 알려드리겠습니다"* 라고 명시했는데, **스트랜딩된 상태에서는 그 약속을 실행할 턴이
   오지 않았다.** 확인 책임이 확인 대상에게 있으면 실패 시 아무도 확인하지 않는다 —
   [[butler-loud-failure-must-be-verified-to-reach-someone]]과 같은 구조다. **압축을 건
   쪽이 확인한다.**
