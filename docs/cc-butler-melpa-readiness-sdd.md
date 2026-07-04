# cc-butler MELPA readiness — SDD

## Intent

Decide how far to take cc-butler toward being an *installable, archive-shaped*
Emacs package — from "clone it onto your load-path" to something a stranger can
install with one form — and name the smallest solid step that gets us there.

## Where we already are

More is done than a fresh audit assumes:

- **Modules are split** — one concern per `cc-butler-*.el` (13 files), each with a
  matching `(provide 'cc-butler-*)`. `cc-butler.el` is a thin wiring file that
  only `require`s the modules.
- **Tests + runner** — `tests/` holds ~61 ERT tests across 6 `*-test.el` files
  and a batch runner (`emacs -Q --batch -l tests/run-tests.el`).
- **License** — MIT `LICENSE` at root, `SPDX-License-Identifier: MIT` header in
  every one of the 13 `.el` files (and the test runner).
- **Main-file header exists** — `cc-butler.el` already carries `Author`,
  `Maintainer`, `Version: 0.1.0`, `URL`, `Keywords`, a `Package-Requires`, and a
  real `;;; Commentary:` block. This is the part usually missing; here it is
  present.

So this is not a from-scratch packaging job. It is a *finishing* job.

## The gap

What still stands between us and archive-shaped:

- **`Package-Requires` is incomplete.** It declares
  `((emacs "29.1") (claude-code-ide "0.2.7"))` but omits **`hydra`**, which is a
  genuine runtime dependency (`(require 'hydra)` + `defhydra` in
  `cc-butler-decision.el`, and the topic hydra in `cc-butler-workspace.el`).
  `hydra` is resolvable (GNU ELPA / MELPA), so it belongs in the list. The other
  externals — `org`, `tab-line`, `cl-lib`, `seq`, `subr-x`, `filenotify`,
  `format-spec` — ship with Emacs and need no declaration.
- **README is `.org`, not `.md`, and half-finished.** `README.org` exists and is
  good, but its *License* section still says `TBD` (contradicting the MIT
  reality) and *Installation* only covers the manual load-path path. MELPA does
  not require Markdown, but the License contradiction should be fixed either way.
- **Byte-compile is unverified.** MELPA's CI treats byte-compile warnings as a
  gate. We have not yet confirmed a clean `emacs -Q --batch -f
  batch-byte-compile` across all 13 modules (`.elc` is gitignored, so this is
  cheap to run and cheap to leave uncommitted).
- **The `claude-code-ide` caveat.** cc-butler hard-depends on
  `claude-code-ide` (and `claude-code-ide-mcp-server`), which is **not on MELPA
  or GNU ELPA** — it lives only as a GitHub repo. A dependency that no archive
  can resolve makes a *clean* MELPA recipe non-trivial: MELPA's build fetches
  declared deps from archives, and this one has nowhere to fetch from.

## The open question (gating)

**How far do we take it?**

- **(a) Structure-ready only** — headers complete (add `hydra`), README finished,
  deps correct, clean byte-compile. Installable *today* via
  `package-vc-install` / `straight` / manual load-path. MELPA submission
  deferred.
- **(b) Also submit a MELPA recipe** — everything in (a) **plus** a public tagged
  release, a PR to `melpa/melpa`, and a resolution for the unresolvable
  `claude-code-ide` dependency (e.g. upstream it to an archive first, or accept
  a non-standard recipe). Substantially more work, and gated on a third party.

## Recommendation

**Do (a), structure-ready first — it is the SPT.** Everything in (a) is a strict
prerequisite for (b), so no work is wasted, and (a) already delivers the real
user-facing win: a one-form install via `package-vc-install`. (b) is blocked on
the `claude-code-ide` not-in-archive problem, which is out of our hands and makes
a clean recipe non-trivial; there is no reason to couple the achievable step to
the blocked one. Revisit (b) once `claude-code-ide` is itself archive-resolvable.

## If (a): the concrete buildable pass

A small, verifiable sequence — each step independently checkable:

1. **Fix `Package-Requires`** — add `(hydra "…")` at the minimum version we rely
   on; leave the Emacs-bundled deps out.
2. **Finish the README** — correct the *License* section to MIT (it currently
   says `TBD`), and add the `package-vc-install` install path alongside the
   manual one. Keep `.org`; no need to convert to `.md`.
3. **Confirm the Commentary** reads as a coherent package summary (it already
   does) and that `Version`/`URL`/`Keywords` are accurate.
4. **Green byte-compile** — `emacs -Q --batch -f batch-byte-compile
   cc-butler*.el` with **zero warnings**; fix any that surface. This is the MELPA
   CI gate and the one item still unverified.

## Open questions (GATING → 정수님's inbox)

1. **(a) or (b)?** Structure-ready only (recommended), or also chase a MELPA
   recipe now despite the `claude-code-ide` blocker?
2. **`hydra` minimum version** — pin to what's installed, or the lowest version
   whose API we use? (Affects how strict the requirement reads.)
3. **README format** — keep `.org`, or does MELPA-mindedness argue for a `.md`
   README as well? (MELPA does not require it.)
