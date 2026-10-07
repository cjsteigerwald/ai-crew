# intaking-work-items: choose the superpowers or mattpocock chain — design

- **Date:** 2026-10-07
- **Skill:** `dev-workflow/skills/intaking-work-items/`
- **Status:** Approved design, pending implementation plan

## Problem

Step 6 of `intaking-work-items` hard-wires one downstream chain: `superpowers:brainstorming` →
`superpowers:writing-plans` → `dev-workflow:plan-implementation` → `dev-workflow:opening-pull-requests`.
Users who work with the `mattpocock-skills` plugin — whose planning output is GitHub issues
(`to-spec` publishes one spec issue, `to-tickets` publishes child ticket issues) rather than a local
plan file — cannot use intake with that family.

## Goal

Let the user pick, per ticket, either the superpowers chain or the mattpocock chain for the
design → plan → implement stages, with intake driving whichever is chosen. Steps 0–5 and the
shared PR stage are identical for both.

## Facts this design relies on (verified 2026-10-07)

- `mattpocock-skills` 1.2.3 marks `to-spec`, `to-tickets`, `implement`, `implement-spec`,
  `grill-with-docs`, `wayfinder`, `triage` and `setup-matt-pocock-skills` with
  `disable-model-invocation: true` (frontmatter line 4 of each `SKILL.md`).
- Claude cannot launch them: a `Skill` call to `mattpocock-skills:to-spec` returns
  "cannot be used with Skill tool due to disable-model-invocation. Ask the user to run
  /mattpocock-skills:to-spec themselves … Do not replicate this skill's workflow by other means".
  No `settings.json` key re-enables model invocation (code.claude.com/docs/en/skills.md,
  "Control who invokes a skill").
- `to-spec` publishes exactly one issue to the configured tracker with the `ready-for-agent` label,
  after checking test seams with the user (`to-spec/SKILL.md` steps 2–3).
- `to-tickets` presents a breakdown for approval, then publishes child tickets with blocking edges
  to the configured tracker (`to-tickets/SKILL.md` §5).
- `implement` builds from a spec or tickets, using `tdd` at agreed seams, then `/code-review`, and
  commits to the branch.
- The tracker is configured by `setup-matt-pocock-skills` in `docs/agents/issue-tracker.md`.

## Decisions

| # | Decision | Chosen |
|---|---|---|
| D1 | Which steps switch with the family | **Step 6 only.** Steps 0–5 and the controls are unchanged. |
| D2 | Where mattpocock planning output lives | **GitHub issues** (the user's choice). |
| D3 | How Claude runs user-only mattpocock skills | **The user types each command.** Intake stops at the checkpoint and names the exact command. Typing it is the user's confirmation for the issues that command creates. |
| D4 | Spec issue | **GitHub ticket → no `to-spec`**; the existing issue is the spec. **Jira ticket → user runs `/mattpocock-skills:to-spec`** to create one GitHub spec issue citing the Jira key. |
| D5 | When the family is chosen | **At the start of step 6**, with a default: mattpocock when `docs/agents/issue-tracker.md` exists in the target repo, otherwise superpowers. |
| D6 | Implement and PR on the mattpocock path | **`/mattpocock-skills:implement`**, then intake's shared `dev-workflow:opening-pull-requests` stage. `implement-spec` is not used. |

## Design

### Step 6 becomes a fork

`SKILL.md` step 6 keeps only: the chain choice, the shared checkpoint rules (go / Skip / cancel
between every stage), the shared **settled AC list** rule (plans and tickets cover only active AC;
deferred, skipped and out-of-scope AC are listed as not delivered), and the shared ship stage. Each
family's stage-by-stage detail moves to its own file, read only when that family is chosen:

- `chain-superpowers.md` — today's step 6 stages 1–3 (brainstorming, writing-plans or the bounded
  task list, plan-implementation), moved verbatim except for references back to SKILL.md.
- `chain-mattpocock.md` — the new path below.

### Choosing the chain (start of step 6)

1. Check the target repo for `docs/agents/issue-tracker.md`. Present → recommend mattpocock;
   absent → recommend superpowers.
