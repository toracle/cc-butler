---
name: butler-your-own-assumption-returns-as-corroboration
description: "A verification subagent handed a claim as 'what X believes' can only check it against the world — it can never discover X never believed it; test a belief at its source, not against your summary"
metadata:
  node_type: memory
  type: feedback
---

When you dispatch a subagent to verify something, the FRAME you hand it is not under test — only the claim inside the frame is. So if you write the prompt as "worker X believes P; check P", the subagent can return "P is false" but can never return "X never believed P." Your own inherited assumption then comes back wearing the face of independent corroboration, and you relay it upward as a finding about X.

**Why:**

2026-08-04, post-restart roll-up. The 00:09 dashboard and the pre-crash handoff both said monocle-jarvice-978 was "idle and fully on hold pending the `options` decision." The steward rehydrated from those artifacts, inherited the sentence, and dispatched a verification subagent with the claim framed as *the worker's* belief. The subagent dutifully checked it against git, found the decision had shipped in #1501, and returned "STALE BELIEF: the worker believes it is on hold — false." That flowed up to the butler and into a status document 정수님 was reading.

The worker had never said it. It closed #1476, filed #1510 and commented on #1480 at 21:02Z — all *after* #1501 merged at 17:11Z. It was working with the decision in hand the entire time. The "on hold" sentence was ours, not its.

It was caught only because the worker refused to accept the correction by default and asked which of its own reports supposedly showed that belief — and because the steward then checked instead of re-asserting. Note the shape: the tracker was stale, not the worker, which is the very pattern (`the-tracker-keeps-claiming-work-that-already-shipped`) running in the direction nobody was watching.

**How to apply:**

- To test what an agent *believes*, read its own current output. Its self-report is the source; your summary of it is hearsay, and a subagent cannot tell the two apart.
- To test whether a claim is *true*, hand the subagent the claim WITHOUT attribution — "check whether P holds" — so the verdict cannot be silently misread as a verdict about who holds P.
- Keep the two questions in separate dispatches. "Is P true?" and "does X think P?" have different sources and must not share a prompt.
- When a rehydrated artifact and a live agent disagree, suspect the artifact first. It was written at a moment; the agent is the moment.
- Treat a subagent result that merely agrees with the assumption you fed it as UNCORROBORATED, not confirmed. Related: `steward-adversarial-check-beats-judgement`, `merging-agent-results-must-keep-per-claim-provenance`, `evaluation-independence`.
