---
name: butler-fixing-a-fail-closed-stage-runs-the-next-one-for-the-first-time
description: "In a serially fail-closed pipeline, the blocked stage shields every stage below it from ever executing — so fixing the blocker does not finish the job, it runs untested downstream code in production for the first time ever. Expect serial discovery, budget for it, and never let the gate be 'the stage I fixed now succeeds'."
metadata:
  node_type: memory
  type: feedback
---

A stage that fails closed does not merely block itself — it **shields everything downstream from ever running**. So the downstream code has no production history at all: no logs, no errors, no evidence of any kind, because it has never been invoked. Fixing the blocker therefore does not complete the pipeline. It causes never-executed code to run in production for the first time, and whatever is wrong with it surfaces immediately.

Corollary that matters for estimates: **"one more deploy and we're done" is almost always wrong here.** The correct expectation is *serial discovery* — fix, expose the next stage, discover its latent defect, fix, repeat — with an unknown number of rounds. Say that out loud to the human early, rather than promising an end that keeps receding.

**Why:** 2026-08-05/06, monocle#16 (EventBridge scheduler, staging). The dispatch Lambda failed closed because `STARK_API_KEY` could not be read (SSM SecureString is structurally unsupported in Lambda `Environment.Variables`). Six consecutive invocations died on `AccessDeniedException`. That took most of the night to diagnose and fix (runtime SSM lookup + an `ssm:GetParameter` IAM grant).

The fix worked exactly as designed: the very next tick logged `tenants_ok=1 schedules_seen=5`, and the gate the whole night had been aimed at finally opened. It was reported up as success.

Then the next hop died. The launcher Lambda `schedule_ecs_launcher` crashed at **module import** on every invocation — `open_webui.env` runs `if WEBUI_AUTH and WEBUI_SECRET_KEY == "": raise ValueError(...)` at module level, and the launcher's CDK env block never included `WEBUI_SECRET_KEY`.

The decisive detail: **that bug had been latent since the launcher was created, and was undiscoverable.** The launcher is invoked only by SQS messages, the dispatcher had never successfully published one, so the launcher had never run — not once. There were no error logs to find because there were no invocations. Fixing bug A is what produced the first SQS message in the system's history, which is what executed the launcher for the first time, which is what exposed bug B.

Note the shape both bugs share, which is worth recognising on sight: **a thin new variant did not inherit the fat predecessor's environment baseline.** The dispatch Lambda inherited `refreshMemoryLambda`'s whole env block and so happened to carry `WEBUI_SECRET_KEY`; the launcher was deliberately designed "thin" and lost that line in the narrowing. This is [[butler-new-variant-completeness]] with a fail-closed detonator attached.

**How to apply:**

- Before calling a fail-closed fix "done", **enumerate the stages downstream of the blockage and ask of each: has this ever executed in this environment?** Any stage that answers no is untested code scheduled to run in production the moment you deploy. Treat it as unreviewed.
- **Set the gate end-to-end from the start**, not at the stage you are fixing. "The dispatcher now succeeds" is not the goal; "a schedule reaches the user's chat UI" is. A gate anchored at the repaired stage will report success while the pipeline is still broken — it did exactly that here, and the optimistic report had to be retracted.
- Expect the verification criterion to **move downstream after each fix**, because the actual unknown moves. That is structural to serial discovery, not sloppiness — but change it deliberately and say so, or you will judge a new state by a stale check. Tonight the criterion changed four times.
- **Absence of evidence about a downstream stage is not evidence it works.** "No errors in the launcher logs" meant "the launcher has never run", which is the most dangerous possible reading of a clean log. See [[butler-a-tools-success-check-covers-only-its-own-layer]].
- After unblocking, **check what the blockage did to in-flight inputs.** Messages that piled up while a consumer crashed at INIT are typically retried to `maxReceiveCount` and moved to a DLQ, so they will not flow on their own after the fix — and if the schedule policy already advanced `next_fire_at`, nothing re-fires either. A perfect fix can then produce *no visible activity at all*, which is indistinguishable from failure unless you planned for it. Verify with a **freshly planted end-to-end case**, and hold DLQ redrive until after that succeeds so the two signals do not blend.
