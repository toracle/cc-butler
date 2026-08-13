---
name: butler-github-org-members-are-inside-the-trust-boundary
description: "정수님 ruling (2026-08-09): GitHub org 멤버는 신뢰 경계 안 — private 레포 이슈에 미패치 취약 경로 등 상세 기술을 두는 것은 노출이 아니다; 이 판단은 '이런 상세를 어디에 적을지'의 기준으로 쓴다"
metadata:
  node_type: memory
  type: feedback
---

GitHub org(warmblood-kr) 멤버는 신뢰 경계 **안**이다. private 레포의 이슈·PR·코멘트에 미패치 취약 경로, 크로스테넌트 위험, 보안 상세를 기술하는 것은 "공개"가 아니며, default-safe 판단에서 노출 리스크로 계상하지 않는다.

**Why:** 2026-08-09. 버틀러의 GO 판정 ②("4단 public 폴백 공개 이슈화 보류 — 미패치 크로스테넌트 경로를 공개 기술하지 않는 것이 default-safe")를 집행하려던 검증에서 두 사실이 나왔다: jarvice는 PRIVATE 레포라 노출 범위가 인터넷이 아니라 org 멤버였고, 그 미패치 경로는 이미 #1614 본문에 하루 전부터 상세히 적혀 있었다. 워커와 steward 모두 "org 멤버 = 신뢰 경계 안인가"를 자기 판단 범위 밖으로 명시하고 올렸고, 정수님이 직접 답했다: **"github org 멤버는 신뢰 경계 안이라고 봐도 됩니다."**

**How to apply:**

1. private 레포 이슈에 보안 상세(미패치 경로, 파일:라인, 재현 체인)를 적는 것을 막거나 축약하자는 판단을 세우지 말 것 — 상세함은 표류 방지 장치다(#1614가 그 예).
2. "공개 이슈화" 류 결정에서 노출 범위를 계상할 때, 레포 visibility를 실물 확인하고(`gh repo view --json isPrivate`), private이면 org 멤버 = 신뢰 안으로 둔다.
3. 이 판단이 바뀌면(외부 협력자 초대, org 구성 변화 등) 이 노트를 갱신할 것 — 경계는 구성의 함수다.
