---
name: copilot-agent-readiness
description: >
  Audits and remediates any repository to maximize GitHub Copilot coding agent
  (cloud agent / copilot-swe-agent[bot]) output quality. Use when: a repo will
  be worked by the Copilot coding agent, Copilot PRs are low quality or ignore
  conventions, onboarding a repo to autonomous agent work, or asked to "make
  this repo Copilot-ready / agent-ready", "optimize for Copilot", "audit
  copilot instructions", "set up AGENTS.md". Covers the instruction-file
  layering Copilot actually reads, what it ignores, MCP wiring, and a fix
  workflow. Skip for IDE-only Copilot tuning (different surface) and for
  Claude Code skill authoring.
allowed-tools: Bash, Read, Glob, Grep, Edit, Write
---

# Copilot Agent Readiness

Make a repo produce better PRs from the GitHub Copilot **cloud coding agent**
(`copilot-swe-agent[bot]`). The agent runs autonomously in an ephemeral GitHub
Actions environment — it can build, test, and lint. Most quality wins come from
the instruction files it auto-reads, not from the task prompt.

## When to Use This Skill

- A repo is (or will be) targeted by the Copilot coding agent.
- Copilot PRs ignore repo conventions, miss build/test steps, or explore aimlessly.
- "Make this repo agent-ready", "audit copilot instructions", "add AGENTS.md", "optimize for the Copilot agent".

## When *Not* to Use This Skill

- Tuning IDE Copilot (VS Code agent mode) — different surface, different MCP support (it reads `.vscode/mcp.json`, supports MCP resources). This skill is the **cloud** agent.
- Authoring Claude Code skills — use a skill-scaffolding helper if your workspace has one.
- Writing the orchestrator/dispatch plumbing — that's the hub repo, not the target repo.

## What the cloud agent actually reads (auto-loaded, no prompt needed)

| File | Scope | Notes |
|------|-------|-------|
| `.github/copilot-instructions.md` | repo-wide, always-on | Keep **under ~2 pages**. Bloat gets truncated/deprioritized. |
| `.github/instructions/*.instructions.md` | path-specific via `applyTo:` glob | **Cloud-agent + code-review only.** Highest-impact lever for monorepos. |
| `AGENTS.md` | nestable anywhere, **nearest-wins** | Cross-agent (Copilot, Claude Code, Cursor, Jules). |
| `CLAUDE.md`, `GEMINI.md` (repo root) | root-level | Also honored by the cloud agent. |

**Agent skills** (GA Dec 18 2025) — folders containing a `SKILL.md` (+ optional
scripts/resources), **model-invoked**: loaded only when the agent judges them
relevant, *not* always-on like instructions. Read from `.github/skills/`,
`.claude/skills/`, `.agents/skills/` (project) and `~/.copilot/skills/`,
`~/.agents/skills/` (personal). Copilot **auto-adopts** an existing
`.claude/skills/`. Supported on cloud agent, code review, CLI, Copilot app, and
VS Code/JetBrains agent mode. Org/enterprise-level skills "coming soon."

Copilot reads skills from all of `.github/skills/`, `.claude/skills/`, and
`.agents/skills/`. **Respect the repo's established convention** — wherever the
repo already keeps skills, leave them there. Do not relocate, duplicate, or
bridge skills between locations to serve another tool.

MCP servers extend the agent with **tools** (not resources/prompts). Configured
in the **repo Settings UI** (Settings → Copilot → coding agent → MCP), as JSON —
**not** an in-repo file. GitHub MCP + Playwright MCP are on by default; GitHub
MCP is read-only on the current repo, Playwright is localhost-only.

## Co-located, per-module instructions → AGENTS.md (cross-tool standard)

For rules that live *in* a subtree (module/area/workspace specific), **`AGENTS.md`
is the vendor-neutral standard** (agents.md) — read by the Copilot cloud agent
plus Codex, Cursor, Jules, Gemini CLI, and more, **nested + nearest-wins**.
`CLAUDE.md`, `.cursorrules`, `GEMINI.md` etc. are the older tool-specific files it
consolidates. Default to AGENTS.md for co-located instructions.

