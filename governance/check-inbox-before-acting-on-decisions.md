---
name: butler-check-inbox-before-acting-on-decisions
description: "Before acting on a decision — especially anything external or irreversible — read the human's ACTUAL answer with check_inbox; a delivered CC/arrival is not the same as having read it, and acting without reading causes desync + overreaction"
metadata:
  node_type: memory
  type: feedback
---

The answer-CC and the arrival notification make a decision's status **reach** the
inbox — but reaching is not reading. **Before acting on a decision, actually read
the human's answer** (`check_inbox` / open the decision doc) and confirm it says
what you think it says.

**Why:** acting on an *assumed* answer, without reading the real one, causes
desync and overreaction. On 2026-07-04 the butler flipped the public repo to
private **before the human's answer had arrived** — the human had actually
decided to *accept* the exposure (no private, no purge), so the flip was an
out-of-sync overreaction that then had to be corrected. The information to
prevent it was in the inbox; it just wasn't read first.

**How to apply:** gate every decision-driven action on a fresh inbox read —
**especially anything external or irreversible** (publish, force-push, a
visibility change, a deploy, a delete, touching another account). The more
irreversible the action, the more mandatory the read. Never let a passive
"a decision is pending" signal, or your own expectation of the answer, stand in
for the human's actual words. Ties to [[butler-verify-delivery]] (delivered ≠
acted-correctly), [[butler-state-desync]] (anchor in real state, reconcile before
acting), and [[butler-broadcast-verify-one-first]] (verify before the
irreversible fan-out).
