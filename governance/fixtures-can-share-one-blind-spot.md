---
name: butler-fixtures-can-share-one-blind-spot
description: "Tests agree with each other when their fixtures share an assumption — so a suite can be uniformly green and uniformly blind; ask what every fixture has in common, and stub where production resolves rather than where it lands."
metadata:
  node_type: memory
  type: feedback
---

A suite is not N independent checks. It is N checks over whatever the fixtures
have in common. **When every fixture shares an assumption, the tests agree with
each other and none of them touches the case that breaks.** Green is uniform, and
so is the blindness.

Four distinct shapes, all found in a single PR on 2026-08-09 (jarvice #1627):

1. **The attribute is absent, so nothing can be lost.** Every test of a config
   override passed a *scheduled* request — an object with no `base_url`. The bug
   was that the override lost to `base_url` whenever one existed. No fixture had
   one, so no test could see it. The override was broken **precisely in the case
   it exists for** (an interactive browser turn) and the suite was silent.
2. **The attribute is present, so the failure is masked.** `conftest`'s
   `MockRequest` supplies `base_url`. Testing against it would have hidden the
   original defect entirely — the bug *is* that the real object lacks it.
3. **The patch point is wrong, so bypassing the seam still passes.** Production
   resolves a repository through a configured seam; the fixture stubbed the
   **concrete class**. Code that constructed the class directly — walking around
   the seam — kept every test green. The test could not distinguish "uses the
   seam" from "happens to reach the same class."
4. **Nothing is asserted at all.** A test opened a live `engine.connect()` in a
   unit test with no stub, and passed on a machine with no database — because the
   repository swallows exceptions and returns `None`. It would have passed with
   tenant lookup **completely broken**.

5. **The guard for a deleted branch passes for the wrong reason.** A test written
   to prove a branch was removed also passed against the *old* tree — the old
   code rejected the same input by a different rule, returning the same value. It
   could not distinguish "deleted" from "still there." Feeding it an input only
   the deleted branch would have answered produced a real failure.
6. **The fixture feeds the value the code expects, not the value production
   sets.** A test named `test_dev_override_ignored_in_prod` patched `ENV="prod"`
   — but deployment sets **`prd`**. The gate it guarded was broken for the real
   value, and the test passed, was named for the case, and counted toward
   coverage. **Green and empty.**

7. **The test is real, but silently skips where you ran it.** An issue named a
   test as its **mandatory deliverable** — "must exercise real tenant-schema
   routing." The file existed. Run locally it reported `2 skipped`, because it
   guards on `TEST_POSTGRES_URL`. **A skipped test exercises nothing**, so
   existence did not satisfy the requirement. Closing on "the file is there"
   would have closed on a deliverable that had never run. Confirmed only by
   checking CI actually sets the variable (`test-backend.yaml:75`) *and* watching
   `2 skipped` become `2 passed`.

The first three *hide* a failure. The fourth never looked. The fifth proved
something other than what it claimed. The sixth is the most dangerous, because
depth, branch, and assertion are all genuine — only the **input** is fictional,
so none of the other five checks catch it. The seventh is different in kind: the
test is **correct and sufficient**, and the blindness is **conditional on where
it runs** — so it is invisible to every review of the test's own content, and
`skipped` reads as benign in a summary line dominated by passes.

**Why:** These were not sloppy tests; each was written deliberately while fixing a
real bug, by a worker that was otherwise catching its own errors all day. The
blind spot lived in the **fixture design**, one level below where attention was.
That is what makes it worth a habit rather than more care: care was already
present.

**How to apply:**

- **Ask what every fixture has in common.** That shared trait is the shape of
  your blind spot. If all of them are the same kind of object, the case you are
  defending against may be a different kind.
- **Stub where production resolves, not where it ends up.** If the code is meant
  to go through a factory, registry, or configured seam, patch *there* — patching
  the concrete class cannot tell adherence from coincidence.
- **A unit test that passes without stubs deserves suspicion.** Ask what it
  asserts. Swallowed exceptions plus `None` returns make "broken" and "fine" look
  identical, and a test with no assertion certifies neither.
- **Test both polarities of the attribute under suspicion.** Present and absent,
  set and unset, empty and populated — the bug lives on whichever side the
  fixtures omit.
- **When a test is added to pin a bug, revert the production code and watch it
  fail for the *stated* reason.** Failing for a different reason (an import
  error, a missing helper) means it pins existence, not behavior. See
  [[butler-name-the-command-a-check-that-resembles-the-gate-is-not-the-gate]].
- **Trace environment/config values to where they are actually produced.** Not to
  what the code reads, but to the deployment manifest, CDK, or Helm chart that
  sets the literal — often a different language in a different directory — and
  feed the test *that* string. A test asserting behaviour under `ENV="prod"`
  proves nothing about a fleet running `prd`.
- **A test named for a case is not a test of that case.** The name reassures
  readers and satisfies coverage while the input is wrong. Check what it feeds,
  not what it is called.
- **When fixing a vacuous test, watch it go red first.** Change the input to the
  real value before changing the code — if it does not fail, the "fix" changed
  nothing and the gap is elsewhere.
- **A guard for removed code must be given the input that code would have
  answered.** Otherwise it proves the branch was already dead, not that you
  deleted it.
- **Never accept a test's existence as evidence it ran.** When an issue names a
  test as a deliverable, run it and read the *counts* — `skipped` is not `passed`,
  and a summary line reports both in the same breath. Then confirm the
  environment that un-skips it exists somewhere real (CI config), and watch the
  skip flip to a pass with your own eyes.
- **Prefer structurally impossible to rule-to-remember.** The same PR fixed an
  empty-string leak by normalizing *before* the check, so the bad value could not
  be produced. Rules get forgotten; structure does not.

**SPT:** the habit is *before trusting a green suite, ask what all its fixtures
assume — and whether the bug you fear lives exactly there.*
