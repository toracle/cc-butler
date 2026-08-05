---
name: butler-a-fork-is-usually-inherited-not-derived
description: "When you are handed an either/or, check whether the fork exists in the code or only in someone's description of it — naming one cheap check and actually running it dissolves most of them"
metadata:
  node_type: memory
  type: feedback
---

Most either/or choices that reach a manager are not properties of the system. They are properties of how the system was **described** to you — usually by someone summarising, often by you. Before weighing the two options, ask whether the fork exists in the source at all. Name the single cheapest check that would settle it, and then **run it**. A surprising fraction of the time the answer is not "option A" or "option B" but "the thing that made these look mutually exclusive isn't there."

**Why:** On 2026-08-05 this happened three times in a single afternoon, on three unrelated questions, and each time the dichotomy came from a description rather than from the code:

1. **"Leave the fail-open, or close it and accept the availability cost."** My framing. The steward found the third option: "no policy row" and "the DB raised" were being conflated at one `try/except`, and they are separately distinguishable in the code today. Separating them closes the hole with no availability cost at all. The tradeoff I had posed did not exist — the conflation did.
2. **"Claim B is contained because it stays inside the user's own enabled set."** Also mine, and the justification was wrong even though the verdict was right: the Craft candidate set comes from `get_active_servers()`, tenant-wide, with records synthesised for users with no `UserMcpServers` row. What actually contains it is that the authorization filter still runs — which is *precisely* the thing the other confirmed defect disables. Had I kept my stated reason, I would have judged the composition of the two defects safe.
3. **"Reuse the single `credential` string, or add fields and change agent-sandbox too."** Shared assumption, both of us. The worker was told to name the check that would decide it, named it (T1), and **ran it**: `resolve_user_credential_detailed` is keyed `(user_id, provider)` over `UserConnectors` and knows nothing of `TenantMcpServer`. The blocker was never on the agent-sandbox side. There was one repo to change the whole time, not two.

Two of the three forks were authored by me and handed down as though they were findings.

**How to apply:**

- Treat "which of these two?" as a prompt to check the premise, not to start weighing. The question to ask first is *where did this fork come from* — a file, or a sentence?
- **Name the check before you argue.** "What one observation would settle this?" If you cannot name one, you do not understand the fork well enough to choose within it.
- **Then run it.** Naming a check and not running it is the failure mode; a named-but-unrun check gets quoted later as though it had been performed. In the case above, the instruction was only to *name* it — the worker ran it anyway, and that is what dissolved the question.
- Watch your own framings hardest. A fork you authored arrives back at you wearing the authority of a finding. See [[butler-your-own-assumption-returns-as-corroboration]].
- A right conclusion can rest on a wrong justification, and you find out only when someone composes it with something else. When you accept a verdict, check the *reason* too — that is what the next question will be built on.

See also [[butler-probably-unchanged-is-an-argument-not-a-check]], [[butler-adversarial-check-beats-judgement]], [[butler-structurally-impossible-beats-checked-and-absent]].
