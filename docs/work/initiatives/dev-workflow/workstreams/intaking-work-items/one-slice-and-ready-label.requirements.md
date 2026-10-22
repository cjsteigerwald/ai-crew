---
id: dev-workflow-intake-one-slice-and-ready-label-requirements
type: requirements
status: draft
owner: dev-workflow
representation: canonical
canonical: docs/work/initiatives/dev-workflow/workstreams/intaking-work-items/one-slice-and-ready-label.requirements.md
---

# ai-crew-50: intake publishes without `ready-for-*`; one-slice work uses the spec issue

**Source:** [cjsteigerwald/ai-crew#50](https://github.com/cjsteigerwald/ai-crew/issues/50)
**Linked items:** `sdlc-process` 0.4.14 `bundle/.agents/skills/to-spec/SKILL.md:18` and `to-tickets/SKILL.md:62,76` (the `ready-for-agent` defaults): related context, upstream, read-only. `bundle/docs/work/agent-orchestration/process/orchestration.process.md:372` (ready label follows the readiness gate) and `bundle/.claude/skills/sdlc-process/SKILL.md:42` (to-tickets "when decomposition is needed"): related context. `dev-workflow/skills/setting-up-project-boards/templates/issue-tracker.md:54,55,71` (board lifecycle): related context. No equivalent, parent or dependency.
**Fetched:** 2026-10-22. Issue state `OPEN`, no labels, no comments, no cross-referenced PRs; sprint `none`, estimate `none`
**Intake by:** Christopher Steigerwald with the `dev-workflow:intaking-work-items` skill
**Status:** Ready. Step 3 (grilling) complete; no steps skipped. Doc path follows this repo's `docs/work/` convention instead of `docs/specs/<KEY>-requirements.md` (step 0: repo procedure wins).
**Chain:** sdlc-process

> Snapshot of the issue on the fetched date plus the decisions below. If the issue changes,
> re-run intake for the changed rows rather than editing this doc by memory.

## Story

As an agent running `dev-workflow:intaking-work-items` through the sdlc-process chain, I want
`chain-sdlc-process.md` to say that intake publishes spec and child issues without a `ready-for-*`
label, and that one-slice work uses the spec issue as its delivery issue, so that published issues
follow the readiness gate and the repo's board lifecycle, and one piece of work does not become two
board items and two handoffs.

## Scope

**In scope**
- `dev-workflow/skills/intaking-work-items/chain-sdlc-process.md`, stage 4: the label override (to-spec and to-tickets) and the one-slice rule; stage 5 and the Controls section only where the one-slice rule must be cross-referenced.
- `dev-workflow/skills/intaking-work-items/SKILL.md`: at most a one-line mention of the one-slice record in step 1's **Resume status** list.
- `dev-workflow/tests/run.sh`: one assertion per AC-1 and AC-2; the pinned version assertion (`run.sh:900-916`) updated in place.
- dev-workflow version 0.2.4 → 0.2.5 in `dev-workflow/.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json`.

**Out of scope**
- Upstream `sdlc-process` (sidkik-plugins) sources: this repo only consumes them (decision 5).
- `dev-workflow/skills/setting-up-project-boards/templates/*`: the lifecycle there is already right (decision 5).
- Wayfinder publications (map and child tickets) (decision 5).

## Requirements

### Functional
- **FR-1** At stage 4, intake publishes the spec issue and every to-tickets child issue without a `ready-for-*` label, in the repo's refining state where its tracker doc defines one, otherwise with no triage label. Only the readiness gate applies `ready-for-*`. This overrides the label defaults of `sdlc-process:to-spec` and `sdlc-process:to-tickets`, in every repo (decisions 1, 2).
- **FR-2** When to-tickets' proposed breakdown has one slice, intake publishes no child issue; the spec issue is the delivery issue. Chain artifacts record `tickets: none — one slice`. This is not the plan-skip rule: no skip warning and no "Intake: plan skipped" line. The AC coverage check runs against the spec issue; on Full tier the plan pass runs on the spec issue alone; stage 5 takes the "One ticket, or no decomposition" route (decision 3).
- **FR-3** A one-slice delivery issue has no children, so the board's "parent carries no `ready-for-*`" rule does not apply to it; it gets `ready-for-*` through the readiness gate like any delivery issue (derived from decisions 1 and 3, confirmed with the AC on 2026-10-22).

### Non-functional
- **NFR-1** None beyond current behaviour (decision 8).

## Acceptance criteria

Each AC is testable as written and names how it is verified. Plans and PRs cite these numbers.

- **AC-1** (FR-1) Given intake reaches stage 4, when it reads `chain-sdlc-process.md`, then the doc states that the spec issue and any to-tickets child issues are published without a `ready-for-*` label (in the repo's refining state where its tracker doc defines one), and names the readiness gate as the only path to `ready-for-*`, overriding to-spec's and to-tickets' label defaults.
  *Verify:* `run.sh` assertion "AC-1" greps the rule's stable phrase in `chain-sdlc-process.md`; reviewer reads stage 4.
- **AC-2** (FR-2, FR-3) Given to-tickets' proposed breakdown has one slice, when intake is at stage 4, then the chain doc tells it to publish no child issue, to use the spec issue as the delivery issue, to record `tickets: none — one slice` in Chain artifacts (not as a plan-skip, no "Intake: plan skipped"), to check AC coverage against the spec issue, and to take stage 5's "One ticket, or no decomposition" route.
  *Verify:* `run.sh` assertion "AC-2" greps the rule's stable phrase; reviewer reads stage 4, stage 5 and Controls.
- **AC-3** (FR-1, FR-2) `bash dev-workflow/tests/run.sh` exits 0 and includes one assertion each for AC-1 and AC-2, named by AC number; deleting either rule's phrase from the chain doc makes it fail.
  *Verify:* run the suite (exit 0); delete each phrase in a scratch copy and rerun (non-zero, the AC's failure line).
- **AC-4** (DoD) dev-workflow is 0.2.5 in `dev-workflow/.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json`; the pinned assertion at `run.sh:906` is updated to 0.2.5 and run.sh passes.
  *Verify:* `run.sh` version assertion; `grep -n '"version"'` on both files.

## Definition of done

- [ ] AC-1 to AC-4 verified with recorded evidence
- [ ] Full-tier review: plan pass and diff pass (fresh-verifier + codex-adversary)
- [ ] Draft PR opened with `Refs cjsteigerwald/ai-crew#50` (no closing keyword; the user closes the issue at close-out, decision 6)

## Dependencies and gates

| Item | Kind | State on fetched date |
|---|---|---|
| None — no upstream ticket, approval or repo gate | — | — |

## Test plan

| AC | Kind | Seam | Catches / misses | Test name | Location |
|---|---|---|---|---|---|
| AC-1 | unit (doc assertion), agent-verifiable | `chain-sdlc-process.md` text | catches the rule's removal / misses wording that is present but unclear (review covers) | `AC-1 chain doc: publish without ready-for-*, readiness gate only` | `dev-workflow/tests/run.sh` |
| AC-2 | unit (doc assertion), agent-verifiable | `chain-sdlc-process.md` text | catches the rule's removal / misses a contradicting sentence elsewhere (review covers) | `AC-2 chain doc: one slice, spec issue is the delivery issue` | `dev-workflow/tests/run.sh` |
| AC-3 | unit (suite run + mutation), agent-verifiable | `run.sh` exit code | catches assertions that cannot fail / misses nothing in scope | suite run + phrase-deletion check | `dev-workflow/tests/run.sh` |
| AC-4 | unit (manifest assertion), agent-verifiable | `plugin.json`, `marketplace.json` | catches a missed manifest / misses nothing in scope | existing version assertion, updated | `dev-workflow/tests/run.sh:900-916` |

Repo-wide checks: `bash dev-workflow/tests/run.sh`.

## Verification evidence

None — step 7 not run.

## Run log

| Time | Step | Event | Attempt | Blocker |
|---|---|---|---|---|
| 17:20 | 1 | Fetched cjsteigerwald/ai-crew#50; verified its citations | 1 | — |
| 17:30 | 2 | Gap table: rows 3, 5, 8, 10 Missing; 4, 6, 9, 13 Vague (C1, C2) | 1 | — |
| 17:40 | 3 | sdlc-process entry + orchestrator loaded; grill-with-docs (grilling, domain-modeling); round 1 accepted; AC agreed | 1 | — |
| 17:44 | 6.1 | Work branch `feat/intake-one-slice-ready-label`; review base `c23c119` (merge-base with origin/main) | 1 | — |
| 17:46 | 5 | Writeback: comment posted on cjsteigarwald/ai-crew#50 (issuecomment-6353836654), read back | 1 | — |
| 17:47 | 6.1 | `review-ledger.sh link branch:feat/intake-one-slice-ready-label plan:ai-crew-50` → 0 rows | 1 | — |
| 17:48 | 6.4 | User chose "Skip both" to-spec and to-tickets: #50 + this doc are the spec, one slice. Intake: plan skipped; no spec issue. Plan pass runs on this doc | 1 | — |

## Risks

- An agent on a repo without board docs publishes unlabelled issues — none beyond waiting for the readiness gate, which applies the label — no mitigation needed.
- Prose-only change to a skill — wrong wording misleads later intakes — Full-tier review; rollback is a revert.

## Decision log

| # | Question | Answer | Who / date |
|---|---|---|---|
| 1 | Contradiction C1: "published without a `ready-for-*` label" unconditional (issue AC-1) vs "the repo's issue-tracker doc wins over to-spec's label default" (issue Suggested fix 1) | Unconditional: intake never applies `ready-for-*` at publication; refining state where the tracker doc defines one, else no label | Christopher Steigerwald, 2026-10-22 |
| 2 | Does the override also cover to-tickets' children (`to-tickets/SKILL.md:62,76`)? | Yes; AC-1 widened | Christopher Steigerwald, 2026-10-22 |
| 3 | How is one slice detected; is it a plan-skip? | to-tickets runs its breakdown; one slice → no child published, spec issue is delivery issue, recorded `tickets: none — one slice`, not a plan-skip | Christopher Steigerwald, 2026-10-22 |
| 4 | Contradiction C2: issue AC-2 "stage 5" vs to-tickets at stage 4 (`chain-sdlc-process.md:94`) | Stage 4 | Christopher Steigerwald, 2026-10-22 |
| 5 | Out of scope | Upstream sdlc-process, board templates, wayfinder publications; intake SKILL.md only for a one-line Resume-status mention | Christopher Steigerwald, 2026-10-22 |
| 6 | Definition of done | Patch bump 0.2.5 with the run.sh assertion updated; draft PR with `Refs` | Christopher Steigerwald, 2026-10-22 |
| 7 | Tests | One mandatory run.sh assertion per AC-1, AC-2, named by AC | Christopher Steigerwald, 2026-10-22 |
| 8 | NFR and risks | None beyond current; low risk, revert to roll back | Christopher Steigerwald, 2026-10-22 |
| 9 | Settled AC-1 to AC-4 | "agree" | Christopher Steigerwald, 2026-10-22 |

## Deferred and out-of-scope items

| Item | Status | Source | User's words | Gap left open | Follow-up |
|---|---|---|---|---|---|
| Upstream sdlc-process label defaults | out of scope | decision 5 | "accept" | to-spec/to-tickets still default to `ready-for-agent` outside intake | none |
| Board templates, wayfinder publications | out of scope | decision 5 | "accept" | none | none |

## Gap table at skip

None — step 3 completed.

## Chain artifacts

- Wayfinding: none
- `CONTEXT.md` / ADR changes: none (no term or hard-to-reverse decision settled)
- Work branch: `feat/intake-one-slice-ready-label`; review base `c23c119`
- Review tier: Full (skill definition change)
- Spec issue: none — `to-spec` skipped (user, 2026-10-22)
- Tickets: none — `to-tickets` skipped (user, 2026-10-22); Intake: plan skipped. Owning issue: cjsteigarwald/ai-crew#50
- Writeback: cjsteigarwald/ai-crew#50 issuecomment-6353836654
- **Last completed stage:** 6.4 (plan stage skipped)
