---
name: butler-steward-routing
description: Worker/cc-butler-touching dispatch routes through the steward to keep one coherent ops picture; real-time read-only clarifications may be butler→worker direct
metadata:
  node_type: memory
  type: feedback
---

During the butler/steward split rollout, the butler several times dispatched
worker-touching or cc-butler build work directly to sessions (bypassing the steward),
which crossed with the steward's own in-flight instructions — e.g. the steward's maildir
"stand down" vs the boss's four UX requests relayed straight to the cc-butler dev session;
and butler→worker direct queries. The worker (correctly) paused and asked the steward to
reconcile rather than act across a stand-down.

**Resolution (the boss adopted this explicitly):** instructions that touch a worker or
cc-butler route **through the steward**, so the steward keeps a single coherent dispatch
picture and can track each item to its DoD. Same family as [[butler-state-desync]] —
parallel butler judgment + relayed instructions diverge silently otherwise ("echo").

**Refinements (not a blanket rule):**
- **Real-time boss clarification (read-only)** — the butler querying a worker directly for a
  fact to relay to the boss mid-conversation is fine (keeps the live channel fast). Only
  *dispatch/build* work touching the worker fleet must route through the steward.
- **cc-butler self-UX** (doc-view, role docs, etc.) — where the boss + butler are effectively
  the product owner, the butler↔boss↔cc-butler-dev loop may drive directly, **as long as**
  the dev session keeps reporting to the steward so the steward stays informed.

**How to apply:** [as butler] route worker/cc-butler-touching dispatch through the steward.
[as steward] if you observe the butler dispatching worker work directly, reconcile it, surface
the routing principle, and keep the ops picture whole. Related: [[butler-decision-routing]],
[[butler-institutionalize-learning]].
