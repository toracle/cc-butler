---
name: the-running-daemon-may-not-be-the-code-on-disk
description: "cc-butler is infrastructure that is running while you edit it. A committed, pushed, test-green change does NOT take effect until the live Emacs reloads it — and any verification you perform THROUGH the running system reflects the old code. Completion for a cc-butler change is 'reloaded and observed working', not 'committed and green'. Check which version produced your result, not merely that you got one."
metadata:
  node_type: memory
  type: feedback
---

**The incident (2026-08-03).** A governance-cache defect was fixed, tested (393/393), committed and pushed. On
verifying against the real store, the worker found `cc-butler-governance--load-dir` was **void** — the live
Emacs had never loaded that day's edits at all. It force-reloaded and only then did the fix actually run.

The steward had, earlier that same evening, invoked `emacsclient --eval '(cc-butler-governance-regenerate)'`
several times and verified the results: note bodies byte-identical in the cache, index entries absent (so it
hand-added them). Every observation was accurate. But those results are **exactly what the OLD code produces** —
body sync without index sync. The steward was verifying diligently while having no idea which version of the
code was producing what it verified. The conclusions happened to survive; the method did not deserve to.

**Why this class of system is different.** Most code you change is not the code you are running. cc-butler is:
the agent edits the orchestrator that is currently orchestrating it. So the usual chain — write, test, commit,
push, verify — has a silent gap between "push" and "verify", and worse, **the verification step itself runs
through the stale system**, which makes it look like confirmation. A test suite passing proves the code on disk
is correct. It proves nothing about the process currently serving your calls.

**How to apply.**
1. **For any cc-butler change, completion is "reloaded and observed working", not "committed and green".**
   Reload explicitly (`reload_butler_code`, or force-reload from the session) and re-observe. Write that into
   the definition of done before starting, not as a cleanup step.
2. **Before trusting a result obtained through the running system, ask which code produced it.** If you cannot
   answer, you have not verified the thing you think you verified — you have observed the behaviour of an
   unknown version. This is the same discipline as asking what a metadata field actually establishes
   (see [[session-id-change-is-not-a-second-agent]]), applied to the executing code rather than the evidence.
3. **A result that matches the OLD behaviour is not a bug report — it is a reload prompt.** If a freshly-shipped
   change appears to have had no effect, suspect the load state before suspecting the change.
4. **Prefer making the load state observable.** Exposing a version/hash of the loaded code, comparable against
   disk, converts this from a thing you must remember into a thing you can check. Absent that, treat "did I
   reload since the last edit?" as a standing question.

**Scope note:** this is broader than the governance store. It applies to every cc-butler change — tools,
hooks, dashboard, compaction logic. Any of them can be committed, correct, and simultaneously not in effect.

Related: [[direct-writes-to-the-store-skip-the-cache]] (the same "written but not in force" shape one layer
down), [[verify-delivery]] (confirm the fact rather than inferring it from a successful send).

**SPT:** the habit is *when you change the system you are running inside, reload before you believe anything you
observe through it.*
