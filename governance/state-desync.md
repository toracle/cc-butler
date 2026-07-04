---
name: butler-state-desync
description: Butler↔worker interactions suffer stale-context echo + assumed-common-ground; anchor relays in time/state and reconcile deltas
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 24305c3a-429a-4449-800d-2bf67f660d4b
---

The user observed a systemic "echo/resonance" (공명/반향) in butler↔worker coordination:
an instruction given to the butler at T1 gets relayed to a worker later at T2; in between,
the situation changed. Workers report on the frame they last synced to (which goes stale
after long work), while the butler judges on the current basis. Worse, **both sides assume
shared common ground that isn't actually shared** — the worker assumes the butler holds its
(stale) context; the butler assumes the worker knows what changed. Latency + frame-mismatch
+ assumed-common-ground = the "echo."

**Why:** In a fleet the butler mediates, state diverges constantly. Silent judgment on the
current frame (when the other party is on an old frame) produces mismatched actions and
answers that talk past each other. Same family as [[butler-no-overinterpret]] (mistaking
one's own frame for reality), but here the failure is *stale/unshared state*, not inferred
user state.

**How to apply (butler operating rules):**
- **Anchor relays in time/state.** When relaying an instruction, note when/against-what it
  was given AND what changed since ("as of your report at X; note Y changed"). Use `date`
  for real timestamps (see [[butler-no-overinterpret]]).
- **Freshness-check before acting on stale reports.** If a worker's report references an old
  situation (or it has been working a long time), don't silently judge on the current basis
  — name the delta: "you referenced X; current is Y — reconcile."
- **Bridge common ground explicitly.** Assume the worker does NOT know what changed since it
  last synced; include the needed current state in the relay. Assume you do NOT know the
  worker's full current state; re-read/ask if its report seems to be on an old frame.
- **Shrink the staleness window.** Relay promptly; when parking something, mark it "held,
  state may drift" and re-verify freshness on unpark. (E.g., the just-before-delete git
  safety recheck when removing a stale workspace.)
