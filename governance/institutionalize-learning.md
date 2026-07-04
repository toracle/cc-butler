---
name: butler-institutionalize-learning
description: "A core butler/steward duty — when a recurring/looping problem is resolved well, capture the anti-recurrence learning in the right DURABLE, RECALLABLE home so it doesn't die with the session context and the problem doesn't recur"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 24305c3a-429a-4449-800d-2bf67f660d4b
---

The user named this a core butler/steward role: **institutionalize anti-recurrence learning.**
When a situation repeats / recurs / loops (반복·재발·맴돎) and is then resolved well, the fix-
knowledge must NOT live only in a session's context window (which is cleared/compacted and lost)
— it must be documented in a durable place that the next person/session who could hit it will
RECALL automatically, without remembering to look.

**Route the learning by scope (the key move — right home for recall):**
- **Operating / coordination** (how butler & steward work) → butler/steward **memory** (loads
  every session). e.g. [[butler-no-overinterpret]], [[butler-state-desync]],
  [[butler-evaluation-independence]].
- **Reusable engineering discipline** (a class of problem) → **warmblood-kr/skills** engineering
  plugin (triggers on the situation). e.g. the `global-consistency` skill from the subdomain bug.
- **Repo / project-specific gotcha** → **that repo's CLAUDE.md** (loads when working there).
  e.g. monocle: normalize a shared value via one function because it's stored in 3 places.
- **Cross-repo project fact** → the warmble-jumble vault.

**Trigger (the habit):** right after resolving a recurring/looping situation
(reflection-on-action, cf. `reflective-learning` skill), ask: (1) will this recur? (2) what is
the smallest artifact that prevents it? (3) where must it live to be recalled by whoever hits it
next? — then route it there.

**Recall guarantee:** each home auto-loads at the right time (memory every session; skills on
trigger; repo CLAUDE.md when working that repo), so the learning returns without anyone looking.

**Ownership:** the **steward** sees the worker firehose → routes worker-side / repo / engineering
learnings; the **butler** captures operating/coordination learnings. A standing duty in both
role CLAUDE.mds.

**Runtime-neutral homes ONLY (the user's hard constraint).** Do NOT couple the knowledge to
Claude Code's memory mechanism — if the runtime later changes (Codex, opencode, …) the
principles would be lost. The *source of truth* must live runtime-neutral: the warmble-jumble
**vault**, the **warmblood-kr/skills** repo, a repo's own project doc, or a **cc-butler-owned
store** (Emacs/file-based). The per-runtime context file (Claude Code memory/CLAUDE.md, Codex
AGENTS.md) is a *generated adapter* from that neutral source — never the source. cc-butler (the
runtime-neutral orchestration layer) owns the knowledge and injects it per runtime; Claude
Code's memory is at most a generated cache. (This aligns with the heterogeneous-agent
governance-bus: neutral core + per-runtime adapters.) MIGRATION DONE: the butler/steward
operating principles now live in the cc-butler repo store `governance/` (one .md each) as the
single source of truth; `cc-butler-governance-regenerate` writes them back into Claude Code
memory, which is now a *generated cache*. **Workflow (important):** route a new operational
learning by **editing the store `governance/<principle>.md` + regenerating** — NOT by editing
memory directly (a direct memory edit is overwritten on the next regenerate). The
routing-target for operational/coordination learning is therefore the **store**, generated to
memory.

**SPT:** the system IS the routing-to-existing-durable-homes habit, NOT a heavy new tracker.
Don't over-build it. Ties to [[warmblood-talent-philosophy]] (Leave It Better; Count the Outcome).
