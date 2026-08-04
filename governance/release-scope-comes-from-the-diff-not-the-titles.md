---
name: release-scope-comes-from-the-diff-not-the-titles
description: "A sync-merge titled '#1109 + #1113' actually carried #1110, #1111 and #1112 as well — one of them modifying the production deploy job. Nothing was hidden; the title simply described what someone remembered merging, not what the merge contained. In the same investigation, a track recorded as 'blocked until the tooling ships to production' turned out to have a second path that had been live in production for two years. Both times the written record was a fact about when it was written, and the answer was one diff away."
metadata:
  node_type: memory
  type: feedback
---

**The incident (dealmatch + steward, 2026-08-04).** A seasonal data update was recorded as blocked on a
production promotion. Before escalating that promotion for approval, the worker was asked to establish what the
promotion would actually deploy. Two premises died.

**1. The merge titles understated the payload — and the omission was the part that mattered.**
`origin/master..origin/staging` held nine merges. The handoff, and my own escalation draft, described them as
"five PRs, all the seasonal feature." The diff said otherwise:

- Only **three** were the feature (`#1109`, `#1115`, `#1116`). Two were devel→staging sync merges, which are not
  feature PRs at all.
- One of those sync merges, `#1114`, **named `#1109` and `#1113` in its title while carrying `#1110`, `#1111`
  and `#1112` as well** — everything that happened to be sitting on devel at that moment.
- The unnamed passenger that mattered: **`#1111` modifies the production deploy job itself** (Dockerfile and
  deploy-job pip pins). Pure version pinning, no logic change — but it is on the deploy path, which is precisely
  the thing a reviewer of a *data* release would never think to look at.

A sync merge's title is written by whoever triggered it, about the change they had in mind. **It is a note about
an intention, not a manifest.** Nothing was concealed and no one did anything wrong; the title was simply never
the kind of artifact that could be complete.

**2. "Blocked on X" described one path, not the goal.** The tooling really was absent from production — that
part of the record was true and stayed true. But the same capability had a second route: a manual admin upload
screen, shipped to production **two years earlier**, entirely independent of the promotion. So the work was
never actually blocked; only the automated path was. The escalation would have asked for approval on a
production deploy to unblock something that was not blocked — and would probably have got it, because the
request looked coherent.

Note what saved it: not skepticism about the *blocker* (it was real), but the routine question **"what else
rides along?"** Answering it required reading the diff, and reading the diff is what surfaced the alternative.

**How to apply.**
1. **Before approving or requesting a release, derive its contents from the diff.** `git log
   <prod>..<staging>` and read the actual commits. PR titles, merge messages, changelogs, and handoff notes are
   all summaries authored at some earlier moment, by someone with a narrower question in mind.
2. **Split the list into what was asked for and what merely rides along, and say so explicitly.** The person
   approving is approving *a release*, not *a feature*. If they cannot see the passengers, their approval does
   not mean what everyone will later assume it meant.
3. **Give sync/merge commits the same scrutiny as feature commits — more, actually.** They are the ones whose
   titles are structurally incapable of listing their payload, and they are the ones nobody reviews.
4. **When something is recorded as blocked, ask what it is blocked *for*, not just *by*.** A true statement about
   one path ("the tool is not deployed") silently becomes a false statement about the goal ("the data cannot be
   updated") the moment a second path exists. See [[an-offer-of-next-steps-is-a-question]] for the sibling
   failure, where a real constraint was mistaken for a request that had actually been made.
5. **Do not escalate a half-specified irreversible action.** Sending "promote staging to master?" upward without
   the payload, the rollback path, and the alternatives is not delegation — it moves the decision to someone with
   *less* information than you had. Fill it in first, even when it costs another round trip.
6. **Fix the stale record in place, with the date you verified it.** The handoff here claimed the feature PR was
   unmerged and CI-red when it had been merged and promoted the day before. Correcting it — and stamping *when*
   the correction was checked — is what stops the next context from re-deriving it.

Related: [[cdk-synth-is-not-a-deploy-diff]] and [[ci-deploy-is-not-cdk-deploy]] (the same gap between a
description of a deploy and the deploy), [[the-running-daemon-may-not-be-the-code-on-disk]] (a state you
asserted vs the state in force), [[a-stop-that-reports-success-is-not-a-stop]] (a record answering a narrower
question than the one being asked), [[prod-data-access-requires-explicit-approval]].

**SPT:** the habit is *before anything irreversible ships, read the diff and name the passengers out loud — and
ask what the blocker actually blocks.*
