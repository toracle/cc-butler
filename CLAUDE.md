# claude-code-ide is pinned — do not upgrade casually

cc-butler depends on [claude-code-ide](https://github.com/manzaltu/claude-code-ide.el),
pinned in practice at commit `a9485f766ea69f6cb3a3f08dea20d44fd6596673` (**v0.2.7**,
2026-06-01). CI clones exactly this SHA (`.github/workflows/test.yml`).

## The trap

Upstream **v0.3.0 (current upstream main) removed `claude-code-ide--processes`**,
the directory-keyed process hash table. This is a *removed data structure, not a
rename* — there is no successor (only `--session-counter` and
`--last-accessed-buffer` remain).

## Blast radius

cc-butler reads that table directly in four places:

- `cc-butler-orchestrator.el:54`
- `cc-butler-orchestrator.el:838`
- `cc-butler-session.el:207`
- `cc-butler-session.el:217`

Additionally, the MCP registry self-heal (PR #92 / `cc-butler-mcp-resilience.el`
once merged) uses that same table as its *recovery source* — under 0.3.0 that
feature needs a redesign, not a repointing.

## The rule

Upgrading claude-code-ide is a **standalone migration task**:

1. audit every usage site of removed internals,
2. redesign the MCP resilience layer's recovery source,
3. re-pin CI to the new SHA —

never a side effect of routine package upgrades. The live daemon's copy is a git
checkout in `~/.emacs.d/elpa/claude-code-ide`, deliberately left in **detached
HEAD** at `a9485f7` (2026-08-20) as a guard: `git pull` there now fails loudly
with "You are not currently on a branch". That failure is the guard *working*,
not breakage — do **not** "fix" it with `git checkout main`; that is exactly the
trap. The clone's local `origin/main` already points at 0.3.0 (`32a8a90`), so
staleness no longer protects anything: `package-upgrade-all`,
`package-vc-upgrade`, a casual `git pull`, **or re-attaching the checkout to a
branch** would advance it to 0.3.0 and break cc-butler at runtime. Treat all of
those as breaking actions on this machine.

---

# Merging several PRs? Re-run the suite AFTER the last one

Per-PR CI green does not compose. Each PR is tested against the `main` it was
written on, and GitHub's mergeability check is textual — neither of them ever
sees the state where all of them are in at once.

**So after a run of merges, before you call it done:**

```
git fetch && git checkout main && git pull
emacs -Q --batch -l tests/run-tests.el
```

## This is not hypothetical — three times in one afternoon (2026-09-06)

A sweep merged 12 PRs. All 12 were individually green with no conflict. Three
pairs still broke on contact, and every one of them broke SILENTLY — the code
kept working, the guarantee did not:

- **#136 + #146** — two sessions independently fixed the same leaked-tool-call-XML
  bug with disjoint patterns. Merged together, #146's guard ran above #136's, so
  #136's `REJECTED …` log never fired for the commonest payload. Rejections kept
  happening while the log that measures them read zero — indistinguishable from
  the fix having worked. (Its ERT test caught it, which is the only reason it was
  found.)
- **#165 + #148** — #165 adds `escalation-drain-*.log`, whose own docstring says
  it grows without bound. #148 adds rotation matching `ops-`/`msg-` only. Merged
  together, rotation reported success forever and never touched the one file that
  needed it.
- **#170 + #165** — #170's base branch WAS #165's branch. Merging #165 with
  `--delete-branch` auto-closed #170 and left it unreopenable until the deleted
  ref was recreated. Check `baseRefName` on every open PR before deleting a
  branch.

## The shape

All three are the same failure: **a mechanism that still reports success after it
stopped covering the case it exists for.** Nothing goes red, nothing logs, and
the difference between "working" and "holed" is invisible from outside. The whole
suite, run once at the end, is what makes it visible — and it is cheap (~6s).

While you are there, run it more than once: three tests spawn real subprocesses
and flake under concurrent runs (issue #177), so a single green is weaker
evidence than it looks.

---

# There are two test surfaces here, and only one of them is the gate

`matrix-bridge.el` carries its own `matrix-bridge-self-test` (in-file
`cl-assert`s) AND has an ERT suite under `tests/`. They overlap, so a change can
turn one red while the other stays green.

**The gate is the ERT suite, not the in-file self-test:**

```
emacs -Q --batch -l tests/run-tests.el      # 705 tests as of 2026-09-06
```

That is what CI runs. Passing `matrix-bridge-self-test` proves nothing about it.

## Why this is written down

2026-09-06: a change to `matrix-bridge-event-line` (appending
`matrix-bridge-human-reminder` to the human's own messages) updated the in-file
self-test and shipped. The ERT test
`matrix-bridge/event-line-human-sender-shows-attribution` still held the old
expected string, so CI went red on a PR that had been reported as ready to
merge. It was caught by hand, one step before the merge button.

The self-test is not redundant — it runs without the ERT harness and reads as
documentation next to the code. But it is a convenience, and **green there is
not evidence.** Run the suite.

## While you are here: an expectation built from a variable

When a test asserts on output that embeds a configurable string, build the
expectation by referencing the variable, not by pasting a copy of its current
wording:

```elisp
(concat "[matrix · 정수님 · id:$abc] hi" matrix-bridge-human-reminder)
```

Rewording the reminder should not turn an attribution test red. A pasted copy
makes every such test a second place the wording has to be maintained, and the
failure it produces points at the wrong thing.
