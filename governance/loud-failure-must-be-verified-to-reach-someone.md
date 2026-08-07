---
name: butler-loud-failure-must-be-verified-to-reach-someone
description: "Before telling a decision-maker 'it fails loudly, so we can fix it later,' verify the signal actually reaches a human — a log line is not an alarm"
metadata:
  node_type: memory
  type: feedback
---

When a risk assessment leans on "it will fail loudly" or "we'll notice and backfill later," treat the loudness as a **claim to verify**, not a property to assume. Find the actual path from the error to a person: is there an alarm, a metric filter, a log subscription, a DLQ, a pager? If the answer is "an ERROR line in a log group," the risk is unmonitored, not monitored.

Watch especially for the case where the *graceful* handling deliberately bypasses the mechanism that would have surfaced it. Code that catches an exception specifically so it does **not** fail the record is, by construction, code that keeps the problem out of the DLQ and the retry alarm.

**Why:** 2026-08-05, reviewing chat-proxy#350 for 정수님. I established that shipping #342 without stark's catalog degrades gracefully — billing continues via cost_factors, the raw envelope is preserved losslessly, and the aggregator logs the unknown surface. That reassurance was going to 정수님 with "it fails loudly and is re-derivable" doing real work in the sentence. Butler pushed back and asked whether the log *goes anywhere anyone watches*. It does not: stark has zero MetricFilter and zero SubscriptionFilter repo-wide, warmblood-infra likewise, usage_tracking_stack.py defines no alarm or SNS topic, and `UnknownUsageSurface` is deliberately separated from `MetricAssemblyError` precisely so the record does *not* fail — so it never reaches the DLQ, the one mechanism that would have surfaced it. The safety argument had two legs and both were weak: not loud (no alarm), and the backfill is a capability rather than a scheduled job. Combined, the realistic outcome is that nobody ever finds out.

**How to apply:**
- Grep the infra for `Alarm` / `MetricFilter` / `SubscriptionFilter` / DLQ wiring before asserting loudness. Zero hits repo-wide is strong evidence.
- Separate what you verified from what you inferred: "no alarm is defined in code" is a fact; "nobody watches it" is a strong inference. Say which is which — console-created alarms are invisible to a code search.
- Distinguish a **capability** ("the raw is preserved, so it can be re-derived") from a **procedure** ("a job re-derives it"). In retelling, "we can recover it" reliably becomes "it will be recovered," and then no one does it. Name the person and the time, or don't count it as mitigation.
- If the mitigation is unmonitored, say so plainly — it raises the cost of "accept the gap" even when the data really is safe. See [[verify-delivery]] and [[verify-subagent-claims-directly]] for the same shape one level over.
