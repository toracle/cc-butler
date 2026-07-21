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
`read_session_output` now detects and redacts a ghost-faced input line
itself (`cc-butler--read-output-redacted` in `cc-butler-orchestrator.el`,
`cc-butler#6`) — every caller is safe by default, with no rule to remember
and no manual check required. This is deliberately a short note, not a
multi-clause standing rule: a tool that hands out a trustworthy signal
doesn't need a norm compensating for one that didn't.

**Manual check, if you ever need it:** a parked input line rendered
`#a7a7a7` on `#262626` is ghost; anything else is real.

**If a new case turns up that this fix doesn't catch**, that's evidence the
detection is incomplete (a face variant, a different marker) — extend the
fix, don't add a remembered clause here.

Refines [[butler-ghost-text-not-input]]; unrelated to
[[butler-relay-safe-worker-decisions]] (the `AskUserQuestion` live-wizard
hazard is a different failure mode, still fully in force).
