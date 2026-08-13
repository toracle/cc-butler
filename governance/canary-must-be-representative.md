---
name: butler-canary-must-be-representative
description: "broadcast-verify-one-first only works if the canary sits at the RISKY end of the axis that varies — a canary picked at the safe end certifies the whole fleet wrongly and the failure is silent"
metadata:
  node_type: memory
  type: feedback
---

`broadcast-verify-one-first` is not satisfied by verifying *any* one session. Before firing the canary, name the axis along which the fleet varies for this operation (context size, session age, repo state, branch, model, permissions), and pick a canary at the RISKY end of that axis — or verify all of them. A canary chosen at the safe end returns a clean result that certifies nothing, and you will read it as fleet-wide proof.

**Why:** 2026-08-12, resurrecting 14 workers after a machine shutdown. The butler relaunched `monocle-iros` as the canary; it resumed straight to a ready prompt, kept its model, and reported CTX=79747. The butler recorded "no interactive resume prompt this time, models survived" and fired the other 13 on that basis — even writing the finding into the relaunch script's header as a fact.

It was wrong. The `--continue` resume prompt ("This session is 2h 5m old and 111.1k tokens... 1. Resume from summary") is armed by session SIZE, and iros at 80k was one of the smallest sessions in the fleet. Six of the fourteen — skills (111k), security (317k), model-router (154k), paid-mcp-tool-billing (152k), jarvice-1130 (115k), server-side-orchestration (146k) — came up parked on that prompt and sat there silently doing nothing. The canary had been verified honestly and had simply been unrepresentative of the one variable that decided the outcome.

The failure mode is quiet in both directions: a parked session looks "running" in the session list, and the canary's clean result looks like evidence.

**How to apply:**
- Before the canary, ask out loud: *what varies across these targets, and where does my canary sit on it?* If the canary is at the safe end, pick another or widen to all.
- Prefer the WORST case as canary — the biggest context, the oldest session, the dirtiest repo. A canary that passes at the risky end genuinely covers the easy ones; the reverse is false.
- Then still sweep for the cheap tell rather than trusting the extrapolation. Here the tell was mechanical: a session parked on the prompt reports NO MODEL in `list_claude_sessions` and `?` context in `session_status`, because its statusline never comes up. One `session_status` call exposed all six; reading fourteen screens was never needed.
- Related: [[butler-broadcast-verify-one-first]], [[butler-suspiciously-uniform-is-the-instruments-fingerprint]], [[butler-a-test-that-cannot-fail-is-not-evidence]].
