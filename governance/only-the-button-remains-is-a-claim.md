---
name: butler-only-the-button-remains-is-a-claim
description: "'All blockers are cleared, only pressing deploy remains' is a claim, not a state — deploy-time permissions are invisible to diff, synth, and CI, and only the attempt reveals them"
metadata:
  node_type: memory
  type: feedback
---

When a deploy has been researched to the point of "everything is ready, someone just has to run it," treat that sentence as an unverified claim about the *last* step. Pre-checks establish what the change does; they do not establish that the identity running it is permitted to perform the deploy. Say "no blocker is known to remain," and expect the attempt itself to be the first real test of the deploy path.

**Why:** 2026-08-05, monocle#16 EventBridge scheduler staging deploy. A full day of work reduced it to a clean position: CDK infra already merged, the diff measured (1 TaskDefinition replace, 3 new outputs, 0 deletions, one env var — 정수님's own #1429 welcome-model flip), the cross-stack coupling proven, the flag's live state confirmed via cloudformation:GetTemplate. Every remaining item was framed as "정수님 presses the button in that session." He pressed it. It failed at **asset publish, before CloudFormation was reached** — `<AWS_ROLE_STAGING>` is explicitly denied `s3:ListBucket` on the CDK asset bucket. That role cannot run `cdk deploy` at all. Staging was left untouched, so the failure was harmless, but the day's standing summary had been wrong in a way no amount of further diffing would have corrected. Adding to the trap: `cdk diff` had *succeeded* publishing to the same bucket minutes earlier (plausibly a cached identical asset hash skipping the upload — the worker flagged this as unconfirmed rather than asserting it), so the pre-check actively produced evidence that the path worked.

**How to apply:**
- Distinguish "the change is understood" from "the actor can deploy it." Different evidence, different failure modes; the first is what diffs prove.
- A successful `cdk diff` is not proof that `cdk deploy` will get past asset publish — different S3 operations, and caching can make diff succeed where deploy is denied. Related: [[cdk-synth-is-not-a-deploy-diff]], [[ci-deploy-is-not-cdk-deploy]].
- When you can, verify the deploy identity's permissions *before* declaring readiness, or state explicitly that they are unverified so the remaining risk is visible rather than implied away.
- A permission wall is a good failure — it stops before CloudFormation and changes nothing. Report it as a discovered blocker, not as a botched deploy.
- When the fix is "use a different role," check the replacement stays inside the same account; and note an IAM grant may itself need approval. See [[workers-must-not-reach-aws-profiles]].
