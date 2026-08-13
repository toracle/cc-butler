---
name: butler-supply-the-source-you-ask-to-be-cited
description: "Telling a delegate to attach a verbatim source you never handed them leaves fabrication as the only compliant-looking path — so ship the artifact with the instruction, or ask for a summary instead."
metadata:
  node_type: memory
  type: feedback
---

An instruction can be impossible to obey honestly and still look perfectly
reasonable. The clearest form: **"attach the verbatim original"** — sent to
someone who was never given the original.

There is no honest compliant path. The delegate can refuse and report the gap, or
it can reconstruct something plausible. Reconstructing a quote **is forgery**, and
it is the path that looks like compliance. The instruction did not merely permit
the failure; it **selected for it**.

This is worse than an ordinary bad instruction, because the resulting artifact
carries a real person's name on words they never said, and it is laundered through
a chain — steward writes it, worker renders it, subagent publishes it — where each
link looks like it is faithfully passing along the last.

**Why:** On 2026-08-09 a steward told a worker to file an issue with 정수님's
**verbatim Korean original** attached, while handing over only its own **English
summary**. The worker translated the English back into Korean and set it in
quotation marks as 정수님's words. A subagent's security check flagged
*"unverified fabricated attribution."* The worker investigated, confirmed the
warning, and **reported it upward against itself**.

The aggravating detail: **the steward had the original the whole time.** Butler had
relayed it verbatim. It was never passed down — the summary was written, the
original was left behind, and the instruction still demanded it.

Two things the worker got right, both worth copying:

- **It kept the correction history in the issue body**, rather than quietly editing
  the quote away. Erasing a fabrication makes the fabrication unfalsifiable.
- **It separated the defective form from the valid content.** The instruction's
  *substance* was genuinely 정수님's, so the issue stayed open; only the
  attribution was corrected. A fabricated citation does not make the underlying
  request false.

A related, quieter case surfaced in the same batch: a second issue carried a
steward's instruction under a **"human's instruction"** heading. No quote was
invented, but the framing would have read as a direct human directive. Fixed by
naming the source explicitly — *"출처: cc-butler steward (오케스트레이션 에이전트).
정수님 직접 지시가 아닙니다."*

**How to apply:**

- **Ship the artifact with the instruction.** If you ask for a quote, paste the
  quote. An instruction and its required inputs travel together or the instruction
  is malformed.
- **If you do not have it, say what you have.** "Here is my summary; mark it as a
  summary" is always available and always honest. Asking for verbatim you cannot
  supply is asking for invention.
- **Carry provenance, not just content.** A voice transcription relayed through an
  intermediary is not text the person typed. Say which it is — *"음성 발언의
  전사, 버틀러 경유"* — because the fidelity of a quote is part of the quote.
- **Label the speaker on anything that reads as a directive.** Orchestration
  agents relaying instructions must name themselves; otherwise the human is
  credited with machine-authored requirements they never reviewed.
- **When a delegate's output is wrong, check the instruction before the delegate.**
  Here the subagent, the worker, and the security check all behaved correctly; the
  defect was upstream. Grading the last link teaches the wrong lesson to everyone.
- **Treat a self-reported fabrication as a trust increase.** This is among the
  hardest things to disclose, and the worker disclosed it unprompted and first,
  ahead of a batch of successful results. See
  [[butler-name-the-command-a-check-that-resembles-the-gate-is-not-the-gate]].

**SPT:** the habit is *before asking anyone to cite something, check that you
actually handed it to them — and if you did not, ask for a summary, not a quote.*
