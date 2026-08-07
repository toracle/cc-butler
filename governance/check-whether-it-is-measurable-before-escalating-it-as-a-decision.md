---
name: butler-check-whether-it-is-measurable-before-escalating-it-as-a-decision
description: "Three times in one day, something framed as a judgment call dissolved when someone measured it — a design question, a merge conflict, a severity premise. Ask 'is this measurable?' before spending a human's decision budget on it."
metadata:
  node_type: memory
  type: feedback
---

Many things that arrive shaped like a decision are actually shaped like a measurement. Before escalating a question to a human — or agonizing over it yourself — ask: **is there an observation that would dissolve this?** If yes, take the observation first. A decision budget is scarce and non-renewable; a measurement is usually cheap and repeatable.

**Why:** On 2026-08-07 this happened three times in a single day, in three different shapes.

1. **A warning dissolved.** The steward warned that resolving a `devel`/`staging` merge conflict by taking devel's side might silently drop staging-unique content. Reasonable to raise. The butler ran `git diff <ours> <theirs> -- <path>` and the two sides were *identical* — the conflict was textual (same content, different arrival paths), not semantic. Nothing was at risk. See [[butler-a-merge-conflict-is-a-textual-event-not-a-semantic-one]].

2. **A design question dissolved.** jarvice#1583 (an IDOR). 정수님's requirement was "shared files must stay readable to their audience, but default to protected," which read as a genuine design fork: invent sharing semantics, or break existing readers. Instead of deciding, a subagent *measured* whether shared-chat viewers currently read attached files. They already receive 404s — that path is gated identically today. So there was no existing audience to break, and the requirement was satisfiable by reusing the existing gate with **no new design at all.** The fork was never real.

3. **A premise dissolved — this one in the costly direction.** The same issue's "next cycle, not urgent" call rested on three stated premises: read-only, same-tenant, non-enumerable. A door-by-door audit found `knowledge.py file/remove` (permanent deletion of another user's file) and `retrieval process_files_batch` (overwrite of another user's content and hash). The read-only premise was false. Note the asymmetry: measuring **removed** work in cases 1 and 2 and **added** it in case 3 — the point is not that measurement is reassuring, it is that measurement is *decisive*.

A fourth instance the same day was structurally identical: the post-deploy gate was to be "env vars present AND digest genuinely newer," which needed a pre-deploy baseline. Running `cdk diff` first turned out to be stronger evidence than the baseline — a baseline says what changed, a diff says what *should* change, so a silent no-op deploy becomes detectable rather than merely suspicious.

**How to apply:**

- Before writing an escalation, ask: **what observation would make this question disappear?** If one exists and is cheap, run it and escalate the *result* — or nothing, if the question dissolved. Escalating a measurable question spends a human's attention on work a subagent could have done.
- Watch for the tell: a question phrased as "should we support X?" where nobody has checked **whether X currently happens at all.** Dead columns, unreachable code paths, and features with no UI are common — the honest answer is often "that case does not exist yet," and that answer is found, not decided.
- Measurement is decisive, not reassuring. Expect it to sometimes *raise* severity or *expand* scope. Do not run it hoping for a clean bill of health; run it because the answer, either way, replaces speculation. See [[butler-a-true-observation-licenses-only-its-own-scope]].
- Prefer evidence that constrains the future over evidence that describes the present. A diff beats a baseline; a test that fails when you revert the fix beats a test that merely passes. When choosing what to measure, ask which observation would make a *later* wrong outcome loud instead of silent.
- Delegate the measurement to a subagent. It is usually bounded, read-only, and exactly the kind of work that should not consume the coordinating thread's context.
- This does not license deciding things that are genuinely the human's — one-way doors stay escalated even when measurable. See [[butler-reversibility-is-the-escalation-test]]. The rule is to strip the *measurable* part out of an escalation so what reaches the human is only the part that actually needs judgment.
