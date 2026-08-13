---
name: butler-the-justification-for-a-decision-becomes-its-premise-not-its-test
description: "Right after deciding, the reasoning is vivid — so you write it down as an assertion about the code and stop treating it as the thing to check. In a comment it becomes a false guarantee; in a test it becomes a monkeypatch that deletes the subject under test."
metadata:
  node_type: memory
  type: feedback
---

Immediately after making a design decision, its justification is the most vivid thing in your head. That vividness is the trap: the reasoning that *led* to the decision gets recorded as though it were an established fact *about the code*. You stop treating it as the claim under test and start treating it as the premise you build on.

The failure has two surfaces, and they look unrelated until you notice they share a root:

- **In a comment**, it becomes a false assertion — the comment states the guarantee you intended, not the behaviour the code has.
- **In a test**, it becomes a test that cannot fail — most sharply, a `monkeypatch` that replaces the very thing that needed verifying, so the body never runs and green means nothing.

The comment case is the familiar one. The test case is worse, because a passing test is *evidence*, and it gets reported upward as "fixed."

**Why:** On 2026-08-08 a worker on jarvice PR #1613 hit this four times in one day, and counted them itself:

1. A comment asserting `config` tables live only in the public-schema branch — false; `config` exists in both.
2. A docstring asserting "the poller supplies ambient context" — false for the `ThreadedExecutor` backend, whose worker threads have no contextvar.
3. A comment saying "the stored one is then the real one" where `return terminal or run` actually returns a stale RUNNING model.
4. A fix for missing Sentry alerting, `_ensure_sentry_initialised()`, guarded on `"sentry_sdk" in sys.modules`. Because `config.py:12` imports `sentry_sdk` unconditionally, that predicate measures *"somebody imported the SDK"*, never *"init() ran"*. The function returned `True` on its first line and never initialised anything. **Its test passed because it monkeypatched `_ensure_sentry_initialised` wholesale — the body under test never executed once.**

The fourth is the instructive one. The worker had been *ordered* only to check whether sibling entrypoints shared the hole; while counting siblings it disproved its own already-reported fix. It produced a five-line measurement putting `D. function returns True` beside `E. main still never imported` — a textbook false positive — and retracted the fix in the same breath as the sibling census.

Its own synthesis is the principle: *"right after deciding, the justification is vivid, so you treat it as a premise rather than as the thing to be verified. In a comment that yields a false assertion; in a test it yields deleting the subject under test."*

A related shape from the same day: a comment reading `Verified live 2026-08-08: the stg worker flushed 2 events with HTTP 200`. The observation was true when written. A later commit moved the bootstrap that made it true, and the sentence stayed behind wearing a true face. As the worker put it — *"the observation wasn't wrong; I removed the observation's premise."*

**How to apply:**

- **Ask "is this my intent, or the code's behaviour?"** — not "did I verify this?" The verification question invites you to recall the reasoning that already feels settled; this one forces the comment/test to point at the artifact instead. It catches all four cases above.
- **A `monkeypatch` over the thing you are testing is a red flag, not a convenience.** If the subject is replaced, the test asserts your intent back to you. Patch the *environment* the subject runs in, never the subject.
- **Check what the predicate actually measures.** `"x" in sys.modules` means *imported*, not *initialised*. `hasattr` means *present*, not *correct*. When a guard is cheap to write, that is usually because it is answering an easier question than the one you need answered.
- **When you write `Verified live`, write the condition that made it true.** Otherwise a later change removes the premise and leaves the sentence standing. Prefer stating what would have to hold for the claim to survive.
- **Count recurrences across a session, out loud.** This worker's fourth instance was legible *because* it had been counting since the first. Three occurrences is not a habit, it is a structure — and only a running count makes the structure visible in time to look for the shared root. See [[butler-institutionalize-learning]].
- **A fix reported as done on the strength of a test that bypassed it is a false report, not a small miss.** Grade it as such. The worker correctly ranked the code impact Low and the *evidence* impact MAJOR, because the steward had already relayed "⑥ fixed" upward on that test's authority.

**SPT:** the habit is *when writing the comment or the test that accompanies a decision you just made, point it at what the code does — the reasoning that convinced you is exactly what must not be assumed.*
