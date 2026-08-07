---
name: butler-externalizing-is-not-delivering
description: "Work can be finished AND durably externalized and still never reach the person who asked — externalization removes the felt pressure to notify, so close the loop back to the asker by name"
metadata:
  node_type: memory
  type: feedback
---

Writing the answer into a durable artifact — a vault note, a GitHub issue comment, a handoff file, a dashboard — is **not** the same as delivering it to whoever asked. Externalization *feels* like completion, and that feeling is exactly what removes the pressure to notify. The artifact then sits, correct and complete and unread, while the asker waits or re-asks or dispatches the same work again.

**Why:** On 2026-08-05 this happened four separate times in one day, in four different shapes, and nobody was careless in any of them:

1. The butler relayed 정수님's decisions straight to a worker, bypassing the steward. The decisions landed. But the steward's dashboard went stale, and the steward independently placed a HOLD on a worker for a decision that had *already been answered*.
2. `jarvice-978` sat waiting on a decision that had in fact been made and delivered — to someone else.
3. `monocle-16-scheduler` was asked five questions before a shutdown. It **answered them**: a 4998-character comment on `monocle#16` (re-fetched to confirm it landed) and a vault note (`2026-08-05 배포 블로커 정리 + scheduler-stack.ts-486 재검증.md`, commit `4e5d25fe`, verified by `ls-remote`). The externalization discipline was executed *better than asked*. The butler never learned any of it existed, went through a compaction, and re-dispatched the same five questions as though nothing had been done.
4. The steward's own dashboard prose drifted from live state for the same reason — written once, never pushed back to its reader.

Note the irony in #3: the worker's externalization was **exemplary**, and that is precisely what made the loss invisible. A worker that had done a sloppier job would have left the thread visibly open. Doing it well produced silence that looked like completion.

This is a distinct failure from `verify-delivery`, which is about the human's actual receipt of something surfaced. This one is about the *asker inside the fleet*, and about durable-write-as-false-completion.

**How to apply:**

- Finishing a piece of work has **two** terminal steps, not one: externalize it, **then** push it to whoever asked, naming them. A `report_to_steward` / `escalate_to_butler` / `send_to_session` is part of "done", not an optional courtesy after it. Reporting up is a push, never a queue somebody else is expected to drain.
- When you dispatch a question, record **who owes you an answer** somewhere that survives your own compaction. The butler lost five outstanding questions to a context boundary; the answers existed the whole time.
- Before re-dispatching *any* question, first check whether it was already answered — the worker's own notes, the issue thread, the vault, the log. Assume the artifact may exist and you simply never saw it. Re-dispatching is the expensive branch; looking first is cheap.
- A worker whose activity title has moved on has not necessarily dropped your thread. It may have closed it in a place you never looked.
- Symmetrically: if you are the one who externalized, do not treat the write as the end. Say, to the specific asker, that it exists and where.

See also [[butler-verify-delivery]], [[butler-report-up-is-a-push]], [[butler-state-desync]], [[butler-an-offer-of-next-steps-is-a-question]].
