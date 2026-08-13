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

**A failure's blast radius is the same kind of claim, and needs the same control.**
On 2026-08-09→10 the steward's `send_to_session` timed out eight times running. It
diagnosed the scope **three times, wrongly, in sequence**:

1. *"The MCP server is down"* — escalated to 정수님 asking for a restart. Refuted by
   noticing the butler's own relay had reached the steward fine.
2. *"My session's MCP client is hung"* — withdrawn on realising that
   `compact_session`, `escalate_to_butler`, `butler_log`, `read_session_output`,
   `session_status` and `regenerate_governance` had **all been working from that
   same session the whole time**.
3. Only then the true statement: **`send_to_session` alone fails, only from the
   steward.**

Every refutation came from evidence that was **already in hand and free to check**.
The control — *call a neighbouring tool and see if it works* — cost one call and was
available before the first escalation. Instead the most salient symptom was
generalised straight to "the system is down", and a request went to the human to
restart a server that was never broken — a restart that would have disturbed every
running session to fix a fault in one.

So: **"X is broken" is a claim about the boundary of the failure, not just the
failure.** Before naming a scope, exercise the nearest thing that should still
work. A failure whose blast radius is asserted rather than bounded will be
asserted too wide, because the widest reading is the one the first symptom
suggests.

**How to apply:**

- **Bound a failure before you name it.** One working neighbour separates "the
  server is down" from "this one call is down", and the two have completely
  different remedies. Do this before escalating, not after.
- **Be suspicious when a diagnosis needs revising twice.** Each revision here came
  from evidence already available — the pattern is not bad luck, it is concluding
  at the first symptom and re-concluding at the second.
- **A remedy whose blast radius exceeds the fault's is a tell.** Being about to ask
  for a restart of everything to fix one call should have prompted the check.
- Never report a negative without a control that must hit. If the control comes back empty too, the instrument is broken, not the world.
- Before searching, ask what the store physically records. Transcripts record messages; they do not record keypresses, menu selections, terminal state, or anything the TUI handled locally. Registries record process liveness, not screen contents.
- Say "structurally inconclusive — this evidence class does not exist here" rather than "not found." They lead to different next actions: one sends you to a different source (billing records, the human's own word), the other closes the question wrongly.
- Exclude your own channel from searches over shared stores. Orchestration chatter about a string is not an instance of the thing.
- When a negative would clear someone of wrongdoing, raise the bar rather than lower it — that is precisely the direction in which a false negative is most costly.
