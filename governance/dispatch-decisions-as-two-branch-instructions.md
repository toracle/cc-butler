---
name: butler-dispatch-decisions-as-two-branch-instructions
description: "A worker verifies a decision's premise when the instruction has two branches — apply if it holds, report if it breaks. Told only 'apply this', the same worker applies it. The checking is a property of the dispatch format, not of the worker's diligence."
metadata:
  node_type: memory
  type: feedback
---

When relaying a decision to a worker, the difference between these two dispatches
is not politeness — it changes what work gets done:

- *"Apply decision X."* → the worker applies X.
- *"Verify X's premise holds in the code. **If it holds, apply. If it breaks, do
  not apply — report immediately.**"* → the worker checks first, and the check is
  part of the job rather than an act of initiative.

**Verification you want to happen must be written into the instruction as a
branch.** A single-branch instruction names an outcome, and a worker delivering
that outcome is doing exactly as asked. There is no moment where checking is the
obvious next step, because the instruction already said what the end state is.

**Why:** On 2026-08-09, under widened delegation, the butler ruled that the
#472 interpretation-hop belongs to chat-proxy — a decision *deduced from a stated
principle*, not read off the code. The steward passed it down with an explicit
two-branch condition. The worker split the derivation into three claims and found
the central one false: base64 already traverses every internal hop today, so
"jarvice resolving it would newly violate the rule" could not be true. The
conclusion survived; the stated reason did not, and a document citing an
already-broken rule as the reason to protect it never shipped.

The worker then declined the credit, and its reasoning is the principle:

> *"To be precise, it was the steward who attached the condition to doubt it. I
> received two branches — apply if it holds, report if it breaks — so the
> comparison was part of the task. Had I received only 'apply this', I most
> likely would have applied it. What is reproducible is not my disposition but
> the instruction format."*

That is the correct attribution. Treating it as worker virtue makes the outcome
unreproducible; treating it as dispatch design makes it a lever the steward can
pull every time.

A second instance the same hour, same mechanism: the steward said *"check your
HANDOFF has today's decisions **before** compacting."* The worker looked and found
**no HANDOFF existed at all** — a session days old, carrying live architecture
decisions, with no durable record. Its own note: had it looked *after* compacting,
it could not have distinguished "the file was thin" from "there was never a file."
The instruction's *ordering* produced a finding that the same instruction, given
later, would have destroyed.

**How to apply:**

- **Write the failure branch explicitly.** "If the derivation breaks, do not
  apply — report." Without a stated branch for failure, the only path is success.
- **Deduced decisions always ship with a verification branch.** A conclusion
  derived from a principle has not touched the code. That is precisely the shape
  that hardens into premise — see
  [[butler-the-justification-for-a-decision-becomes-its-premise-not-its-test]].
- **Order the instruction against what would erase the evidence.** "Check before
  compacting/clearing/merging" is not the same instruction as "check." Put the
  check where the answer still exists.
- **Name what to verify, not just that verifying is good.** The steward listed
  three concrete questions (does chat-proxy have the access, the storage path,
  the credentials?). The worker exceeded them — but the list is what made the
  task tractable enough to exceed.
- **When a worker credits your instruction rather than itself, believe it and
  bank the format.** The reusable artifact is the dispatch shape. Praising the
  worker's judgment and moving on discards the only part that generalizes.

**SPT:** the habit is *before sending a decision downward, ask "what would this
worker do if the premise were false?" — and if the answer is "apply it anyway,"
add the branch.*
