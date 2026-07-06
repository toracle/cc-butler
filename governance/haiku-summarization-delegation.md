---
name: butler-haiku-summarization-delegation
description: "Refines subagent-first for the pure-summarization case: when the sub-agent's only job is to read a long document/log/tool-output and answer a specific question, default its model to haiku — reserve larger models for sub-agents that must reason, decide, or verify."
metadata:
  node_type: memory
  type: feedback
---

`subagent-first` already says delegate by default, and already names "session
output, large tool output, or logs" as a trigger. This principle sharpens that
for one specific case: **pure summarization/extraction has no judgment call in
it**, so it doesn't need a reasoning-tier model. Reading a long file and
answering "what does X say about Y" is exactly the class of work haiku is
priced and speeds for. Save the larger models for sub-agents that must weigh
trade-offs, make a call, or adversarially verify a claim.

**How to apply.** Before reading a long file/log/session-output directly,
spawn a sub-agent (`Agent` tool, `model: "haiku"`) whose prompt (a) names the
exact file/output to read, (b) states the specific question the summary must
answer, and (c) instructs it to return only the distilled answer — not a copy
or paraphrase of the source. If the task requires judgment (deciding what to
do about what it found, weighing options, verifying a claim against
counter-evidence), it is no longer pure summarization — use the default
model instead.

**Applies identically to butler and steward** — both read long docs/logs
directly today; the same discipline and the same default model choice apply
to either, not just one.

**Known gap (same one `subagent-first` already names): guidance alone does
not change behavior.** A rule to remember mid-task is exactly the kind of
thing that erodes under load. The fix is a device, not a paragraph — a
reusable, named sub-agent definition that makes "delegate this read as a
haiku summarization" a single tool call instead of something to reconstruct
from memory each time.

**SPT.** Start with one local `.claude/agents/*.md` haiku-model summarizer
agent definition, dogfooded across the butler and steward homes first. Do not
build a shared public marketplace-style distribution mechanism (an Emacs-side
installer + a plugin repo other workspaces pull from) until the local version
has actually run for a while and proven itself — cheapest signal first; don't
build distribution infrastructure the cheaper local step might make
unnecessary or reshape.

Ties to `subagent-first` (this is a refinement of it, not a new rule) and
`worker-context-hygiene` (the same context-cost motivation, applied to what
model does the reading).
