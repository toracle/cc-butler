---
name: the-tracker-keeps-claiming-work-that-already-shipped
description: "Six times in one night, a task list, handoff, project note or issue said work was still open when it had already shipped — one of them three days earlier, with the merged PRs sitting right there. The usual worry is a record that hides remaining work; this is the inverse, and it costs duplicated effort and requests for permission to unblock things that were never blocked. Every single time, the thing that caught it was checking git/gh before starting, and nothing else would have."
metadata:
  node_type: memory
  type: feedback
---

**The night (steward + five workers, 2026-08-03/04).** Six independent instances, same shape:

1. **A worker's own task list** still showed two items open that had been resolved and delivered hours earlier.
2. **A repo handoff** described a PR as "unmerged, CI-red." It had merged the previous day and been promoted to
   staging.
3. **A worker's project note** was six days stale: it recorded the whole feature PR as held, when it had merged,
   been promoted, and received a follow-up bugfix.
4. **An issue's Definition-of-Done checkboxes were never ticked**, so three days after both halves of the work
   shipped (two merged PRs plus a promotion), the issue still read *"awaiting a decision."*
5. **The steward's own handoff** led with a correction block saying a track had been reverted and needed
   rebuilding. The rebuild had happened.
6. **Another worker** found three stale spots in its own handoff and fixed them unprompted.

**This is the inverse of the failure everyone guards against.** We build habits around records that *understate*
work — the forgotten task, the silent dependency. These records *overstate* it. That reads as harmless, and it
is not: it produced a subagent about to open a duplicate PR for work already merged, a plan to escalate a
production deploy to unblock something that was never blocked, and a dispatch built on a premise that had been
false for hours. **An overstating record doesn't cause an omission; it causes work.**

It is also *invisible from the inside*. An understated record eventually announces itself — someone asks where
the thing went. An overstated one never does: the worker picks up the item, works it, and the duplication only
surfaces if somebody happens to look at the artifact first.

**Why it accumulates.** Shipping and recording-that-you-shipped are different actions, and only the first one
has any pressure behind it. The merge is satisfying and observable; ticking the DoD box is neither, and it lives
in a different tool. So the loop stays open by default, and nothing degrades — until someone reads the record
cold.

**What actually caught it — all six times, and nothing else would have:** somebody checked `git`/`gh` for the
real state *before starting work*. Not skepticism about the document, not a smell test — the mechanical habit of
verifying against the artifact. In instance 4 the subagent had already been dispatched to build the thing; it
checked first, found both halves merged, stopped, and cleaned up its worktree. That is the whole defence.

**How to apply.**
1. **Before starting any tracked item, confirm it is actually undone — from the artifact, not the tracker.**
   `git log`, `gh pr list --state merged`, the file on the default branch. This costs seconds and is the only
   thing that has ever caught this.
2. **Close the loop in the same motion as shipping.** Tick the DoD, close the issue, update the note, in the
   turn where the merge happens. Later never arrives; the session ends.
3. **When you correct a stale record, stamp the date you verified it** and leave the old text visible rather
   than silently overwriting. A correction with no date becomes the next stale record.
4. **Supersede rather than delete.** A handoff correction that was true when written and is now false should get
   a newer block above it saying so — deleting it destroys the reason someone believed it.
5. **An unticked DoD is not evidence of open work, and a ticked one is not evidence of done work.** Both are
   claims about when somebody last touched the checkbox. See [[a-test-that-cannot-fail-is-not-evidence]].
6. **Say the count out loud when a pattern repeats.** A worker reported this as "the second time tonight"; it
   was the sixth. Nobody had the whole picture because each instance looked local. Whoever sees across workers
   owes the fleet the tally.

Related: [[release-scope-comes-from-the-diff-not-the-titles]] (same morning, same root: derive state from the
artifact, not from its description), [[search-for-the-existing-decision-first]] (a closure that never landed,
re-litigated), [[an-offer-of-next-steps-is-a-question]] (a request that was never actually made — the mirror
case, where the record understates), [[the-running-daemon-may-not-be-the-code-on-disk]].

**SPT:** the habit is *check the artifact before you start, and tick the box in the same breath as the merge.*
