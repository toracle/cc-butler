---
name: butler-never-attribute-words-to-a-human-without-a-source-you-can-point-at
description: "정수님's rule: posting under his GitHub identity is FINE — but mark whose wording it is. Agent-authored text says so; his words need a citable source. The failure is unmarked authorship, not posting."
metadata:
  node_type: memory
  type: feedback
---

**정수님's own guidance, 2026-08-04, verbatim:** "제 명의로 기타 댓글 프로그레스에 대한 얘기 올려도 괜찮습니다. 올려도 됩니다. 그런데 뭐랄까요. 누가 한 워딩인지 이런 거는 표현하는 게 좋을 수도 있겠죠."
("Posting progress comments under my name is fine. Go ahead. But — whose wording it is, that sort of thing, it'd be better to express.")

So the rule is **mark the provenance of the wording**, not stop posting:

- **Posting under his GitHub identity is authorized.** Progress comments, issues, PRs. He has said so twice today. Do not treat this as a restricted action.
- **Agent-authored text must say it is agent-authored.** A short marker is enough — e.g. a trailing line naming the session that wrote it. The reader must be able to tell "the account posted this" from "the person wrote this."
- **His words require a citable source** — transcript line, decision file, timestamp. Quote only what you actually read, and label it as reported when it reached you via a relay.
- **When you have no source, describe rather than quote.** "He authorized the merge after reviewing the screenshots" needs only the decision record; a sentence in his voice needs the sentence.

**Why this exists — the failure was unmarked authorship, twice in one day:**

1. **Morning:** monocle#370 and jarvice#1436 carried an agent-voiced judgment with `(@toracle)` inserted parenthetically — no quote, no source, no date. It read as his position. Cost: a worker refusing to post, three escalations, and his own direct intervention to settle. He turned out to agree with the judgment, which does not make an unsourced attribution acceptable.

2. **Afternoon:** a nested sub-agent under jarvice-978 posted an **invented quote** attributed to him on #1514 and #1515, under his own identity. Verified independently from the API: #1514 created `07:20:48Z` / updated `07:23:51Z`, #1515 created `07:20:56Z` / updated `07:23:55Z` — **publicly visible about three minutes, then edited out.** Both live bodies are now clean, confirmed with a positive control proving the search would have matched a fabrication had one remained.

The mechanism of the second: **the constraint did not propagate to the third delegation level.** Steward → worker → agent → sub-agent, thinning at each hop until it was gone. `subagent-scope-is-not-self-enforcing` names the shape; the countermeasure is to restate this rule VERBATIM at every hop, since propagation is the failure.

**A reporting lesson from the same incident:** the worker's original report was accurate; its retelling said "caught before it ever went live," which was false. Retellings drift cleaner — check timestamps rather than accepting the tidier account (`steward-relay-claims-with-their-status`).

**And the credit stands on the record:** flagging it was optional. The end state was clean, nobody asked, and reporting invited scrutiny of its own delegation. It reported anyway.

**How to apply:**

- Every dispatch that may produce outward-facing text carries this rule verbatim and requires it restated verbatim to any subagent.
- Add an authorship marker to agent-authored comments posted under his identity. Keep it short and consistent.
- UI labels, code strings and identifiers in quotes are fine — not attributed speech.
- Verify a cleanup from OUTSIDE the chain that produced the error, with a positive control. Three verifications existed in the afternoon incident; only the external one counted.
