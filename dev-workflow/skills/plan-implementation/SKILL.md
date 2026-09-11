---
name: plan-implementation
description: >
  Orchestrated implementation of an approved plan through tiered worker lanes —
  no manual delegation prompts needed. Use when: the user green-lights a
  multi-step plan in ANY form — explicit ("implement it", "execute the plan",
  "build it") OR a bare affirmative in response to a proposed plan ("yes",
  "yeah", "go for it", "do it", "sounds good", plan-mode approval). What
  matters is the situation (a plan exists and the user just approved it), not
  the exact words. The orchestrator decomposes the plan, routes each task by
  shape to a worker lane (read lanes for locate/digest work, tiered writer lanes
  for implementation), does interdependent work itself, and verifies every
  delegated task deterministically plus by its own diff inspection. Lanes are
  named by role so the skill ports to projects with different agents.
  NOT for: single-file trivial edits, doc-only plans, investigations/RCA (no
  code to implement), or exploratory work with no approved plan.
---

# Plan Implementation (Orchestrated)

You are the orchestrator. The user has approved a plan; your job is to execute it through the worker loop without asking the user to spell out delegation. Do not ask "should I use code-writer?" — apply the routing rules below automatically.

## 1. Decompose and route

Break the plan into tasks, then route each by shape:

| Task shape | Route |
|---|---|
| Independent, well-scoped, mechanically verifiable (per-file edits, scripted fixes, config/doc generation, test authoring) | Delegate to a **worker lane** (below) — in parallel when tasks don't share files |
| Interdependent, design-heavy, or cross-cutting (the coherent core of a feature) | **Implement directly yourself** — evidence says a strong model solo beats delegation here |
| Trivial (one small edit) | Just do it — no delegation |
| Read-shaped (digest these files, locate every call site, inventory configs) | Delegate to a **cheap read lane** (below) — never grind through it inline |

