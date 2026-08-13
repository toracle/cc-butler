---
name: butler-a-test-that-cannot-fail-is-not-evidence
description: "A test result is evidence only if the opposite result was reachable. Green proves nothing unless you saw it red on the broken version — and RED proves nothing unless it went red because the defect fired. Three ways it silently fails: a vacuous assertion, a mock that bypasses the code under test, and a SUBSTRATE (sqlite standing in for Postgres) that cannot express the failure at all — the last one survives every assertion-quality fix."
metadata:
  node_type: memory
  type: feedback
---

**The rule.** A test outcome is evidence only if the *other* outcome was reachable. That cuts both ways,
and this store has now been bitten in both directions.

- **Green side:** green on the fixed version means nothing until you have seen it red on the broken one.
- **Red side:** red means nothing until you know it went red *because the defect fired*. A red produced
  for the wrong reason is worse than no test — the fix turns it green, and the green now certifies
  something never tested. You finish with more confidence than you started with and less warrant for it.

The question is never "did it pass?" or "did it fail?" but **"could it have come out the other way, for
the reason I am claiming?"**

---

**Green-side incidents (monocle-security, 2026-08-03).**

*cbor2.* Existing tests asserted a precision guard rejected bad input. They passed. But the assertion sat
behind **two layers of broad `except Exception`**, so "the guard fired" and "an unrelated error occurred"
were indistinguishable to the test — it would have passed with the guard entirely removed. Fixed in PR
#1161 by asserting the **specific** `CBORDecodeError` at the decoder directly.

*pyasn1.* Six regression tests for CVE-2026-59884/59885/59886 passed 8/8 on the fixed version (0.6.4). The
worker did not stop there. It built an **isolated scratch venv on the vulnerable 0.6.3** and confirmed
exactly **4 CVE-detection tests fail and only the 2 sanity tests pass**. Only then was the 8/8 green evidence.

**Red-side incidents (jarvice, 2026-08-05) — two workers, same day, opposite directions, both self-caught.**

*jarvice-1130, Claim A composition test.* First draft mocked `get_for_servers` itself to raise — which
**bypassed that function's own `try/except`, the exact construct under test**. The test was red. It proved
nothing. The worker noticed because the *captured logs contained no fail-open warning*: had the buggy path
run, it would have logged. Absence of that line meant the real code never executed. Fixed by patching
`get_db` instead — the dependency the real function body calls — so the actual `try/except` runs. Only then
was RED genuine, with the restricted server observably present in the manifest as corroboration.

*jarvice-978, MySQL read-only guarantee.* Unprompted, the worker added a **READ WRITE control group**: the
same nested `SELECT→function→CALL→procedure` write that gets rejected under `START TRANSACTION READ ONLY`
was shown to *succeed and actually insert a row* under READ WRITE. Without the control, "it was rejected"
is indistinguishable from "that call never works here" — the rejection would have been credited to a
guarantee that might have been doing nothing.

---

## The third axis: the SUBSTRATE cannot express the failure (dealmatch#1149, 2026-08-13)

The two axes above are about the *test*: is the assertion vacuous, does the mock delete the code under test.
Both are fixable by writing a better test. **There is a third axis that no amount of assertion quality
reaches — the environment the suite runs against cannot produce the failing input in the first place.**

dealmatch#1149 fixed a class of opaque-500s caused by Postgres rejecting NUL bytes
(`UntranslatableCharacter`) and over-length values (`StringDataRightTruncation`). **CI runs sqlite
in-memory. sqlite silently accepts both.** So CI could go green on every commit, forever, including the
commit that reintroduced the bug — not because the tests are weak, but because **the backing store
normalises away the exact condition under test.** The author saw this and mocked the exception instead,
which was the right call; the reviewer's contribution was naming *why* the green was uninformative, which
is what stopped the steward from treating "CI green" as the merge gate it normally is.

**The same review found the mock-over-reach variant one layer down.** The test mocked `DealDetail.save` to
raise, but `objects.create()` calls `save()` internally — so the mock blocked the create too. Its
`assertFalse(...exists())` "no partial write" assertion therefore passes only *because the mock reaches too
far*; against real Postgres the create succeeds and a stray `additionals={}` row remains. The assertion
states a property **the code does not guarantee**, and the environment hides that.

**Why this matters more than it looks:** a substrate mismatch is invisible in the test file, invisible in
the diff, invisible in the coverage report, and invisible in the CI log. Every artifact a reviewer normally
consults says the check ran and passed. It is the only one of the three axes where **doing the review well
still misses it** unless you ask the substrate question explicitly.

---

**Why this is not "write better assertions."** Reading a test and watching it go green tells you it *ran*;
it cannot tell you it *discriminates*. A vacuous test is not visible by reading — it looks exactly like a
good one and passes forever, including the day the thing it guards breaks. And a substrate mismatch is not
visible even by reading the test perfectly.

**How to apply.**
1. **Before believing a regression test, run it against the state it must catch** — the vulnerable version,
   the reverted fix, the mutated input. If you cannot make it fail, you have written a comment that costs CPU.
