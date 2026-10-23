---
id: dev-workflow-intake-one-slice-and-ready-label-requirements
type: requirements
status: ready
owner: dev-workflow
representation: canonical
canonical: docs/work/initiatives/dev-workflow/workstreams/intaking-work-items/one-slice-and-ready-label.requirements.md
---

# ai-crew-50: intake publishes without `ready-for-*`; one-slice work uses the spec issue

**Source:** [cjsteigerwald/ai-crew#50](https://github.com/cjsteigerwald/ai-crew/issues/50)
**Linked items:** `sdlc-process` 0.4.14 `bundle/.agents/skills/to-spec/SKILL.md:18` and `to-tickets/SKILL.md:62,76` (the `ready-for-agent` defaults): related context, upstream, read-only. `bundle/docs/work/agent-orchestration/process/orchestration.process.md:372` (ready label follows the readiness gate) and `bundle/.claude/skills/sdlc-process/SKILL.md:42` (to-tickets "when decomposition is needed"): related context. `dev-workflow/skills/setting-up-project-boards/templates/issue-tracker.md:54,55,71` (board lifecycle): related context. No equivalent, parent or dependency.
**Fetched:** 2026-10-22. Issue state `OPEN`, no labels, no comments, no cross-referenced PRs; sprint `none`, estimate `none`
**Intake by:** Christopher Steigerwald with the `dev-workflow:intaking-work-items` skill
**Status:** Ready, revision 4 (decision 13: FR-6–FR-8, AC-8–AC-10) (plan-pass revisions R1–R7, decision 10; R8–R10, decision 11). Step 3 (grilling) complete; to-spec and to-tickets skipped by the user (Intake: plan skipped). Doc path follows this repo's `docs/work/` convention instead of `docs/specs/<KEY>-requirements.md` (step 0: repo procedure wins).
**Chain:** sdlc-process

> Snapshot of the issue on the fetched date plus the decisions below. If the issue changes,
> re-run intake for the changed rows rather than editing this doc by memory.

## Story

As an agent running `dev-workflow:intaking-work-items` through the sdlc-process chain, I want
`chain-sdlc-process.md` to say that intake publishes the spec issue and every issue to-tickets publishes without a `ready-for-*`
label, and that one-slice work uses the spec issue as its delivery issue, so that published issues
follow the readiness gate and the repo's board lifecycle, and one piece of work does not become two
board items and two handoffs.

## Scope

**In scope**
- `dev-workflow/skills/intaking-work-items/chain-sdlc-process.md`: stage 4 (label override for to-spec and to-tickets; the one-slice rule; the coverage check and plan-pass wording at `:109-111`), stage 5 records (`:138-139`), and Controls → Resume (`:179-181`) for the one-slice delivery issue (decision 10, R1–R3, R5).
- `dev-workflow/skills/intaking-work-items/SKILL.md`: step 1 **Resume status** (one-slice record), step 8 PR-body rule (`:343-345`) and the Full-tier plan-pass wording (`:350-351`) (decision 10, R4, R5).
- `dev-workflow/skills/intaking-work-items/template.md`: one clause in Chain artifacts (`:116-118`) for the `tickets: none — one slice` record (decision 11/R10).
- `dev-workflow/tests/run.sh`: a new section `== intaking-work-items one-slice / ready-label ==` with one assertion per AC-1, AC-2, AC-5, AC-6; the pinned version assertion labelled "AC-8" (`run.sh:939,945,953,955`) updated in place (decision 10, R7).
- dev-workflow version 0.2.4 → 0.2.5 in `dev-workflow/.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json`.
- Added by decision 13 (FR-6–FR-8, AC-8–AC-10): `dev-workflow/skills/intaking-work-items/piece-mode.md` (a stage 4 `to-spec` row in **What changes**, the `spec-refresh` STUCK reason, and a "when woken" rule), `dev-workflow/skills/orchestrating-pieces/SKILL.md` §4 STUCK bullet (the parent acts on `spec-refresh`), `dev-workflow/skills/opening-pull-requests/pr-body.md:46,212` (the "Spec issue" line names the one-slice delivery issue), and their `run.sh` pins. The version stays 0.2.5 (unreleased, same PR).

**Out of scope**
- Upstream `sdlc-process` (sidkik-plugins) sources: this repo only consumes them (decision 5).
- `dev-workflow/skills/setting-up-project-boards/templates/*`: the lifecycle there is already right (decision 5).
- Wayfinder publications (map and child tickets) (decision 5).

## Requirements

### Functional
- **FR-1** At stage 4, intake publishes the spec issue and every issue to-tickets publishes without a `ready-for-*` label, in the repo's refining state where the tracker doc read at step 0 (e.g. `docs/agents/issue-tracker.md`) defines one, otherwise with no triage label. Only the readiness gate applies `ready-for-*`. This overrides the label defaults of `sdlc-process:to-spec` and `sdlc-process:to-tickets` (to-tickets permits it: "unless instructed otherwise", `to-tickets/SKILL.md:62`), in every repo (decisions 1, 2, 10/R7). Publication labelling is the one exception to "the repo procedure wins" (SKILL.md step 0); other repo gates still apply (decision 12).
- **FR-2** When a spec issue was published and to-tickets' proposed breakdown has one slice, intake publishes no child issue; the spec issue is the delivery issue. Chain artifacts record `tickets: none — one slice`. This is not the plan-skip rule: no skip warning and no "Intake: plan skipped" line. The AC coverage check runs against the spec issue; on Full tier the plan pass runs on the spec issue alone; stage 5 takes the "One ticket, or no decomposition" route. When `to-spec` was skipped, the rule does not apply: to-tickets publishes its one ticket as the delivery issue, as today (decisions 3, 10/R1).
- **FR-3** A one-slice delivery issue has no children, so the board's "parent carries no `ready-for-*`" rule (`setting-up-project-boards/templates/issue-tracker.md:71`) does not apply to it; it gets `ready-for-*` through the readiness gate like any delivery issue (decisions 1, 3, 10/R3).
- **FR-4** With `tickets: none — one slice`, stage 5's records (`integrated @<sha>`) are written against the spec issue. On resume, an AC reopened by the refetch diff makes intake refresh the spec issue body as a per-action confirmed writeback (to-tickets does not modify the parent, `to-tickets/SKILL.md:66`), then re-run to-tickets' breakdown (which may now yield more than one slice and publish children), then repeat the coverage check, readiness and, on Full tier, the plan pass (decision 10/R2). Piece mode skips `to-spec` (FR-6), so the one-slice rule never fires there: a reopened AC concerns the piece's own issue, which it may not edit (`piece-mode.md:53-55`; piece mode wins, `chain-sdlc-process.md:7-8`). The piece reports `STUCK #N spec-refresh #<issue> AC-n` (FR-7) and resumes when woken, once the parent session has refreshed the issue; decomposition never re-runs on a stale spec (decision 11/R8, decision 13). If the re-run publishes children, `tickets: none — one slice` and the spec issue's `integrated @<sha>` are recorded as superseded (decision 12).
- **FR-5** Step 8's PR body lists a one-slice spec issue as the delivery issue and gives it the `Refs` (or closing keyword, where the repo allows) line, instead of "sdlc-process: no tickets published" alone. The Full-tier plan-pass wording in `SKILL.md:350-351` and `chain-sdlc-process.md:111` says "(the spec issue alone with one slice)" (decision 10/R4, R5).
- **FR-6** In piece mode, stage 4's `to-spec` is skipped: the piece's issue is the spec and the delivery issue, so a piece never publishes a second spec issue. `to-tickets` runs only when splitting the piece (`piece-mode.md` **Splitting the piece**). The one-slice rule therefore never fires in piece mode (decision 13).
- **FR-7** A piece that needs its issue's body refreshed (an AC reopened by the refetch diff; it may not edit issues, `piece-mode.md:53-55`) reports `STUCK #N spec-refresh #<issue> AC-n`. When woken (`STATUS? #N`, or the user answers in its session), it refetches as in step 1. If the reopened AC is now in the issue, it continues from the stage 4 breakdown; otherwise it stays STUCK. In `orchestrating-pieces` §4, `spec-refresh` is the one STUCK reason the parent acts on: it offers the user the issue-body refresh as a per-action confirmed writeback, then wakes the piece with `STATUS? #N` (decision 13).
- **FR-8** `opening-pull-requests/pr-body.md`'s "Spec issue" line (`:46` placeholder, `:212` guidance) says the spec issue is marked as the **delivery issue** when `tickets: none — one slice`, or else `sdlc-process: no tickets published` (decision 13).

### Non-functional
- **NFR-1** None beyond current behaviour (decision 8).

## Acceptance criteria

Each AC is testable as written and names how it is verified. Plans and PRs cite these numbers.

- **AC-1** (FR-1) Given intake reaches stage 4, when it reads `chain-sdlc-process.md`, then the doc states that the spec issue and every issue to-tickets publishes are published without a `ready-for-*` label (in the repo's refining state where its tracker doc defines one), and names the readiness gate as the only path to `ready-for-*`, overriding to-spec's and to-tickets' label defaults, as the one exception to repo-procedure precedence, needing no second confirmation (decision 12).
  *Verify:* `run.sh` assertion "AC-1" greps the rule's stable phrase in `chain-sdlc-process.md`; reviewer reads stage 4.
- **AC-2** (FR-2, FR-3) Given a published spec issue and a to-tickets breakdown of one slice, when intake is at stage 4, then the chain doc tells it to publish no child issue, to use the spec issue as the delivery issue, to record `tickets: none — one slice` in Chain artifacts (not as a plan-skip, no "Intake: plan skipped"), to check AC coverage against the spec issue, to run the Full-tier plan pass on the spec issue alone, to give that issue `ready-for-*` only through the readiness gate (the parent rule does not apply: it has no children), and to take stage 5's "One ticket, or no decomposition" route; and it states that with `to-spec` skipped the rule does not apply and to-tickets publishes its one ticket as the delivery issue.
  *Verify:* `run.sh` assertions "AC-2" grep the one-slice phrase, the to-spec-skipped exception and the readiness-gate/parent phrase; reviewer reads stage 4, stage 5 and Controls.
- **AC-3** (FR-1–FR-5) `bash dev-workflow/tests/run.sh` exits 0 and includes the new section's assertions for AC-1, AC-2, AC-5 and AC-6, named by AC number; deleting any asserted phrase makes it fail. A green suite proves text presence only; behaviour is evidenced separately (AC-7).
  *Verify:* run the suite (exit 0); delete each phrase in a scratch copy and rerun (non-zero, the AC's failure line).
- **AC-4** (DoD) dev-workflow is 0.2.5 in `dev-workflow/.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json`; the existing assertion labelled "AC-8" (`run.sh:939,945,953,955`) is updated to 0.2.5 and run.sh passes.
  *Verify:* that assertion; `grep -n '"version"'` on both files.
- **AC-5** (FR-4) Given `tickets: none — one slice`, the chain doc says stage 5's `integrated @<sha>` record is written against the spec issue, and that on resume a reopened AC leads to a per-action confirmed refresh of the spec issue body, a re-run of to-tickets' breakdown (possibly publishing children), then the coverage check, readiness and the Full-tier plan pass again; and that piece mode skips `to-spec`, so the one-slice rule never fires there: a reopened AC concerns the piece's own issue, the piece reports STUCK with a `spec-refresh` reason, resumes when woken once the parent refreshed the issue, and never re-runs decomposition on a stale spec.
  *Verify:* `run.sh` assertion "AC-5" greps the resume phrase; reviewer reads stage 5 records and Controls → Resume.
- **AC-6** (FR-5) `SKILL.md` step 8 lists a one-slice spec issue as the delivery issue with its `Refs` line; `SKILL.md` step 1 Resume status and `template.md`'s Chain artifacts (`:116-118`) name the `tickets: none — one slice` record; the plan-pass wording in `SKILL.md:350-351` and `chain-sdlc-process.md:111` covers "the spec issue alone with one slice".
  *Verify:* `run.sh` assertions "AC-6" grep each phrase; reviewer reads step 1, step 8 and **Review = tier**.
- **AC-7** (FR-2, FR-4, FR-5) A reviewer walks the one-slice scenario (spec published, one slice → stage 5 → step 8 → resume with a reopened AC), the same resume in piece mode (`spec-refresh` STUCK on the piece's own issue, no issue edit, no decomposition on a stale spec), and the to-spec-skipped scenario through the changed docs and finds no step that contradicts them or leaves the delivery issue undefined; and confirms the chain doc states the board parent rule does not apply *because the issue has no children* (decision 11/F-4). Recorded as separate person-readable evidence, not as the suite result (decision 10/R6).
  *Verify:* diff-pass reviewer's scenario walk-through, cited in the Verification evidence table.
- **AC-8** (FR-6) `piece-mode.md` **What changes** has a stage 4 `to-spec` row: skipped, because the piece's issue is the spec and the delivery issue, with `to-tickets` only when splitting.
  *Verify:* `run.sh` assertion "AC-8" (one-slice section) greps the row's phrase; reviewer reads the table and **Splitting the piece**. Note: the pre-existing `run.sh` "AC-8" version label belongs to the earlier PR-body work, not to this doc.
- **AC-9** (FR-7) `piece-mode.md` defines `STUCK #N spec-refresh #<issue> AC-n` and the "when woken" rule. `orchestrating-pieces/SKILL.md` §4 says the parent acts on `spec-refresh` (a confirmed issue-body refresh, then `STATUS? #N`), and that every other STUCK reason still waits for the user. The chain doc's piece-mode resume text agrees with both.
  *Verify:* `run.sh` assertions "AC-9" grep the reason form in both files and the wake rule; reviewer walks the piece-mode reopened-AC scenario end to end.
- **AC-10** (FR-8) `pr-body.md:46` and `:212` name the one-slice delivery issue, and the existing `pr-body.md` pins still pass.
  *Verify:* `run.sh` assertion "AC-10" greps the phrase in `pr-body.md`.

## Definition of done

- [x] AC-1 to AC-7 verified with recorded evidence (Verification evidence, verify @562ad5e)
- [ ] Full-tier review: plan pass and diff pass (fresh-verifier + codex-adversary): plan pass @8a5ab29 + bounded @c627c6d; diff pass @9f04e17 + bounded @b393ca3 (partial) and @581145c (resolved); the final delta 581145c..562ad5e is under human review (pending human review)
- [ ] AC-8 to AC-10 (decision 13) verified with recorded evidence
- [x] Draft PR opened with `Refs cjsteigerwald/ai-crew#50` (#51) (no closing keyword; the user closes the issue at close-out, decision 6)

## Dependencies and gates

| Item | Kind | State on fetched date |
|---|---|---|
| None — no upstream ticket, approval or repo gate | — | — |

## Test plan

| AC | Kind | Seam | Catches / misses | Test name | Location |
|---|---|---|---|---|---|
| AC-1 | unit (doc assertion), agent-verifiable | `chain-sdlc-process.md` text | catches the rule's removal / misses wording that is present but unclear (review covers) | `AC-1 chain doc: publish without ready-for-*, readiness gate only` | `dev-workflow/tests/run.sh` |
| AC-2 | unit (doc assertion), agent-verifiable | `chain-sdlc-process.md` text | catches removal of the one-slice rule, the to-spec-skipped exception or the readiness/parent phrase / misses a contradicting sentence elsewhere (AC-7 covers) | `AC-2 chain doc: one slice, spec issue is the delivery issue` (+ exception, + readiness) | `dev-workflow/tests/run.sh` |
| AC-3 | unit (suite run + mutation), agent-verifiable | `run.sh` exit code | catches assertions that cannot fail / misses behaviour (AC-7 covers) | suite run + phrase-deletion check | `dev-workflow/tests/run.sh` |
| AC-4 | unit (manifest assertion), agent-verifiable | `plugin.json`, `marketplace.json` | catches a missed manifest / misses nothing in scope | existing assertion labelled "AC-8", updated | `dev-workflow/tests/run.sh:939-955` |
| AC-5 | unit (doc assertion), agent-verifiable | `chain-sdlc-process.md` text | catches removal of the resume/records rule / misses wrong ordering (AC-7 covers) | `AC-5 chain doc: one-slice records and resume` | `dev-workflow/tests/run.sh` |
| AC-6 | unit (doc assertion), agent-verifiable | `SKILL.md`, `chain-sdlc-process.md` text | catches removal of the step 1, step 8 and plan-pass phrases / misses contradicting text elsewhere (AC-7 covers) | `AC-6 SKILL.md: one-slice delivery issue in Resume status, PR body, plan pass` | `dev-workflow/tests/run.sh` |
| AC-7 | review (scenario walk-through), agent-verifiable | the changed docs, read end to end | catches contradictions and undefined delivery issue / misses runtime agent behaviour | diff-pass scenario walk-through | diff-pass reviewer report |

Repo-wide checks: `bash dev-workflow/tests/run.sh`. Existing run.sh pins on chain-doc and SKILL.md sentences that the edits must not reword (insert new text instead): `run.sh:269` (SKILL.md under 500 lines), `:311-325`, `:354-355`, `:393-394`, `:395-404`, `:411-421` (incl. the removed-text list at `:420-421`), `:423` (the plan-pass sentence R5 touches: insert the clause, keep `'(between to-tickets and Implement)'`, `'after code-review and before Verify'`, `'PR gate accepts'` verbatim), `:424`, `:431-433`, `:438-443`, `:584`, `:586` (piece-mode no-edit rule), `:747-754` (decisions 10/R7, 11/R9) (line numbers as of 581145c).

## Verification evidence

Repo checks (head `562ad5e`, 07:48): `bash dev-workflow/tests/run.sh` exit 0, last line `PASSED`, 0 `^FAIL` lines. Lint and typecheck: n/a, AGENTS.md names none for these files (prose, JSON, bash).

| AC | Check | Kind | Result | Evidence | Base / head / time |
|---|---|---|---|---|---|
| AC-1 | `bash dev-workflow/tests/run.sh`, section `== intaking-work-items one-slice / ready-label ==` | automated, new | verified | base (run.sh from head copied onto a throwaway worktree, no skill or doc files; assertion failures, not setup): `FAIL: AC-1 skills/intaking-work-items/chain-sdlc-process.md: missing the publish-without-ready-for-* rule` (+ 5 more AC-1 FAIL lines); head ×2: `ok: intaking-work-items one-slice / ready-label rules pinned` | `c23c119` / `562ad5e` 07:48 |
| AC-2 | same section | automated, new | verified | base: `FAIL: AC-2 skills/intaking-work-items/chain-sdlc-process.md: missing the one-slice rule (spec issue is the delivery issue)` (+ 3 more AC-2 FAIL lines); head ×2: `ok: intaking-work-items one-slice / ready-label rules pinned` | `c23c119` / `562ad5e` 07:48 |
| AC-3 | `bash dev-workflow/tests/run.sh` x2, then phrase-deletion in a scratch full-repo worktree at head | automated (suite + mutation) | verified | head exit 0 twice (`PASSED`); each of the 19 asserted phrases deleted in turn (chain doc, SKILL.md, template.md): exit 1 and that pin's `FAIL: AC-n ... missing ...` line. One pin (`tickets: none — one slice` in the chain doc, 6 occurrences) survived a first-occurrence-only deletion by design and failed (`FAIL: AC-2 ... missing the one-slice Chain artifacts record`) once all occurrences were removed. Prior reviewers mutation-checked all 19 pins. Green suite proves text presence only (AC-7 covers behaviour) | `562ad5e` 07:53 |
| AC-4 | `grep -n '"version"'` on both manifests; run.sh assertion labelled "AC-8" (`run.sh:939-955`) | automated, existing pin updated | verified | `dev-workflow/.claude-plugin/plugin.json:3: "version": "0.2.5",`; `.claude-plugin/marketplace.json:45` (dev-workflow entry): `"version": "0.2.5",`; head ×2: `ok: AC-8 dev-workflow is 0.2.5 in plugin.json and marketplace.json`; base: `FAIL: AC-8: dev-workflow version is not 0.2.5 in both plugin.json and marketplace.json` | `c23c119` / `562ad5e` 07:48 |
| AC-5 | same section | automated, new | verified | base: `FAIL: AC-5 skills/intaking-work-items/chain-sdlc-process.md: missing the one-slice stage 5 record against the spec issue` (+ 3 more AC-5 FAIL lines); head ×2: `ok: intaking-work-items one-slice / ready-label rules pinned` | `c23c119` / `562ad5e` 07:48 |
| AC-6 | same section | automated, new | verified | base: `FAIL: AC-6 skills/intaking-work-items/SKILL.md: missing the step 1 one-slice record` (+ 4 more AC-6 FAIL lines); head ×2: `ok: intaking-work-items one-slice / ready-label rules pinned` | `c23c119` / `562ad5e` 07:48 |
| AC-7 | reviewer scenario walk-through | review | verified (review) | fresh-verifier diff pass @9f04e17: scenarios i-iii, no contradiction, delivery issue defined; cold read in bounded re-review @581145c: resolved. The delta 581145c..562ad5e is under the user's human review (pending) | — / `581145c` 2026-10-23 |

## Run log

| Time | Step | Event | Attempt | Blocker |
|---|---|---|---|---|
| 17:20 | 1 | Fetched cjsteigerwald/ai-crew#50; verified its citations | 1 | — |
| 17:30 | 2 | Gap table: rows 3, 5, 8, 10 Missing; 4, 6, 9, 13 Vague (C1, C2) | 1 | — |
| 17:40 | 3 | sdlc-process entry + orchestrator loaded; grill-with-docs (grilling, domain-modeling); round 1 accepted; AC agreed | 1 | — |
| 17:44 | 6.1 | Work branch `feat/intake-one-slice-ready-label`; review base `c23c119` (merge-base with origin/main) | 1 | — |
| 17:46 | 5 | Writeback: comment posted on cjsteigerwald/ai-crew#50 (issuecomment-6353836654), read back | 1 | — |
| 17:47 | 6.1 | `review-ledger.sh link branch:feat/intake-one-slice-ready-label plan:ai-crew-50` → 0 rows | 1 | — |
| 17:48 | 6.4 | User chose "Skip both" to-spec and to-tickets: #50 + this doc are the spec, one slice. Intake: plan skipped; no spec issue. Plan pass runs on this doc | 1 | — |
| 17:55 | 6.4 | Plan pass @68a9074: both revise; R1–R7 accepted (decision 10); doc revised (AC-5–AC-7 added) → 8a5ab29 | 1 | — |
| 18:00 | 6.4 | Bounded re-check 68a9074..8a5ab29: NEEDS FULL PASS (churn 50/144 = 34.7% > 20%) | 1 | — |
| 18:10 | 6.4 | Plan pass #2 @8a5ab29 (Codex round 2/3, trigger: changed input): verifier pass w/ comments, Codex needs-attention; R8–R10 accepted (decision 11) → c627c6d | 2 | — |
| 18:20 | 6.4 | `bounded re-review @c627c6d (8a5ab29..c627c6d): resolved` (churn 17.7%) | 1 | — |
| 04:37 | 6.4 | Plan-skip restated before stage 5 (no spec issue, no tickets, no coverage check; PR body says "Intake: plan skipped"); user confirmed | 1 | — |
| 04:37 | 5 | Policy review (sdlc-policy-reviewer) for starting implementation: conditional pass, held on live user go; F1 skip restatement, F2 doc hygiene, F3 Codex 3/3 is last | 1 | — |
| 04:37 | 5 | User go for stage 5 Implement (2026-10-22) | 1 | — |
| 04:39 | 5 | Implement + tdd: AC-1, AC-2, AC-5, AC-6, AC-4 red→green; run.sh exit 0 | 1 | — |
| 04:44 | 5 | code-review @44a3737 (Standards + Spec): 0 must-fix; fixed S1 oslfail wrapper, S2/S3 wraps, P1 one-slice coverage, P2 stage 5 route; kept S3 five-place mention (spec-mandated), S4/S5 accepted; P3 piece-mode resume step out of scope (follow-up) | 1 | — |
| 06:06 | 5 | Full-tier diff pass @9f04e17 (base c23c119): fresh-verifier pass with comments (AC-1–AC-7 met; AC-7 walk-through recorded), codex-adversary 3/3 needs-attention (label precedence); decision 12 | 1 | — |
| 06:06 | 5 | Diff-pass fixes (decision 12) red→green; run.sh exit 0 | 1 | — |
| 06:24 | 5 | Bounded re-review @b393ca3 (eligible, churn 10.1%): C-1 partial (SKILL.md Controls/step 0 still absolute), SHOULD-1 and FLAG-2 resolved; bounded code-review: 3 should-fix; consolidated fixes (decision 12 scope) red→green | 1 | — |
| 07:30 | 5 | Bounded re-review @581145c: resolved (churn 19.4%); user chose human review for the remaining delta (Codex at cap) | 1 | — |
| 07:30 | 5 | FLAG-1 / FLAG-2 fixes @562ad5e | 1 | — |
| 07:53 | 7 | Verify @562ad5e: repo checks + AC-1–AC-7 | 1 | — |
| 08:10 | 8 | Pushed; draft PR cjsteigerwald/ai-crew#51 @9328513 (Refs #50); local CI mirror green | 1 | — |
| 08:30 | 5 | Decision 13: three follow-ups move into PR #51 (FR-6–FR-8, AC-8–AC-10); pieces skip to-spec. Re-enter stage 5 for the new ACs; Verify re-runs | 1 | — |
| 08:36 | 5 | Policy review for decision 13 re-entry: conditional pass (C1–C4, F1–F3) | 1 | — |
| 08:50 | 5 | Decision 13 implement + tdd: AC-8, AC-9, AC-10 red→green; F1/F2 aligned; run.sh exit 0 | 1 | — |

## Risks

- An agent on a repo without board docs publishes unlabelled issues — none beyond waiting for the readiness gate, which applies the label — no mitigation needed.
- Prose-only change to a skill — wrong wording misleads later intakes — Full-tier review; rollback is a revert.

## Decision log

| # | Question | Answer | Who / date |
|---|---|---|---|
| 1 | Contradiction C1: "published without a `ready-for-*` label" unconditional (issue AC-1) vs "the repo's issue-tracker doc wins over to-spec's label default" (issue Suggested fix 1) | Unconditional: intake never applies `ready-for-*` at publication; refining state where the tracker doc defines one, else no label | Christopher Steigerwald, 2026-10-22 |
| 2 | Does the override also cover to-tickets' children (`to-tickets/SKILL.md:62,76`)? | Yes; AC-1 widened | Christopher Steigerwald, 2026-10-22 |
| 3 | How is one slice detected; is it a plan-skip? | to-tickets runs its breakdown; one slice → no child published, spec issue is delivery issue, recorded `tickets: none — one slice`, not a plan-skip | Christopher Steigerwald, 2026-10-22 |
| 4 | Contradiction C2: issue AC-2 "stage 5" vs to-tickets at stage 4 (`chain-sdlc-process.md:100`, inside stage 4 at `:92`) | Stage 4 | Christopher Steigerwald, 2026-10-22 |
| 5 | Out of scope | Upstream sdlc-process, board templates, wayfinder publications; intake SKILL.md only for a one-line Resume-status mention (SKILL.md part superseded by decision 10) | Christopher Steigerwald, 2026-10-22 |
| 6 | Definition of done | Patch bump 0.2.5 with the run.sh assertion updated; draft PR with `Refs` | Christopher Steigerwald, 2026-10-22 |
| 7 | Tests | One mandatory run.sh assertion per AC-1, AC-2, named by AC (extended to AC-5, AC-6 by decision 10) | Christopher Steigerwald, 2026-10-22 |
| 8 | NFR and risks | None beyond current; low risk, revert to roll back | Christopher Steigerwald, 2026-10-22 |
| 9 | Settled AC-1 to AC-4 | "agree" | Christopher Steigerwald, 2026-10-22 |
| 10 | Plan pass @68a9074 (fresh-verifier: revise, 0 must-fix / 4 should-fix; codex-adversary: revise, 1 must-fix / 2 should-fix / 1 flagged): accept R1 (one-slice only with a published spec; to-spec skipped → to-tickets' one ticket is the delivery issue), R2 (records + resume for the spec delivery issue), R3 (AC-2 covers plan pass and readiness/parent), R4 (step 8 PR body), R5 (plan-pass wording), R6 (separate scenario evidence, AC-7), R7 (citations, run.sh section, "AC-8" label, step-0 tracker source, existing pins)? Scope widens to SKILL.md step 1, step 8, Review = tier | "accept R1–R7" | Christopher Steigerwald, 2026-10-22 |
| 11 | Plan pass #2 @8a5ab29 (anchor; fresh-verifier: pass with comments, 0 must-fix / 3 should-fix / 4 flagged; codex-adversary round 2/3: needs-attention, 1 should-fix): accept R8 (piece mode: no spec refresh, STUCK until the parent refreshes; AC-5, AC-7), R9 (complete run.sh pin list incl. `:423`), R10 (`template.md:116-118` record clause; AC-6), housekeeping (records, superseded decisions, frontmatter, F-4 check in AC-7)? | "accept R8–R10" | Christopher Steigerwald, 2026-10-22 |
| 12 | Full-tier diff pass @9f04e17 (fresh-verifier: pass with comments, 0 must-fix / 1 should-fix / 3 flagged; codex-adversary round 3/3: needs-attention, 1 medium): repo precedence vs the label rule; parentless to-tickets ticket; supersession on one-slice resume? | "Intake rule wins" (publication labelling is the one exception to repo-procedure precedence, no second confirmation, other gates apply); "Widen wording"; "Add the clause" | Christopher Steigerwald, 2026-10-23 |
| 13 | The three deferred follow-ups (piece resume after STUCK; whether a piece runs to-spec; pr-body.md "Spec issue" line): new issue, or this PR? Should a piece run to-spec? | "implement the fixes to this PR" (this PR, #51, instead of the recommended new issue). Pieces skip to-spec: first recorded from the agent's recommendation before the user had answered, then confirmed by the user's answer "Pieces skip to-spec" (2026-10-23). Adds FR-6–FR-8 and AC-8–AC-10 | Christopher Steigerwald, 2026-10-23 |

## Deferred and out-of-scope items

| Item | Status | Source | User's words | Gap left open | Follow-up |
|---|---|---|---|---|---|
| Upstream sdlc-process label defaults | out of scope | decision 5 | "accept" | to-spec/to-tickets still default to `ready-for-agent` outside intake | none |
| Board templates, wayfinder publications | out of scope | decision 5 | "accept" | none | none |
| piece-mode.md / orchestrating-pieces §4 resume-after-STUCK step for a stale one-slice spec (P3/FLAG-1); whether a piece runs to-spec at all (FLAG-3) | in scope (decision 13) | diff pass @9f04e17 | "implement the fixes to this PR" | — | FR-6, FR-7; AC-8, AC-9 |
| opening-pull-requests/pr-body.md "Spec issue" line does not name the delivery issue (INFO-1) | in scope (decision 13) | diff pass @9f04e17 | "implement the fixes to this PR" | — | FR-8; AC-10 |

## Gap table at skip

None — step 3 completed.

## Chain artifacts

- Wayfinding: none
- `CONTEXT.md` / ADR changes: none (no term or hard-to-reverse decision settled)
- Work branch: `feat/intake-one-slice-ready-label`; review base `c23c119`
- Review tier: Full (skill definition change)
- Spec issue: none — `to-spec` skipped (user, 2026-10-22)
- Tickets: none — `to-tickets` skipped (user, 2026-10-22); Intake: plan skipped. Owning issue: cjsteigerwald/ai-crew#50
- Writeback: cjsteigerwald/ai-crew#50 issuecomment-6353836654
- Plan pass @68a9074: revise (both); R1–R7 accepted (decision 10)
- `bounded re-review @8a5ab29 (68a9074..8a5ab29): NEEDS FULL PASS` (churn 34.7%)
- `plan pass @8a5ab29` (anchor; Codex round 2/3): verifier pass with comments, Codex needs-attention; R8–R10 accepted (decision 11)
- `bounded re-review @c627c6d (8a5ab29..c627c6d): resolved`
- integrated @3a37f4e6675f94fc5665605ba88844b34fc642f2
- code-review @44a3737: Standards 1 should-fix / 4 flagged, Spec 0 must-fix / 3 flagged; fixes @459780c
- `full-tier diff pass @9f04e17 (base c23c119)`: fresh-verifier pass with comments; codex-adversary (round 3/3) needs-attention; decision 12 fixes @2cccde6
- AC-7 scenario walk-through: fresh-verifier diff pass @9f04e17 (scenarios i–iii, no contradiction, delivery issue defined; F-4 at chain-sdlc-process.md:118-120)
- bounded re-review @b393ca3 (9f04e17..b393ca3): C-1 partial; fixes @6b12eb7
- bounded re-review @581145c (9f04e17..581145c): resolved (fresh-verifier; churn 19.4%)
- final delta 581145c..562ad5e: human review (user, 2026-10-23; Codex 3/3, churn past 20%) — pending
- verify @562ad5e (AC-1–AC-7; re-run after the decision 13 work)
- Draft PR: cjsteigerwald/ai-crew#51 @9328513
- Decision 13 scope (AC-8–AC-10): stage 5 re-entered
- decision 13 integrated @776d298
- **Last completed stage:** 8 (draft PR); decision 13 work in progress at stage 5
