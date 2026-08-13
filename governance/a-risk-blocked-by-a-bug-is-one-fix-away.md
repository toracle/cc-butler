---
name: butler-a-risk-blocked-by-a-bug-is-one-fix-away
description: "When a dangerous path turns out not to be executing, find out WHY not — if the answer is a defect rather than a guard, the danger is one plausible bug-fix away, so the fix and the policy decision must ship as one item."
metadata:
  node_type: memory
  type: feedback
---

"Is the dangerous thing happening?" is the wrong place to stop. **"No" has two
completely different meanings**, and they are indistinguishable in the answer:

- *No, because something prevents it.* — a control. It holds.
- *No, because something is broken.* — an accident. It holds until someone fixes
  the bug, and **the person who fixes it will believe they are removing a defect,
  not opening a door.**

The second is more dangerous than an ordinary open risk, because it comes
pre-disguised as a chore. Nobody reviews a casing fix as a security change.

**Why:** On 2026-08-09 a steward asked a worker to check whether user-selected MCP
servers were already executing inside scheduled runs unreviewed. The answer was
no. The reason was not a guard:

```
DB stores:   meta.toolIds        (camelCase)   ← actually populated
code reads:  meta.get("tool_ids") (snake_case) ← nobody writes this key
```

Live data showed one tenant's model carrying
`["mcp:ms365","mcp:github","mcp:dart","mcp:iros"]`, and two other tenants'
models likewise. Rows with the snake_case key the code reads: **zero**. The
fallback was reading a key nothing populates. So the boundary was intact **by
misspelling.**

Worse, the codebase *documents the camelCase form as a supported mechanism*
(`mcp_tools_assembler.py:49` refers to "custom-model meta.toolIds"). A future
reader comparing the two would file it as an obvious bug and correct it — and
silently switch on unreviewed third-party tool execution inside scheduled runs.

This was the **second** producer/consumer spelling divergence found the same day;
the first was a set of dev-escape-hatch gates comparing `ENV == "prod"` on a fleet
that deploys `prd`. Same shape, opposite polarity: one spelling mismatch left a
door open, the other held a door shut.

**The operational consequence: the fix and the decision are one item.** A PR that
"just corrects the casing" must not merge alone. Whether scheduled runs may attach
user-selected MCP servers is a policy question for a human, and the casing fix is
the thing that *enacts* the answer. Separating them lets an unreviewed policy
change ride in on a typo correction.

**How to apply:**

- **Never accept "it isn't happening" without "because…".** Write the mechanism
  down. If you cannot name the control, you have found an accident, not a
  guarantee.
- **Ask what one plausible edit would flip it.** If a rename, a casing fix, a
  version bump, or a "cleanup" would enable the risk, the risk is live — it just
  has a timer on it.
- **Bind the enabling fix to the policy decision in writing.** Say so in the issue:
  *"this must not be merged separately."* The next person will not reconstruct the
  coupling from the diff.
- **Suspect documentation that legitimises the broken form.** When a doc or a
  comment describes the unused spelling as supported, someone will "restore" it.
  That documentation is a scheduled trigger.
- **Check both directions of a spelling divergence.** Producer/consumer mismatches
  hide open doors *and* fake closed ones; finding one instance is a reason to grep
  for the pattern, not to relax.
- **State what the finding does not cover.** The same worker noted that the run
  under investigation used a different model than the one carrying the `mcp:`
  entries — so even with matching spelling, *that* run would not have picked them
  up. Bounding the claim keeps a real finding from inflating into a bigger one.

**SPT:** the habit is *when the dangerous thing turns out not to be happening, ask
whether a guard or a bug is stopping it — and if it is a bug, treat its fix as the
change that needs the approval.*
