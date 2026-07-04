# The arming gap — a known limitation (not a bug to re-fix)

## What it is

A Claude Code session picks up its MCP tool list **once, at connect**. Any tool
cc-butler registers **after** a session has connected is **invisible** to that
session for its whole life. This is the "arming gap" felt across the project
(e.g. `resolve_reference`, the briefing tools).

## Why it can't be fixed server-side (investigated 2026-07-04)

We confirmed there is **no server-side fix** that makes the running CLI re-fetch
tools:

- **`/mcp reconnect` is not a thing.** `/mcp` is Claude Code's *interactive
  panel* command; there is no headless reconnect. Typing it just opens the panel
  and parks the session in nav mode (the 2026-07-04 incident). Re-arm via a slash
  command is therefore disabled (`cc-butler--rearm` signals; recover a parked
  session with `M-x cc-butler-dismiss-mcp-all`).
- **The HTTP transport can't push.** cc-butler's tools live only on the HTTP MCP
  server, which advertises `tools.listChanged=false` and 404s `GET /mcp` (no SSE).
- **stdio is not viable.** No stdio server exists in claude-code-ide, and the
  shared HTTP server is load-bearing (it multiplexes every session by
  session-id-in-URL). The WebSocket "IDE" channel that *does* push
  `list_changed` carries a **hardcoded** tool list, not the butler tools.
- **Adding SSE + `list_changed` to the HTTP server would not help the CLI.** The
  Claude Code CLI does not open a GET SSE stream for `http`-type servers (it uses
  the old POST-only pattern — claude-code issue #33288), and even if it did, it
  registers **no handler** for `notifications/tools/list_changed`
  (issues #13646, #31893). So server push is futile for the CLI.

The MCP spec *does* define GET-SSE server push; the gap is the CLI's client, not
our server.

## How to live with it (the actual discipline)

1. **Register all tools BEFORE sessions connect.** The gap only appears when a
   tool is registered *after* a session is already up. Ensure every
   `claude-code-ide-make-tool` call runs at load/startup, before workers launch —
   then every session sees the full tool set at connect. This is the primary
   mitigation: make tool registration *early and complete*, not incremental.
2. **A new tool for existing sessions needs a session restart** (which loses
   context) — so treat post-connect tools as expensive and avoid depending on
   them mid-session.
3. **Recovery, not re-arm.** If a session is parked (e.g. someone opened `/mcp`),
   `M-x cc-butler-dismiss-mcp-all` sends ESC to back workers out. Do **not**
   re-run any `/mcp reconnect` re-arm — it is guarded off.

## Status

Documented limitation, not an open bug. Revisit only if a future Claude Code
version implements Streamable-HTTP GET-SSE **and** wires a `tools/list_changed`
handler (watch claude-code issues #33288 / #13646 / #31893).
