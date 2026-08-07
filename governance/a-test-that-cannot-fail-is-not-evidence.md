---
name: butler-a-test-that-cannot-fail-is-not-evidence
description: "A test result is evidence only if the opposite result was reachable. Green proves nothing unless you saw it red on the broken version — and RED proves nothing unless it went red because the defect fired. Both directions fail silently: a vacuous green passes forever, and a red produced by a mock that bypassed the code under test turns green on the fix and certifies nothing."
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

**Why this is not "write better assertions."** Reading a test and watching it go green tells you it *ran*;
it cannot tell you it *discriminates*. A vacuous test is not visible by reading — it looks exactly like a
good one and passes forever, including the day the thing it guards breaks.

**How to apply.**
1. **Before believing a regression test, run it against the state it must catch** — the vulnerable version,
   the reverted fix, the mutated input. If you cannot make it fail, you have written a comment that costs CPU.
2. **When it does fail, confirm it failed for the right reason.** Get independent evidence the code path
   under test executed: a log line the buggy branch emits, an observable side effect, a control group that
   comes out the other way. Colour alone is not the signal.
3. **Mock the dependency, not the defect.** Prefer patching what the real function *calls* (`get_db`) over
   the function that *contains* the bug (`get_for_servers`); the latter silently deletes what you meant to test.
4. **Suspect every broad `except Exception` between assertion and behaviour.** "It raised something" is
   compatible with the guard being deleted.
5. **Non-vacuity belongs in the PR, not the reviewer's imagination.** Record it — "fails 4/4 on 0.6.3,
   passes 8/8 on 0.6.4", or "red confirmed via absent fail-open log, then via manifest contents". It is the
   only claim that makes the result meaningful, and it decays silently if nobody writes it down.
6. **Prefer structural assertions over wall-clock ones**; when timing is genuinely the only signal, assert a
   **ratio, not a threshold** — "10× the input costs no more than 40×" is a property of the complexity class;
   an absolute millisecond bound is a property of the runner's mood.

**The general shape.** *Having run a check is not the same as knowing what it establishes.* A verification
pass once assumed the wrong filename convention and reported five notes MISSING that were present. A green
suite reports SAFE for a guard that may not exist. A red test reports CONFIRMED for a path never executed.
In every case the check ran, exited cleanly, and answered a question nobody asked. **Ask what result would
distinguish the two worlds — and confirm you would actually get a different one.**

Related: [[known-flaky-is-a-claim-not-a-diagnosis]] (an outcome is a claim needing diagnosis, not a verdict),
[[git-claims-need-origin-verification]] (same disease, different organ — a result that looks current but is
stale), [[two-views-of-one-sensor-are-not-corroboration]] (two readings that agree because they share an
origin), [[verify-delivery]] (confirm the fact rather than inferring it from a clean exit).

**SPT:** *make it red on purpose — then prove the red came from the bug.*
