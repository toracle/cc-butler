---
name: butler-every-dispatch-names-the-discipline-to-invoke
description: "정수님's standing instruction 2026-08-04: dispatches must tell the worker to INVOKE the fitting engineering skill (verify-first, sensemaking-loop, bug-fix-driven-development…) — and verify-first is what would have caught today's #1511 failure before the merge"
metadata:
  node_type: memory
  type: feedback
---

**정수님's standing instruction, 2026-08-04:** "verify first 등 sensemaking-loop 류의 스킬을 활용하도록 일러줍시다."
("Let's tell them to make use of skills like verify-first and the sensemaking-loop family.")

So every dispatch NAMES the discipline the worker should invoke, and says *invoke it* — via the Skill tool — not "keep it in mind." The gateway is `sensemaking-loop`; it routes to the focused skills. A worker left to its own devices reaches for the code, not for the discipline.

**Why — today's #1511 is the exact failure these skills prevent:**

The Craft custom-MCP fix went: defect found → fix written → RED/GREEN evidence → CI green → merged → promoted → deploy green → 정수님 told to test → **still not found**. Every gate we built was passed and the thing he cares about did not work.

The root cause was a Definition of Done adopted *after* the work: we treated "CI green + deploy green" as done. The actual observable — *an authenticated Tier-2 custom MCP server, HIS server, visible and callable in Craft* — was never written down as the DoD at the start.

Had `verify-first` been run before implementing, the DoD would have been that observable, and stating it would have immediately exposed the load-bearing unknown: **nobody knew which credential_strategy 정수님 had actually registered.** That unknown was flagged as unverified on the morning of the same day and then reasoned over all afternoon. The fix allowlists only `("none", "provider")`; if his server uses `oauth_public`/`oauth_confidential`/`api_key`, #1511 never covered his case. verify-first would have surfaced that at hour zero instead of after a merge, a promotion and a deploy.

That is the discipline's own warning made flesh: never author the verification after the implementation, because it gets bent to fit what you built.

**How to apply — put the named skill IN the dispatch:**

- Something is already wrong (bug, regression, "worked here not there", a failed prediction) → `bug-fix-driven-development`, plus `debugging-investigation` for the stance. Treat the hunch as falsifiable; build the smallest experiment that could REFUTE it.
- About to implement, or "how will we know it's done" → `verify-first`. Write the DoD and the experiment as tests BEFORE the code. State the predicted outcome as an explicit hypothesis, then compare.
- Scope or approach unclear, or the situation not yet understood → `sensemaking-loop`. It also owns the triage stage — deferring is a valid outcome.
- Risky or hard to reverse (deploy, migration, delete, calling a plan done) → `premortem`.
- Adding a new variant to a flow that already handles others → `new-variant-completeness`. **This one was live today**: Craft credential strategies are exactly a variant axis, and the fix widened the allowlist without driving every strategy to its terminal side effect.
- Changing a shape other code or stored data depends on → `backward-compatible-changes`.

And carry the standing corollary: **a green check is not the observable.** State in the dispatch what the human must be able to SEE, name who can see it, and forbid writing "verified"/"fixed" off CI, a merge, or a successful deploy.
