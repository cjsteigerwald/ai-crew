---
id: dev-workflow-pr-body-template-requirements
type: requirements
status: draft
owner: dev-workflow
representation: canonical
canonical: docs/work/initiatives/dev-workflow/workstreams/opening-pull-requests/pr-body-template.requirements.md
---

# pr-body-template: Incorporate mattpocock-skills `pr` into `opening-pull-requests`

**Source:** [cjsteigerwald/ai-crew#46](https://github.com/cjsteigerwald/ai-crew/issues/46) — spec issue published 2026-10-22 on the user's later instruction "Create github issue, then implement" (initially: "there is currently no ticket (don't create one)"). Request text: "incorporate skill mattpocock-skills-pr into skills/opening-pull-requests".
**Linked items:** `mattpocock-skills` 1.3.1 `skills/engineering/pr/` (SKILL.md, CREDITS.md, MIT LICENSE) — related context, the content being adapted; `dev-workflow/skills/implement-spec/` — related context, precedent for an adapted Pocock skill with its MIT LICENSE.
**Fetched:** 2026-10-22 — ticket status `n/a`, sprint `none`, estimate `none`
**Intake by:** Christopher Steigerwald with the `dev-workflow:intaking-work-items` skill
**Status:** Ready — step 4 (requirements doc) written; awaiting user OK. No steps skipped.
**Chain:** sdlc-process

> Snapshot of the request on the fetched date plus the decisions below. If the scope changes,
> re-run intake for the changed rows rather than editing this doc by memory.

## Story

As an agent (and the human reviewing its work) shipping through `dev-workflow:opening-pull-requests`,
I want a defined PR-body template that leads with the smallest useful visual, shows before/after
evidence and states merge danger, so that PR bodies are consistent, fast to review, and make merge
risk (one-way/two-way door and blast radius) explicit.

## Scope

**In scope**
- New `dev-workflow/skills/opening-pull-requests/pr-body.md`: Pocock's `pr` template and Summary visuals menu, adapted to this skill's gates and to every PR-body item intake step 8 and gates 7/10 prescribe.
- Gate 9 of `dev-workflow/skills/opening-pull-requests/SKILL.md` points at `pr-body.md`.
- Attribution: a `LICENSE` in the skill directory carrying both MIT notices (Matt Pocock; HumanLayer) and a `CREDITS.md` (Matt Pocock `pr`, mattpocock/skills 1.3.1; Dex Horthy `show-me`, humanlayer/skills).
- `dev-workflow/README.md` row for `opening-pull-requests`; dev-workflow version bump to 0.2.3.
- New section-scoped assertions in `dev-workflow/tests/run.sh`.

**Out of scope**
- `intaking-work-items` step 8 text — unchanged; the template gives a home to every item it prescribes (depends-on/Refs lines, `Intake:` lines, spec issue, stub doc, AC lists, evidence tables).
- `dev-workflow:review-policy` — tiers unchanged.
- The separate `developer:opening-pull-requests` plugin — not in this repository (`find . -path '*opening-pull-requests*'` found only the dev-workflow copy and worktree copies).
- Gates 1–8 and 10 of `opening-pull-requests` — unchanged.
- A runtime dependency on `mattpocock-skills` — rejected in favour of vendoring (decision 1).

## Requirements

### Functional
- **FR-1** `pr-body.md` defines the body order: a header block (`**Ticket:**` first line per gate 7, then optional depends-on/supersedes PR lines and `Refs owner/repo#N` lines), then `## Summary`, `## Evidence`, `## Merge Danger`, `## Review`.
- **FR-2** Summary opens with one sentence of what and why, then the smallest visual from Pocock's menu (pseudocode, call tree, component tree, file tree, Mermaid, diff, whole block).
- **FR-3** Evidence carries before/after, gate 9's "proven live vs only inspected" distinction, and — when intake supplies them — the step-7 per-AC evidence table and the parallel-pieces summary table.
- **FR-4** Merge Danger states the door (one-way / two-way) and blast radius, per Pocock, plus gate 10's applied-before-merge disclosure when infrastructure was applied from the branch.
- **FR-5** Review states the review tier (allowing `Exempt — <reason>` for flows that skip the review chain), the coverage-chain records (gate 6), a `Not in this PR` list of known-open issues and undelivered AC, the `Intake: …` skipped-step lines, the spec issue or "sdlc-process: no tickets published", and the stub-doc content when the user chose "no doc at all".
- **FR-6** Domain language comes from the repo's glossary: `CONTEXT.md`, or `GLOSSARY.md` where that is what the repo has.
- **FR-7** Gate 9 tells the agent to write the body from `pr-body.md`.

### Non-functional
- **NFR-1** Attribution: both MIT notices (Copyright (c) 2026 Matt Pocock; Copyright (c) 2026 HumanLayer) and credits travel with the vendored content (precedent `dev-workflow/README.md:14`).
- **NFR-2** No new plugin dependency; the skill works without `mattpocock-skills` installed.
- **NFR-3** `SKILL.md` stays a gate sequencer: the template lives in `pr-body.md`, not inline.
- **NFR-4** New run.sh assertions are bash 3.2 compatible (CI runs `/bin/bash`).

## Acceptance criteria

All automated checks are scoped to the named section or fenced block, not whole-file greps.

- **AC-1** (FR-1) Inside the template's fenced block in `pr-body.md`: the header block (`**Ticket:**` first, then optional depends-on/supersedes and `Refs` lines) precedes `## Summary`, `## Evidence`, `## Merge Danger`, `## Review`, in that order.
  *Verify:* run.sh — line-number order check inside the fenced block.
- **AC-2** (FR-7) Gate 9's own section of `SKILL.md` (between `### 9.` and `### 10.`) links `[pr-body.md](pr-body.md)` and says to write the body from it.
  *Verify:* run.sh, section-scoped.
- **AC-3** (FR-2, FR-6) The Summary guidance opens with one what-and-why sentence, includes the visuals menu, and names `CONTEXT.md` / `GLOSSARY.md`.
  *Verify:* run.sh, section-scoped.
- **AC-4** (FR-3) The Evidence guidance requires before/after and the "proven live" vs "only inspected" distinction, and names the step-7 per-AC table and the pieces summary table as the intake-supplied cases.
  *Verify:* run.sh, section-scoped.
- **AC-5** (FR-5) The Review guidance names the tier (with an allowed `Exempt — <reason>`), the coverage-chain records, `Not in this PR`, the `Intake:` skipped-step lines, the spec issue or "no tickets published", and stub-doc content.
  *Verify:* run.sh, section-scoped.
- **AC-5b** (FR-4) The Merge Danger guidance requires door (one-way / two-way) and blast radius, and the applied-before-merge disclosure.
  *Verify:* run.sh, section-scoped.
- **AC-6** (NFR-1) The skill directory's `LICENSE` contains both MIT notices (Pocock's, identical to the mattpocock-skills 1.3.1 root LICENSE, and HumanLayer's), and `CREDITS.md` credits Matt Pocock `pr` (mattpocock/skills 1.3.1) and Dex Horthy `show-me` (humanlayer/skills, correct URL).
  *Verify:* run.sh grep of both copyright lines and the MIT permission text; CREDITS greps.
- **AC-7** (NFR-1) The `opening-pull-requests` README row itself mentions the PR-body template and "Adapted from mattpocock/skills (MIT".
  *Verify:* run.sh, row-scoped.
- **AC-8** dev-workflow version is `0.2.3`, parsed from `dev-workflow/.claude-plugin/plugin.json` and from the dev-workflow entry of `.claude-plugin/marketplace.json`.
  *Verify:* run.sh python3 JSON parse.
- **AC-9** (NFR-4) Running `dev-workflow/tests/run.sh` exits 0.
  *Verify:* run the command on the final branch.
- **AC-10** (FR-1–FR-5, person-only) This change's own PR body is written from `pr-body.md` and the user judges it readable.
  *Verify:* user review at close-out.

## Definition of done

- [ ] All AC above verified with recorded evidence
- [ ] Merged to `main` via a draft PR marked ready
- [ ] dev-workflow at 0.2.3; README row updated
- [ ] No CHANGELOG to update (`ls CHANGELOG* dev-workflow/CHANGELOG*` → no matches)

## Dependencies and gates

| Item | Kind | State on fetched date |
|---|---|---|
| Ticket / GitHub issue | informs | cjsteigerwald/ai-crew#46 (spec = single delivery ticket), published 2026-10-22 |
| sdlc-process expects GitHub-owned work | informs | may hold at publication; the user decides each hold |
| `mattpocock-skills` 1.3.1 source | informs | installed in plugin cache; content vendored, not depended on |

## Test plan

| AC | Kind | Seam | Catches / misses | Test name | Location |
|---|---|---|---|---|---|
| AC-1 | unit (static), agent-verifiable | the template fenced block as an agent loads it | catches missing/misordered sections / misses prose quality | pr-body order | `dev-workflow/tests/run.sh` |
| AC-2 | unit (static), agent-verifiable | `SKILL.md` gate 9 section | catches a lost pointer / misses whether agents follow it | gate 9 pr-body link | `dev-workflow/tests/run.sh` |
| AC-3 | unit (static), agent-verifiable | Summary guidance section | catches dropped guidance / misses wording quality | summary guidance | `dev-workflow/tests/run.sh` |
| AC-4 | unit (static), agent-verifiable | Evidence guidance section | as above | evidence guidance | `dev-workflow/tests/run.sh` |
| AC-5 | unit (static), agent-verifiable | Review guidance section | as above | review guidance | `dev-workflow/tests/run.sh` |
| AC-5b | unit (static), agent-verifiable | Merge Danger guidance section | as above | merge danger guidance | `dev-workflow/tests/run.sh` |
| AC-6 | unit (static), agent-verifiable | skill directory | catches missing notices / misses licence-text drift beyond the asserted lines | license + credits | `dev-workflow/tests/run.sh` |
| AC-7 | unit (static), agent-verifiable | the README row | catches a missing credit / — | README row | `dev-workflow/tests/run.sh` |
| AC-8 | unit (static), agent-verifiable | parsed manifests | catches a missed bump in either manifest / — | version 0.2.3 | `dev-workflow/tests/run.sh` |
| AC-9 | suite, agent-verifiable | `dev-workflow/tests/run.sh` | catches regressions in other assertions / — | whole suite | local |
| AC-10 | person-only | the opened PR | catches an unreadable body / — | — | GitHub PR |

Repo-wide checks: `bash dev-workflow/tests/run.sh` (baseline PASSED on main per plan-pass verifier).

## Verification evidence

None — step 7 not run.

## Run log

| Time | Step | Event | Attempt | Blocker |
|---|---|---|---|---|
| — | 1–2 | Fetched sources (no ticket); gap table: 9 rows Missing/Vague, 4 contradictions | 1 | — |
| — | 3 | Three grilling rounds; all rows Present or n/a; contradictions resolved | 1 | — |
| — | 4 | Requirements doc written | 1 | — |
| — | 6 | Spec drafted via `sdlc-process:to-spec` (entry: sdlc-process → orchestrator loaded); policy review PASS for publication; published cjsteigerwald/ai-crew#46 with `ready-for-agent`; readback: AC-1–AC-10 present, body byte-identical | 1 | — |

## Risks

- PR bodies from every dev-workflow user change shape — blast radius: all dev-workflow PR bodies — two-way door; revert the commit.
- Vendored content drifts from upstream `pr` — low impact; `CREDITS.md` records the source version (1.3.1), asserted by AC-6.
- Review tier **Full** (touches a skill definition): fresh-verifier + codex-adversary on the plan and on the diff.

## Decision log

| # | Question | Answer | Who / date |
|---|---|---|---|
| 1 | Incorporate by vendoring into `pr-body.md`, runtime-loading `mattpocock-skills:pr`, or inlining into SKILL.md? | Vendor into `pr-body.md` with LICENSE + CREDITS | user, 2026-10-22 |
| 2 | Why? | Consistent, fast-to-review PR bodies; make merge risk (door + blast radius) explicit | user, 2026-10-22 |
| 3 | Contradiction: "use the user's domain language from `GLOSSARY.md`" (Pocock `pr` SKILL.md) vs domain docs are `CONTEXT.md` (AGENTS.md → `docs/agents/domain.md`) | Use the repo's `CONTEXT.md`, or `GLOSSARY.md` where the repo has that | user, 2026-10-22 |
| 4 | Contradiction: requirements doc at `docs/specs/<KEY>-requirements.md` (intake) vs work docs under `docs/work/initiatives/…` (repo precedent) | `docs/work/initiatives/dev-workflow/workstreams/opening-pull-requests/pr-body-template.requirements.md`, KEY `pr-body-template` | user, 2026-10-22 |
| 5 | Contradiction: body starts at `## Summary`, "skip all preambles" (Pocock) vs `**Ticket:**` first line (gate 7) and "what, why" (gate 9) | Ticket line first; Summary opens with one what-and-why sentence | user, 2026-10-22 |
| 6 | What goes in Evidence? | Before/after + live-vs-inspected + intake's per-AC table when present | user, 2026-10-22 |
| 7 | Where do review tier and open items go? | Closing `## Review`: tier, coverage-chain records, `Not in this PR` | user, 2026-10-22 |
| 8 | Out of scope? | Intake step 8, review-policy, `developer:opening-pull-requests`, gates 1–8 and 10 | user, 2026-10-22 |
| 9 | Definition of done? | Merged via draft PR marked ready; 0.2.3; README row; run.sh green; no CHANGELOG | user, 2026-10-22 |
| 10 | Acceptance criteria AC-1–AC-10 as drafted? | Accepted | user, 2026-10-22 |
| 11 | Risks and tier? | Two-way door; Full tier | user, 2026-10-22 |
| 12 | Ticket? (earlier: "don't create one") | "Create github issue, then implement" — spec issue published as the single delivery ticket; no to-tickets decomposition | user, 2026-10-22 |
| 14 | Plan pass (fresh-verifier: sound with changes; codex-adversary round 1: revise) found orphaned PR-body items (gate 7 depends-on line; intake Refs, `Intake:` lines, stub doc, pieces table; gate 10 applied-before-merge), a missing HumanLayer MIT notice (verified: humanlayer/skills LICENSE "Copyright (c) 2026 HumanLayer"), and AC that grep could satisfy trivially. Accept the revised AC? | "Accept the revised AC. Update the requirements doc and edit issue #46 to match, then implement." | user, 2026-10-22 |
| 13 | Planning-doc location: sdlc-process adapter puts planning docs in `sidkik/planning` | Personal repo; kept in `docs/work/…` per repo precedent and decision 4 (noted deviation) | user, 2026-10-22 |

## Deferred and out-of-scope items

| Item | Status | Source | User's words | Gap left open | Follow-up |
|---|---|---|---|---|---|
| Intake step 8, review-policy, `developer:opening-pull-requests`, gates 1–8/10 | out of scope | decision 8 | "accept all" | none | none |
| Runtime dependency on `mattpocock-skills` | out of scope | decision 1 | "agree with recommendations" | upstream changes are not picked up automatically | none |

## Gap table at skip

None — step 3 completed.

## Chain artifacts

Wayfinding: none. `CONTEXT.md` / ADR changes: none (no new domain terms; decision is reversible, so no ADR).
Review tier: Full.
Spec issue: cjsteigerwald/ai-crew#46 (also the single delivery ticket; no to-tickets).
Policy review: publication PASS (2026-10-22).
Plan pass: `plan pass @#46 v1 + requirements doc` — fresh-verifier: sound with changes; codex-adversary (Codex round 1, ledger `plan:ai-crew-46`): revise; findings folded into the revised AC (decision 14).
**Last completed stage:** to-spec (published).
