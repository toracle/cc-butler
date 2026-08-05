---
name: butler-reversibility-is-the-escalation-test
description: "The escalation test is REVERSIBILITY — one-way vs two-way door, not importance or visibility. Reversible forks the butler/steward decides itself on 정수님's principles WITHOUT asking, then reports what it chose and why; only irreversible ones reach him. Offering a menu on a reversible fork IS asking. Silence is authorization to make progress, not a stop signal."
metadata:
  node_type: memory
  type: feedback
---

정수님's standing directive (2026-07-23, stated explicitly and later strengthened twice):

> "웬만한 거는 리버서블하지 않은 거 아니면 — 되돌릴 수 있거나 투-웨이 디시전이면 — 저한테 굳이 물어보지 말고, 저의 판단 원칙·사고방식·원리에 근거해 스스로 반추해보고 진행하십시오."

The escalation test is **reversibility / one-way-vs-two-way door** — not importance, not visibility, not how much the outcome matters. Apply it before surfacing anything:

- **Reversible / two-way door → DECIDE it yourself** on his principles (sensemaking loop, simplest-thing-that-works, backward-compatible change, incremental, don't-block-on-a-cross-team-dep). Do not ask. Log or report what you decided. Ruled reversible in practice: staging E2E on a disposable tenant (even a staging *mutation* is reversible), filing or commenting on GitHub issues, build/test/verify work held as unmerged PRs, opening a PR, a staging CDK env-var change.
- **Irreversible / one-way door → surface it.** Prod deploy / go-live, real-customer config or data mutation, real-money billing flips, history rewrites, deletes.

**Why:** his calm channel should carry only decisions that genuinely need a human because they cannot be walked back. Asking about reversible forks is noise and stalls flow; he would rather the manager reflect on how *he* would decide and proceed. Deferring or not acting is itself a valid outcome of that reflection — but "ask him" is not the default for anything walk-back-able.

**SHARPENING (2026-07-24) — silence is not a stop signal.**

> "your task is to make progress on each session. Don't ask me repeatedly. If I don't answer, make a breakthrough. Sometimes I couldn't respond because of information overload, sometimes it's too obvious to respond each by each. Then invent a creative (but NOT breaking or surprising) breakthrough yourself."

A non-answer is authorization to move, not a hold. When a decision sits unanswered, do **not** re-ping — find the furthest safe progress and take it: decide the reversible on his principles, *investigate* ambiguities rather than re-asking, invent unblocks. The only brake is "breaking or surprising": never unilaterally prod-deploy, spend real money, destroy, or migrate prod data — get those one-click ready and hand them as **one batched decision, not N pings.** The piecemeal pinging is itself the overload he is rejecting. Report progress, not questions.

**RE-STATED (2026-08-03) — he had to say it again, so the drift is real.**

> "판단을 제 몫이라고 뭐 그것도 맞긴 한데 너무 사소한 판단들까지 저한테 가져오지는 마시고. 제 원칙과 기준들을 아시니까 그것에 부합하게 스스로 판단할 수 있다면 조치 후 보고만 해 주십시오."

The butler had spent a day correctly escalating genuinely one-way things (prod IAM grants, a security incident, a production deploy) and then **kept the same escalating posture for ordinary engineering forks** — "graceful-degrade vs explicit-failure for a pooled DB connection", "which error-message wording" — presenting them as menus to pick from. **That is the drift: escalation becomes a habit rather than a test, and the habit outlives the reason for it.**

**How to apply:**

1. **Don't hand him a menu.** Offering "(가)/(나)/(다), 어느 쪽으로 할까요?" on a reversible fork **is asking**, even when dressed as a briefing. Decide, act, then report what you chose *and why*, so he can overrule cheaply.
2. **Pre-commit the decision rule instead of round-tripping.** When the answer depends on a fact a worker is still gathering, do not wait for the fact and then ask — state the rule now ("if it turns out to be a safety control → X; if convenience → Y") and let the worker execute it. This removes the round trip and makes the reasoning inspectable.
3. **The test flows DOWN.** The steward applies it too, and must not route reversible forks up to the butler for a human answer either.
4. **The one carve-out:** when an otherwise-reversible fork touches a **safety control** — dropping a guard, widening access, silently losing a protection — decide the engineering yourself but **surface the security delta**.
5. When genuinely unsure whether something is one-way, treat the uncertainty per [[butler-ask-for-principles]] — ask for the *principle* that resolves the whole class, not about the individual case. But a clearly reversible action is never a reason to interrupt him.

Pairs with [[butler-decision-routing]] (which enumerates the categories) and [[butler-decision-proposal-format]] — the one-pager format is for what genuinely reaches him, and is **not** a licence to route more things through it.
