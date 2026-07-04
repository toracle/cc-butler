# cc-butler governance store

The **runtime-neutral, single source of truth** for the butler/steward
operational principles (SDD: `docs/cc-butler-governance-store-sdd.md`).

Each `*.md` here is one principle, content-only, owned by this repo — *not* by
any runtime. Runtime files (Claude Code role `CLAUDE.md` + memory notes, a
future Codex `AGENTS.md`) are **generated caches** of this store.

- **Edit a principle here + regenerate** → every runtime adapter updates.
- Do **not** hand-edit the generated runtime caches; they are derived.
- Values/philosophy live in the vault, engineering discipline in
  a shared skills repo, repo pitfalls in each repo's own doc — only the
  butler/steward *operational* principles live here.

## Two tiers (built-in + your private layer)

The store is **two-tier** via `cc-butler-governance-user-dir`: this repo ships
the **generic built-in** principles, and you add your own **private,
user-custom** layer (private examples, org-specific principles) in a separate
directory of your own. The two are merged — a user file with the same basename
overrides the built-in of that name. This is the same shape as
`cc-butler-define-project-template` for workspaces: the package provides the
generic facility; your private content stays in your own config.

Regenerate the runtime cache (Claude Code memory) from the store:
`M-x cc-butler-governance-regenerate`.
