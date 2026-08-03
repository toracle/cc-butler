---
name: butler-channel-wedge-fallback-visibility
description: "When the emacs-tools session-driver channel wedges (read_session_output / compact_session / send_to_session all MCP-timeout >120s, non-self-healing, needs a session restart), you are NOT blind: list_buffers metadata + Bash (bypasses MCP) on worker workspaces + Read on on-disk state still reconstruct worker STATE. Only the live typed transcript and dispatch/compact are lost. Don't treat a wedge as total blackout, and don't hammer the wedged tools."
metadata:
  node_type: memory
  type: feedback
---

The steward/butler **session-driver channel wedges** periodically — every tool
that reaches into another session's live terminal (`read_session_output`,
`compact_session`, `send_to_session`) starts MCP-timing-out >120s and does NOT
deliver. It is **session-specific and does NOT self-heal**; a self-`/compact` does
not clear it (the wedge has appeared right after one). The real fix is a **full
restart of the wedged session** — which the wedged agent cannot do to itself, so
**escalate the restart to 정수님** (bundle it with a hand-off of any compaction/
dispatch duty to the still-working partner, e.g. butler covers while steward is
down). See also [[butler-context-ceiling-and-compaction]].

**But a wedge is NOT a blackout.** The failure is narrow — specifically
`ghostel-mode` (live-terminal) *content extraction*. Everything else still works,
so reconstruct worker STATE from other paths before concluding you're blind:

- **`list_buffers` works** → metadata for every session: which sessions exist,
  buffer sizes, modes, and any `magit:` / `magit-process:` / `dired` buffers a
  worker spawned — i.e. *which repos it is touching right now.*
- **⚠️ `get_buffer_content` is NOT always wedge-proof (falsified 2026-08-02).** After a
  network-migration/OS-restart the ENTIRE ghostel channel can go down for a session —
  `get_buffer_content` included (it 120s-timed-out alongside read/send/compact/butler_log
  in a total steward wedge). So the "big one" below holds only for the *narrow* ghostel
  content-extraction wedge; in a TOTAL post-migration wedge you lose screen-read too and must
  fall back entirely to git/gh/files + pending_events/escalate_to_butler. Try it once, but if
  it times out do NOT hammer — treat screen-read as lost and reconstruct from git/files.
- **`get_buffer_content` WORKS in the NARROW wedge — this was the big one** (confirmed 2026-07-27 during a
  live steward wedge; but see the ⚠️ above — not in a total post-migration wedge). It reads the emacs buffer
  text of `*claude-code[NAME]*` DIRECTLY, and — unlike `read_session_output` — in that narrower case it does **NOT** wedge. So you can
  read a worker's actual on-screen transcript: its current output, an open
  permission prompt, a live AskUserQuestion menu, even who typed the last line
  (i.e. whether 정수님 is present in that session). This collapses most of the
  "blindness": the wedge costs you SEND and COMPACT, but NOT READ. Reach for
  `get_buffer_content` before concluding you can't see a session. This directly
  resolved a "possibly-wedged vs long-turn" ambiguity that git-state alone could
  not — one read showed the session had run a genuine 1h+ turn and completed, not hung.
  **IMPORTANT liveness caveat (learned the hard way):** `get_buffer_content` returns
  the buffer's **LAST-RENDERED** text — a ghostel buffer only re-renders when it is
  actually displayed in Emacs, so if nobody is viewing that session the read can be
  a STALE snapshot (observed: a buffer identical across a 2.5h gap, indistinguishable
  from "no progress"). Reliable for *"what was on that screen"* and for catching a
  live prompt/menu, but NOT a guaranteed-live tail — do NOT infer "hung / no progress"
  from an unchanged buffer alone. Corroborate liveness with an independent non-buffer
  signal: `gh issue/pr list` (did the deliverable appear?), `git log --since` (new
  commits?), or the monitor's context-token delta (growing → working). Buffer for
  *content*, gh/git/context-delta for *liveness*.
- **Bash works** (bypasses MCP entirely) → inspect any worker's workspace git
  state directly: `git -C ~/projects/<session>/<repo> log / status / reflog /
  tag / log --branches --not --remotes`. This is authoritative for the one thing
  that matters most under a shared-watch — **did a worker make a prod move**
  (push to main, Release tag, unpushed commits)? The reflog catches it.
- **Read (on-disk) works** → decision files
  (`~/.local/state/cc-butler/mail/decisions/open/*.org`), logs, shared docs.
