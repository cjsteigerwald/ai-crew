---
name: skill-retrospective
description: >
  Capture-and-consolidate loop that keeps the skill library and repo overlays
  self-improving. Two modes: CAPTURE (after a substantial task — route each
  non-obvious learning to its one canonical home: durable repo-scoped rules go
  to a per-repo overlay file in your workspace as a move-with-pointer, reusable
  procedures to the matching skill or a new one, volatile
  state to memory) and
  CONSOLIDATE (scheduled maintenance — merge duplicates, prune stale content,
  rewrite descriptions so auto-triggering stays accurate). Use when: a task
  ends with a correction, a discovered gotcha, a command that finally worked,
  or a wrong assumption fixed; or when asked to "consolidate skills",
  "skill maintenance", "retrospective". NOT for: facts the repo/git history
  already records, or one-off session details with no reusable lesson
  (those stay plain memory entries, not a capture run).
---

# Skill Retrospective

Skills only compound in value if they are both **fed** (capture) and **pruned** (consolidate). Capture without consolidation produces bloated skills that stop triggering correctly; consolidation without capture starves the library. Run both.

## Mode 1: CAPTURE (post-task)

Run at the end of any substantial task — especially after a correction from the user, a failed-then-fixed approach, or a discovery that cost real time.

### What qualifies as a learning

- A command/flag/API pattern that works where the obvious one fails (e.g. "metric_events `event_type` must be ERROR/RESOURCE — unknown values are silently coerced")
- A gotcha that will bite the next agent (silent failures, misleading defaults, auth traps)
- A corrected assumption ("X does not work the way the docs imply; do Y")
- A confirmed workflow the user approved after iteration

### What does NOT qualify

- Anything derivable from the code, git history, or existing docs
- Session-specific state (branch names, in-flight ticket status) — that's memory, not a skill
- Style preferences already in the project's own instructions file(s)

### Procedure

1. List candidate learnings from the task. For each, ask: "would the next agent, in a fresh session, get this wrong without it?" Drop any 'no'.
2. **Freshness-check every memory-derived fact before writing it anywhere durable** (skill, overlay, doc). Memory self-contradicts: an index line can prescribe a convention that a newer `project_*.md` file already records as retired — and a stale index line gets recalled and answered from *before* any mandated file read happens, so "it traces to memory" is not verification. Check newer memories on the same topic AND the live source (git branch dates, current file contents) first.
3. **Route each surviving learning by kind** (one home per fact — never two full copies):
   - **Volatile** (in-flight state, prod-drift, anything a merge/apply invalidates) → memory only. Never promote.
   - **Durable + repo-scoped** (a rule, landmine, or auth pattern tied to one sibling repo) → a per-repo overlay file in your workspace (if you keep one) is the canonical home. Create the overlay if it doesn't exist — but only with real content, never an empty stub. Then **shrink the memory side to a trace**: the per-repo memory section keeps a one-line headline + overlay pointer (this is what answers question-shaped asks, which are served from the index without file reads); delete the underlying fact file if the overlay fully absorbs it, keep it only when it holds depth a short overlay can't.
   - **Reusable procedure** (a workflow any repo could invoke) → a skill; continue with the steps below.
4. Find the owning skill: `grep -ril "<topic keyword>" .claude/skills/*/SKILL.md`. Prefer **updating an existing skill** over creating a new one.
5. If updating: place the learning in the relevant section (not appended to the bottom as a changelog), written as an instruction, not a war story. One learning = one tight paragraph or table row.
6. If no skill owns the topic and the learning generalizes: invoke a skill-scaffolding helper if your workspace has one; otherwise scaffold by hand — directory under `.claude/skills/<kebab-name>/`, `SKILL.md` with `name` + trigger-rich `description` frontmatter (block scalar if it embeds examples), body ≤ ~300 lines with depth split into `references/`.
7. If the learning changes **when** the skill applies, update the frontmatter `description` too — the description is the trigger; content the description doesn't advertise is unreachable.

## Mode 2: CONSOLIDATE (scheduled maintenance)

Run periodically (weekly `/schedule` routine or headless cron: `claude -p "Run the skill-retrospective skill in CONSOLIDATE mode" --permission-mode acceptEdits`).

### Procedure

1. Inventory: for every `.claude/skills/*/SKILL.md`, read frontmatter + skim the body.
2. **Dedupe**: find overlapping content across skills. Move each fact to its single best home; leave a wikilink cross-reference naming the owning skill if the other skill genuinely needs the pointer.
3. **Prune**: delete content that is now wrong, refers to retired systems, or duplicates what the project's own instructions files or docs already say. When unsure whether something is stale, verify against the repo before deleting — flag rather than silently drop if unverifiable.
4. **Re-align descriptions**: for each skill, check that the `description` still matches the body's actual coverage and trigger conditions. Rewrite descriptions that have drifted — include positive triggers AND "NOT for" exclusions (see `plan-implementation` for the house style).
5. **Report**: end with a summary table — skill, action taken (merged/pruned/description-updated/untouched), one-line reason.

### Guardrails

- Consolidation commits go on a branch with a PR — never direct to main. Skill edits are code review material like anything else.
- Never delete an entire skill without listing it in the report with justification.
- **Enforce progressive disclosure**: if a SKILL.md exceeds ~300 lines, split reference material into a `references/` directory (or sibling files) and link them — the SKILL.md keeps triggers, routing, and the load-bearing rules; depth loads on demand.
- **Enforce composition over duplication**: when two skills need the same pattern, one skill owns it and the other says "MUST invoke" the owning skill by its wikilink (a generator skill referencing a governance skill is the model). Wiring/generator skills reference governance skills; they never copy their rules inline.
- **Vendored skills are re-synced, not edited**: skills marked as vendored in `.claude/skills/README.md` get upstream re-syncs; repo-specific adaptations live in the owning native skill or the README, never as local edits to vendored files.
