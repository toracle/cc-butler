---
name: butler-a-bar-the-human-sets-on-one-item-applies-to-its-structural-twin
description: "'When the human imposes a quality gate on one work item, it is a standing bar for every structurally identical item — not a preference about that item; and when his correction arrives, do not extract only the lesson about how to PITCH the next one while leaving what it actually NEEDS unchanged'"
metadata:
  node_type: memory
  type: feedback
---

When the human imposes a gate on one item — *"run /code-review and /verify-first on this first"* — he is stating a **bar**, not a preference about that item. Every work item of the same shape inherits it, immediately, without being told again. If two items are structurally identical and only one got the gate, the asymmetry is **ours to close**, and closing it should not require him to ask.

There is a sharper, second failure hiding inside the first. When his correction lands, it carries both a **substantive** instruction (what the work needs) and an incidental **rhetorical** one (which argument he rejected). Taking only the rhetorical lesson feels like learning — you visibly change behaviour — while leaving the actual gap untouched.

**Why:** 2026-08-08. 정수님 answered a merge request on dealmatch `#1122` not with approval but with `/code-review on PR#1122 and /verify-first`. That review found **4 real defects**, all fixed. The steward read this correctly *as far as it went*, and told the butler explicitly: when re-presenting jarvice `#1613`, do **not** open with *"CI is green, please approve"* — that is the argument he just declined; lead with *"deployment is the precondition for the last check."*

**That was the wrong half.** The steward updated how to **pitch** `#1613` and never asked what `#1613` **lacked**. It lacked exactly what `#1122` had just been sent back for: `reviews: []`, `reviewDecision: ""`, zero code review on 594 added lines across 6 files. The steward had personally verified that PR's CI at the source with `gh` — it had the tool in hand, ran it, and never looked at the adjacent field. So the same argument he had already declined was used a second time on the same day, and it took him asking *"critical defect가 있나요? 아니면 merge 갈까요?"* for anyone to check.

The tell was visible for an hour and got explained away: **one PR had a review gate and its twin did not.** That difference was read as "he happened to care about `#1122`" instead of "he set a bar." A human imposing a gate on the item in front of him is not scoping the gate to that item; he is showing you the standard, once, and reasonably expecting it to propagate.

Note also that "CI green" and "reviewed" are different claims about different things, and CI being green makes the missing review *less* visible, not more — a green check reads as sufficiency.

**How to apply:**

1. **When the human sends work back with a gate attached, immediately ask which other in-flight items are the same shape** — same repo class, same risk class, same "cannot be verified without deploying" structure — and apply the gate to all of them before he sees them. Do this in the same turn the correction arrives.
2. **Separate his correction into substance and rhetoric, and act on the substance first.** "Don't use that argument" is the cheap half. "That item wasn't ready" is the expensive half. If you only changed your wording, you have not responded to him.
3. **Check the adjacent field.** When verifying a PR's readiness, `reviews` / `reviewDecision` sit next to the CI status in the same `gh pr view` output. Deciding to check one and not the other is a choice, and "I verified the PR" is then a claim broader than what was done — see [[butler-a-true-observation-licenses-only-its-own-scope]].
4. **Treat an unexplained asymmetry between twin items as a finding, not a coincidence.** "He asked for X on that one but not this one" almost never means the standard differs; it usually means he saw one and not the other. Raise it yourself rather than waiting to be asked.
5. **Report the omission plainly when it surfaces, including which role held the tool.** Both the butler and steward owned this in their own words. A gate that was skipped is worth more as a recorded standard than as an apology.
6. Related: [[butler-merge-verification-bar]] (what a merge actually requires), [[butler-the-human-acts-outside-your-channels-so-re-check-before-re-asking]] (he sets standards by acting, not only by instructing), [[butler-a-recorded-decision-is-not-a-shipped-decision]].