2. Ask once (`AskUserQuestion`): superpowers / mattpocock / Skip / cancel, recommended first.
3. If mattpocock is chosen:
   - **Not set up** (no `docs/agents/issue-tracker.md`): tell the user to run
     `/mattpocock-skills:setup-matt-pocock-skills` and wait.
   - **Repo rules forbid issues now** (a step-0 rule such as "no GitHub issue until the Jira ticket
     is in a sprint"): say the mattpocock path is unavailable for this ticket and offer superpowers.
     A step-0 override follows **Controls**' second-confirmation rule.
4. Record the choice in the requirements doc's new `Chain:` field.

### The mattpocock path

Each stage: intake prints the exact command and the context to give it, stops, and resumes when the
user reports back. Intake never runs these skills' workflows itself.

1. **Spec.**
   - *GitHub ticket:* no `to-spec`. Offer, as a confirmed step-5-style writeback, a comment on the
     issue carrying or linking the requirements doc. The issue is the spec.
   - *Jira ticket:* user runs `/mattpocock-skills:to-spec`. Intake first states what the spec must
     carry: the requirements doc path, the Jira key and link, and that its user stories and
     out-of-scope must match the settled AC list. After it publishes, intake reads the issue back
     (`gh issue view`) and records it as the spec issue. Offer, as a confirmed writeback, a Jira
     remote link to it.
2. **Tickets — the plan stage.** User runs `/mattpocock-skills:to-tickets`. Intake first states the
   constraints: every ticket cites the `AC-n` it satisfies and links the spec issue as its parent;
   only active AC get tickets. After publishing, intake lists the tickets (`gh issue list` / `gh
   issue view`) and checks coverage: every active AC is cited by at least one ticket, and no ticket
   cites a deferred, skipped or out-of-scope AC. Gaps go back to the user before implementation.
   The ticket list is recorded in the requirements doc.
3. **Implement.** User runs `/mattpocock-skills:implement`, pointed at the spec issue and its
   tickets. Its `tdd` seam confirmation and `/code-review` run as that skill defines.
4. **Ship** — shared stage (below).

### Shared ship stage

Unchanged `opening-pull-requests` hand-off. On the mattpocock path the PR body additionally lists the
ticket issues it delivers (`Refs owner/repo#N` each; closing keywords only where the repo allows),
and the spec issue.

### Controls on the mattpocock path

- **Skip** at a stage checkpoint follows the existing whole-step skip rules (warn once, record,
  continue). Skipping `to-tickets` is the plan-skip rule: explicit go-ahead, implement against the
  settled AC list, PR body states "Intake: plan skipped".
- **Cancel:** intake stops and does not prompt the user to type any further command. Issues already
  created by commands the user ran are reported, not deleted.
- **Resume:** the requirements doc records `Chain:` and the last completed stage (spec issue,
  ticket list), so resume restarts at the first incomplete stage after the usual refetch-and-diff.

### Template change

`template.md` gains, near Status: `Chain: superpowers | mattpocock | — (not yet chosen)`, and a
**Chain artifacts** section: design doc / plan path (superpowers) or spec issue and ticket issues
(mattpocock).

### SKILL.md other edits

- Description: mention the chain choice.
- Step 0's "Intake never creates an issue or ticket on its own" stays true and gains one clause: on
  the mattpocock path, issues are created only by commands the user types.
- Step 5 stays limited to the primary item and confirmed equivalents; the spec-issue comment and
  Jira remote link in the mattpocock path are offered under step 5's per-action confirmation rule.

## Out of scope

- `implement-spec`, `wayfinder`, `grilling`, and `wizard` integration.
- Making mattpocock skills model-invocable (patching or vendoring the plugin).
- Steps 0–5 behavior, and the broader trimming of the Controls section.

## Verification

- `grep` checks: no stale references to "step 6 stage N" in SKILL.md that now live in a chain file;
  every chain file is linked from SKILL.md; `Chain:` appears in template.md.
- Superpowers path text is moved, not rewritten: diff of the moved block against `origin/main` shows
  only reference adjustments.
- Full-tier review: `dev-workflow:fresh-verifier` and `dev-workflow:codex-adversary` on the diff.
