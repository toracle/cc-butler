# Which copy of cc-butler runs, and how far it has drifted

Design note. Repo-side mechanism only — no change to `custom.el` or any live
init file is proposed here; that is a separate permission.

## The situation, measured

Two copies exist on this machine:

| copy | path | revision |
|---|---|---|
| installed | `~/.emacs.d/elpa/cc-butler/` | tracks releases |
| dev checkout | `~/projects/cc-butler` | `d747467` — PR #15 |

`load-path` holds the **checkout first**, the installed copy second. The
running code is nonetheless the **installed** one.

That is the whole problem in one line: the order says one thing and the
outcome is another, because the outcome was not decided by order at all. The
installed copy is activated by `package-initialize` before init ever appends
the checkout, so the entry that sits first on the list arrived too late to
matter. Nothing expressed which copy was *wanted*; the answer fell out of
timing.

Today the accident is benign. Had it fallen the other way the fleet would be
running a tree that stops at PR #15 — thirteen merged PRs of fixes absent,
with nothing on screen saying so.

## What is already solved

PR #27 established one authoritative answer to "which directory am I":
`cc-butler-source-dir`, an explicit override, `cc-butler-use-checkout` /
`cc-butler-use-installed` to move it deliberately, and diagnostics that ride
the existing doctor / launch-preflight / reload-tool surfaces.

So the running copy is **visible**, and switching it at runtime is
**deliberate**. What is still an accident is the *initial* choice, and that is
what remains.

## What cc-butler can and cannot do

It cannot choose its own load-path. By the time any of its code runs, the
choice has been made. Any design that pretends otherwise is fiction.

What it can do is **hold an intent and compare the intent against reality**.
That converts a silent accident into a stated mismatch, which is the honest
limit of what a package can do about its own loading.

## Proposed: declared intent

`cc-butler-preferred-source` — a `defcustom`, default `installed`.

- `installed` — the consumer default; the elpa copy is what should run
- `checkout` — deliberate development against the working tree
- `nil` — no opinion, report nothing

At doctor / preflight time, compare it against `(cc-butler-source-dir)`. On
mismatch, report both paths, both revisions, and the single command that
resolves it. Do not change anything automatically: a package that silently
reloads itself from elsewhere because it disagreed with how it was loaded is
worse than the problem.

This satisfies the standing criterion — the default is `installed`, which is
what already happens, so nothing changes for anyone until they say otherwise.
The new behaviour is a report, and it stays quiet unless an intent is set and
reality disagrees with it.

## Proposed: drift discipline

`cc-butler--source-behind` compares against the last-fetched `origin/main`
and deliberately does **not** fetch, so it can only ever under-report. That
constraint is right — a launch must not touch the network — but it has a
consequence that is currently invisible: **a checkout that never fetches
looks up to date forever.** That is exactly the state of the checkout above.

So the count alone is not honest. Two changes:

1. Report the **age of the last fetch** next to the count. `behind 0, last
   fetched 23 days ago` is a true statement; `up to date` from the same data
   is not.
2. Add an explicit `cc-butler-check-drift` command that fetches first, then
   reports. Interactive only, never on the launch path — the no-network
   constraint is preserved by keeping it off the automatic surfaces rather
   than by weakening it.

A warning threshold in doctor (behind more than N commits, or last fetch older
than N days) turns drift from something you have to remember to look at into
something that speaks up. Values deliberately left open below.

## Deliberately not proposed

- **Editing `custom.el` or init load-path.** Separate permission. The
  mechanism above must work without it, and it does — it reports rather than
  rearranges.
- **Auto-switching on mismatch.** See above.
- **Removing the checkout from `load-path`.** The point is to keep developing
  against it deliberately, not to make it impossible.

## Open, for a human

1. On intent/actual mismatch: warn, or refuse to launch sessions? Refusing is
   defensible when the mismatch means running thirteen PRs behind, and
   indefensible when someone is mid-development. Leaning warn.
2. Threshold values for the drift warning.
3. Whether `checkout` as a declared intent should also make the stale-`.elc`
   check stricter, since a dev tree is where stale bytecode actually happens.
