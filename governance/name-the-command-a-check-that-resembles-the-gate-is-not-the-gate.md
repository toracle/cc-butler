---
name: butler-name-the-command-a-check-that-resembles-the-gate-is-not-the-gate
description: "Running a check that looks like the real gate produces a verification claim that is itself unverified — so when reporting 'I verified it', name the exact command, because that is the only thing that lets the reader see your check and the gate were different."
metadata:
  node_type: memory
  type: feedback
---

Building a defense creates a new claim: *that the defense works.* That claim is
born unverified, and it is unusually well camouflaged — it arrives wearing the
clothes of diligence. You read the warning, you acted on it, you ran a check, it
passed. Every step feels like the opposite of carelessness.

**A command that resembles the gate is not the gate.** Same tool, same version,
same config file, different flags — and a different verdict.

**When you report a verification, name the command you ran.** Not "verified",
not "the check passed" — the literal invocation. It is the only artifact that
lets someone else notice your check and the real gate diverged. This is cheap to
write and impossible to reconstruct later.

**Why:** On 2026-08-09 a worker opened jarvice PR #1621 to correct a false claim
in `CLAUDE.md`. That same file documents a trap: PR #1536 broke CI because a
docs-only PR cut from a stale base hit prettier re-normalization. The worker
**read that warning, obeyed it** (fetched fresh `devel`, branched from it), ran a
formatting check, and reported *"prettier passes, no re-normalization drift."*

CI's `Format & Build Frontend` then failed on exactly that:

```
what the worker ran:  npx prettier --check CLAUDE.md                → PASS
what CI runs:         prettier --write . --config ./.prettierrc \
                              --ignore-path ./.prettierignore       → FAIL
```

Identical version (3.3.3), identical resolved config. Adding `--ignore-path` is
what flips the verdict. The diff was three emphasis markers (`*…*` → `_…_`) and
one blank line — all on lines the worker had added, zero unrelated drift.

The steward then **repeated the unverified claim into the durable handoff and
praised it as good judgment** — so it passed two layers, not one. The steward's
own rule says the verification gate is *the moment a claim leaves your hands
outward*, and a handoff is outward. The question that would have caught it —
"what command could have established this?" — was answerable from the workflow
file in the repo.

Two things make this the sharpest instance in a seven-long series (see
[[butler-naming-a-trap-precisely-is-not-avoiding-it]], where instances 1-6 are
comments, tests, a predicate, and a log line): the flaw was in the **defense**
rather than the artifact, and **reading the warning was not enough** — the worker
obeyed it and still fell in, because obeying produced an action nobody checked.

**The same trap fired again nine hours later — and the second run isolates the
cause more sharply.** A worker edited two table cells in a markdown doc, changing
their width; prettier re-normalized the column padding, and CI failed. Warned in
advance that the lookalike command was the danger, it **ran both and reported
the pair**:

```
npx prettier --check <file> --config ./.prettierrc --ignore-path ./.prettierignore
  → "All matched files use Prettier code style!"        PASSES
npm run format && git diff --exit-code
  → fails on the identical content                      THE GATE
```

Note what this rules out: the lookalike carried `--ignore-path` and the same
config, so the divergence is **not a missing flag**. `--check <one file>` and
`--write .` followed by a diff *ask different questions* — "is this file
formatted?" versus "does formatting the tree change anything?" A command can
match the gate on tool, version, config, and flags and still answer something
else.

The same worker also caught a transient false alarm and named it: an early
`git diff --exit-code` failed only because the re-format was **not yet
committed**, so the diff was against `HEAD`. Re-run on a clean tree, it passed.
Without that distinction the honest report would have been a wrong one.

**The environment is part of the command.** Later the same day a worker fixed a
non-deterministic row-selection bug and, on instruction, wrote a regression test
for the exact case that distinguishes the old rule from the new one. Then it
checked something nobody asked it to check: it reverted to the old rule and ran
the suite on **both** backends.

```
sqlite (what CI runs):        2 of 4 tests FAILED
postgres (what production is): 4 of 4 tests FAILED
```

The two that CI misses are the non-determinism itself and the specific regression
case the steward had ordered — because `DESC` puts NULLs first on Postgres and
last on sqlite. **The protection was half-dead in the only place it would ever
run automatically**, and the steward's instruction had produced a test that
reports green while the bug is present.

