---
name: direct-writes-to-the-store-skip-the-cache
description: "Writing a governance note with the Write tool does NOT put it in the shared memory cache. `record_principle` auto-regenerates as a side effect; a direct file write bypasses that and the note is stranded — present in the store, invisible to every session that loads the cache. Either use `record_principle`, or regenerate explicitly afterwards and verify by diffing source against cache."
metadata:
  node_type: memory
  type: feedback
---

**The incident (steward, 2026-08-03).** Over one night the steward wrote four governance notes with the Write
tool — including [[search-for-the-existing-decision-first]], whose entire subject is *a closure that never
landed where the next agent would read it gets re-litigated from scratch*. All four sat in the store,
unreflected in the shared memory cache, for hours. The lesson about things not landing had itself not landed.

**The mechanism, once checked.** `record_principle` regenerates the cache as a side effect of writing. A direct
file write does not. So the store and the cache silently diverge, and only for notes authored the direct way —
which is exactly the path an agent reaches for when it wants control over the note's wording and structure.
There is no error, no warning, and the file is genuinely there when you look for it. The only visible symptom
is a later session that has not heard of something you are sure you wrote down.

**How to apply.**
1. **Prefer `record_principle`** for governance notes. Its regeneration side effect is the point, not a detail.
2. **If you write a note directly, regenerate explicitly afterwards.** The command is interactive but takes no
   arguments and prompts for nothing, so it can be driven non-interactively:
   `emacsclient --eval '(cc-butler-governance-regenerate)'`
3. **Verify by comparing source to cache, not by the command exiting 0.** "The command ran" is not the
   completion condition; "the note is byte-identical in the cache" is. Diff them.
4. Batch this at the end of a writing session rather than per-note — but do not leave it to the next session,
   which is precisely the failure being described.

**Two more gaps found the same night, once someone actually looked.** Regeneration rewrites every note body but
never touches `MEMORY.md`, the index each session loads — so **20 of 50 cached notes were present on disk and
absent from the index**, effectively unrecallable. Worse, the system's own auto-generated instructions tell
every session that `MEMORY.md` *is* a synced cache, while no code path syncs it: the documentation asserts a
guarantee the implementation does not provide, which is why nobody thought to check. And regeneration is
strictly **add-only** — it never reconciles deletions or renames, which is how a renamed note left a stale
duplicate sitting in the cache indefinitely.

So the completion condition is a step further out than it first appears. Not "the command ran," not even "the
note is byte-identical in the cache," but **"the next session will actually recall it"** — which depends on the
index, not the note. Verify the thing that gets loaded.

**A caution on checking, learned by getting it wrong in the middle of this:** the cache prefixes filenames
(`butler-<slug>.md`). A first verification pass that assumed bare slugs reported all five notes MISSING — a
false alarm produced entirely by an assumption about the check itself, corrected by listing the directory.
Having run a check is not the same as knowing what it establishes.

**And the store itself is not durable either — same root, one layer further out.** A check the same night found
**18 of 42 notes in `governance/` were UNTRACKED in git**, including all seven written that evening and eleven
older ones. The overlap with the unindexed set was near-total, and for one reason: a note created by direct
`Write` skips regeneration *and* never gets committed. The direct path bypasses everything. So the "durable
home" for institutional learning was a working tree — one `git clean -fd`, one fresh clone, one disk loss away
from erasing nearly half of it. Note the shape of the mistake: the steward had, that same evening, caught a
worker leaving valuable test fixtures uncommitted and told it that "hold" means don't change product behaviour,
not let evidence evaporate — and was doing exactly that to its own notes.

Also worth knowing: a scoped `git status <paths>` reporting "clean scope, only my intended files" is perfectly
compatible with a working tree full of uncommitted valuable work elsewhere. Scope your status check to what you
changed, then look once at the whole tree before you walk away.

**The general shape, worth carrying past this tool:** when a store has a generated cache, *any* write path that
bypasses the generator creates a silent divergence — and the bypass path is usually the more expressive one, so
it is the one a careful author picks. Whenever you learn that a system has a "and then it regenerates"
side effect, immediately ask **which write paths don't have it**.

Related: [[search-for-the-existing-decision-first]] (a closure that does not land gets re-litigated — the same
failure, and the note that was itself stranded by this), [[verify-delivery]] (confirm arrival, don't infer it
from a successful send).

**SPT:** the habit is *after writing anything into a store that feeds a cache, check the cache — not the store.*