Mirror-image blind spots for *nested* files:

| Co-located file | Claude Code | Copilot cloud agent |
|---|---|---|
| nested `CLAUDE.md` | ✅ nearest-wins | ❌ (root only) |
| nested `AGENTS.md` | ❌ (reads `CLAUDE.md` only) | ✅ nearest-wins |

To make one set of co-located rules load in **both** agents: put the canonical
content in **`AGENTS.md`** and drop a one-line sibling **`CLAUDE.md`** that imports
it:

```
<dir>/AGENTS.md      # canonical content — Copilot reads (nearest-wins)
<dir>/CLAUDE.md      # one line:  @AGENTS.md   — Claude Code reads, expands the import
```

- The real content **must** be in `AGENTS.md`: Copilot does **not** expand
  Claude's `@path` imports, so the shim direction is fixed (`CLAUDE.md` →
  `AGENTS.md`, never the reverse). Add Claude-only lines under the import if needed.
- A symlink (`ln -s AGENTS.md CLAUDE.md`) also works but needs admin/Developer
  Mode on Windows — prefer the `@AGENTS.md` import.
- **Renaming trap:** both agents discover by *exact filename*. Renaming a nested
  `CLAUDE.md` → `AGENTS.md` silently drops it from Claude Code; a nested
  `CLAUDE.md` is invisible to Copilot. Keep **both** names, one as the shim.
- Verified against live docs: GitHub docs — AGENTS.md nested nearest-wins,
  `CLAUDE.md`/`GEMINI.md` root-only; Claude Code docs — *"Claude Code reads
  `CLAUDE.md`, not `AGENTS.md`"* and recommend the `@AGENTS.md` bridge.

**Prefer AGENTS.md+shim over `.github/instructions/*.instructions.md`** when you
want both tools *and* co-location. `*.instructions.md` is **Copilot-only**
(GitHub-specific, not cross-vendor); Claude's path-scoping equivalent is
`.claude/rules/*.md` with `paths:`. Reach for `.instructions.md` only as a
Copilot-specific add-on (globbed file-type scoping or code-review coverage), not
the primary layer.

## What the cloud agent does NOT read (common trap)

- **`.copilot/` at the repo root — not a skills directory.** Personal skills live at `~/.copilot/skills/` (home dir), not a repo-level `.copilot/`.
- **Skills are model-invoked, not guaranteed.** A skill loads only when the agent decides it's relevant. Hard guardrails ("never deploy to prod manually", "register in version-guide.json") must live in always-on `copilot-instructions.md`/`AGENTS.md`, not *only* in a skill.
- Org/enterprise instructions can apply too, but the per-repo files above are what you control here.

> This feature shipped Dec 18 2025 and is evolving. Re-verify directory list and
> surface support against live GitHub docs (`about-agent-skills`) before relying
> on edge cases — earlier docs/snapshots incorrectly stated `.github/skills/`
> was unread by the cloud agent.

## Audit (read-only first)

Run `scripts/audit.sh` from the repo root for an inventory of what exists, sizes,
and gaps. Then judge against the checklist below. (Execute it — only stdout hits
context.)

```
bash <this-skill>/scripts/audit.sh
```

Checklist — flag any that fail:

