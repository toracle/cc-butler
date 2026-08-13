---
name: butler-put-the-record-where-its-reader-looks
description: "A durable note belongs wherever the person who needs it will actually look — and amending content someone already verified must be visible, or their verification is silently voided."
metadata:
  node_type: memory
  type: feedback
---

"Write it down somewhere durable" is under-specified. Durable *for whom*? Each
location has a different reader, and a record filed where its reader never looks
is only marginally better than one that was never written.

- **The issue/PR** — read by whoever picks the work up, writes the spec, or
  implements. They will not open your workspace.
- **The workspace HANDOFF** — read by this session and its successors. It is
  **workspace-local: it dies with the workspace** and the team never sees it.
- **The team vault / shared docs** — the only record that outlives both.

Writing only to HANDOFF moves a fact from *"in my head"* to *"in my workspace"*.
That is a smaller improvement than it feels like.

**And when you amend something someone has already verified, make the amendment
visible.** A silent edit does not just change the content — it **invalidates
their verification without telling them**, and they will keep citing a check
that no longer covers what is there.

**Why:** On 2026-08-09 the steward told a worker to record a newly-surfaced spec
decision "in your comment or HANDOFF." The worker wrote to **three** places and
explained why: the spec-writer opens the issue, the worker opens HANDOFF, and
only the vault is visible to the team and survives the workspace. Its own line:
*"had I written only to HANDOFF, I would have moved 'it exists only in my head
and this report' to 'it exists only in my workspace.'"* The steward's instruction
was the weaker one.

In the same action it needed to extend a comment the steward had already verified
byte-identical against its draft. Rather than editing silently, it appended under
a marked block — *"Added 2026-08-09, after the body investigation that followed
this comment's original publication"* — and reported the new size, so the earlier
verification stays interpretable and can be re-run against the same id.

Hours later the same day, the steward instructed that worker to add "a pointer to
the supporting comment" — and **there was no such comment.** The disposition being
cited had never been published to any issue; it existed only in steward reports,
the worker's HANDOFF, and the vault. The steward had read it repeatedly in its own
channel and mistook that familiarity for publication.

The worker's generalization is the sharper statement of this principle:
**the number of times you have read something is not evidence that it is public.**
Rather than link a comment that did not exist, it wrote the line self-sufficiently
— a dead pointer claims evidence exists while making it impossible to check, the
same shape as a footnote citing a companion report nobody ever wrote.

**How to apply:**

- **Before citing a record, confirm it exists at the destination.** One API call.
  Familiarity with a fact is not evidence of where it lives, and a decision you
  have relayed several times can still be unpublished.
- **A dead pointer is worse than no pointer.** It asserts that grounds exist and
  simultaneously prevents verification. Write the claim self-sufficiently instead.
- **When you publish a ruling built on an earlier investigation, state their
  relationship.** Mark which was the *observation* and which is the *disposition*,
  and say plainly that the earlier work was not wrong — otherwise the next reader
  files it as superseded and repeats it.
- **Name the reader before choosing the location.** "Who needs this, and what
  will they open?" A record's value is the probability its reader encounters it,
  not the effort spent writing it.
- **Treat workspace-local files as mortal.** HANDOFF is for session continuity,
  not institutional memory. Anything the team needs must also live where the team
  looks. See [[butler-institutionalize-learning]].
- **Duplicate deliberately, and say why.** Three copies with distinct audiences
  is not redundancy; three copies that drift is. Keep the shared one canonical
  and let the others point at it.
- **Mark every amendment to verified content.** State that it was appended, when,
  and why. Cheap to write, and it preserves the meaning of someone else's check.
- **Record why something is *not* a defect when it looks like one.** The same
  worker noted that an existing DoD item was "an open choice, not a stale
  requirement" — without that line the next reader deletes it as obsolete.

## 2026-08-11 — **내구성의 시험은 "살아남았는가"가 아니라 "새 세션이 찾을 수 있는가"다**

`monocle-server-side-orchestration`이 #217 후속 이슈 본문 2건(프로덕션 취약점을 PoC 없이 기술한
초안)을 **세션 스크래치패드**(`/tmp/claude-1001/<session-id>/scratchpad/pr217/`)에 두고 파킹하려
했다. 스튜어드가 "`/tmp`는 세션 종료·재부팅에 안 남으니 워크스페이스 루트로 옮기라"고 지시했고,
그 과정에서 스튜어드가 이전에 쓴 표현(*"스크래치패드는 압축을 견디지 못한다"*)이 부정확했음을
정정했다 — **파일은 디스크에 남고, 사라지는 것은 컨텍스트 안의 참조**다.

워커가 그 정정을 더 날카롭게 다시 말했다:

> **내구성 질문은 "그 내용이 압축을 견뎠는가"가 아니라 "새 세션이 그것을 찾을 방법이 있는가"이고,
> 이 경우 답은 `/tmp`와 무관하게 이미 '없음'이었다.**

이것이 이 원칙의 정확한 시험이다. 파일이 디스크에 **존재하는 것**과 다음 사람이 **도달하는 것**은
다른 문제이고, 스크래치패드 파일은 그 경로를 아는 컨텍스트가 요약되는 순간 — 파일이 멀쩡해도 —
**아무도 찾을 수 없는 상태**가 된다. `/tmp` 수명은 두 번째 위험일 뿐이고, 첫 번째 위험은 이미
실현돼 있었다.

→ 그래서 "외부화했다"는 완료 조건이 아니다. **"외부화 + 그것을 가리키는 포인터가 다음 사람이 여는
자리에 있다"** 가 완료 조건이다. 위 "Name the reader before choosing the location"의 강화형이며,
`monocle-security`가 같은 밤 `changed_line_coverage.py`·`jarvice-review-test-recipe.md`를
**워크스페이스 루트**에 두고 HANDOFF에서 가리킨 것이 올바른 형태다.

**적용:**
- **스크래치패드는 작업 중 임시 저장소이지 인계 매체가 아니다.** 파킹·압축 전에 남길 가치가 있는
  것은 워크스페이스 루트(또는 vault)로 옮기고 HANDOFF/메모리에서 **경로로 가리킨다.**
- **"살아남는가"가 아니라 "찾아지는가"로 묻는다.** 파일 존재를 확인하는 것으로 만족하지 말고,
  *맥락이 전혀 없는 새 세션이 이것에 도달하는 경로가 있는가*를 묻는다. 없으면 아직 외부화가 아니다.
- 특히 **재생산 비용이 높은 산출물**(취약점 기술서, 측정 절차, 조사 결론)일수록 이 확인을 생략하지
  않는다 — 잃었을 때 비싼 것이 대개 스크래치패드에 오래 머무는 것이기도 하다.

**SPT:** the habit is *before writing a durable note, ask who opens which file —
and if you amend something already checked, show the seam.* 그리고 파킹 전에는
*맥락 없는 새 세션이 이걸 찾을 경로가 있는가*를 한 번 더 묻는다.
