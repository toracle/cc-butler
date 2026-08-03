---
name: a-test-that-cannot-fail-is-not-evidence
description: "A passing test proves something only if it would have failed otherwise. Green on the fixed version is not evidence — you must also see it red on the broken one. Two shapes cause silent vacuity: a broad `except Exception` that swallows the distinction between 'the guard fired' and 'something unrelated blew up', and a regression test never run against the vulnerable version it claims to cover. Run it against the condition that must fail, and watch it fail."
metadata:
  node_type: memory
  type: feedback
---

**Two incidents, one night, same track (monocle-security, 2026-08-03).**

*cbor2.* Existing tests asserted that a precision guard rejected bad input. They passed. But the assertion sat
behind **two layers of broad `except Exception`**, so "the guard fired" and "an unrelated error occurred" were
indistinguishable to the test — it would have passed with the guard entirely removed. Fixed in PR #1161 by
asserting the **specific** `CBORDecodeError` at the decoder directly, so the green now means what it says.

*pyasn1.* Six regression tests for CVE-2026-59884/59885/59886 passed 8/8 on the fixed version (0.6.4). The
worker did not stop there. It built an **isolated scratch venv on the vulnerable 0.6.3** and ran the new file
alone, confirming that exactly **4 CVE-detection tests fail and only the 2 sanity tests pass**. Only at that
point was the 8/8 green evidence of anything.

**Why this is not "write better assertions."** The instruction that produced the good outcome was almost the
right one and still not sufficient. The steward said *"don't trust the sub-agent's report — open the files and
run them yourself."* The worker did more: it verified the tests **fail when they must**. Those are different
acts. Reading the file and watching it go green tells you the test *ran*; it cannot tell you the test
*discriminates*. A vacuous test is not a bug you can see by reading — it looks exactly like a good one, and it
passes forever, including on the day the thing it guards breaks.

**How to apply.**
1. **Before believing a regression test, run it against the state it is supposed to catch** — the vulnerable
   version, the reverted fix, the mutated input. If you cannot make it fail, you have not written a test, you
   have written a comment that costs CPU. This is the completion condition, not an extra.
2. **Suspect every broad `except Exception` between the assertion and the behaviour.** Assert the specific
   exception type and message. "It raised something" is compatible with the guard being deleted.
3. **A regression test's non-vacuity is part of the PR, not part of the reviewer's imagination.** Record the
   evidence — "fails 4/4 on 0.6.3, passes 8/8 on 0.6.4" — in the PR or issue. It is the only claim that makes
   the green meaningful, and it decays silently if nobody wrote it down.
4. **Prefer structural assertions over wall-clock ones**, and when timing is genuinely the only signal
   available, assert a **ratio, not a threshold**: "10× the input costs no more than 40×" is a property of the
   algorithm's complexity class (linear ~10× vs quadratic ~100×, wide margin on both sides). An absolute
   millisecond bound is a property of the runner's mood.

**The general shape.** This is the testing-side instance of a habit this store keeps rediscovering: *having run
a check is not the same as knowing what it establishes*. There, a verification pass assumed the wrong filename
convention and reported five notes MISSING that were present. Here, a green suite reports SAFE for a guard that
may not exist. In both cases the check ran, exited cleanly, and answered a question nobody had asked. **Ask what
result would distinguish the two worlds — and confirm you would actually get a different one.**

Related: [[known-flaky-is-a-claim-not-a-diagnosis]] (a test outcome is a claim needing diagnosis, not a verdict),
[[direct-writes-to-the-store-skip-the-cache]] (the caution on checking — a check whose premise is wrong is worse
than no check), [[verify-delivery]] (confirm the fact rather than inferring it from a clean exit).

**SPT:** the habit is *before trusting a green test, make it red on purpose — if you can't, it wasn't testing anything.*
