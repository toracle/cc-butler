# cc-butler governance store

The **runtime-neutral, single source of truth** for the butler/steward
operational principles (SDD: `docs/cc-butler-governance-store-sdd.md`).

Each `*.md` here is one principle, content-only, owned by this repo — *not* by
any runtime. Runtime files (Claude Code role `CLAUDE.md` + memory notes, a
future Codex `AGENTS.md`) are **generated caches** of this store.

- **Edit a principle here + regenerate** → every runtime adapter updates.
- Do **not** hand-edit the generated runtime caches; they are derived.
- Values/philosophy live in the vault, engineering discipline in
  warmblood-kr/skills, repo pitfalls in each repo's own doc — only the
  butler/steward *operational* principles live here.

Migrated from the Claude Code memory (`~/.claude/projects/-home-toracle--ccsm/
memory/`), which now becomes a generated cache of this store.

Regenerate the Claude Code memory cache: `M-x cc-butler-governance-regenerate`.
