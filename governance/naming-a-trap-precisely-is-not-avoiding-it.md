---
name: butler-naming-a-trap-precisely-is-not-avoiding-it
description: "Comments and test names are written from intent; code is written from mechanism. Intent always reads as true, so the clearest statement of a requirement is the artifact least likely to be checked against the implementation — clarity gets mistaken for evidence of verification."
metadata:
  node_type: memory
  type: feedback
---

A comment, a docstring, a test name — these are written from **intent**. The code beneath them is written from **mechanism**. Intent is always correct (it is what you meant), so on every re-reading the sentence reads as true, and therefore never gets checked against what the mechanism actually does.

The sharper form, and the one that stings: **the artifact that states the requirement most clearly is the one least likely to be compared against the implementation** — because clarity is mistaken for evidence that verification happened. Having the distinction in words feels like having applied it.

**Naming a trap precisely is not avoiding it.**

**Why:** On 2026-08-08 a worker on jarvice PR #1613 counted five instances of this in a single day, and found the shared root itself:

1. `return terminal or run` under a comment asserting *"the stored one is then the real one"* — it returns a stale RUNNING model.
2. `_ensure_sentry_initialised()` whose docstring was correct and whose body was not.
3. A comment in `remote.py` saying a path was *"masked ... because `worker_entrypoint` imports `open_webui.main`"* — that import had been removed by the same PR.
4. A test named `test_the_divergence_alert_actually_reaches_sentry`, whose docstring opened with **"Attached is not the same as reaches."** Its body injected a fake `sentry_sdk` into `sys.modules` — **satisfying the very guard under test in order to make the test pass.** It could only ever prove the branch was taken, never that anything was reachable.
5. The PR *added* a new `if "sentry_sdk" in sys.modules:` alert guard at `dispatch.py:342` — the exact predicate the same PR had spent a round proving meaningless, fixed elsewhere, and commented onto issue #1615. Confirmed as `+` lines in `git diff origin/devel...HEAD`.

Instance 4 is the purest case. The steward's instruction had been explicit: *"verify by test that Sentry actually **reaches** — do not assume attached."* The worker restated the instruction in the test's name, wrote the trap into the first line of the docstring, and then walked into it. Its own summary: *"I answered an instruction not to assume attachment with a test that checks only attachment."*

Instance 5 shows the failure is not about comments at all: the same misreading produced *new broken code* inside the PR diagnosing that breakage. And the consequence was real — the halt could only fire in the dispatcher Lambda, which deliberately never imports `main.py`, the only place `sentry_sdk.init()` runs. **The one process able to raise the alarm was the one process with no alarm channel.**

6. A **log line** at `dispatch.py:151-157` asserting `"marked RUN_FAILED, next_fire_at advanced"` — naming precisely the two things that may not have happened, because the `except Exception` above it catches only *raises* while the model methods it calls swallow internally and return `None`.

Instance 6 is what makes the shape general: **the artifact class does not matter.** Three comments, one test, one predicate, one log line. Anything written from intent inherits the defect — and a log is the worst carrier, because it is read later, by someone debugging, as a record of what happened rather than a claim about what was attempted.

**How to apply:**

- **Ask "is this intent or mechanism?" — not "did I verify this?"** The verification question invites you to recall reasoning that already feels settled. This one forces the sentence to point at the artifact.
- **Treat a crisply-worded requirement as a flag, not a comfort.** When a docstring states a distinction sharply, that is the moment to check the body against it — precisely because the sharpness will discourage anyone (including you, later) from looking.
- **A test that satisfies the condition under test is not a test.** Injecting into `sys.modules` to pass a `sys.modules` guard, or monkeypatching the function whose body is the subject, proves your intent back to you. Stub the *boundary*; execute the *subject*.
- **Push the distinction one level further than feels necessary.** "Attached ≠ reaches" was right, and still insufficient: `init()` called ≠ event transmitted (a Lambda freezes on return; without `flush()` the event dies in the queue). Each layer needs its own evidence.
- **Count instances across a session and look for the root, not the list.** This worker's fifth instance was legible only because it had been counting since the first — and the count is what surfaced "intent vs mechanism" instead of five unrelated slips. See [[butler-institutionalize-learning]] and [[butler-the-justification-for-a-decision-becomes-its-premise-not-its-test]], which is this principle's other face.
- **Debt you create is not a sibling you may defer.** A rule like "don't fix the pre-existing instances in this PR" does not cover a *new* instance the PR introduces. You may defer someone else's hole; not the one you just dug.
- **Before covering test pollution with a stub, ask what the pollution says about production.** This is the strongest *detection* method found so far, and it works from the outside — you do not have to suspect the trap first. On 2026-08-08 the same worker's two `worker_entrypoint` tests failed together but passed alone: its new test called the *real* `init()`, which hooked global logging and survived `set_client(None)`. Adding one method to the stub would have made it green. Instead it asked why the leak existed — and the answer was a production fact: default integrations turn every `ERROR` log into an event, so a handler that logs a per-tenant failure every tick would have converted its whole log stream into alert traffic. **Narrowing production removed the pollution too.** Cross-test interference is a measurement of real global state; a stub deletes the measurement, not the cause.
- **The log line is the trap's best hiding place.** A comment is read as intent and a test as a check, but a log line is read as *evidence of what happened* — by someone debugging, under time pressure, who will not go read the code that emitted it. Write logs from what the code can prove, not from what the branch was for: prefer `"attempted RUN_FAILED"` over `"marked RUN_FAILED"` unless the return value was checked.

**SPT:** the habit is *when you write the sentence that states the requirement most clearly, stop and read the code against it — that sentence is the least-audited thing you will produce.*
