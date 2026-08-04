---
name: butler-probably-unchanged-is-an-argument-not-a-check
description: "When you extend a model/spec/test-suite, a prior UNSAT or passing-negative result does not carry over — new expressiveness can only add witnesses, so it can silently break exactly the results that assert none exist. A plausible argument that nothing changed is not a substitute for re-running the check."
metadata:
  node_type: memory
  type: feedback
---

**Where this came from (2026-08-04, `monocle-server-side-orchestration`).** The
steward asked whether Alloy check #4 (`MediationRemovalFlipsCustomTools`, UNSAT
— the mandatory positive control) would still hold once the model was extended
with a credential mode it had turned out not to represent.

The worker answered **NO, it must be re-run** — and then, unprompted, gave the
reason rather than the verdict:

> Extending a model with new expressiveness can only ever put **NEW SAT
> witnesses** within reach — it cannot remove ones that already existed. UNSAT
> is exactly the property new expressiveness can silently break; SAT is
> comparatively safe under extension, since old witnesses stay valid.

It also had a perfectly reasonable argument that nothing would change in
practice — the two facts #4 actually depends on (Tier-2 has no mediator;
`CredentialRequired` true) were independently confirmed and unlikely to move
under either resolution. It refused to let that argument stand in for the check:

> **"Probably unchanged" is an argument, not a check, and I'm not substituting
> the one for the other.**

## The asymmetry, stated generally

This is not Alloy-specific. It applies to anything where a result asserts
*absence*:

- **UNSAT / "no counterexample found"** — asserts no witness exists in the
  searched space. Widen the space and a witness may appear. **Does not survive
  extension.**
- **SAT / "here is a witness"** — the witness is still a witness in the larger
  space. **Survives extension.**
- **A passing test** asserting an error is raised, a value is rejected, a list
  is empty, a permission is denied — same shape as UNSAT. Widen the input
  domain (a new variant, a new enum value, a new code path) and the guarantee
  may quietly stop holding while the old test still passes, because the old
  test never exercises the new value. (This is why
  [[new-variant-completeness]] wants a test parameterized on the NEW variant
  rather than a reuse of the old happy path.)
- **A green suite after adding a feature flag or a config mode** — the suite
  covers the old branch; the assertion of absence was never re-established for
  the new one.

## The discipline

1. **Classify the result before reusing it.** Does it assert existence or
   absence? Absence-shaped results are invalidated by widening, not by
   changing.
2. **Re-run rather than reason**, when re-running is cheap. The cost of the
   check is almost always smaller than the cost of a wrong absence claim —
   which is invisible by construction, since nothing fails.
3. **Say "argument" or "check" explicitly** in the report. Both are legitimate
   inputs; conflating them is what does the damage. If a re-run is genuinely
   impractical, record the reasoning AS reasoning, so a later reader can see it
   was never verified.

## Why it earns its own note

The hard direction is applying it **against your own convenience**. Everyone
can insist that someone *else's* control be re-run. Here the worker had a good
argument that its own already-passing control was fine, and re-running meant
more work for itself — and it still declined to accept the argument. That is
the same discipline as not letting a positive control be
[[verify-first]]-quietly-assumed-discharged, pointed inward.

Related: [[a-test-that-cannot-fail-is-not-evidence]],
[[absence-of-evidence-needs-a-control-and-an-evidence-class]],
[[structurally-impossible-beats-checked-and-absent]] — that last one is the
payoff when you *can* convert an absence claim into a structural guarantee, as
Craft check 2 did in the same session.
