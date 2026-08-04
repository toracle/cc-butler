---
name: butler-close-sessions-does-not-mean-close-topic
description: "'Close/hibernate the sessions' for a shutdown or machine move NEVER means close_topic — that tool permanently DELETES the workspace directory and every local file. Hibernation needs no tool: the roster plus transcripts restore everything on `--continue`."
metadata:
  node_type: memory
  type: feedback
---

When asked to "close the sessions", "hibernate", or "shut everything down" ahead of a reboot, a machine move, or the end of a day: **do NOT reach for `close_topic`.** That tool is `DESTRUCTIVE, IRREVERSIBLE` by its own description — it kills the session AND **permanently deletes the topic workspace directory, its git clone(s) and every local file**. It exists to retire a *finished* worker whose work is already pushed and whose workspace is no longer wanted.

**Hibernation requires no tool at all.** Shutting the machine down closes the sessions on its own, and `/home/toracle/.emacs.d/cc-butler-sessions.eld` plus the per-session transcripts under `~/.claude/projects/` restore all of them with `claude --continue`. That path is proven: the unannounced 06:05 crash on 2026-08-04 took twelve workers and all twelve came back with their full context.

**Why:**

2026-08-04, ahead of a planned desktop move, 정수님 said "let's hiberate (close) all sessions and prepare dehydrate," then "close sessions yourself." The only session-closing tool the butler holds is `close_topic`. Using it on twelve workers would have permanently destroyed twelve workspaces — the exact opposite of hibernation, and irreversible. The butler read the tool's description before calling it, flagged what it actually does, and did not use it. 정수님's reply: "oh, close_topic deletes workspace. no. I don't want it."

The trap is linguistic: "close the session" and "close the topic" are near-identical phrasings for opposite operations. And the tool's own safety gates would not have saved us — they refuse only on uncommitted or unpushed git state, and a worker that had just been told to commit everything for the shutdown would sail straight through them. **The sweep we ran to make the shutdown safe would have removed the last obstacle to deleting everything.**

**How to apply:**

- For a shutdown, reboot, or move: **externalize, commit, then let the machine close the sessions.** Verify the roster is intact first — that is what makes resume possible — and verify it by reading the file, not by assuming.
- What is actually volatile is **session context in memory**, not the working trees, which survive a move on disk. Prioritize accordingly: state-to-artifact first, commit second, tree hygiene third, push as insurance. Getting this order wrong sends workers off to commit build artifacts while their analysis dies unrecorded.
- Never let "the tool has safety gates" substitute for reading what the tool does. Here the gates were real and would have passed.
- If someone genuinely wants a workspace retired, that is a separate, named decision with its own confirmation — never a step inside a shutdown procedure.
- Related: `subagent-destructive-op-scoping` (a destructive op needs explicit per-target scoping), and the standing rule to look at the target before deleting or overwriting.
