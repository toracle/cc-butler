---
name: butler-one-path-for-write-and-read
description: "A generated cache and its source must be located by ONE piece of code; a path default computed at definition time freezes across hot reloads, so writer and reader drift apart and the write reports success while landing nowhere"
metadata:
  node_type: memory
  type: feedback
---

When one place writes a store and another regenerates from it, **both must
ask the same function for the path**. And an operation that writes through a
generated cache is not done when it returns — it is done when the written name
has been **read back off disk** at the destination.

**Why:** on 2026-07-23 the butler hand-wrote operating principles into
`~/projects/cc-butler/governance/` and called `cc-butler-governance-regenerate`
three times. Each call answered `"regenerated"`. **Not one principle reached the
generated memory.** `cc-butler-governance-dir` was a `defcustom` whose default was
computed from `load-file-name` — and a defcustom default binds once, at first
definition, then survives every later reload. The code had since been hot-loaded
from a different checkout, so the code moved and the path did not. Writer and
reader were looking at two different directories, and nothing in the return value
could tell them apart.

Two failures, and the second is the dangerous one: (1) write and read chose
different paths; (2) **the failure reported itself as a success.** A wrong answer
that announces itself is a bug; a wrong answer that congratulates you is a trap,
and it cost three silent repetitions before anyone looked.

**How to apply:**
- Derive a location from something that re-evaluates with the code (`defconst`,
  or a function), never from a `defvar`/`defcustom` default that captures
  `load-file-name`. Honour an explicit user setting; delete the frozen default.
- Expose one accessor for the path and route every caller through it. A tool that
  takes the destination as an argument has handed the disagreement to its callers.
- Return evidence, not a verb. "regenerated" is not evidence. The absolute path
  written, the count before and after, and a read-back confirming the name is
  present at the destination — and if the read-back fails, return failure.
- This generalises past this store: any write that lands somewhere other than
  where it is read — caches, generated configs, deploy targets, another checkout
  — deserves the same read-back before it claims to have worked.
