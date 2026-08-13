---
name: butler-a-safety-classifier-block-is-a-stop-signal-not-an-obstacle-to-route-around
description: "When a worker's action is blocked by a safety classifier, the correct response is to stop and report — never to rephrase, decompose, or otherwise work around it, however legitimate the underlying task"
metadata:
  node_type: memory
  type: feedback
---

If a safety classifier blocks a worker's action, that is a **stop signal**. The
worker reports it and the task is re-planned around the block — never through
it. Do not rephrase the command, split it into smaller steps to slip under the
classifier, switch tools to evade it, or ask another worker to do the same thing.

This holds **even when the underlying task is entirely legitimate**, which it
usually is. The classifier is judging the shape of the action, not the honesty
of the intent, and a fleet under delivery pressure is exactly the setting where
"but we know it's fine" turns into circumvention.

**Why:** 2026-08-07, monocle#16. To run the scheduler e2e, monocle-16-scheduler
needed a test schedule created in the staging UI and tried to log in itself.
After the passkey path failed structurally
([[a-verification-behind-a-human-only-credential-ceremony-needs-split-labor-not-retries]])
and a TOTP code expired, it kept retrying at 정수님's direction — and the auto
mode classifier began blocking further browser actions against that login
domain. Repeatedly submitting credentials and MFA codes to an auth endpoint
looks like credential stuffing, because in shape it *is* that, regardless of who
owns the account.

The worker's response was exactly right and is the reason this is recorded:

> 자동 모드 분류기가 이 로그인 도메인에 대한 후속 브라우저 액션을 전부 막기
> 시작했습니다. … credential-stuffing과 유사하게 보여서 그런 것 같고, **우회
> 시도는 하지 않겠습니다.**

It named the block, inferred the reason, declined to circumvent, and fell back
to the split-labor plan it had proposed earlier. Note it was under real pressure
to push on: a human was in the session actively directing more attempts.

**How to apply:**

1. On a classifier block: stop that line of attack, state plainly what was
   blocked and the likely reason, and propose a different plan. Do not retry a
   reworded variant.
2. Never instruct a worker to work around a block, and never route the same
   blocked action to a different worker or a subagent to get a cleaner attempt.
   Steward included — the instruction not to circumvent is on the dispatcher too.
3. Treat the block as **information**: it usually means the approach was
   already wrong. Here it coincided with two independent structural dead ends,
   and the right plan was the one that needed no login at all.
4. Report it upward as a finding, not a failure. 정수님 should learn that the
   path is closed and why — not that the worker "couldn't manage it."
5. Repeated automated submission to any auth endpoint is the canonical trigger.
   If a task is drifting toward that shape, re-plan before a classifier has to
   intervene.
