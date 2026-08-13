---
name: butler-never-ask-a-human-to-type-into-a-session-you-just-queued-work-on
description: "Compaction, clears, and model switches take minutes and type into the session themselves — so a request that makes the human type into that same session must be sequenced after they finish, not sent alongside them."
metadata:
  node_type: memory
  type: feedback
---

Context operations — `compact_session`, a clear, a model switch — are **not instantaneous and not silent**. They drive the target session by typing into it: `/model <cheap>`, then `/compact`, then `/model <original>`, over minutes. During that window the session's input path belongs to the machine.

So any message that will cause **a human to type into that same session** must be sequenced *after* the operation completes — never dispatched in the same breath. The danger is not that you touched the session; it is that you invited a third party to touch it while the machine was mid-transaction, and they have no way to know that.

**Why:** On 2026-08-08 the steward forced a compaction on `monocle-16-scheduler` and, moments later, escalated a request for 정수님 to type `/code-review` into that same session — because `/code-review` cannot be self-invoked and had to come from his hand. The butler relayed it promptly, as it should have. The steward then checked the session's screen and found the compaction at 89%, still on the cheap model with the restore step pending. Had he typed then, the input would have landed inside the compaction — swallowed, or tangled with the model-restore step. That exact collision class had already stranded a worker on a cheap model earlier the same morning.

It was caught only because the steward re-read the screen while waiting, not by any check in the flow that produced it. The two messages were individually correct and the order between them was never considered — which is what makes this a sequencing defect rather than a mistake of judgment.

The recovery was a retraction sent immediately to the butler with a **concrete, observable go-signal** rather than a duration: *wait until the statusline reads `MODEL=Opus-5` / `CTX=0`*. "Wait a minute or two" would have handed the human the same guessing problem.

**How to apply:**

- **Order the pair explicitly: operation completes → verify by screen → then ask.** Treat "I have queued/forced a context operation on session X" as a lock on requesting human input to X. Release it only after seeing the restore land.
- **Watch for the trigger shape.** The risk concentrates where a command *cannot* be self-invoked (`/code-review`, `/model`, `/compact`) and so must be routed to a human. Those are exactly the requests that arrive as escalations, travel through a relay, and land with no knowledge of the session's live state.
- **When you must retract, give a state to observe, not a time to wait.** A statusline the human can read beats an interval they have to estimate. See [[butler-verify-delivery-at-the-recipient-not-the-return-string]].
- **Own the ordering error to the relay, not just the target.** The butler had already delivered the request in good faith; leaving it to discover the problem would make it look careless to the human it serves.
- **A queued (non-forced) compaction does not remove the hazard.** It fires on its own the moment the session goes idle — which may be seconds after you send an unrelated instruction. The lock is on the *pending* operation, not only the running one.

**SPT:** the habit is *before asking a human to type into a session, ask what the machine is currently typing into it.*
