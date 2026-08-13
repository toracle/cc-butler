---
name: butler-model-and-context-readings-lag-force-a-repaint
description: "run the discriminator on ONE instance before converting all N — applying the fix to every instance destroys the evidence that would have told you whether the fault was real (mechanism detail lives in resume-reverts-the-model-and-the-status-line-lags)"
metadata:
  node_type: memory
  type: feedback
---

When N instances show the same anomaly, the fix and the evidence are often the same object. Applying the fix to all N **destroys your ability to ever confirm the anomaly was real.** Run the discriminating probe on one, leave the others untouched until it returns, and only then sweep.

The model/status-line mechanism itself is recorded in [[resume-reverts-the-model-and-the-status-line-lags]] — this note is the general form of the procedural error made alongside it.

**Why:** 2026-08-11 post-reboot restore. Five workers read `MODEL=Opus-5` against a 19:14 dashboard recording them as Sonnet-5. The butler ran a clean control proving the alias `/model sonnet` works and the status line is the lagging instrument — then immediately converted all five. Every one now reads Sonnet-5, which is equally consistent with two different worlds: "they had really drifted to Opus and I fixed it," and "they were already on Sonnet and my repaint merely revealed it." The probe that separated those worlds was a neutral repaint on an *unconverted* worker, and after the sweep there was none left to run it on. The corrective action was correct and cheap; the cost was that the diagnosis behind it can no longer be confirmed.

Note the sequencing trap: the butler had *just* built a control for a neighbouring question and got the discipline right there, then dropped it one step later when the action felt obvious and low-risk. Cheapness of the fix is what makes this easy to skip — it removes the pressure that would otherwise make you pause.

**How to apply:**
- Before a sweep, ask: "after I apply this everywhere, what observation could still tell me whether the fault was real?" If the answer is none, hold one instance back as the control.
- Holding one back is nearly free when the fix is cheap and reversible — which is exactly the case where the urge to skip it is strongest.
- This is the same discipline as [[steward-capture-evidence-before-changing-state]], applied to a *fix* rather than a restart: the remediation is the thing that erases the record.
- Related: [[broadcast-verify-one-first]] (verify one before applying to all) is the safety form; this is the epistemic form — verify one so you can still *learn* after applying to all.
