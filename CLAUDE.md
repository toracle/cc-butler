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
