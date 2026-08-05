---
name: butler-a-tools-success-check-covers-only-its-own-layer
description: "record_principle honestly reported 'written and verified on disk' for principles that were never in git — a tool verifies at the layer it owns, and durability usually lives one layer below"
metadata:
  node_type: memory
  type: feedback
---

A tool that reports success is telling the truth **about the layer it checks**. It says nothing about the layers beneath it, and durability almost always lives one layer down. "Written and verified on disk" is not "committed"; "committed" is not "pushed"; "pushed" is not "backed up". Each of those is a different tool's job, and no single success string spans them.

**Why:** On 2026-08-05 the butler and steward recorded operating principles with `record_principle`. Each call returned, honestly, that the note had been written to `/home/toracle/projects/cc-butler/governance/` and **read back off disk to confirm it named the principle** — a genuinely good check, added precisely because a regeneration once reported success while landing nothing.

An idle-worker sweep then found **twelve files in `governance/` that were not in git**: all five of that day's principles, plus six that had been sitting untracked for days across earlier sessions. `governance/` is the **source of truth** for operating principles; the memory notes loaded at every session start are a *generated cache* of it. Untracked meant not on origin, not backed up, and **one `git clean -fd` away from deletion.**

The irony is exact and worth keeping: the fleet spent that entire day telling workers *"don't leave learning in scrollback, route it to a durable home"* — while the durable home itself was untracked. And the tool never lied. It verified what it owned and reported that faithfully. The artifact was unprotected at a layer the tool does not look at.

This is the third instance of the same shape in one day: a log that exists at a level nobody reads (`credential_strategy` gate at `log.info`), an aggregator that fails loudly into a channel with no alarm (chat-proxy `#342`), and a store that writes successfully into a directory git has never seen.

**How to apply:**

- When a tool reports success, ask **which layer it checked** and name the next one down. For anything meant to be durable: written → committed → pushed → recoverable-if-this-machine-dies. Verify the last one you actually care about, not the first one that returned green.
- **Periodically check the durable homes themselves**, not just the writes into them. `git status` on the store, not another successful write to it.
- Treat "the tool said it verified" as evidence about the tool's own contract, not about your outcome. See [[butler-verify-delivery-at-the-recipient-not-the-return-string]] and [[butler-direct-writes-to-the-store-skip-the-cache]].
- Preserve first, decide later: committing an untracked artifact to a branch is reversible; `git clean` is not. Do not wait for a decision about where it belongs while it is still deletable. **But preserving and restoring are two operations — see [[butler-preserving-an-untracked-store-can-delete-it]] before you commit a live store.**
- **Distinguish untracked from tracked-modified.** Untracked means deletable by a routine command; tracked-modified means silently reverted on checkout. Different failure, different severity. Eleven of the twelve were untracked; one was tracked with an uncommitted update, and calling all twelve "untracked for days" overstated the alarm — a wrong claim that reached the human before it was caught.
- **Check `.gitignore` before treating untracked-for-days as a bug.** Long-lived untracked files may be deliberate, in which case committing them is the error. Ask, and be willing to be wrong.
- When you do preserve: branch from the mainline rather than whatever feature branch is checked out, stage the specific path rather than `-A` (other untracked trees will otherwise be swept in), and confirm the remote SHA with `ls-remote` rather than trusting push output. See [[butler-git-claims-need-origin-verification]].
- Note also what the fix reveals: `/home/toracle/projects/cc-butler` has a remote (`toracle/cc-butler`, a personal account); the butler *home* at `~/.emacs.d/cc-butler/butler` still has **no remote at all** — and the dashboard, the daily logs, and the steward handoff all live there. Fixing one durability gap is not evidence about its neighbours — check each.
