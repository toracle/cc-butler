---
name: butler-a-found-defect-licenses-the-rest-of-the-sentence
description: "문장에서 결함 하나를 찾아 정정하는 행위가 그 문장의 나머지 주장들을 무감사 통과시킨다 — 정정할 때는 찾은 결함만 고치지 말고 문장이 주장하는 바를 항목별로 세어 각각 감사하라"
metadata:
  node_type: memory
  type: feedback
---

Finding and correcting one defect in a sentence feels like auditing the
sentence. It is not — it audits one claim, and the act of correction itself
becomes the license that ships the rest unexamined. The corrected sentence now
carries *more* credibility than before ("this was checked"), while its other
claims were never looked at.

**Why:** On 2026-08-09 night, the butler told 정수님 tonight's schedule run was
"처음으로 끝까지 달린 것" (the first to run end-to-end), attributing it to the
#1626 fix. The butler then self-reported the **attribution** defect (two
variables — revision and output format — changed between the morning failure and
the night success, so causality was unproven) and proposed holding a correction
until logs decided it. Reasonable — but that self-report let **"처음으로"** pass
unexamined, and that word was a *fact* claim already contradicted by evidence in
hand: the 16:40 run had **already** completed end-to-end (file created, `url`
present, attachment realized — the very evidence that closed branch A hours
earlier). One defect was correctly deferred to measurement; the other could
never become true by waiting. The steward's framing: "틀린 부분이 아니라 맞은
부분이 나머지를 통과시킵니다" — and the same shape had recurred all day (302.9s
measured correctly but sample identity wrong; file search actually run but
result misread).

**How to apply:**
- When you correct (or self-report a defect in) a sentence you sent, **re-read
  the whole sentence and enumerate what it claims, item by item** — then audit
  each item, not just the one you caught. This is the sentence-version of
  "never write a count without writing its list"
  ([[butler-the-verified-half-licenses-the-unverified-half]]).
- Sort each claim by *how it can be resolved*: some are pending measurement
  (defer, then correct once), some are already contradicted by held evidence
  (correct now — waiting cannot make them true). A deferral plan for one class
  must not absorb the other.
- Superlatives and firsts ("처음으로", "유일하게", "가장") are fact claims about
  a set you must actually enumerate — they hide in narrative sentences and
  survive correction passes aimed at causal claims.
- The feeling of "I already flagged the problem with that sentence" is the tell.
  One flag per sentence is not a property of sentences.
