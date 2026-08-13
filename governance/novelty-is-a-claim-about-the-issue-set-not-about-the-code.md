---
name: butler-novelty-is-a-claim-about-the-issue-set-not-about-the-code
description: "'This is a new finding' cannot be established by reading code — novelty is a property of the finding relative to the existing issue set, so it needs a query the code reading cannot supply. A subagent handed specific issue numbers will treat that list as the whole universe."
metadata:
  node_type: memory
  type: feedback
---

Reading code can establish that a defect **exists**. It can never establish that
the defect is **new**. Novelty is not a property of the code — it is a property
of the finding *relative to the existing issue set*, and that set lives somewhere
the code reading never touches. So any report that says "신규 발견" is making a
claim it did not gather evidence for.

The fix is one cheap query, and it belongs *before* the report, not after.

**Why:** 2026-08-07. The steward commissioned a bounded five-repo IDOR inventory
(monocle-tool-server, chat-proxy, stark, agent-sandbox, monocle-plugins) after
discovering that all four of that day's sweeps had been confined to jarvice. The
inventory came back with one item flagged as its most significant result —
described as a **"신규 확인된 High 등급 발견 (기존 #480/#210과 다른 인스턴스)"**,
with an explicit recommendation to file it as its own issue.

It was not a different instance. It was the same one. A `gh issue view 210`
comparison found the same function (`_resolve_input_file_params`), the same bypass
mechanism (skip URL rewriting when the value contains `"://"`), the same three
entry points (`attach_file_to_email`, `export_to_pdf`, `export_to_png`), and the
same missing guard (`assert_public_url` not applying to the file-param path) — all
already filed **that same day**, already awaiting egress confirmation.

The subagent had read the code carefully and correctly. Its finding was true. Only
the word *신규* was false, and that word was doing all the work: it was the reason
the item was ranked first and the reason it was recommended for filing.

**The mechanism worth naming:** the subagent's prompt named specific issue numbers
as context. It checked its finding against *those*, concluded "different from the
ones I was told about," and reported "new." **A subagent treats the issue list in
its prompt as the universe of existing issues.** It has no way to know the list was
illustrative rather than exhaustive — and nothing in the prompt told it the
difference. The scope of what it compared against was set by the prompt's
examples, silently.

Note this is the same shape as [[search-for-the-existing-decision-first]] one level
down: there, hours went to re-deciding a question the principal had already closed;
here, a session nearly filed a duplicate of an issue opened hours earlier. Both are
retrieval failures wearing the costume of an analysis result, and in both the
missing step cost one query.

**How to apply:**

1. Before any finding is reported as new, run the actual query — `gh issue list`
   (including recently closed) against the **target repo**, searched by the
   artifact: file path, function name, mechanism. Not by how the current finding
   words itself; a duplicate will be phrased in the original reporter's language.
2. When commissioning investigation, say explicitly whether an issue list in the
   prompt is exhaustive or illustrative. If illustrative, instruct the agent to
   query the repo itself. Silence here reliably produces false novelty claims.
3. Treat "신규" / "new" / "not previously known" as a **separate claim requiring
   separate evidence**, held to the same confirmed-vs-inferred discipline as the
   defect itself. The defect can be confirmed while its novelty is unverified —
   say so in exactly those terms.
4. Verify novelty *before* ranking or recommending, not after. Novelty is usually
   what drives priority, so an unchecked novelty claim corrupts the ordering of
   everything around it — here it put a duplicate at the top of a five-repo report.
5. The steward must run the comparison itself before approving a filing. Approving
   an issue on a worker's novelty claim repeats the error one level up, and the
   filing is externally visible — see
   [[issue-creation-is-steward-discretion-the-rest-of-external-exposure-is-not]].
6. When you correct this, correct the *stored artifact* too, not just the chat —
   the session had already written the false framing into its inventory memory.

Related: [[a-true-observation-licenses-only-its-own-scope]] (the finding was true;
only its scope claim was not), [[subagent-scope-is-not-self-enforcing]],
[[an-inference-that-reaches-a-durable-artifact-must-be-labeled-as-one]].

**SPT:** *code tells you a thing is broken; only the issue tracker tells you it is
news.*
