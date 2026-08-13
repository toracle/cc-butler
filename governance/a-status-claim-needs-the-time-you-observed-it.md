---
name: butler-a-status-claim-needs-the-time-you-observed-it
description: "State when you last observed a system's state, not just what it is — a bare present-tense status claim silently becomes false while looking exactly as authoritative as when it was true, and crossing messages make this routine in a fleet"
metadata:
  node_type: memory
  type: feedback
---

When you report the state of a system — a deploy's status, whether a check has run, what remains outstanding — **say when you observed it**, not merely what it is. "As of 02:39, both flags read `true`" degrades visibly as it ages. "Both flags read `true`" does not: it silently becomes false while looking exactly as authoritative as it did when true.

This is not pedantry about phrasing. In a fleet where several roles report concurrently, **messages cross constantly**, and every crossing produces a bare present-tense claim written from a read that has already been superseded.

**Why:** 2026-08-12/13, three times in one night, across three different roles, none of them careless:

- The **steward** told a worker that the scheduler stack's functional verification was "the one remaining item" — it had already been completed and reported. The messages crossed. **The worker corrected the steward**, which is the only reason it did not persist.
- The **butler**, twenty minutes later, told 정수님 the same verification "hasn't been done — a worker can run it read-only whenever you like." It had been done at 02:39. Same crossing, one relay hop further from the source, and this one was **a statement to the principal about production state** — he could have gone to bed believing an item was open, or woken and commissioned finished work.
- Earlier the same night the butler had also offered to have the steward "pull together which repos and what enforcement is missing" — that measurement was already filed as monocle#558 with a proposal attached. Again: a true statement when formed, false by the time it was read.

Note what these have in common with the night's larger theme: they are the relay-traffic form of **a local reading treated as the state of the world**. The banner read as budget truth, the stale checkout read as current source, the plugin version read as what shipped — and then, in our own messages, a read from four minutes ago read as now. Same disease, smaller scale, and it struck the roles that had spent the night naming it.

**How to apply:**
- **Timestamp status claims.** "As of HH:MM" costs four words and makes staleness self-announcing. Anything describing mutable state — deploy status, check results, queue depth, what is outstanding, who is blocked — is perishable.
- **Before telling the principal something is outstanding, re-check that it still is.** The asymmetry matters: telling a human that finished work is pending costs them either sleep or duplicated effort, and they have no way to catch it.
- **When a report and a status claim cross, the report wins.** The worker doing the thing observes it before anyone relaying about it. Do not reconcile in favour of the message you wrote.
- **A subordinate correcting a superior's status claim is the mechanism working.** Both instances above were caught that way — say so out loud when it happens, or the incentive to check quietly inverts. See [[butler-relayed-authority-cannot-self-certify]]: it has to run in both directions or it does not run.

Related: [[butler-a-banner-reading-is-not-a-measurement]], [[butler-a-stale-checkout-is-invisible-to-grep]], [[butler-a-true-observation-licenses-only-its-own-scope]] (its "figure describing mutable state is perishable" clause is this note's parent), [[butler-verify-delivery]].
