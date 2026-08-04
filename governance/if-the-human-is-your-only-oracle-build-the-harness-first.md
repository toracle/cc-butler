---
name: butler-if-the-human-is-your-only-oracle-build-the-harness-first
description: "정수님, 2026-08-04: when a defect cannot be reproduced or tested locally, building that test environment outranks shipping the fix — otherwise the human becomes the only instrument and every fix is a guess he has to validate"
metadata:
  node_type: memory
  type: feedback
---

**정수님's judgement, 2026-08-04, verbatim:** "1511 그 커스텀 엠시피가 크래프트에서 안 잡히는 문제는 로컬에서 재현하거나 테스트가 안 되는. 그 테스트 환경을 갖추는 게 제일 중요할 것 같습니다."
("For the problem of the custom MCP not being picked up in Craft — it can't be reproduced or tested locally. Building that test environment is probably the most important thing.")

So: **when a defect cannot be reproduced locally, the harness outranks the fix.** Not after the fix, not alongside it — before. Otherwise the human is the only instrument, and every attempt is a guess he has to validate at his own cost.

**Why:**

The Craft custom-MCP defect ran the whole of 2026-08-04 without a single local reproduction. What happened instead:

- The cause was inferred by *reading code* — a string mismatch where an allowlist checked `"auth_provider"` while the generated value was `"provider"`. Real, confirmed in source, and fixed in jarvice#1511 with a regression test.
- Every gate passed: RED/GREEN evidence, CI green, merged, promoted, deploy verified two-source.
- 정수님 tested. **Still not found.**
- Only then did the load-bearing unknown surface: nobody knew which `credential_strategy` his server used. It had been flagged unverified that same morning and reasoned over all afternoon.
- And it could not be checked, because no screen renders it (monocle#435) and the backend reports a wrong build hash so "which commit is running" is unanswerable on any environment (monocle#434).

Three separate observability holes, and the human absorbing all of them. He ran the only test that existed, and it cost him a merge, a promotion, a deploy and an afternoon to run once.

**The deeper point:** "we didn't know his credential_strategy" is the proximate cause. The real one is that **there was no way to observe the system except through him.** A harness would have enumerated all five strategies against the real manifest path and produced the whole table — at which point his value merely says which row he is in, rather than being the precondition for knowing anything.

**How to apply:**

- The moment you notice "I can't reproduce this locally," that becomes the work item, ahead of the fix. Say so out loud rather than proceeding on code-reading.
- Invoke **`boundary-contract-testing`** — this is precisely its case: an integration bug across a boundary, where you emulate the channel, test each contract locally, and leave only the one irreducible physical step. Then **`verify-first`**: the harness's DoD is a test that FAILS on the broken state and PASSES on the fixed one, per variant, through the real code path — not a test that merely runs.
- Pair with **`new-variant-completeness`**: enumerate every value on the axis (here all five credential strategies) and drive each to its terminal side effect. Widening an allowlist without doing that is what shipped a fix for the wrong case.
- Never make the human the oracle for something a harness could answer. If he must be — because only he holds the fact or the access — say explicitly that this is what you are doing and why, and name what would remove the need.
- Related: `a-test-that-cannot-fail-is-not-evidence`, `steward-verify-the-running-artifact`, `bug-fix-driven-development` (reproduce before fixing — this note is what to do when you *can't* reproduce yet).
