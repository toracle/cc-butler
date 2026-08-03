---
name: a-stop-that-reports-success-is-not-a-stop
description: "TaskStop returned \"not running (status: completed)\" six times for a task that then kept acting for another 33 hours. It was not lying about execution — it answered \"is this executing right now?\" while the operator was asking \"will this act again?\" Those differ for any idle-but-reachable agent. The observable signal is the task's output-file mtime (`stat -L`, dereference the symlink), live-validated to rise while running and stop on completion. No registry, lock, or PID file exists."
metadata:
  node_type: memory
  type: feedback
---

**The incident (2026-08-03).** A session called `TaskStop` on a background task **six times** across two days
(07-30 06:34, 07:12, 07:32, 08:48, 09:01; 07-31 10:49). Every call returned
`"Task ... is not running (status: completed)"` with `is_error: true`. The task went on taking real external
actions — GitHub comments, an OAuth flow — until 07-31 15:17. The launching session never resumed it.

**The status was not a lie. It was an answer to a different question.** Transcript archaeology established that
nothing was re-awakening the task: every action was immediately preceded by a genuine live user message. So the
task really was *not executing* at each moment `TaskStop` was called — it was **idle and still reachable**, and
it acted again the next time a message arrived. `TaskStop` reported on *current execution*; the operator was
asking about *future reachability*. **For anything that sleeps between turns, those two are routinely different,
and only one of them is what "stopped" means to a human.**

That is why this is worth writing down rather than filing as a bug: the failure survives the tool being
correct. Even a perfectly accurate "not currently executing" leaves the operator believing something is halted
when it is merely quiet.

**What actually works — verified, not assumed.**
- **Poll the task's output file mtime:** `stat -L "tasks/<task_id>.output"`. **The `-L` matters** — the path is
  a symlink, and without dereferencing you stat the link instead of the target and see a frozen timestamp.
- **Live-validated in both directions**, which is what makes it usable: a deliberately launched background agent
  showed mtime advancing while it ran and stopping immediately on completion. A signal only checked on the
  failing case tells you nothing (see [[a-test-that-cannot-fail-is-not-evidence]]).
- In the incident, that mtime was **still advancing 4h51m after the last "completed" response**, and more than
  **33 hours** after the first — so this signal would have caught it every single time.
- **No registry, lock file, or PID file exists** for these tasks (checked, negative). The output file is the
  instrument available, not merely the one chosen.

**How to apply.**
1. **Treat any stop/cancel/kill return value as a claim about the request, never about the state.** "The call
   succeeded" and "the thing is stopped" are separate facts, and only the second one matters.
2. **Confirm a stop by observing absence of activity over time**, not by a single status read. Absence is a
   claim about a duration; no instantaneous call can establish it.
3. **When a status surprises you, ask what question the API is actually answering.** "Completed", "idle",
   "inactive", and "cannot act again" are four different states that vendors freely collapse into one string.
4. **If you need something to genuinely stop, removing its ability to act beats asking it to stop** — the same
   lesson as [[subagent-scope-is-not-self-enforcing]], where a capability boundary held and a written
   prohibition would not have. Note the sharp inversion here: that note concluded capability boundaries are the
   thing that actually enforces, and this incident is a capability boundary *failing while reporting success* —
   so verify even those.

**Scope note.** `TaskStop` and its status mechanism are **not cc-butler's code** — a full repo plus
git-history grep returns zero hits, and there is no task-registry concept here at all. It belongs to the Claude
Code CLI/SDK harness. Recorded so the next investigator does not re-spend hours grepping this repository:
**the answer is not in here.**

Related: [[verify-delivery]] (this is that note's mirror image — there, confirm the message arrived rather than
inferring it from a successful send; here, confirm the task stopped rather than inferring it from a successful
stop call), [[the-running-daemon-may-not-be-the-code-on-disk]] (a state you asserted vs the state in force).

**SPT:** the habit is *after asking something to stop, watch it be quiet — a success code is not silence.*
