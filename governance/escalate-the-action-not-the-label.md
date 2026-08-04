---
name: butler-escalate-the-action-not-the-label
description: "An escalation that names a resource by LABEL ('the staging API key', 'prod access') instead of the concrete action needed is unanswerable — the human cannot tell what is being requested. And never aggregate a blocker across tracks without verifying each one: 'one key unblocks six' was false, two of the six needed nothing at all."
metadata:
  node_type: memory
  type: feedback
---

Two failures, one root. Both surfaced when 정수님 finally asked what we had been requesting for days.

## 1. Name the ACTION, not the label

An escalation that asks for a resource by its label cannot be answered, because the label does not tell the human what to do.

> 정수님: "스테이징 API 키는 뭐죠? 스테이징의 내용을 읽고 싶다라는 거 같은데 그러면은 AWS 어카운트의 액세스토큰 같은 거 말하는 건지 싶네요."
>
> ("What is the staging API key? Sounds like you want to read staging — so do you mean something like an AWS account access token?")

He could not tell whether we wanted an application key or cloud credentials. Those are wildly different asks with different risk, and we had merged them under one phrase. The request had been sitting in his queue as a blocker across multiple tracks, unanswerable, because it never said what to actually *do*.

**Answerable form** — the concrete action, self-contained:

> Log into staging jarvice as a tenant admin → `POST /api/v1/auths/api_key` → use the returned `sk-…` as the Bearer token. You hand over nothing; the key is minted on your own account.

**Unanswerable form:** "we need the staging API key."

This extends [[butler-annotate-every-identifier]] from identifiers to *resources and asks*. The test: could the human act on this sentence alone, without asking a follow-up question? If not, it is not an escalation yet.

## 2. Never aggregate a blocker across tracks without verifying each one

The same escalation claimed one credential unblocked six tracks. Checked against the actual code paths, that was false in every interesting way:

- **Two and a half tracks needed NOTHING.** Craft Tier-2 verification is a local `pytest` — the fix was already committed, and `conftest.py` forces in-memory SQLite with no boto3 in the path. The 16-scheduler *verify* half runs locally via `dev_local.py` and had already reached `RUN_SUCCEEDED` weeks earlier. We had been asking the human for access we did not need, to unblock work that was not blocked.
- **Exactly ONE track** genuinely wanted the app API key — and it was self-serviceable, so there was no secret to hand over at all.
- **Two tracks needed AWS credentials** — and not the same ones: two different profiles in two different accounts.
- **Two tracks needed neither** — an interactive SSO/OTP browser session, because those views are `@login_required` with no Bearer path. An API key cannot substitute.

Four distinct needs, collapsed into one phrase. The aggregation did not merely lose detail; it *created* a blocker that did not exist and stalled tracks that could have proceeded immediately.

**Why aggregation is seductive:** summarising "these six are all waiting on staging access" reads as helpful synthesis and makes a tidy queue item. It is the same move as a summary that flattens per-claim provenance ([[butler-merging-agent-results-must-keep-per-claim-provenance]]) — plausible, compact, and wrong in a way nobody can see from the summary itself.

**Why:** 2026-08-04. Six tracks were recorded as blocked on "the bundled staging API key". Verification from code found the above. Two of them had been idle for nothing, and the one valid ask was something the human could do himself in thirty seconds without giving us anything.

## How to apply

- Before escalating a resource need, state the **concrete action** — the exact endpoint, command, profile name, or click-path — and what the requester must actually do.
- Say whether it is **self-serviceable** (the human mints/performs it, hands over no secret) or genuinely requires transferring a credential. These have very different answers.
- **Verify per track, from the code path, before grouping.** If tracks differ, list them separately: "these two need X, these three need Y, this one needs nothing."
- Distinguish **verify** from **deploy** — they routinely need different access, and conflating them invents a blocker for the cheap half.
- When inheriting an aggregated blocker from an earlier escalation, treat it as an unverified claim, not as established state ([[the-tracker-keeps-claiming-work-that-already-shipped]]).
