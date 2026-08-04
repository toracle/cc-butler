---
name: butler-structurally-impossible-beats-checked-and-absent
description: "'I checked and the bad thing isn't there' and 'the bad thing cannot be there' are different guarantees — when a cheap structural fact upgrades you from the first to the second, find it and say which one you have."
metadata:
  node_type: memory
  type: feedback
---

When guarding against a failure mode, notice whether your evidence is "I looked and it is absent" or "it could not be present". The first is a measurement of one moment and decays — it must be redone every time, and it is only as good as the completeness of the look. The second is a property of the situation and holds without re-checking. When a cheap structural fact is available that lifts you from the first to the second, go get it, and state in the record WHICH of the two you have.

**Why:** 2026-08-04, promoting jarvice#1511 devel→staging. The known failure mode was promotion #1502, recorded as carrying "#1109 + #1113" but actually carrying #1110/#1111/#1112 as well, one of which modified the production deploy job — release scope taken from titles instead of the diff. The guard asked for was an enumeration: list every commit in `staging...devel` and every changed file under sensitive paths. The worker did that (5 files, 241 insertions / 1 deletion, sensitive-path filter empty) — a clean *checked-and-absent* result. But it also established, via `git merge-base --is-ancestor origin/devel origin/staging` returning YES, that devel was already fully absorbed into staging. That single fact meant the promotion could only ever carry the one new merge commit, so an unexamined extra payload was *structurally impossible* on this promotion rather than merely looked-for and not found. Same action taken, far stronger guarantee, and it cost one command.

**How to apply:**
1. After a clean negative check, ask once: is there a cheap structural fact that would make this failure mode impossible rather than absent? Ancestry, uniqueness constraints, a type that cannot represent the bad state, a single normalization point, an empty set by construction.
2. Write down which one you have. "Scope verified as #1511 only" and "scope could only be #1511" read alike to a later reader and are not the same claim; the first needs redoing next time and the second does not.
3. Do not let the stronger form make you skip the check when it is cheap — the enumeration above was still worth having, because the ancestry fact is what made it conclusive, not a substitute for looking.
4. Beware the reverse error: a structural argument that is actually an entailment from something you measured elsewhere is still a measurement, one hop removed. See [[a-test-that-cannot-fail-is-not-evidence]] and [[absence-of-evidence-needs-a-control-and-an-evidence-class]] — the same day, jarvice-978 had to be corrected for presenting exactly such an entailment ("staging already resolved, by implication from the local matrix") as though staging had been measured.
5. Related: [[release-scope-comes-from-the-diff-not-the-titles]] is the failure this was guarding; [[merge-verification-bar]] for what a promotion record must contain.
