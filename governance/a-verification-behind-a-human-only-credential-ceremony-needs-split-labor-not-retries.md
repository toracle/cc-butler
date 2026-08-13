---
name: butler-a-verification-behind-a-human-only-credential-ceremony-needs-split-labor-not-retries
description: "When a worker must reach the product UI to verify something, passkey/WebAuthn and similar human-only auth block it structurally — detect it early, split the work so the human does only the credentialed step, and never let a failed login look like a pending push on their phone"
metadata:
  node_type: memory
  type: feedback
---

Some verification steps sit behind an authentication ceremony that only a human
body can complete — passkey/WebAuthn (fingerprint, Face ID), hardware tokens,
SMS/TOTP to a personal device. A worker in a headless sandbox cannot pass these,
and no amount of retrying or cleverness changes that. This is a *structural*
boundary, like [[live-aws-verification-uncloseable-in-worker-sandbox]], not a
difficulty to push through.

When you hit one, do not keep trying. Restructure the division of labor: the
human performs **only** the credentialed action, and the worker verifies
everything downstream from the backend, where it has real access.

**Why:** 2026-08-07, monocle#16 scheduler e2e. To exercise the full chain the
worker needed a test schedule created in the staging UI, so it tried logging in
itself with a headless browser. "패스키로 로그인" produced no dialog and no page
change. The console gave the exact cause:

    NotSupportedError: Resident credentials or empty 'allowCredentials'
    lists are not supported at this time.

Two things mattered here beyond the failure itself:

1. **Nothing was ever sent to 정수님's phone.** The headless browser's WebAuthn
   implementation rejected the request client-side, before it reached the
   server. Had this gone unexplained, he could have sat watching a phone for an
   approval that was never dispatched — a silent wait manufactured by a
   worker's failed attempt. Compare the same failure family in
   [[verify-delivery-at-the-recipient-not-the-return-string]].
2. **The email-code fallback was worse, not better.** It works, but it turns
   every verification into a code-relay round trip through the human. The
   worker correctly rejected it.

The worker's own proposal was the right one and cost the human a single action:
정수님 creates one test schedule and reports the tenant plus scheduled time;
the worker then verifies every hop (dispatcher → SQS → launcher → ECS RunTask →
schedule_run → DB message) from CloudWatch and the AWS CLI, with no login at all.

**How to apply:**

1. Before dispatching any verification that touches the product UI, ask whether
   it requires an authenticated session. If it does, assume the worker cannot
   get one and plan the split up front rather than discovering it after a
   failed attempt.
2. Cut the human's part down to the **minimum credentialed action** — usually
   "create one object and tell me its identifiers." Everything observable from
   the backend stays with the worker. Never ask for repeated UI steps.
3. When reporting such a block upward, state explicitly whether the human's
   device was contacted. "폰으로 아무것도 가지 않았습니다 — 기다리지 않으셔도
   됩니다" is load-bearing: it cancels a wait they might not know they were in.
4. Quote the actual error (console/log line). It is what distinguishes a
   structural block from a fixable misconfiguration, and it stops the next
   session from re-attempting the same dead end.
5. Do not manufacture a substitute check to avoid asking. An unverified step
   reported honestly beats a proxy measurement presented as verification — see
   [[a-test-that-cannot-fail-is-not-evidence]].
