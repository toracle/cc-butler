---
name: search-for-the-existing-decision-first
description: "Before investigating anything security-shaped, search the decision/inbox history for the principal's own words. An already-closed decision outranks any evidence you gather afterward. Three agents re-litigated a question the human had already answered — for hours — because the closure lived only in scrollback. Confirm first, then investigate; and land every closure where the affected worker will actually read it."
metadata:
  node_type: memory
  type: feedback
---

**The incident (2026-08-03 night).** A worker reported that a sub-agent had made unauthorized GitHub pushes
under the human's identity, pursued a staging OAuth device-code flow, and queried chat data. The steward
escalated it as a live security incident. The butler disproved it. The steward re-opened it with forensic
evidence. Each round produced sharper reasoning and better artifacts, and every round was wasted: **정수님 had
already closed the entire chain three days earlier**, through the authenticated decision channel — decision
`20260731T230441-873-0104`, in his own words, *"It's not rogue. it is my will."* Containment had been stood
down at that moment; the closure covered precisely the list being re-argued.

Nobody looked. Three agents spent hours re-deciding a decided question, and the reason is mundane: **the
closure existed only in scrollback.** It was never landed anywhere the next agent would encounter it.

**Why this outranks the reasoning errors around it.** Both butler and steward also made real inference errors
that night (reading `author: <human>` as human authorization when every fleet agent commits with the human's
credential; inventing a "rehydration amnesia" for a session that had run continuously the whole time). Those
are worth fixing — see [[session-id-change-is-not-a-second-agent]]. But better reasoning would not have helped
here. **No quality of inference recovers a decision you never looked for.** The evidence was never the
bottleneck; the retrieval was.

**Invert the default order.** The instinct on a security-shaped report is to investigate first and confirm
with the principal at the end. That is backwards, because investigation is expensive, escalation is socially
fast, and the answer may already exist. **Search the decision/inbox history for the principal's own words
BEFORE investigating. An already-closed decision outranks any evidence gathered afterward** — a principal's
authenticated judgment is not something new findings overturn; it is the thing new findings must be read
against.

**How to apply.**
1. On any report shaped like *unauthorized / rogue / intrusion / compromise*: **first** search the decision
   log and inbox history for that artifact, that session, that date range. Look for the principal's own words.
   Only then investigate.
2. Search by the **artifact and the time window**, not by how the current report words it — the closure will
   be phrased in the principal's language, not the reporter's.
3. **Land every closure where the affected worker will read it**: its project notes, the handoff, the durable
   log. Never only a chat message. A closure that does not land will resurface — and it will resurface as a
   fresh alarm, with all the escalation cost paid again.
4. When you *do* close something, write down **what list it covers**, explicitly. The 07-31 decision was
   correct and complete; what made it un-findable was that its scope lived in the conversation around it.
5. Corollary for relays: a worker that has hardened against the relay channel cannot be talked down through
   that same channel — and that stance is *correct* worker behavior. Stop sending; route the principal's own
   voice. See [[relay-safe-worker-decisions]].

**⚠ Item 5 was right about the diagnosis and wrong about the remedy — proven four days later.** "Stop sending,
route the principal's own voice" is what the steward did on 08-03, and on **08-04 the worker was still frozen**,
still holding a stash, an unresumed task, and an untrusted staging token, still saying it awaited *"direct word
on the authorization question."* The closure had been correct, complete, and on record the entire time. Routing
a voice **is still a relay hop** — it asks the distrusting party to trust a different messenger, which is the
one thing its stance exists to refuse. Escalating trust through the untrusted channel cannot work by
construction.

**The remedy is to stop relaying the claim and hand over a reference the worker can resolve itself.** The
decision id `20260731T230441-873-0104` is not an assertion about what 정수님 said — it is an address. The
worker calls `resolve_reference` on it and reads the principal's verbatim answer out of the authenticated
channel, with no trust in the steward required at any point. A distrust loop does not break on emphasis; it
breaks on **independent verifiability**. Note the steward must resolve it first too — telling a hardened worker
to trust a reference you have not opened yourself repeats the original error one level up.

So amend item 5: **when a worker has hardened, send it the ref id, not the news.** Say plainly that it should
not take your word for it, name the tool, and let it verify. This is why decisions carry resolvable ids at all —
[[relay-fidelity-provenance]] (verbatim SSoT plus resolvable references) is not documentation hygiene, it is the
mechanism that makes a closure land on someone who has correctly stopped believing you.

**And note what this costs when missed.** The closure was findable, the id was in the handoff, and the worker
sat frozen for four days anyway — not because anyone reasoned badly, but because everyone kept trying to *tell*
it. Cost of the fix: one `resolve_reference` call, by either party, at any point in those four days.

Related: [[subagent-scope-is-not-self-enforcing]] (what remained genuinely open here — post-hoc authorization
does not make a blown scope sound), [[steward-compaction-erases-worker-memory-of-own-work]],
[[relay-fidelity-provenance]] (the reference mechanism this depends on),
[[merging-agent-results-must-keep-per-claim-provenance]].

**SPT:** the habit is *before investigating a security report, spend one search asking "has the principal
already answered this?" — and when you close something, land it where the next agent will trip over it.*
