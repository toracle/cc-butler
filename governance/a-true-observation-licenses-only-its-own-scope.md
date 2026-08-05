---
name: butler-a-true-observation-licenses-only-its-own-scope
description: "'Ruling something OUT is not ruling something IN. Searching the open set is not searching all of them. A blocked command is a fact about that exact command, flags included. Three same-day incidents where an accurate observation produced a false conclusion because the conclusion covered more ground than the evidence — before acting on a negative result, state what you actually looked at and check the conclusion fits inside it.'"
metadata:
  node_type: memory
  type: feedback
---

An observation can be perfectly accurate and still not support the conclusion drawn from it. The recurring failure is not sloppy looking — the looking is usually fine — it is that **the conclusion covers more ground than the evidence does**, and nothing in the moment flags the gap. A true premise makes a false conclusion feel verified.

Three forms, all seen on 2026-08-06 within a few hours of each other, across three different sessions:

**1. Exoneration mistaken for diagnosis.** The steward investigated whether jarvice#1567 caused the CI formatter drift blocking every PR, established with three solid data points that it did **not**, and stopped there. Ruling out a suspect answers "was it this?" — it does not answer "then what was it?", and only the second question ends the outage. The real cause (our own #1562 merging two unformatted files) was one `git log` away and went unfound for hours while the fleet kept merging conditionally past red checks.

**2. A subset searched, a universe concluded.** Hours later the butler checked the ~30 **open** PRs for a formatter fix, found none, and concluded no fix existed — then dispatched a worker to build one. PR #1574 had already been merged and closed, which is precisely why it was not in the open set. The observation was true of the set examined; the conclusion was about all PRs.

**3. A narrow denial read as a broad malfunction.** A worker's `gh pr merge` was blocked, and it reported the permission classifier as non-deterministic, noting an identical command had worked that morning. It was not identical: this run carried `--delete-branch`, which the earlier one did not. The classifier was denying the destructive branch-deletion side effect while permitting the merge itself — entirely deterministic. Re-running the bare form succeeded on the first try. Note this instance's target: the false conclusion was about a **tool** rather than a code artifact, and it took the shape of "the control is unreliable," which is the most expensive possible misreading of a working safety control.

**Why:** Each of these cost real time or nearly caused real harm — hours of conditional merging, a redundant dispatch that had to be recalled, and (had it been believed) a standing distrust of a control that was functioning correctly. In all three the person was being careful and reported honestly; honesty is what made them catchable. What was missing was a single explicit step between observing and concluding.

**How to apply:**

1. **After a negative result, say the next question out loud.** "It wasn't X" is a waypoint, never a destination. If an outage or defect is still live, the only terminal answer is what *is* causing it. Do not close, report, or move on from a pure exoneration.
2. **Name the set you actually searched, in the same breath as the conclusion.** "No fix exists among the *open* PRs" is a claim you can check; "no fix exists" is not. Writing the qualifier makes the gap visible — most of these die on contact with their own scope statement. Closed/merged items, archived channels, and filtered defaults are where the answer hides precisely because they fell out of the default view.
3. **Diff what you ran against what you meant to run, before blaming the tool.** A blocked or failed command is evidence about that exact invocation — every flag included. Reproduce with the narrowest form that would satisfy the intent before concluding the tool is broken, flaky, or non-deterministic. See [[known-flaky-is-a-claim-not-a-diagnosis]], which is the same disease in the specific setting of test failures: a label that ends inquiry.
4. **Treat "the control is unreliable" as the highest-bar claim you can make.** It licenses working around a safety mechanism, so it needs stronger evidence than any other conclusion, not weaker. Narrowing the request is legitimate; switching mechanism to accomplish a just-denied action is circumvention. See [[relayed-authority-cannot-self-certify]].
5. **Expect this from good workers, and ask for the scope rather than the certainty.** All three instances came from careful operators reporting accurately. The correction is not "be more careful" — it is a habit of stating scope, which is cheap and mechanical. When a worker reports a negative finding, ask what set it covered before acting on it.

**SPT:** the habit is *before acting on "it's not X" or "there's no Y," say what you actually looked at — and check the conclusion fits inside it.*
