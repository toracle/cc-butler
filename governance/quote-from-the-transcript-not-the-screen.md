---
name: butler-quote-from-the-transcript-not-the-screen
description: "A terminal screen is a rendering, not a record — read_session_output returns wrapped, truncated, scroll-bounded lines, so a quote taken from it looks verbatim and is not. Source any quote that will travel from the transcript. Tell: a quote that begins mid-sentence is a fact about the viewport, never about what someone said."
metadata:
  node_type: memory
  type: feedback
---

When a human's words are going to TRAVEL — be relayed upward, dispatched to a worker, pasted into an issue, or acted on — source them from the **transcript**, not from `read_session_output`.

A terminal screen is a *rendering*, not a record. It wraps, truncates at the left and right edges, and is bounded by the scroll window. Text lifted from it looks verbatim and is not. The loss is silent: you get a grammatical, plausible sentence with a clause missing.

**The tell, and it is reliable: a quote that begins mid-sentence is a fact about the viewport, never about what the person said.** If your quote opens on a fragment, you are looking at a rendering. Go to the source.

**Why:** 2026-08-04. The cc-butler session's last pre-crash prompt was 정수님 asking it to investigate session-list instability. Relaying it upward, the steward quoted from that session's screen:

> "...after that, claude-session list became be ziggled. shall we inspect what causes it?"

The visible line began with the fragment "a while." — truncated at the left edge — and the steward relayed it without going to the source and without flagging it as partial. The butler pulled the original from the transcript:

> "suddenly, cc-butler's claude-sessions became unstable and ziggles. as I know, **we pulled cc-butler codebase which was not updated for a while.** after that, claude-session list became be ziggled. shall we inspect what causes it?"

The dropped clause is 정수님 supplying a suspected **cause** — the strongest lead in the investigation. The relay reduced his question to a bare symptom report with no lead at all, and the worker would have started from nothing.

**Second-order lesson, which is the more important one.** Reviewing your own relay more carefully would NOT have caught this — you cannot see a truncation that is not in your copy. It was caught by someone re-deriving from the primary source. The same shape appeared an hour earlier the same morning: the steward fed a verification subagent its own inherited assumption labelled as "what the worker believes", and got it back as apparent independent corroboration. Both defects were in what was passed FORWARD, and both were caught only by returning to the source.

So the general rule: **for any claim that will be acted on, the check is re-derivation from the primary artifact, not re-reading your own summary.** Self-review validates transcription; it cannot validate provenance.

**How to apply:**
- Quoting a human or a worker for relay/dispatch/an issue → pull from the transcript (`~/.claude/projects/<project>/*.jsonl`) or the decision store, not from `read_session_output`.
- `read_session_output` remains right for *state* — is it idle, is a wizard open, is there stray input, what model, what CTX. Those are properties of the screen, which is exactly what it renders.
- If you must quote from a screen (source unavailable), say so in the relay: "quoted from screen, may be truncated."
- Any quote you are about to send that starts mid-sentence: stop, fetch the original.

Related: [[butler-relay-fidelity-provenance]] (carry verbatim words as a referenceable artifact — this is *how* you get the artifact), [[steward-relay-claims-with-their-status]] (watch for your own guess returning as corroboration), [[butler-ghost-text-not-input]] (the other way a screen misrepresents input).
