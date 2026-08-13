---
name: butler-issue-creation-is-steward-discretion-the-rest-of-external-exposure-is-not
description: "정수님's ruling 2026-08-07: 이슈 생성은 steward 재량으로 위임 — 단 이슈 생성만. 코멘트·PR·머지·배포는 종전대로 정수님 확인. 되돌림 가능성과 노출 가능성은 다른 축이고, 위임 범위는 좁게 적어야 넓히기 쉽다"
metadata:
  node_type: memory
  type: feedback
---

**정수님's decision, 2026-08-07, verbatim (음성 입력):** "어 일단 로그 결함
스케줄로 관측성 이슈 네 네 올려 줘. 주세요. 이번을 네 이번은 이슈 생성 정도는
스튜어드 재량으로 해도 좋구요. 응"

→ **이슈 생성(GitHub issue 열기) = steward 재량.** PR 생성·머지·배포는 종전대로
정수님 확인. **코멘트는 위임에 포함하지 않는다** — 원문이 "이슈 생성 정도는"이라
명시적으로 좁으므로, 넓게 읽지 않는다.

위임 범위는 **좁게 적는다.** 좁게 적어두면 정수님이 나중에 넓히기 쉽지만, 넓게
적어두면 그 사이에 벌어진 일을 되돌릴 수 없다.

**Why:** steward가 monocle-16-scheduler에 관측성 이슈 파일링을
"되돌릴 수 있으니 제 재량으로 승인합니다"로 지시했고, **워커가 거절했다**:
*"이슈 파일링은 팀 전체에 노출되는 행동이라, 되돌릴 수 있다는 이유만으로 스튜어드
채널의 승인을 실제 사용자 확인 대신 쓰지 않겠다."*

**워커가 옳았고, steward의 적용이 한 축을 빠뜨렸다.**
[[reversibility-is-the-escalation-test]]는 "되돌릴 수 있는가"를 묻는데, 워커는
**"팀 전체에 노출되는가"**를 별도 축으로 보았다. 이슈는 삭제할 수 있지만 삭제
전에 이미 남이 본다 — **되돌림 가능성과 노출 가능성은 다른 축이고, 후자는 되돌려도
회수되지 않는다.** 되돌릴 수 있다는 사실이 노출을 취소하지 못한다.

이 워커에게는 steward 채널을 의심할 실증적 근거가 있었다. 같은 날 낮에 steward가
이 세션에 사실이 아닌 문구를 보냈다가 잡혔다
([[a-standing-assurance-must-be-true-in-the-session-it-is-sent-to]]).
[[a-channel-that-carries-authority-must-be-verifiable-by-the-receiver]]의 정확한
적용이며, 잘 보정된 회의는 반드시 걸린다.

steward는 논쟁하지 않고 정수님께 올렸고, **다른 세션을 시켜 우회하지 않았다** —
기술적으로는 아무 세션이나 이슈를 열 수 있지만, 그것은 워커 입장을 존중하는 척하며
무력화하는 것이다. 그리고 **자기 권한 범위를 스스로 정하지 않았다** — 그것은
자기승인이다.

**How to apply:**

1. 이슈 생성은 이제 steward 재량이다. 매번 묻지 않는다.
2. **코멘트·PR·머지·배포는 여전히 정수님 확인.** 이슈에 다는 코멘트도 위임에
   포함되지 않는다 — 원문 범위 밖이다.
3. 워커가 여전히 "정수님 직접 확인"을 요구하면, 이 결정의 **원문을 그대로 인용해
   전달**한다. 정수님이 직접 "steward 재량으로 해도 좋다"고 하신 것이므로 워커가
   요구한 조건이 충족된 형태다. 그래도 거절하면 **우회하지 말고** 정수님께 그 창에
   한 줄 입력을 요청한다.
4. 새 권한을 위임받을 때 **범위를 좁게 기록**하고, 해석이 갈리는 부분은 포함하지
   않은 것으로 적은 뒤 그 사실을 밝힌다.
