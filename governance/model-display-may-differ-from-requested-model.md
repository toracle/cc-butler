---
name: butler-model-display-may-differ-from-requested-model
description: "Fable falls back to Opus automatically; a session showing Opus after a verified Fable switch is normal, not a failed switch — do not re-apply /model, each retry forces a full context re-read"
metadata:
  node_type: memory
  type: feedback
---

A session's displayed model can differ from the model that was requested and successfully set. Fable falls back to Opus automatically, and that fallback is unavoidable — it is a property of the environment, not a failed switch, not a reverted setting, and not something to diagnose.

So: after a `/model` switch has been applied and verified once, **stop looking**. Do not institute a periodic check that re-applies the model when the statusline shows something else, and do not treat a drifted display as evidence that the earlier switch did not take.

**Why:** On 2026-08-08 정수님 asked for butler and steward to run on Fable. The steward switch was applied and verified on-screen (`Set model to Fable 5`, statusline `MODEL=Fable-5`). Twenty minutes later the statusline read `Opus-5` with no session restart — context had grown continuously from 154k to 167k, so the conversation was intact. Butler read this as a silent revert of unknown cause, re-applied the switch, and then told 정수님 it would *periodically re-check and re-fix the model*. 정수님 answered that Fable turns to Opus automatically and it is unavoidable.

That planned recurring check would have been actively harmful, not merely useless. The switch dialog states it plainly: *"This conversation is cached for the current model. Switching means the full history gets re-read on your next message."* At steward's ~170k context, every unnecessary re-application pays a full cache re-read. A monitor built on a misread signal would have billed that repeatedly, forever, to correct something that was never wrong.

The same session also produced the softer half of this: `session_status` and the live terminal screen disagreed about steward's model in both directions within minutes. The status tool reports what a session's statusline last emitted, which is a claim about the past, not a live measurement.

**How to apply:**
1. Apply a model switch, verify it once on the live screen, and consider it done. `Opus` appearing later is expected.
2. Never build a watchdog on a signal whose normal behavior you have not confirmed with the principal. Ask what the signal does before deciding it is broken — "why does this drift?" is one question to 정수님, whereas a wrong answer becomes standing recurring cost.
3. Before promising 정수님 any *recurring* remediation, price one cycle of it. If a single cycle is expensive (full context re-read, a restart, a deploy), the bar for the diagnosis behind it is much higher than for a one-off fix.
4. When a status tool and the live screen disagree, the screen wins — but neither is evidence that a *setting* failed. See [[butler-context-ceiling-and-compaction]] on read figures being claims, and [[butler-suspiciously-uniform-is-the-instruments-fingerprint]] on suspecting the instrument before the world.
