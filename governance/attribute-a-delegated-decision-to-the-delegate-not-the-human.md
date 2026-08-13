---
name: butler-attribute-a-delegated-decision-to-the-delegate-not-the-human
description: "A decision made under delegated authority must be recorded as the delegate's, never as the human's — writing their name on your call puts words in their mouth and turns their later reversal into self-contradiction."
metadata:
  node_type: memory
  type: feedback
---

When a human widens delegation — *"obvious한 사안은 go"* — the decisions that
follow are **yours**, made under their authority. They are not the human's
decisions. Recording them as the human's is a factual error with real
consequences, and it is a *new* hazard that appears exactly when delegation
widens: the more you decide on their behalf, the more chances to sign their
name to it.

Three things break when you misattribute:

1. **It puts words in their mouth**, often in a public artifact (an issue
   comment, a design doc, a changelog) that outlives the session.
2. **It makes their reversal look like self-contradiction.** A delegated call is
   reversible by definition — that reversibility is usually *why* it qualified as
   obvious. But if the record says *they* decided it, overturning it reads as the
   human flip-flopping rather than a principal correcting an agent.
3. **It destroys the audit trail.** "Who decided this, on what authority?" is the
   question that arrives months later. If every decision bears the human's name,
   the answer is unrecoverable — and the delegation itself becomes invisible.

**Why:** On 2026-08-09 정수님 widened decision delegation. The butler ruled five
items obvious and the steward executed them. Applying one of these, a worker
drafted a public comment on monocle#489 closing with **"정수님 판단"**. It caught
this before publishing: the ruling had come from the butler and steward under
delegation, not from 정수님 at all. It corrected the line to state explicitly
that the call was made *within delegated scope, not by 정수님 directly.*

The worker classified it itself as the same species as an earlier miss where it
had stated an inference as fact — and it is: an unverified claim about **who
decided**, written in the voice of settled record. The draft's sentence was not
sloppy, it was *confident*, which is what made it dangerous. Note also what
caught it: the worker refused to assume its scratchpad draft matched the
published body, fetched the published comment, and compared. The attribution
error surfaced during that comparison.

**How to apply:**

- **Name the actual decider and the authority, in the artifact itself.** "Decided
  under delegated authority by <role>; not a direct ruling by <human>." One
  clause. It costs nothing at write time and is unreconstructable later.
- **The hazard scales with the delegation.** Every widening of authority
  multiplies the artifacts you sign. Treat "the human approved X" as a claim
  requiring the same verification as any other — did they, or did you, on their
  behalf?
- **Preserve the reversal path.** Correct attribution is what lets a principal
  overturn a delegated call cheaply and without loss of face. Wrong attribution
  quietly raises the cost of them changing their mind, which is the opposite of
  what reversibility was for.
- **Escalations and relays carry the same duty.** When reporting upward, keep
  "we decided" and "you decided" distinct. See
  [[butler-relay-fidelity-provenance]] — a relay must not manufacture authority
  any more than it manufactures certainty.
- **Compare the published artifact to your draft.** Attribution slips live in
  closing lines and summaries — the parts written last, revised least, and read
  first. Fetching the published body and reading it back is what exposed this
  one.

**SPT:** the habit is *before publishing a decision, ask "who actually made this
call?" — and if the answer is "I did, under their authority," write exactly
that.*