- **`pending_events` + `escalate_to_butler` work** (own-queue tools) → you still
  RECEIVE worker reports and can escalate up; you just can't push into a session.
  **Routing gotcha (confirmed 2026-08-01, steward under a wedge):** for STEWARD,
  `report_to_butler` **loops back into steward's OWN event stream — it does NOT
  reach butler** (the message re-appeared in the steward's own auto-drain feed).
  The real steward→butler channel is **`escalate_to_butler`** (feeds the queue
  butler processes; render a relay with an explicit "RELAY REQUEST (not a 정수님
  decision)" header so it isn't mistaken for a decision). And the always-works
  back-channel butler reads is the shared `steward-handoff.md`. So under a wedge,
  to hand butler a SEND for a worker: `escalate_to_butler` the verbatim text +
  mirror it in the handoff doc — never `report_to_butler`.

**What you genuinely lose:** only the ability to **SEND** to a session
(dispatch/unblock/answer) and to **COMPACT** it — until the restart. **What you
keep:** full READ (via `get_buffer_content` for the on-screen transcript + git +
files + buffer metadata) and `pending_events`/`escalate_to_butler`. So you can see
everything a worker is doing and whether anything is unsafe or blocked; you just
can't act *on the session* — route any needed action through the butler / 정수님
instead. Earlier notes here said the transcript was lost; that was wrong —
`get_buffer_content` recovers it.

**Discipline:** the moment the driver tools time out twice, STOP re-firing them
(pure 120s-timeout waste), switch to the fallback-visibility paths above, and
escalate the restart. Confirmed real by an overnight shared-watch: a session
grew 30k tokens autonomously and unreadable; a direct `git reflog` on its
workspace proved it was doing reversible branch work (even a prd-*disable*
rollback), no prod promotion — watch satisfied without ever reading its screen.

**SPT:** don't build a wedge-detector; the habit is *stop hammering the wedged
send/compact + reach for `get_buffer_content`/git/files/metadata to SEE + escalate
the restart to regain the ability to ACT.*

**Structural addendum (2026-08-03): why a wedge can look FLEET-WIDE, and why
that is consistent with everything above.** Confirmed by reading the actual
Elisp/MCP-transport source (`claude-code-ide-mcp-http-server.el`,
`claude-code-ide-mcp-server.el`, `web-server.el`) during the 08-03 ~10:14
incident (cc-butler#18's investigation): every session's MCP tool calls are
served by **one shared Emacs daemon process** over an HTTP server (`web-server`'s
`ws-filter`), and Emacs is single-threaded/cooperative — while ONE connection's
request handler is running, **no other session's request can be serviced**
until it returns. `send_to_session`/`read_session_output` are already bounded by
an 8s `cc-butler-session-io-timeout` (`cc-butler-orchestrator.el`, added
2026-07-15 for exactly this class of hang) — but that guard is a Lisp-level
timer, and it cannot preempt a call that blocks *inside* the opaque, compiled
`ghostel-module` native calls (`ghostel--write-pty` / `ghostel--redraw`), which
is where a >120s hang not explained by the 8s guard most likely sits (see also
cc-butler#11: a JSON-RPC dispatch error above that same guard has already been
observed to hang the layer for ~5 minutes with the guard never engaging).

**What this means in practice:**
- A **single session's** wedge (this note's main case) can be explained by a
  target-keyed stall as described above — only calls reaching that ONE session
  are affected.
- A stall that looks like the **whole fleet** froze and then self-recovered is
  *also* explained by this same architecture, with no new mechanism needed:
  ANY one session's handler blocking non-yieldingly inside the native module
  stalls **every** session's MCP calls simultaneously (not just the wedged
  session's), and everything unblocks together the moment that one native call
  finally returns. **This is the first thing to suspect** when multiple,
  unrelated sessions report a simultaneous hang that clears on its own with no
  visible cause — it does not necessarily mean multiple sessions are each
  individually wedged.
- This also means a **caller-selective** symptom (session A's calls hang,
  session B's succeed, at the same moment) is NOT explained by this
  single-thread model, and is not explained by any caller-keyed code path
  either (none exists — caller identity is used only for the self-send guard
  and logging). If that specific shape recurs, the likely explanation is
  ordinary bad luck of *which target* each caller happened to be reaching at
  that moment, not a new per-caller mechanism — confirm by checking what each
  caller actually targeted before assuming otherwise.