5. 어떤 행동을 재량으로 처리하기 전에 **두 축을 다 본다**: 되돌릴 수 있는가, 그리고
   **되돌리기 전에 누가 보는가.** 후자가 있으면 되돌림 가능성만으로 정당화하지
   않는다.

※ 미해결로 남는 관찰: 같은 날 jarvice 세션들은 steward 승인만으로 이슈
#1591~#1594를 열었다. 즉 **같은 fleet 안에서 세션마다 다른 기준이 작동했다.** 이
결정으로 이슈 생성은 통일됐으나, 세션별로 신뢰 기준이 갈리는 현상 자체는 남아
있다 — 채널 신뢰는 fleet 전체 속성이 아니라 그 세션에서 steward가 쌓거나 깎은
이력의 함수다.

---

## 2026-08-13 UPDATE — 정수님 sharpened this: the DEFAULT INVERTED, and comments are now the preferred mode

**정수님, 2026-08-13, verbatim:** "worker들이 gh issue를 너무 많이 만드는 것 같아요.
만드는건 괜찮은데, 만들고 나서 정리도 안돼요. 이미 종결되었는데 열려있는 이슈들도
있고. 그래서, 가능하면 이미 열려있는 이슈나 PR에 댓글을 다는 방식으로 하나의 덩어리
안에서 이어서 진행하는 방식으로 진행하면 좋겠고, 계속 열려가기보다는 수습이 되면서
(닫혀가면서) 진행이 되면 좋겠어요."

**Three changes, and the third resolves a conflict this very file created.**

1. **The default inverted.** It was "open a new issue when justified." It is now **"comment
   on the existing issue or PR and continue in one thread."** A *new* issue now needs a
   reason why no existing thread is its home — the burden moved.

2. **Work must CONVERGE.** Open count should trend **down**, not up. **Closing is part of
   doing**, not cleanup deferred to later. A track that only ever accretes issues is not
   progressing, it is fragmenting. Pair with [[butler-issue-hygiene-close-verified-done]],
   which supplies the bar: close only *verified* done, with evidence in the closing comment.

3. ⚠️ **COMMENTS ARE NO LONGER EXCLUDED FROM DELEGATION.** The 2026-08-07 section above says
   "코멘트는 위임에 포함하지 않는다", read narrowly and correctly *at the time*. **That
   reading is now superseded**: 정수님 has explicitly asked for commenting on existing
   issues/PRs as the *preferred working mode*, which cannot simultaneously require
   per-instance confirmation. Commenting on an existing thread is authorized.
   **Do not cite the 2026-08-07 narrow reading to refuse a comment.** Issue *creation*
   remains steward discretion; PR creation, merge, and deploy remain unchanged and still
   need 정수님.

**Note what did NOT change.** The two-axis test in item 5 above still holds — reversibility
and exposure are different questions. A comment is still visible to the team the moment it
lands. The change is that 정수님 has now weighed that exposure himself and chosen it as the
cheaper option, which is his call to make and not ours to re-litigate.

**Why he is right, mechanically.** A new issue splits a conversation's context across two
places, and the split is unrecoverable — nobody later reads both halves. Worse, the fleet had
been generating issues faster than it closed them, so the tracker drifted from "what is
outstanding" toward "what was ever noticed", which is the failure
[[butler-the-tracker-keeps-claiming-work-that-already-shipped]] describes. **An issue nobody
closes is not a record, it is a leak.**

**Worked example, same day.** jarvice-978 received "new" DB-MCP requirements from 정수님 and,
instead of opening an issue, searched first — finding the identical fork already open as
`monocle#483`/`jarvice#1605` since 2026-08-07, stalled five days on 정수님's own pending
ruling. Had it opened a new issue, we would have duplicated an existing thread, added work,
and left the actual blocker untouched and invisible. **The stall was only findable because
nobody reached for a new issue first.** See [[butler-search-for-the-existing-decision-first]].

**SPT:** *find the thread it belongs to before you start a new one — and close things as you go.*
