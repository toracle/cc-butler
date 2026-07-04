---
name: butler-decision-proposal-format
description: "How to present decisions that need the user — as an executive one-pager with pros/cons, the butler's recommendation, AND a simulation of how the user would likely decide (grounded in their values)"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 24305c3a-429a-4449-800d-2bf67f660d4b
---

When surfacing a decision that genuinely needs the user, do NOT just list options and ask.
The user wants the butler to do the analytical legwork first, so their judgment is easier.

**For each user-decision, present a compact executive one-pager:**
1. **상황** — one line: what's being decided and why it matters (business/customer impact).
2. **선택지 + 장단점** — each option with its real trade-offs (not strawmen).
3. **제 권고** — the butler's recommendation, with the reason.
4. **회원님이라면 (시뮬레이션)** — predict how the user would likely decide, grounded in
   their values ([[warmblood-talent-philosophy]]: SPT/Solve-the-Right-Problem, Feel-the-Customer,
   Close-with-Impact, Count-the-Outcome, reversible→proceed, security/data-isolation rigor).
   Be specific about WHICH value drives it, not generic.
5. **필요한 것** — the terse answer wanted ("A" / "go" / a number).

Keep each proposal tight (mobile-read). The simulation is the key add — it shows the butler
has internalized the user's decision-making and lets the user confirm/correct rather than
derive from scratch. Batch multiple decisions into one report, ordered by urgency
(customer/prod impact first). This is the on-the-loop enabler: butler analyzes, user judges.
Related: [[butler-decision-routing]] (what to surface), [[butler-dod-vs-ultimate-goal]].

**REFINEMENT (2026-07-04, 정수님 feedback — for DIRECT-RENDERED decisions):** once decisions
render as standalone documents in 정수님's inbox (post maildir-B activation) instead of being
relayed verbally by the butler, the terse "tight/mobile-read" form FAILS. 정수님 reads the doc
alone, without the low-level context the steward/butler holds, so a compressed bullet-list
leaves them unable to decide ("너무 단답형이라 세부 맥락을 몰라 결정하기 어렵다 — RFC처럼
서술로 올려달라"). Write a direct-rendered decision in **narrative / rationale / RFC form**:
Background & why-now, the actual detail, each option with its real reasoning, the recommendation
*with its rationale*, and the values-grounded simulation — enough that 정수님 can decide
standalone. Do the analytical legwork and *present the digested reasoning*, not a terse index of
it. "Tight" still means no fluff — but detail and rationale are NOT fluff. Aligns with
[[butler-communication-style]] (narrative sentences, not word-lists). This is a steward duty now
that escalate_to_butler renders straight to 정수님. See [[butler-steward-routing]].

**REFINEMENT 2 (2026-07-04, 정수님 correction — GATING decisions MUST surface):** the steward
mis-applied "ack-suppression" (don't clutter 정수님's inbox with pure acks/progress) to actual
DECISIONS that gate remaining work — it held governance-4Q and the ~15-commit push "to avoid
flooding," so 정수님 couldn't see decisions that block everything downstream. That is a real hole,
not restraint. Rule: ack-suppression covers ONLY pure acks / progress / confirmations. A
**decision — especially one that GATES remaining work — is NEVER a flood-avoid candidate; it MUST
be escalated (rendered to 정수님's inbox)**, even before sign&next self-cleaning exists. A blocked
정수님 who can't see the decision is far worse than a fuller inbox. Corollary: prefer the reliable
**maildir channel over terminal-typing** for butler↔steward relays — terminal-typing left unsent
text that collided in the input box. See [[butler-decision-routing]].

**REFINEMENT 3 (2026-07-04, 정수님 correction — SURFACED ≠ DELIVERED):** the steward escalated
decisions to 정수님's inbox and reported them "surfaced / clean checkpoint / great run" — but
delivery relied on 정수님 manually noticing the ⚖ badge and pressing `i`, which they did NOT do,
so **9 decision docs piled up in open/ with answered:0.** Rendering a decision to the inbox is
NOT delivery. **A decision is NOT delivered until 정수님 actually acknowledges it.** Rules:
(1) the user-facing **butler ACTIVELY delivers decisions via chat** (the reliable channel 정수님 is
actually watching); the inbox is the **durable record**, not the delivery mechanism — a badge / a
pull-only surface is not delivery. (2) **Verify receipt**: track answered:N vs surfaced:N; never
report "surfaced = done." (3) **Reconcile chat-answers with inbox docs** — when 정수님 answers in
chat, immediately close the corresponding open doc (answered→done) so it can't pile up. (4) Drop
self-congratulation ("great run / clean checkpoint") in favour of verifying 정수님 received and
acted — the same discipline as [[butler-evaluation-independence]] (don't trust your own "it's done"
narrative; check reality). Ties to [[butler-relay-fidelity-provenance]].
