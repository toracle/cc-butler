---
name: butler-a-shared-limit-degrades-unevenly
description: "A usage/quota limit does not stop a fleet uniformly — it kills subagent dispatch first while main threads keep completing calls. So 'the fleet is stopped' is almost never the accurate description; read a screen and establish the blast radius before naming it. Also covers the inverse over-correction ('only one worker'), and what to do operationally when dispatch fails but main threads work."
metadata:
  node_type: memory
  type: feedback
---

**A quota limit fails PARTIALLY and UNEVENLY, so name its blast radius before naming the limit.** The failure surface that goes first is **subagent dispatch** — the expensive, many-call, parallel-fan-out work. Main threads keep completing model calls normally, often for hours. A session can therefore show a real "You've hit your weekly limit" error on screen *and be actively working two lines below it*.

"The fleet is stopped" is the intuitive description and it is almost always wrong.

**Why:** On 2026-08-12 a weekly limit (reset 19:00 KST) hit while several workers were running. The steward reported the fleet as STOPPED and framed the usage-limit chooser as blocking all work. 정수님 asked the butler to re-check. Reading `monocle-chat-turn-model`'s actual screen showed: a subagent ("Settle #1505 vs chat_version dependency") had died with the limit error, and the *same session's main thread* had then run `gh pr view 1505` successfully and was mid-draft at CTX=281k. In the same window `monocle-16-scheduler` finished its work and compacted. The limit was real; the stoppage was not.

The butler then over-corrected to "it killed one worker's subagent, that's all" — also wrong, in the opposite direction, because the constraint genuinely does bite any heavy multi-subagent work for the rest of the window. **Two relay stages, two inaccurate frames, converging on the truth only because the human asked for a re-check.**

The accurate word was neither *stopped* nor *fine*. It was **degraded**.

This was the third instance the same day of one pattern: **accurate content, over-amplified frame, and the second relay stage holding the evidence to check but not checking** (see [[butler-establish-impact-before-choosing-the-noun]] and the "fail-open by default" → "defaults ON" distortion). A limit is especially prone to it because the error text is genuinely alarming and genuinely real — the temptation is to relay the error's severity rather than measure its reach.

Note the cost asymmetry that makes this worth catching: an overstated limit invites the human to **spend money** (buy credits, upgrade a plan) to solve a problem that resolves itself on a timer. Over-amplification here has a price tag.

**How to apply:**

- **Before reporting any limit/outage/quota event, read at least one affected session's screen and one unaffected session's screen.** The question is never "is the limit real" — the error text settles that. It is "what still works", and only a screen answers it.
- **Prefer *degraded* to *stopped* unless you have seen a main thread fail.** State what specifically fails (dispatch, heavy fan-out) and what specifically still works.
- **Check the reset time and put it in the report.** A limit with a known reset is a schedule cost, not a safety event, and it usually makes any spend decision moot. Say so explicitly — "no money needs spending, this self-resolves at HH:MM" — because the human's default reading of a quota error is that they must act.
- **Do not over-correct into "it only hit one worker".** The constraint is real for the rest of the window and forbids starting new heavy work. Both frames are failures of measurement.
- **Operationally, when dispatch fails but main threads work, do NOT tell a worker to "just do it in the main thread".** That trades a budget problem for a context problem, and the context one makes the worker *unreliable* rather than merely *slow*. Split the remaining work by SHAPE: cheap checks (own-document comparison, a single grep) proceed inline; subagent-shaped work (multi-file crawls, call-chain tracing) parks until reset with a one-line note of the question it must answer. This matters most on a worker already near or past 200k.
- **Say the standing subagent-first habit is temporarily unavailable, and name the substitute.** A worker told only "you can't delegate right now" will reasonably infer "so do it all yourself" — which is the exact failure above. The substitute is *park the expensive part*, not *absorb it*.
- **Re-dispatch the narrow dead question after reset, not the whole concern.** When a verification subagent dies, identify precisely what it was settling; the surrounding facts it was refining are usually already established and re-deriving them wastes the restored budget.
- **Set the posture for the remainder of the window explicitly:** start no new heavy work, finish what is already running.
