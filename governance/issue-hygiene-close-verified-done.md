---
name: butler-issue-hygiene-close-verified-done
description: "정수님 상설 지시(2026-08-11): 완료된 것으로 보이는데 안 닫힌 GitHub 이슈들을 관리하라 — 단, 검증된 완료만 닫고 추정으로 닫지 않는다"
metadata:
  node_type: memory
  type: feedback
---

함대는 관할 리포 전체의 GitHub 이슈 위생을 상설 관리한다: 작업이 끝났는데 열린 채 남은 이슈를 주기적으로 찾아 닫는다.

**Why:** 정수님 지시 (2026-08-11, 축어): "and, we also need to take care of gh issue closing. 이미 이미 완료가 된 것으로 보이는 깃허브 이슈들도 클로즈가 안 된 경우들이 있는 것 같습니다. 그것들도 잘 관리해 줘야 합니다." 열린-이슈 목록이 실제 미결 작업을 반영하지 않으면 트래커가 거짓말을 하게 되고, 이미 배송된 작업을 다시 잡는 낭비([[the-tracker-keeps-claiming-work-that-already-shipped]])가 생긴다.

**How to apply:** (a) "완료로 보임"과 "완료 검증됨"을 가른다 — 닫는 것은 검증된 완료만: 해당 수정이 실제로 병합·(해당 시) 배포되었고 이슈의 DoD(2026-08-06 지시가 적용되는 이슈면 구현+리뷰+QA/E2E)가 충족됐음을 확인한 뒤, **근거(커밋/PR/배포 확인)를 닫는 코멘트에 남기고** 닫는다. (b) 추정만으로 대량 닫기 금지 — 애매한 건은 닫지 말고 목록으로 보고한다. (c) close_topic류 판정 시 스테일 로컬 ref 함정 유의([[close-topic-audit-uses-local-refs]] — full-fetch 후 origin 기준). (d) 감사 주체는 스튜어드가 워커에 위임해 주기적으로 돌린다.
