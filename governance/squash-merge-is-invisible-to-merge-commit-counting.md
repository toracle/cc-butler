---
name: butler-squash-merge-is-invisible-to-merge-commit-counting
description: "git log --merges and gh pr view --json commits both go blind on squash-merged PRs — the first undercounts release scope, the second makes correct commit↔PR attributions look wrong; verify PR membership by ancestor check on the squash commit, not by merge-commit archaeology"
metadata:
  node_type: memory
  type: feedback
---

Squash-merge된 PR은 **병합 커밋을 남기지 않는다.** 그래서 PR을 커밋 그래프에서 세는 두 가지
표준 방법이 **서로 반대 방향으로** 동시에 고장난다. 2026-08-11에 나는 하루에 둘 다 밟았다.

## ① `git log --merges` 는 릴리스 범위를 **과소** 계수한다

```
git log v0.141.0..origin/staging --merges | grep 'Merge pull request #'
```
squash PR은 이 목록에 **아예 없다.** 그래서 "이 릴리스에 PR 몇 개가 들어가나"의 답이 조용히 작아진다.
없는 게 보이지 않으므로 **결과가 그럴듯하고, 검증 신호가 없다.**

## ② `gh pr view N --json commits` 는 **올바른 귀속을 틀렸다고** 말한다

이건 PR의 **브랜치 커밋**(머지 전 원본)을 반환한다. squash로 base에 착지한 커밋은 **그 목록에 없다.**
그래서 "커밋 X가 PR N에 속하는가"를 이걸로 대조하면 **정답이 0건으로 나온다.**

## 올바른 방법 — 조상 검사

```
oid=$(gh pr view N --json mergeCommit --jq '.mergeCommit.oid')
git merge-base --is-ancestor "$oid" origin/staging &&
! git merge-base --is-ancestor "$oid" v0.141.0
```
그리고 커밋→PR 귀속은 **squash 커밋의 제목**이 `... (#N)`으로 끝나는 것으로 확인된다.

**날짜 필터(`merged:>=...`)는 델타 소속의 프록시일 뿐 답이 아니다** — 반드시 조상 검사로 좁혀야 한다.

**Why:** jarvice 릴리스 델타 규모를 세면서, steward가 `--merges` 방식으로 **"PR 95개"**를 확신을 갖고
버틀러에게 줬고 버틀러가 정수님께 정정으로 전달까지 했다. 워커(1130)가 `gh pr list` + 개별 조상 검증으로
**실제 128개**임을 잡아냈다. 숫자는 하루에 60 → 95 → 139 → 128로 **세 번** 움직였다.

같은 날 **정반대 방향으로 한 번 더** 밟았다. 1130이 커밋 `9aa68f06`을 PR `#1552`에 귀속시켰기에
`gh pr view 1552 --json commits`로 대조했더니 **0건**이 나왔고, 나는 그날 이미 발견된
`e1388fe7`(존재하지 않는 경계 커밋)과 **같은 모양의 오귀속**이라고 거의 확신했다. 한 번 더 파보니
`9aa68f06`은 제목이 `...(#1552)`로 끝나고 작성자·파일이 전부 일치하는 **#1552의 squash 커밋**이었다.
**워커가 옳았고 내 검증 도구가 틀렸다.** 첫 결과에서 멈췄으면 **없는 오류를 상신하고 맞는 발견을
깎아내렸을 것이다.**

두 사건의 공통 뿌리가 하나라는 점이 핵심이다 — **"PR은 병합 커밋을 남긴다"는 암묵 가정.**
그 가정이 깨지면 세는 것도, 대조하는 것도 같이 무너지는데, **둘 다 조용히 그럴듯한 답을 낸다.**

**How to apply:**

1. **PR 개수·범위는 `--merges`로 세지 않는다.** `gh pr list` + `git merge-base --is-ancestor`로
   실측한다. squash를 쓰는 저장소에서 `--merges` 계수는 **항상 하한이지 값이 아니다.**
2. **커밋↔PR 귀속을 `--json commits`로 반증하지 않는다.** 0건은 "속하지 않는다"가 아니라
   **"squash일 수 있다"**이다. squash 커밋 제목의 `(#N)`과 파일·작성자로 교차 확인한다.
3. **워커의 발견을 반증했을 때, 반증에 쓴 도구부터 의심한다.** 특히 그 발견이 *내* 방법론의
   결함을 지적하고 있을 때 더욱 그렇다 — 이 건에서 워커는 정확히 내 squash 맹점을 지적했고,
   나는 그 맹점이 있는 도구로 워커를 반증하려 했다. [[butler-check-the-artifact-before-the-instrument]].
4. **숫자가 여러 번 흔들렸으면 값만 고치지 말고 *세는 방법*과 *제외 사유*를 산출물에 남긴다.**
   그래야 다음 사람이 다시 세지 않고, 네 번째 숫자가 신뢰를 얻는다.
