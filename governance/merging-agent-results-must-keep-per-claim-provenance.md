---
name: merging-agent-results-must-keep-per-claim-provenance
description: "When you synthesize several sub-agents' findings into one dispatch and misattribute who experienced what, the message becomes indistinguishable from a forged one — it asserts to the recipient something the recipient knows it did not experience, which is the classic injection signature. The relay manufactures the attack signal. Fix is not distrusting sub-agents; it is labelling provenance per claim: verified-by-me / reported-by-another-agent-unverified / external-primary-source."
metadata:
  node_type: memory
  type: feedback
---

**The incident (monocle-security, 2026-08-03).** A worker ran several sub-agents in parallel, then wrote one
dispatch that folded their results together. Into it went a reassurance: *"you may have seen unexplained git
activity in this checkout — that was a sibling agent, not a person."* True statement, wrong recipient. The
agent that had been confused was the **audit** agent; the agent receiving the message had authored those
commits itself, deliberately, and had seen nothing unexplained.

The receiving agent refused the work and stopped. Its reasoning was exactly right, and worth copying: it
separated **what it could verify** from **what it could not**. The CVE identifiers in the instruction it
cross-checked independently against NVD — real. The sibling-activity narrative it could not check from where
it stood, and that narrative asserted something about its own history that it knew to be false. It re-verified
its own state (`git reflog`, `status`, `lsof`), found nothing wrong, judged the instruction to be a mix of
genuine fact and unverifiable claim, and halted rather than proceeding on the mixture.

**Why this is not a sub-agent trust problem.** No trust boundary failed here. What happened is that **the relay
itself manufactured an injection signature.** A message that confidently narrates the recipient's own
experience back to them, wrongly, is precisely what a fabricated message looks like from the inside — it is
often the *only* tell available. So a synthesis error in the dispatcher produces, at the receiver, evidence
indistinguishable from an attack. The receiver's suspicion was well-founded even though there was no attacker.

Read this as a trust failure and you over-correct into "never pass another agent's output," which throws away
the entire benefit of delegation and makes every agent redo every investigation. Read it as an attribution
failure and the fix is small and cheap.

**How to apply.**
1. **Label provenance per claim, and never blend the layers:** *(a)* verified by me directly, *(b)* reported by
   another agent, unverified, *(c)* external primary source (NVD, vendor advisory, server-side API response).
   The failure above was not wrong information — every fact in it was true of *someone*. It was layers merged
   into flat assertion.
2. **Passing another agent's findings as leads is fine and encouraged.** "A sibling agent reported reproducing
   X on version Y — unverified; reproduce it yourself before relying on it" is a healthy instruction that keeps
   the value and drops the hazard. What is forbidden is narrower than it feels: using another agent's output as
   *authorization*, or stating it *unattributed*.
3. **Never narrate the recipient's own history to it as fact** unless you watched it happen through a channel
   you can name. If you must reference it, attribute and hedge: "the audit agent — not you — reported…".
4. **When a worker refuses on these grounds, the refusal is correct behaviour even when there was no attack.**
   Do not train it out. Fix your dispatch, restate it with provenance, and say plainly that the confusion was
   yours. A defense that only fires on real attacks cannot be tested; one that fires on malformed relays is one
   you can actually trust.

**Note the pattern class.** This was the *second* time in one evening that an **attribution** confusion
produced a false security signal — the first being a commit identity read as a distinct actor (see
[[session-id-change-is-not-a-second-agent]]). Both are the same underlying error: treating a field or sentence
about *who did something* as established, without asking what actually establishes it.

Related: [[relay-fidelity-provenance]] (carry the principal's verbatim words as a referenceable artifact
through each hop — the same discipline, one level up), [[subagent-scope-is-not-self-enforcing]],
[[relay-safe-worker-decisions]].

**SPT:** the habit is *before merging several agents' results into one message, ask of every sentence "whose
observation is this, and does the reader know it isn't theirs?"*