1. `.github/copilot-instructions.md` exists **and is ≤ ~2 pages** (~200 lines is already long; GitHub's own guidance is "no longer than 2 pages"). Over-long = top finding.
2. Instructions contain, concretely: **build/test/lint commands with tool versions**, **project layout**, **CI/CD details**, **environment/auth specifics**. Vague ("follow best practices") is the #1 failure mode across GitHub's 2,500-repo analysis.
3. Instructions say **"trust these instructions; only search if they're incomplete."** Reduces wasted exploration.
4. **Known errors + mitigations** are documented (error → cause → fix). The agent re-derives these expensively otherwise.
5. Monorepo or mixed stacks → **co-located `AGENTS.md` per area** (nested, nearest-wins) with a `CLAUDE.md`→`@AGENTS.md` shim, instead of one giant repo-wide file. (Nested `CLAUDE.md` alone is invisible to Copilot; `.github/instructions/*.instructions.md` is a Copilot-only add-on, not the cross-tool layer.)
6. Skills are in a location Copilot reads (`.github/skills/`, `.claude/skills/`, or `.agents/skills/`) — **leave the repo's existing convention as-is**; don't relocate or duplicate.
7. Always-on **guardrails are not left only in model-invoked skills** — critical "never do X" rules belong in `copilot-instructions.md`/`AGENTS.md`.
8. The agent can actually **build/test/lint in its environment** (deps installable, test command real). If the env can't validate, PR quality drops.
9. `AGENTS.md` present at root with build/test/validate commands + hard constraints (read natively by the cloud agent).

## Remediation workflow

Branch first (never commit to main). Then, in priority order:

1. **Slim the repo-wide file.** Move everything to the essentials: purpose, layout, build/test/lint, key constraints, "trust these instructions." Cut tutorials, exhaustive tables, and per-area detail — those go to step 2.
2. **Co-locate per-area rules in `AGENTS.md`** (canonical, nested + nearest-wins) with a one-line `CLAUDE.md` → `@AGENTS.md` shim beside each so both agents read them. This is the cross-tool standard (see section above). Put authoring rules, gotchas, and area error tables here; lift the always-apply guardrails so they don't live only in a model-invoked skill.
3. **Add/keep `AGENTS.md` at root** with build/test/validate commands and hard constraints (also nestable — nearest-wins).
4. **(Optional, Copilot-only) `.github/instructions/*.instructions.md`** with `applyTo:` globs — add only for Copilot code-review coverage or file-type globbing that AGENTS.md nesting can't express. Not the primary layer; don't duplicate AGENTS.md content into it.
5. **Leave existing skills where the repo keeps them** — Copilot reads `.github/skills/`, `.claude/skills/`, and `.agents/skills/`. Follow the repo's established convention; don't relocate or duplicate to chase another tool.
6. **Lift hard guardrails out of skills** into always-on `copilot-instructions.md`/`AGENTS.md` — skills are model-invoked and may not fire.
7. **MCP** (optional, heavier): only after instructions are solid. Configure via repo Settings UI; allowlist specific read-only tools, not wildcards (the agent uses MCP tools autonomously without per-call approval).

8. **Verify with a work-shaped smoke test, not a question.** A prompt phrased as a
   question ("which branch do I use for X?") gets answered from indexed context
   (memory, instruction summaries) with **zero file reads** — it proves nothing about
   whether instruction files load. Phrase the test as *beginning work* ("Begin work:
   add a new X — do your mandatory pre-work instruction loading, then state your
   first step") and observe the actual reads, e.g.
   `claude -p "<work-shaped prompt>" --output-format stream-json --verbose` piped
   through a filter on `tool_use` file paths. Run a negative test too (an
   out-of-scope task must NOT read the instruction files). Self-report ("I read
   the instructions") is not evidence; the tool-use stream is.

Templates (copy-paste, fill in): see [templates.md](templates.md) — repo-wide
file, a path-specific file with frontmatter, and `AGENTS.md`.

## Gotchas

- **`applyTo` frontmatter is YAML** in `.github/instructions/*.instructions.md`; the file extension must be `.instructions.md` exactly.
- **Skills vs instructions:** instructions are always-on context; skills are model-invoked (load only "when relevant"). Use instructions for guardrails that must always apply, skills for specialized repeatable procedures.
- The cloud agent **may still ignore instructions** intermittently (documented community complaint). Specificity and short files reduce it; don't assume 100% adherence — keep CI gates that fail bad PRs.
- Product was renamed "coding agent" → "cloud agent"; the `excludeAgent` value moved from `coding-agent` to `cloud-agent`. If using agent-specific instruction exclusion, verify the current value against live GitHub docs.
- The task prompt does **not** need to tell Copilot to read these files — they're auto-loaded. Prompt should carry the *task*, not the *environment*.

## References

- Source research synthesized into this skill (deep-research workflow, 22 primary sources incl. GitHub docs + the 2,500-repo `agents.md` analysis).
- Live docs to re-verify time-sensitive bits: docs.github.com → Copilot → customizing / coding-agent (instruction files, MCP).