**Prefer an honest skip to a false pass.** Both are green in CI, but they say
opposite things: a pass claims *"checked, and fine"*; a skip admits *"not checked
here."* A test that passes in the presence of the bug is worse than no test,
because it actively certifies the thing it cannot see — and the next person
reverts the fix, sees the regression test pass, and concludes they are safe.

**How to apply:**

- **Ask what your test environment does differently from production**, especially
  defaults nobody chose deliberately: NULL ordering, collation, timezone, integer
  width, filesystem case sensitivity. A test only binds where its assumptions hold.
- **Gate environment-dependent tests on the environment and say why in the skip
  message.** Point the skip at the issue tracking the gap, so the reader learns
  what was not covered instead of inheriting a green they cannot interpret.
- **Report the invocation, not the verdict.** "Verified" hides which command ran;
  `npx prettier --check CLAUDE.md` shows it. Had that string been in the report,
  the mismatch against CI's `--write .` was visible to any reader. Applies
  upward too — a steward saying "confirmed at source" should name the call.
- **Ask what question each command answers, not whether the flags match.** Same
  tool, same config, same flags can still be a different question — checking one
  file is not the same as formatting the tree and diffing.
- **Distrust your own monitoring output too.** The same worker's CI watcher
  printed "ALL RUNS COMPLETE" while a job was still `in_progress`; it discarded
  that output and queried `gh run list` directly. A wrapper you wrote is an
  instrument, and instruments get verified before their verdicts are used.
- **Dry-run the criterion against the present state before trusting it to judge a
  future one.** A worker was handed the criterion *"`git diff --stat
  origin/staging origin/devel` empty = fully promoted"* and caught that it was
  wrong for its repo — not by superior insight, but by **printing the current
  diff first, before promoting anything.** The criterion already returned the
  wrong answer about today; that is decisive evidence it cannot judge tomorrow.
  In its own words: *"the part that actually worked was the ordering — looking at
  what the criterion says about the current state before applying it."* Cheap,
  and it catches a bad criterion before it has anything to certify.
- **Confirm the artifact under test is the one you think shipped.** A test
  designed so that "nothing changed" means the fix works will report the opposite
  if run against a rollout still in progress — and the failure signal is
  indistinguishable from a genuine one. Match the *running* revision's image SHA
  to the promoted commit (`describe-services` first, then the task definition —
  the family's latest revision is not necessarily the running one), rather than
  accepting that the deploy job went green.
- **Separate "the gate failed" from "the tree was dirty."** A diff-based gate run
  against uncommitted work fails for a reason that has nothing to do with the
  gate. Re-run clean before reporting a failure.
- **Reproduce the gate, don't approximate it.** Read the workflow/Makefile and
  run *that*. The worker's fix was `npm run format && git diff --exit-code` —
  the gate's own logic — not a friendlier command that answers a similar
  question. Convenience flags are where the divergence hides.
- **When a defense fails, prove whether it measured anything at all.** The worker
  fed a deliberately-malformed probe file to *both* commands; both caught it. So
  the honest conclusion is narrow — *"these two commands disagree on this one
  file"* — not *"my check is worthless."* That distinction matters: a tool you
  stop trusting is a tool you stop running. Avoid over-correcting past the
  evidence.
- **Stop at the goal, not at full understanding.** *Why* `--ignore-path` changes
  a formatting verdict is prettier's business. The worker declined to chase it
  and said so. Naming the boundary you chose not to cross is a finding; silently
  leaving it looks like you missed it.
- **Obeying a warning is an action, and actions need verification.** Reading the
  trap and taking a countermeasure feels like closure. It is not — the
  countermeasure is now the thing that could be wrong. Ask what would show the
  countermeasure worked, and go get that.
- **A self-caught error raises trust, and say so.** This worker retracted a claim
  the steward had just singled out for praise, which is the hardest kind to
  retract. Grade the disclosure, not just the miss — otherwise the next
  correction arrives later, or not at all. See
  [[butler-a-delegated-sweeps-confident-prose-is-not-verified-fact]].

**SPT:** the habit is *when you write "verified", write the command next to it —
and before trusting it, ask whether that command is the gate or merely looks
like it.*
