# Templates

Copy-paste starting points. Fill the bracketed parts in; delete what doesn't apply.

- [Repo-wide: `.github/copilot-instructions.md`](#repo-wide)
- [Path-specific: `.github/instructions/<area>.instructions.md`](#path-specific)
- [`AGENTS.md` (root)](#agentsmd)

## Repo-wide

`.github/copilot-instructions.md` — keep under ~2 pages. Essentials only;
push per-area detail into path-specific files.

```markdown
# <Repo name> — Copilot agent instructions

Trust these instructions. Only search the repo if something here is missing or
proven wrong.

## Purpose
<1-2 sentences: what this repo is and produces.>

## Layout
<top-level dirs, one line each — only what an agent needs to navigate.>

## Build / test / lint (exact commands, with versions)
- Install: `<cmd>`  (toolchain: <e.g. Python 3.12, Poetry 1.8>)
- Lint: `<cmd>`
- Test: `<cmd>`
- Pre-PR gate: `<cmd>`  ← run before opening any PR

## CI/CD
<what runs on PR, what blocks merge, where deploys happen.>

## Hard constraints
- <e.g. never deploy to dev/test/prod manually — CI only.>
- <e.g. every new bundle must be registered in version-guide.json.>

## Known errors → fix
| Error | Cause | Fix |
|-------|-------|-----|
| <msg> | <why> | <do this> |
```

## Path-specific

`.github/instructions/<area>.instructions.md` — loads only when the agent edits
files matching `applyTo`. Cloud-agent + code-review only. One per distinct area.

```markdown
---
applyTo: "<glob, e.g. edp_unitystorage/shared/sql_warehouses/**>"
---

# <Area> authoring rules

<The specific, opinionated rules for this area — the stuff too detailed for the
repo-wide file. Authoring conventions, required fields, anti-patterns.>

## Known errors → fix (this area)
| Error | Cause | Fix |
|-------|-------|-----|
| <msg> | <why> | <do this> |
```

Multiple `applyTo` patterns: use a YAML list or comma-separated globs per current
GitHub docs. Verify syntax against live docs if unsure.

## AGENTS.md

Root `AGENTS.md` — cross-agent (Copilot, Claude Code, Cursor, Jules). Nestable;
nearest file in the tree wins. Keep it to commands + constraints.

```markdown
# AGENTS.md

## Build / test / validate
- <install cmd>
- <test cmd>
- <validate cmd>

## Conventions
- <branch naming, commit format>
- <where code goes>

## Constraints
- <hard rules an agent must not violate>
```

## Co-located per-module: `AGENTS.md` + `CLAUDE.md` shim

The cross-tool standard for rules scoped to a subtree. Canonical content in
`AGENTS.md` (Copilot reads it nested, nearest-wins); a one-line `CLAUDE.md` shim
beside it so Claude Code reads the same content. Content **must** live in
`AGENTS.md` — Copilot doesn't expand Claude's `@` imports.

`<dir>/AGENTS.md`:
```markdown
# <Area> authoring rules

<Optional: "Follow the parent [workspace rules](../AGENTS.md) plus the rules below.">

- <area-specific convention / required field>
- <always-apply guardrail lifted out of the model-invoked skill>
- For the full procedure use the **<skill-name>** skill (`.claude/skills/`).

## Known errors → fix (this area)
| Error | Cause | Fix |
|-------|-------|-----|
| <msg> | <why> | <do this> |
```

`<dir>/CLAUDE.md` (the shim — exactly one line, plus optional Claude-only notes):
```markdown
@AGENTS.md
```