Each route decision is **stated as a one-line classification before the first edit**
("independent/mechanical → dispatching <lane>" / "cohesive/interdependent → solo:
<reason>") — this is the write-side delegate-or-justify rule, canonical wherever your
own global instructions live, so it applies in every session, plan-driven or not. The
stated lines are the audit trail for delegation-rate measurement. Terraform scope: lanes
may **author** `.tf`/`.tfvars` files but never run any terraform CLI command — the
orchestrator runs those under the applicable approval policy.

### Worker lanes

Lane selection happens **only after** §1 has already classified a task as delegable. A
lane's description never re-opens that decision: if §1 routed the work to you because it
is interdependent, design-heavy, or cross-cutting, no lane applies — including the Opus
lane, whose "correctness-critical" wording describes difficulty *within* one bounded
task, not cross-cutting scope.

Every dispatch **names its lane with a one-line justification** — lane choice stays visible and vetoable in the transcript. No silent lane substitution: if a lane is unavailable or fails, choosing a different one is an explicit decision, stated in the open. For fan-out, prefer the Haiku lane; single hard tasks can take the Opus lane when quality demands it.

**Minimum granularity.** Every dispatch costs a spec, a returned report, and your own diff
inspection — roughly `prompt + report + diff` back in your context regardless of task size.
Below that floor, delegation loses: batch several tiny same-shaped edits into ONE
recipe-shaped dispatch rather than one worker per file. Delegation buys you the worker's
reasoning and exploration, never the need to read the resulting artifact.

Lanes are listed by **role** first — the role is what the routing rule means, the agent
name is this workspace's binding. Another project substitutes its own agents per role
(see § Adapting this skill).

The tiered read/write lanes below (`claude-scout`, `claude-reader`, `claude-implementer-*`)
come from the separate `claude-crew` plugin — invoke them with the `claude-crew:` prefix
(e.g. `claude-crew:claude-implementer-sonnet`). `code-writer`, `fresh-verifier`, and
`codex-adversary` ship in **this** plugin (`dev-workflow`) — invoke them with the
`dev-workflow:` prefix (e.g. `dev-workflow:code-writer`).

| Role | Lane here | Choose when |
|---|---|---|
| Cheap read — locate | `claude-crew:claude-scout` | Find where something lives, enumerate matches, inventory files. Returns locations, not file dumps |
| Cheap read — digest | `claude-crew:claude-reader` | Compress named material (logs, docs, many configs) into a structured digest |
| Convention-aware writer | `dev-workflow:code-writer` | The task needs repo/session conventions or judgment beyond the written spec; **the default when in doubt**, and the fallback when no tiered lanes are installed |
| Cheapest writer | `claude-crew:claude-implementer-haiku` | Mechanical, exact-recipe chores. Fan out freely across **already-batched, disjoint** units that clear the minimum-granularity floor below — not one worker per trivial edit |
| Mid-tier writer | `claude-crew:claude-implementer-sonnet` | Routine, well-specified implementation with clear spec and existing patterns |
| Frontier writer | `claude-crew:claude-implementer-opus` | Intricate logic or correctness-critical work **within one already-delegable task** — gnarly debugging, anything where mid-tier output would need rework (costliest; never burn it on routine work) |

**Capability resolution — one ordered rule for every route.** Resolve a role to a concrete
agent by taking the first option that exists:

1. **The mapped agent for that role** in the table above.
2. **A platform equivalent** — Claude Code ships `Explore` and `general-purpose` (read-capable);
   `dev-workflow:code-writer` covers any writer role when the tiered lanes are absent.
3. **Do it inline yourself.** This is the only case where §1's "never grind through it
   inline" yields — a rule with no reachable target is worse than an honest exception.
   Say so in the classification line rather than silently absorbing the work.

The tiered read/write lanes ship in the separate `claude-crew` plugin. Without it,
**writer** routes resolve to `dev-workflow:code-writer` at step 2 — read routes do not,
because `code-writer` is a writer; they resolve to a platform read agent or step 3.

The read lanes are here so this skill routes every task shape a plan can contain without
depending on an external instruction file. A session-wide trigger for ad-hoc reading
(delegate before the third consecutive manual search) is a separate, complementary rule —
keep it wherever your own global or workspace instructions live.

**Codex implementer lanes** (from the separate `codex-crew` plugin, e.g. `codex-implementer-luna`/
`-terra`/`-sol`) are deliberately off this table by default. Two invariants bind every
write-enabled Codex job, pilot or otherwise — they are safety rules, not history:

1. **User approves each dispatch.** The orchestrator may PROPOSE a mechanical-fan-out or
   routine-well-specified Codex implementer lane; outside that proposal mechanism a Codex
   implementer needs an explicit user request. Either way the lane is declared in the dispatch.
2. **A dedicated git worktree, always** — created before dispatch, validated, removed after.
   There is no real-checkout alternative, and at most ONE write-enabled Codex job runs per
   repository at a time.

Rationale, pilot terms, and reversal criteria live in your own project's review-governance
docs, if you keep them. Codex participation is primarily review-side (`codex-adversary`),
where cross-model independence is actually exercised.

### Concurrency caveat

Lane-table workers are native subagents and can use the Agent tool's `isolation: "worktree"` —
use it only when parallel workers must touch the same files, since each worktree costs setup
time and disk. Codex implementer jobs write outside that mechanism and always get their own
worktree per the invariant above: a second concurrent writer in a repo is a second agent.

## 2. Delegation prompts are specs

Every dispatch must contain: objective, exact files in scope, expected output format, explicit boundaries (what NOT to touch), and the **verification command** (default for Python: `ruff check <files>` + targeted `pytest`). A worker prompt missing any of these produces collisions and rework.

**Test-authoring mandate:** if the task adds or changes public behavior, the spec REQUIRES the worker to author tests for it — or the orchestrator states in the dispatch (visibly) why tests are not applicable. An implementation task without either is an incomplete spec. The same rule binds the orchestrator's own solo implementations via the delegate-or-justify classification.

## 3. Verify delegated work

For each delegated task:

1. **Deterministic first** — confirm the worker's verification evidence is real (it must include actual command output). Re-run cheap checks yourself if in doubt.
2. **Inspect the diff yourself** against the spec — requirement by requirement. You dispatched the work, so stay skeptical: hunt for silently dropped requirements, scope creep, and report claims with no corresponding code. This inspection gates task acceptance; the **cold, unbiased pass** happens at pre-PR time (`dev-workflow:fresh-verifier` + `dev-workflow:codex-adversary`, per this plugin's README § Review policy) — the worker loop does not replace it.
   ⚠️ **There is no shortcut here — read the hunks.** A tempting substitute for large
   mechanical fan-outs is a deterministic assertion that the transformation happened,
   skipping the diff. Two successive attempts to make that safe both failed review:
   proving the intended change occurred says nothing about what *else* changed, and
   `git diff` variants see only part of the picture — untracked files, staged content,
   mode changes, pure renames, and binaries all produce an empty filter result while a
   dropped auth flag or an unrelated edit ships. Making it sound requires a task-start
   baseline, `git status --porcelain=v2 --untracked-files=all`, staged-and-unstaged
   comparison, and paired before/after line matching — more machinery, and more ways to
   be wrong, than reading the patch. Read the patch.

3. **Escalation** (fixed rules, don't improvise):
   - Deterministic check fails twice on the same issue → take over the task yourself.
   - One respec-and-retry round per task; a second failed round → take over.
   - Your inspection and the worker's report disagree → trust the code, not the report.

## 4. Close the loop

When all plan items are done:

1. Run the repo's quality gates (`ruff check` + `pytest` where Python changed) — a Stop hook may enforce this too, but don't rely on it as the first line.
2. Report per-task status with evidence (lane, verification output) — audit every progress claim against a tool result from this session; never report unverified work as done.
3. Apply the tiered review policy (this plugin's README § Review policy) before any `gh pr create` — the worker loop does not replace the pre-PR chain.
4. Run `skill-retrospective` in CAPTURE mode if the implementation surfaced non-obvious learnings.

## Adapting this skill to another project

This skill is portable; the names in it are not. Everything below is a **local binding** —
substitute your own and the routing logic is unchanged. Nothing here is required for the
skill's rules to work; a project with none of it still gets decompose → route → spec →
verify → close.

**Agents.** Map each *role* in the lane table to whatever you have. A project with a single
generic worker collapses all four writer rows onto it and loses only cost tiering, not
correctness. With no worker agents at all, every route becomes "do it yourself" and the
skill degrades to a decomposition and verification checklist — still useful.

**Review chain.** This workspace runs a cold-context verifier plus an adversarial
cross-model pass before a PR. Substitute your own gate, or drop §4 step 3 if you have
none — but keep the principle: *the worker loop is not a review*. The orchestrator
inspecting a diff it commissioned is not an independent check.

**Verification commands.** §2 names `ruff check` + `pytest` because this workspace is
Python. Replace with your stack's linter and test runner. What must not change is that
every dispatch carries **some** deterministic command the worker has to run and report.

**Workspace-specific pointers.** Any reference to your own project's review-governance
sections, orchestration docs, or global instructions file is a **local binding** —
substitute your own or drop the reference on adoption. Likewise the `skill-retrospective`
and `session-handoff` skills, and the whole Codex-lane block, which describes a plugin
you may not have installed.

**What is NOT optional** — the parts that carry the value:
decompose-and-classify-before-editing; a stated classification per task; specs that name
objective, scope, boundaries, and a verification command; deterministic verification before
diff inspection; fixed escalation rules; and the batching floor.

## Notes

- Follow the repo's branching rules: feature branch first, prompt before commit/push/PR.
- **Check context at task boundaries.** Plan execution is where sessions grow large, and a
  parked session's re-warm costs `context x input x 2` — ~$4 at 200K, ~$18 at 900K, derived
  from the model's per-MTok input price (re-derive before reusing; the figure moves with
  pricing). Past ~400K, finish the current item before starting the next, and invoke
  `session-handoff` **if a break over an hour is likely**. An uninterrupted run keeps its
  cache warm at any size, so do not hand off mid-flow; the task boundary is when to
  *check*, not to stop.
- Long plans (multi-session): keep a progress checklist in the plan file or task list — one item at a time, commit per completed item, so any session can resume from git log + checklist.
