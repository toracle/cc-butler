# cc-butler Gherkin BDD visualization — SDD

## Intent

Make the *behavioral specification* of cc-butler visible as Gherkin
(Feature / Scenario / Given / When / Then) for a human reader — without a second
test framework and without duplicating the logic the ERT suite already proves.

## The problem

cc-butler's tests are **ERT**, and they are good tests: faithful-state and
non-tautological — they assert the *observable result state* (a message landed in
the right inbox, a queue item was removed, a tab was added), not merely that some
function was called. The specification is genuinely *in there*. Many docstrings
already read as Given/When/Then, e.g.:

> `cc-butler-mail/return-path` — "Given the butler asks a worker
> (reply-to=butler), When the worker replies, Then the reply lands in the
> BUTLER's inbox (not the steward's)."

But that spec is **buried in Emacs Lisp**. A non-Emacs reader — or 정수님 skimming
"what does the butler actually guarantee?" — cannot see the Given/When/Then as a
first-class artifact. **Gherkin IS the spec**: a `.feature` file states behavior
in a form humans read directly, independent of the test framework that enforces
it. The gap is *visibility*, not *coverage*.

## Options

**(a) ecukes — real executable `.feature` files.** True Gherkin, actually run.
But it is a separate, heavyweight runner alongside ERT, and every `Given/When/Then`
line needs a step-definition in Elisp that re-expresses logic the ERT tests
already contain. We would maintain two encodings of the same behavior and run two
frameworks. Highest fidelity, highest cost, most duplication.

**(b) buttercup — describe/it BDD.** Readable, nested specs and a nice runner.
But buttercup is **not Gherkin** — no `Feature`/`Scenario`/`Given`/`When`/`Then`
syntax. It would mean rewriting the suite in a different BDD dialect to get
prose that still isn't the Gherkin we want to surface.

**(c) `.feature` files as living SPEC DOCS mapped to the existing ERT tests.**
Hand the reader real Gherkin — one `.feature` per module, its `Scenario`s
mirroring the module's `deftest`s — while **ERT stays the runner**. The `.feature`
file is documentation that *tracks* the tests (each `Scenario` names/points at its
`cc-butler-*/…` deftest), not a second executable suite. Lightweight, no new
framework, no duplicated logic; the cost is that the mapping is by convention, not
enforced (a `.feature` can drift from its test).

## Recommendation

**Do (c) — spec-doc `.feature` files — as the SPT.** It delivers exactly the ask
(Gherkin made *visible*) at the lowest cost: no second test framework, no
duplicated step-definitions, ERT keeps running the actual checks. It also has a
running start — the ERT test names are already slash-namespaced by module
(`cc-butler-mail/return-path`, `cc-butler-inbox/end-to-end-answer-removes-from-queue`)
and many docstrings are already written as Given/When/Then, so the `.feature`
content is largely *transcription*, not authoring. If a future need for
*executable* Gherkin appears, (c)'s files are the natural seed for an ecukes (a)
migration — so (c) is not a dead end.

The one real weakness — drift between a `.feature` doc and its ERT test — is
manageable by keeping the Given/When/Then wording canonical in the ERT docstring
and generating (or at least reconciling) the `.feature` from it.

## Open questions (GATING → 정수님's inbox)

1. **Executable or spec-doc?** Does 정수님 want *executable* `.feature` files
   (ecukes, option (a) — real runner, real cost) or *spec-doc* `.feature` files
   (option (c) — documentation mapped to the existing ERT suite)? The
   recommendation is (c).
2. **Granularity** — one `.feature` **per module** (mirroring each `*-test.el`),
   or one **global** `cc-butler.feature`? Per-module matches the existing test
   layout; global reads as a single product spec.
3. **Source of truth** — **generate** the `.feature` from the ERT docstrings
   (which already read as G/W/T, so the docstring stays canonical and the
   `.feature` is derived), or **hand-write** the `.feature` as the primary spec
   and let tests follow it?
