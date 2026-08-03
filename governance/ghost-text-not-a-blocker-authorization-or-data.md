---
name: butler-ghost-text-not-a-blocker-authorization-or-data
description: "Historical note, not a standing rule: Claude Code's ghost/autocomplete input-line suggestions used to be indistinguishable from real typed text through read_session_output. Fixed at the tool itself on 2026-07-21 (cc-butler#6) — read_session_output now detects and redacts ghost text, so every caller is safe by default with nothing to remember."
metadata:
  node_type: memory
  type: feedback
---

Ghost/autocomplete text used to be invisible to `read_session_output`
(`buffer-substring-no-properties` stripped the one signal — a distinct gray
face, `#a7a7a7` on `#262626` — that told it apart from real input). Two
measured incidents on 2026-07-21 showed the cost in both directions: a
phantom `merge #1361` produced a false blocker (a session stuck at 561k
context, uncompactable), and a phantom `PR #72 머지 진행해주세요` would have
been a false authorization to merge a PR nobody approved.

**Fixed at the source, 2026-07-21 — not by discipline.**
`read_session_output` detects and redacts the input row itself
(`cc-butler--read-output-redacted` in `cc-butler-orchestrator.el`,
`cc-butler#6`) — every caller is safe by default, with no rule to remember
and no manual check required. This is deliberately a short note, not a
multi-clause standing rule: a tool that hands out a trustworthy signal
doesn't need a norm compensating for one that didn't.

**The color check was itself wrong, and was deleted 2026-07-24.** Measured
live, this fleet paints ghost text `#8686a8` on `#00005f`, not `#a7a7a7` on
`#262626` — so the comparison never matched here, and the "cannot tell ->
real input" fail-safe silently promoted every ghost row to real input. The
question is now answered by the terminal CURSOR (`cc-butler--input-state`
in `cc-butler-session.el`): a painted suggestion leaves the cursor at the
prompt because the input buffer is genuinely empty, while typed text
advances it. Styling is not state. **There is no manual color check any
more; do not reintroduce one.**

**The predicate reports three outcomes** — real, ghost, and *unknown* — and
resolves none of them, because the two callers need opposite fail-safes:
the compaction guard treats unknown as real input and refuses to type,
while `read_session_output` treats unknown as ghost and redacts, marking
the row `UNVERIFIED` so a guess is never shown as a determination.

**If a new case turns up that this fix doesn't catch**, that's evidence the
detection is incomplete — extend the fix, don't add a remembered clause
here.

Refines [[butler-ghost-text-not-input]]; unrelated to
[[butler-relay-safe-worker-decisions]] (the `AskUserQuestion` live-wizard
hazard is a different failure mode, still fully in force).
