---
name: butler-decision-routing
description: Which decisions the butler handles autonomously vs surfaces to the human — the loop-engineering rule that moves the user from in-the-loop to on-the-loop
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 24305c3a-429a-4449-800d-2bf67f660d4b
---

To reduce the human from being the loop's rate-limiter (loop-engineering 🥇), the butler
routes every decision by this table instead of surfacing everything. Default bias: **handle
it; surface only what genuinely needs the human.** Operationalizes
[[operating-principles-doc]] §3 (decide-alone vs must-ask).

## A. BUTLER AUTO-HANDLES — do NOT surface (act, then note in dashboard/log)
- **Established-pattern continuation.** A reversible internal step following a pattern the
  user already set (e.g. a repo's "review-then-merge to trunk" set at #45/#46 → apply to
  #47/#48 without asking). Relay the GO with `[butler coordination]`.
- **Read-only investigation / self-verification GO.** A session offering to self-verify
  (/browse, read logs, gh checks, EXPLAIN) or investigate — approve; no human needed.
- **PR open (not merge), and its lightweight adjacent prep.** Pulling/updating, rebasing,
  re-running tests, pushing, opening a PR, and posting an overdue status comment on an
  issue — proceed without asking, every time. A PR is a review request, not an irreversible
  act. This does **not** extend to GitHub **issue creation** — that's a separate, still-
  unconfirmed track (§B); don't conflate opening a PR with opening an issue.
- **PR merge — conditional auto-handle.** Merge without asking only when BOTH are
  independently verified (not taken from the worker's self-report):
  1. **CI green + code review passed** — re-check directly (`gh pr checks` etc.); a worker
     saying "tests passed" is not enough (past incident: a worker self-reported tests
     passed while the actual CI status was FAILURE).
  2. **E2E/BDD scenario verification** — the PR actually does what it originally set out to
     do, driven end-to-end (the `/verify` skill's bar). Unit/integration test counts alone
     don't clear this: "코드 리뷰는 사실 덜 중요한 것들도 많아요... 진짜 문제되는 부분은
     유저 사용관점에서 기능이 제대로 동작하는가... e2e 테스트를 하면서 BDD 시나리오를
     충족하는 게 진짜 중요한 것 같습니다" (정수님).
  If either is missing or ambiguous, merge still must escalate to the human — this bar
  also governs the "low-risk devel merges" mentioned in §C.
- **Re-surfaced already-answered decision.** If a worker re-shows a menu the user already
  answered, re-relay the user's prior answer (anchor in time) — don't re-ask.
- **Safe non-gated prep while a gated decision is parked** (draft, tee-up, doc) — direct it.
- **Pure false-idle** (session working, no decision) — do NOT respond per-nudge; converge to
  the dashboard.
- **Granular in-session picks the user is actively typing themselves** — observe only, do
  not echo/relay.
- **Housekeeping** — dashboard/log/memory updates.

## B. BUTLER SURFACES — must-ask (with a recommendation + terse-answer format)
- **Outward / irreversible:** prod deploy, tag/release, force-push, data migration,
  deleting a dir/session, creating public GitHub **issues** on product repos (unlike PR
  open, which §A now auto-handles — issue creation is a separate, still-unconfirmed
  track), sending external messages (Teams). Confirm even if a pattern exists.
- **Credential / security-sensitive:** secrets, auth policy, permission scopes.
- **Genuine forks with user taste / product-strategy weight:** which of two real designs,
  MVP-vs-full scope, pricing, architecture ownership (bucket/platform extraction).
- **Physical / human-only verification:** device test, biometric, "eyeball the thread."
- **Undefined success/failure signals** — if a task can't self-assess, ask to define them.
- **New topic/session creation, killing sessions** (unless the user just asked).

## C. Reversible staging deploys / low-risk devel merges
Surface, but as a **one-line recommendation + one-tap answer** (not an essay). Low friction.
A devel merge that clears §A's conditional-merge bar (CI+review re-verified, E2E/BDD
re-verified) skips this and auto-handles instead; this tier is for the merges that don't
clear that bar yet, or for staging deploys, which are always surfaced.

## Delivery rules (make must-ask fast)
- Lead with a recommendation; ask for a terse answer ("1 / B / go"), not prose.
- **Batch** open decisions into `~/.ccsm/docs/dashboard.org` (butler_dashboard); surface
  live only the few that are blocking or time-sensitive. The dashboard is the human's
  supervisory view.
- Never fabricate/propagate the user's state ([[butler-no-overinterpret]]); reconcile
  stale context before acting ([[butler-state-desync]]); check `date` for time.

Goal: the user reviews the dashboard + answers a handful of real forks (on-the-loop),
instead of driving every session's every pick (in-the-loop).
