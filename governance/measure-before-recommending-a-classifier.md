---
name: butler-measure-before-recommending-a-classifier
description: "Before proposing to split behaviour by exception class, error code, message pattern, or structured field, measure the real objects — a field existing in the API does not mean it is populated, and prefer making the distinction structural so no classifier is needed"
metadata:
  node_type: memory
  type: feedback
---

When a fix turns on "distinguish safe case A from unsafe case B," do not recommend a discriminator — exception class, error code, message substring, structured field — from reasoning about how the library *ought* to behave. Force the real errors and inspect the real objects first. Before building any discriminator, ask whether the distinction is already known **structurally** at the call site. And when a discriminator relies on reading a field, confirm that field is actually **populated** in the exact cases you care about: an API exposing `x.column_name` is not evidence that `column_name` has a value when it matters.

**Why:** 2026-08-05, jarvice#978. `SqlExecutionError` collapses DB errors to a bare class name because driver text can echo the DSN. I proposed three designs across the day; each was sent down labelled as a hypothesis to *measure*, not implement. Two died and the third survived only in mutilated form:

1. **Split by exception class.** Postgres separates connect (`OperationalError`) from query (`ProgrammingError`/`DataError`), but **pymysql raises `OperationalError` for both** wrong-password (1045) and unknown-column (1054). Building it would have leaked MySQL host/port/username into the "safe" bucket — and MySQL was the entire subject of the track.
2. **Split by `try` placement** ("a try wrapping only execution catches query-phase errors by construction"). Refuted by reproduction: a live connection can be killed mid-session (`pg_terminate_backend`), and the next `.execute()` raises `OperationalError: server closed the connection unexpectedly` *inside* the query-only try — the exact string the file already classifies as connection-phase. MySQL mirrors it (2013). My premise that code position knows the phase ignored that a connection can die *after* being established.
3. **Reassemble from structured fields** (`psycopg2 e.diag`). The fail-safe property held — connect failures and mid-session deaths have `e.diag` entirely None. But **`column_name` and `table_name` are also None for `UndefinedColumn`**, the most common authoring mistake; only `message_primary` and `sqlstate` populate. The fields I proposed selecting were empty exactly where they were needed. MySQL has no equivalent decomposition at all — only `(errno, msg)` — so extracting a column name would require regex-parsing free text, i.e. regressing to the blacklist approach already rejected.

Round 3's specific finding was caught only because the worker noticed its subagent's report ended after a single `tool_use` — thin for the work claimed — and independently re-reproduced everything in fresh containers. See [[verify-subagent-claims-directly]].

**How to apply:**
- Never ship a discriminator you have not seen fire against real inputs on **every** engine/driver in scope. Cross-engine symmetry is an assumption, not a property.
- Check that fields are populated, not merely present. Read the actual object; do not infer from documentation that a field exists.
- Ask first whether position in the code already implies the distinction — but verify the precondition, including whether the established state can be lost mid-operation. See [[structurally-impossible-beats-checked-and-absent]].
- Prefer safety arguments that are structural over ones that are empirical. "The server composes this message from SQL semantics and cannot know the client's host/port" is stronger than "it did not leak in the four cases I tried" — and say which kind you have.
- State a hypothesis as a hypothesis when handing it down, and order measurement rather than implementation. A recommendation labelled "verify this" gets corrected; one labelled "do this" gets built. See [[decision-as-process]].
- If every table-free design falls, a maintained table is the **floor**, not a compromise — argue about whether it is worth it, not about avoiding it.
