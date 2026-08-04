---
name: butler-absence-of-evidence-needs-a-control-and-an-evidence-class
description: "Before reporting 'no trace found', prove your search CAN find things (a control that must hit) and prove the store even records that class of event — a broken command and a true negative look identical"
metadata:
  node_type: memory
  type: feedback
---

A negative result is a claim about your instrument until you prove otherwise. Before reporting "nothing found," establish two things: (1) a CONTROL — run the same search for something certain to be present and watch it hit, so you know the search works at all; and (2) the EVIDENCE CLASS — confirm the store you searched actually records the kind of event you are asking about. Skipping either turns "my command failed" or "this log never captured that" into "it did not happen."

**Why:**

2026-08-04, asking who switched the Claude Code account to usage credits — a worker acting unilaterally on spend, or 정수님. Three separate failures stacked in one search:

1. *The broken command.* The first search failed with `ls: invalid option -- 'e'` and produced no output. An empty result is exactly what a clean negative looks like. It was caught only by re-running with a control grep for a word certain to exist.

2. *The wrong evidence class.* Even a working search could not have answered it. A chooser selection is a **TUI keypress**, not a conversation turn — the jsonl transcripts record messages, so no amount of searching them can distinguish who pressed Enter on which option. The evidence simply does not exist in that store. The honest answer was "structurally inconclusive," not "no worker did it."

3. *Own words returning as evidence.* The files that DID contain "Switch to usage credits" were the butler's and steward's own transcripts — because the two had been writing that string to each other all afternoon. Nearly reported as a finding. Same shape as `your-own-assumption-returns-as-corroboration`.

This was the fourth measurement artifact in a single day, after two false watcher fires and a truncated-screen quote — consistent with `fixing-one-instrument-flaw-does-not-validate-the-instrument`.

**How to apply:**

- Never report a negative without a control that must hit. If the control comes back empty too, the instrument is broken, not the world.
- Before searching, ask what the store physically records. Transcripts record messages; they do not record keypresses, menu selections, terminal state, or anything the TUI handled locally. Registries record process liveness, not screen contents.
- Say "structurally inconclusive — this evidence class does not exist here" rather than "not found." They lead to different next actions: one sends you to a different source (billing records, the human's own word), the other closes the question wrongly.
- Exclude your own channel from searches over shared stores. Orchestration chatter about a string is not an instance of the thing.
- When a negative would clear someone of wrongdoing, raise the bar rather than lower it — that is precisely the direction in which a false negative is most costly.
