---
name: butler-for-a-two-repo-bug-search-the-other-repo-s-tests-first
description: "When a bug lives across a boundary between two repos, read the OTHER side's tests before designing anything — a test name on the far side often already documents the exact failure mode, because whoever built that boundary encoded what breaks it."
metadata:
  node_type: memory
  type: feedback
---

A bug that crosses a repo boundary must be searched on BOTH sides before any
diagnosis is trusted, and the far side's **tests** are the highest-yield place to
look. Whoever implemented the boundary encoded its known failure modes as
assertions, often with the failure named in plain language in the test title.
Reading them costs one search and can hand you the answer outright.

**Why:** 2026-08-04. A custom MCP server was not appearing in Craft. We spent an
afternoon on it entirely inside `jarvice`: inferred a cause from reading code,
fixed a genuine string-mismatch defect, proved it red-then-green, merged,
promoted to staging, verified the deploy two-source, and asked 정수님 to test.
It still did not work.

Only later, while building a harness, did a subagent discover that
`container/tests/http-task-message.test.ts` in the **agent-sandbox** repo —
commit `948a279`, dated **2026-06-01**, ungated and passing continuously for two
months — already asserted the relevant failure mode, with the test literally
named `"NOISY-FAIL: missing callbackUrl drops…"`. Someone had understood that
exact silent-drop two months earlier and written it down where we never looked.
The knowledge existed on the far side of the boundary the entire time. This was
not a tooling gap: we searched one repo for a two-repo bug.

**How to apply:**
1. The moment a bug is identified as crossing a boundary (service↔service,
   backend↔sandbox, API↔client), list the repos on both sides *before*
   diagnosing, and grep the far side's tests for the feature, the field names,
   and the failure words ("missing", "drop", "silent", "skip") — not just its
   source.
2. Treat a far-side test as a **specification of the boundary's contract**. If it
   asserts your failure mode as expected behaviour, the defect is probably on
   YOUR side (you are producing something the other side is documented to
   discard), and the fix is to fail loudly rather than to change the far side.
3. Read the issue a far-side test cites. Prior reasoning, a deferred decision, or
   an owner may already exist; designing without it repeats work and may
   contradict a decision someone already made.
4. Before concluding a far-side search found nothing, confirm the search *could*
   have found it — see
   [[butler-absence-of-evidence-needs-a-control-and-an-evidence-class]]. The same
   day, a subagent ran `gh issue view` **without `--comments`**, saw no mention of
   a topic, and wrongly concluded the issue did not cover it; the comment existed.
   A wrong-flags command and a true absence are indistinguishable.
5. Corollary for `boundary-contract-testing`: before writing a seam test, check
   whether the far side already has one. A subagent asked to write exactly such a
   test found it already existed and **stopped rather than producing a duplicate
   carrying a wrong issue citation** — the right call, since plausible-looking
   duplicate work passes review and quietly muddies provenance.
6. This is the cross-repo case of [[butler-state-desync]]: what is true lives
   somewhere you are not looking.