2. **When it does fail, confirm it failed for the right reason.** Get independent evidence the code path
   under test executed: a log line the buggy branch emits, an observable side effect, a control group that
   comes out the other way. Colour alone is not the signal.
3. **Mock the dependency, not the defect.** Prefer patching what the real function *calls* (`get_db`) over
   the function that *contains* the bug (`get_for_servers`); the latter silently deletes what you meant to test.
   **And check the mock does not reach further than intended** — patching `save` also disables `create`.
4. **Ask what the substrate can express, before crediting the green.** For any defect rooted in a *backend's*
   strictness — DB column limits, encoding rejection, constraint enforcement, filesystem semantics, timezone
   handling — name the engine the suite actually runs on. If it is not the production engine, **the green is
   silent on this defect class and must be reported as such.** The remedy is a fresh disposable instance of
   the real engine ([[steward-shared-test-container-contamination]]), not a better assertion.
5. **Suspect every broad `except Exception` between assertion and behaviour.** "It raised something" is
   compatible with the guard being deleted.
6. **Non-vacuity belongs in the PR, not the reviewer's imagination.** Record it — "fails 4/4 on 0.6.3,
   passes 8/8 on 0.6.4", or "red confirmed via absent fail-open log, then via manifest contents". It is the
   only claim that makes the result meaningful, and it decays silently if nobody writes it down.
7. **Prefer structural assertions over wall-clock ones**; when timing is genuinely the only signal, assert a
   **ratio, not a threshold** — "10× the input costs no more than 40×" is a property of the complexity class;
   an absolute millisecond bound is a property of the runner's mood.

**A cheap tell: wall-clock implausibility.** *A green that arrives faster than the work should take is the
signature of a subset run, a skipped suite, or a collection error swallowed into success.* You usually do not
have to audit a green — you have to notice when its **duration is inconsistent with its claim**, which costs
one glance and is available before you open anything.

Worked example (2026-08-13, steward, dealmatch#1149). CI reported `test` SUCCESS after **2m34s**, against a
suite the worker had measured locally at **324s**. The conclusion field said what I wanted; the clock did not
agree with it. Opening the job steps settled it in one call: step `uv run make test` ran 114s and the log said
verbatim `1235 passed, 2 skipped, 26 warnings in 108.10s` — **byte-identical to the worker's post-fix local
count**, and since the pre-fix count was 1234, the newly added test demonstrably executed *in CI*, not merely
on someone's laptop. The step `Initialize containers` further confirmed real Postgres rather than a sqlite
stand-in, closing the substrate axis above. The gap reconciled honestly: the 324s local figure carried
coverage instrumentation, which CI does not run.

Note what made this checkable at all: **a known expected count**. "1235 passed" is only evidence because
1234 was the pre-fix number. Prefer verifications that produce a number you can compare against a number you
already knew — a bare `SUCCESS` is unfalsifiable, and a test count you have never seen before proves nothing.

**Corollary: do not merge on the first green.** In the same episode the rollup showed **two** `test` checks —
one SUCCESS, one still IN_PROGRESS — and `mergeStateStatus: UNSTABLE`. The cause was mundane: `push` and
`pull_request` each trigger the workflow, so the identical SHA is tested twice. Merging on the green one would
have been defensible and still wrong. **Read the whole rollup and the merge state, not the check you were
waiting for.** Waiting cost three minutes and produced a second independent confirmation for free.

**Consequence for the merge gate.** [[butler-devel-merge-standing-rule]] has the steward personally confirm
"CI completed and all green" before pressing merge, because the platform does not enforce it. That check
answers *did the gate run*, not *what the gate covers*. When condition 1's coverage evidence cannot be
produced **and** the substrate cannot express the defect class, the two gaps compound: there is no machine
evidence the changed lines execute, and the green that remains is structurally blind to the bug. That is a
merge-block, not a judgement call — and it is not the reviewer's failure for reporting it.

**The general shape.** *Having run a check is not the same as knowing what it establishes.* A verification
pass once assumed the wrong filename convention and reported five notes MISSING that were present. A green
suite reports SAFE for a guard that may not exist. A red test reports CONFIRMED for a path never executed.
A green CI reports SAFE for a rejection its database never performs. In every case the check ran, exited
cleanly, and answered a question nobody asked. **Ask what result would distinguish the two worlds — and
confirm you would actually get a different one.**

Related: [[known-flaky-is-a-claim-not-a-diagnosis]] (an outcome is a claim needing diagnosis, not a verdict),
[[git-claims-need-origin-verification]] (same disease, different organ — a result that looks current but is
stale), [[two-views-of-one-sensor-are-not-corroboration]] (two readings that agree because they share an
origin), [[verify-delivery]] (confirm the fact rather than inferring it from a clean exit),
[[a-true-observation-licenses-only-its-own-scope]] (the verdict does not travel past what was measured).

**SPT:** *make it red on purpose — then prove the red came from the bug, on a substrate that can produce it.*
