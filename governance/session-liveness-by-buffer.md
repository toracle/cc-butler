---
name: butler-session-liveness-by-buffer
description: "A worker session's liveness/state is determined by its terminal BUFFER (buffer-live-p), not the MCP registry — the registry cannot tell a stuck/parked session from a dead or a healthy one"
metadata:
  node_type: memory
  type: feedback
---

To act on or reason about a worker session's liveness and state, use its
**terminal buffer** (`buffer-live-p` on the session's ghostel buffer), NOT the
MCP registry.

**Why:** the MCP registry records that a session *connected*; it cannot
distinguish a session that is **healthy**, one that is **stuck/parked** (e.g. in
the `/mcp` panel after the 2026-07-04 incident), and one that is **dead**. The
buffer is the ground truth of what the session actually is right now. This is why
recovery/operations iterate session **buffers**: `cc-butler-dismiss-mcp-all`
sends ESC by walking the session buffers, and `cc-butler--rearm`/`--send-escape`
gate on `buffer-live-p` of the session buffer.

**How to apply:** any fleet operation (recover, send, count, target) enumerates
session buffers and checks `buffer-live-p`, treating the registry as a hint about
connection history, not current state. Ties to [[butler-state-desync]] (anchor in
real state, not an assumed one) and [[butler-broadcast-verify-one-first]].
