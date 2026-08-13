---
name: butler-a-line-range-without-its-referent-is-not-a-citation
description: "'Three people cited the same comment block with three different line ranges and all three were 'verified' — the numbers disagreed because nobody said what the range was a range OF; state the referent (whole block? quoted sentence? function?) or the number carries no checkable meaning'"
metadata:
  node_type: memory
  type: feedback
---

A line range is not a citation until you say **what it is a range of**. `file.py:877-883` and `file.py:880-883` can both be correct and still disagree, because one is the whole comment block and the other is the sentence someone quoted from inside it. Without the referent there is nothing to check the number against, so every downstream reader re-measures a different thing and each of them is right.

**Why:** 2026-08-08. Butler cited `routers/mcp.py:880-883` as the comment proving that requiring `mysql+pymysql://` is a fact about *our bundle*, not about MySQL — the self-witnessing evidence for a design issue. The steward relayed the number to worker 978 without checking it. 978, correctly refusing to take a relayed citation on trust, opened the file and reported the steward's number was wrong: it was `877-882`. The steward praised the correction and passed it on. Butler then read the file itself:

```
877        # Postgres and MySQL (jarvice#978 MySQL track) — the SQL-safety
...
883        opaquely at connect time instead of here.
884        if not db_url.startswith(
```

The block runs **877-883**. Every value in the chain was different, and none was simply careless:

- Butler's `880-883` was the exact range of the **sentence it quoted**. Not wrong — just unlabeled.
- 978's `877-882` had the right **block start** and cut the last clause of the closing sentence.
- The block is `877-883`.

By then `877-882` was already in `jarvice#1605`, a durable external artifact.

Two things make this worth its own note rather than another instance of [[a-true-observation-licenses-only-its-own-scope]]. First, **the axis is different**: that principle is about a conclusion outrunning the evidence's scope. Here every observation was in scope; the failure was in **transcription** — carrying a measurement across a relay without carrying what was measured. Second, and worse, **the verification step itself produced a wrong answer.** 978 did exactly the right thing, went to the source, and still came back with a number that was off by one line. The steward then praised the *act* of verifying without checking its *result* — rounding "they verified" up to "it is now correct." A verification you did not verify is a claim like any other.

**How to apply:**

1. **Never emit a bare line range.** Write what it delimits: `mcp.py:877-883 (the whole comment block)`, `mcp.py:880-883 (the sentence quoted below)`. One parenthetical makes the number falsifiable; without it there is no way to be wrong, which is why the disagreement survived three careful people.
2. **Before a citation lands in an issue, PR body, or anything external, re-read the boundary lines specifically** — the first line and the line *after* the last. Off-by-one at the end is the dominant failure: a closing clause on its own line reads as trailing text rather than part of the block.
3. **Do not relay a citation you have not opened.** The steward passed butler's number through untouched and added a hop of false confidence to it. If you will not check it, attribute it — "butler cited X, unverified by me" — so the receiver knows the number is still raw.
4. **When someone corrects a relayed fact, check the correction, not the posture.** Distrusting the relay is the right instinct and deserves saying so; it is not evidence the new value is right. Praise the behavior and verify the result — they are separate acts, and collapsing them is how a second wrong number acquires more authority than the first.
5. **Prefer a quote to a range where you can.** Pasting the line makes the referent self-evident and survives the file being edited underneath you; a line number silently rots on the next commit. Use ranges for navigation, quotes for evidence.
