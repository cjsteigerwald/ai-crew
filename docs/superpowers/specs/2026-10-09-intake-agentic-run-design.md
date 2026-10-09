# intaking-work-items: unattended run, AC verification, and close-out — design

- **Date:** 2026-10-09 (revised the same day after the full-tier plan review)
- **Skill:** `dev-workflow/skills/intaking-work-items/`
- **Status:** Approved design, revision 2 pending re-review

## Problem

Intake settles requirements well, but everything after step 6 assumes a human at every checkpoint,
and nothing between implementation and Ship checks the work against the acceptance criteria:

- The template has a `*Verify:*` line per AC and a Definition of done (`template.md:45-47`, `:49-52`),
  but no step runs them. Step 6 goes straight from the implement stage to Ship (`SKILL.md:280`).
- Checklist row 9 "Test plan" (`checklist.md:24`) asks how each AC will be verified, but nothing ties
  an AC to a concrete test shown to fail first and pass after.
- Every stage of step 6 ends in a user checkpoint (`SKILL.md:260-263`), so a ticket cannot be
  intaken and then left to run.

## Goal

Pull a ticket, answer every question in one sitting, approve design and plan in that same sitting,
then walk away. The run builds, verifies each agent-verifiable AC with recorded evidence on the
commit it ships, and opens a **draft** PR. Everything else outward-facing waits for the user.

Success: one intake sitting, then either a draft PR whose body carries a per-AC evidence table, or a
local stop with the reason in the Run log — and in both cases a notification.

## Facts this design relies on (verified 2026-10-09)

- `mattpocock-skills` 1.2.3 is the only installed version; `implement-spec` and `retro` live under
  its `skills/in-progress/` group, both with `disable-model-invocation: true`.
- The user keeps user-level copies at `~/.claude/skills/implement-spec/` and `~/.claude/skills/retro/`.
  `retro` is byte-identical to the plugin copy. The user's `implement-spec` differs: per-ticket
  worktrees whose implementer calls `tdd`; an integration branch; step 3 opens a draft PR after the
  first merge when the tracker closes work through PRs, "marked as closing the spec and tickets";
  step 8 marks the PR ready or closes the tickets; `disable-model-invocation: true` at line 4.
- `retro` writes nothing: it reads session logs and returns ranked suggestions.
- `dev-workflow:skill-retrospective` routes learnings to memory, a per-repo overlay, or skills
  (`skill-retrospective/SKILL.md:46-48`); the file never mentions AGENTS.md, hooks, or lint.
- Gates intake's unattended run must answer in advance:
  - `tdd/SKILL.md:22-24`: "No test is written at an unconfirmed seam" — seams are confirmed with the
    user before any test.
  - `plan-implementation/SKILL.md:201`: "prompt before commit/push/PR".
  - `opening-pull-requests/SKILL.md:104-106` (gate 8): "ask before running `gh pr create`".
  - `opening-pull-requests/SKILL.md:44-46` (gate 2) rebases on main before any PR, and `:52-54`
    (gate 3) forbids pushing unless lint and the full suite are clean. It has no draft concept.
- The mattpocock chain today ends with the user typing `/mattpocock-skills:implement`
  (`chain-mattpocock.md:53-60`; also named at `SKILL.md:66-67` and `chain-mattpocock.md:71-76`).
  `dev-workflow/tests/run.sh:270` asserts the chain files exist; `:309` the "Never replicate these
  skills" rule; `:310` the GitHub-only gate.
- `SKILL.md` is 305 lines (`run.sh:267` caps it at 500); its description is 932 chars (`run.sh:264`
  caps it at 1024) and says "with a user checkpoint between each" (`SKILL.md:9-10`).

## Decisions

1. **Run modes: `unattended` (default) and `attended`.** Attended is today's behaviour. Skip on the
   run-mode question means attended.
2. **The sitting answers every downstream gate in advance**, and the doc's Run log records each:
   - the AC→test table, approved in step 4, *is* the seam confirmation `tdd` requires;
   - plan approval answers `plan-implementation`'s commit/push/PR prompt and
     `opening-pull-requests` gate 8;
   - on the mattpocock chain, which has no plan-approval question, an explicit "go unattended?"
     question after the `to-tickets` coverage check is the equivalent go.
3. **The go pre-authorizes exactly two outward actions:** pushing the work branch and opening one
   **draft** PR (`gh pr create --draft`), only after verification and the full review chain pass.
   Nothing else outward — marking ready, editing a PR other than the one intake opened, ticket
   comments, Jira transitions, closing tickets — before the user returns.
4. **Unattended preflight** (user still present) must pass, else intake offers attended:
   checklist row 14 (access) Present; the **baseline is green** — the full suite and lint pass on
   the base commit (a red baseline or no runnable test suite means attended only); the permission
   mode will not stall on prompts; a notification channel exists or the fallback is accepted.
5. **Stop conditions:** a check still failing after 2 fix attempts; an AC found wrong or untestable;
   work beyond the agreed scope; a repo gate or missing access; any outward write outside
   decision 3; a gate decision 2 did not answer. On a stop:
   - **checks green** (scope, a wrong AC, a person-only gap, an unanswered gate): run the review
     chain, push, open the draft PR with the blocker in its body, notify;
   - **checks failing, or no push/PR access:** stop locally — commits stay on the branch, the Run
     log and final message carry the blocker, notify. Nothing is pushed.
6. **Verification (step 7)** runs on the final branch, re-running everything rather than trusting
   worker reports, and **again on the exact commit Ship pushes** if a rebase or review fix changed
   the tree. Evidence is stale the moment the tree changes.
7. **Red-on-base is evidence only for an assertion failure.** Each new test is applied to the base
   commit in a throwaway worktree and must fail on an assertion about the AC's behaviour. A
   collection, import, or compile failure (the code under test does not exist on base) is recorded as
   `red n/a — new interface` and the AC is verified by its head run plus the reviewers' check that the
   test asserts the AC. Each new test must also pass twice on head; a differing result is a failure
   (flaky). The evidence row records the base SHA, the command, and the failure reason.
8. **A person-only AC keeps the PR in draft** until the user confirms it at close-out.
9. **mattpocock chain uses the user's `implement-spec` in intake mode**, invoked as the bare Skill
   identifier `implement-spec` (not `mattpocock-skills:implement-spec`). Intake mode publishes
   nothing: no draft PR at its step 3, no ready/close at step 8, no closing keywords; it returns the
   integration branch to intake. This needs edits to `~/.claude/skills/implement-spec/SKILL.md`
   (outside the repo, applied only on the user's confirmation): drop `disable-model-invocation`, and
   make steps 3 and 8 honour intake mode. If the edits are declined, or the Skill call errors, the
   mattpocock chain runs **attended only** — the user types the command and intake does not go
   unattended on that chain.
10. **Steps are renumbered:** 6 Chain, 7 Verify, 8 Ship, 9 Close-out. Every cross-reference
    (`SKILL.md`, both chain files' lines 3-4 and their "return to … Ship" lines) is updated.
11. **Close-out (step 9)** runs on the user's return and offers `/retro`. Status becomes `Delivered`
    only if every active AC is verified (person-only ones confirmed) and the PR is ready; otherwise
    `Partial`, with the open AC listed. Skill and memory findings from `/retro` go to
    `dev-workflow:skill-retrospective`; accepted environment changes go on a separate branch and PR.
12. **Layout: thin `SKILL.md`, detail in `run-modes.md` and `verify.md`**, as the chain files already
    do. Rejected: a standalone verifying skill (no second caller yet), and inlining everything.

## Flow

| Step | Who | What |
|---|---|---|
| 0–2 | user | Repo procedure, fetch, gap analysis — now with row 14 (access) and the person-only AC tag |
| 3 | user | Close gaps; choose run mode (default unattended; Skip = attended) |
| 4–5 | user | Requirements doc with the AC→test table (= seam approval); confirmed writebacks |
| 6 | user, then unattended | Chain choice; superpowers: design + plan approved in the sitting; mattpocock: user types `to-spec`, `to-tickets`, then the go question. Preflight runs before the go. Then implement unattended |
| 7 | unattended | Verify; 2 fix attempts, then a stop |
| 8 | unattended | Ship: `opening-pull-requests` with gate 8 pre-answered; re-verify if the tree changed; `gh pr create --draft` with the evidence table |
| 9 | user, on return | Close-out |

Attended mode is the same flow with today's checkpoint between every stage.

## Components

### `SKILL.md`

- Description: replace "with a user checkpoint between each" with wording for the unattended run,
  verification, and close-out; stay ≤ 1024 chars. Mirror in `dev-workflow/README.md:13`.
- New `## Run mode` after **Controls**, pointing at `run-modes.md`.
- Step 3 gains the run-mode question. Controls: the plan-skip go-ahead carries the same
  pre-authorization as plan approval; cancel leaves an already-open draft PR untouched and reports it.
- `## 6. Chain` title drops "a user checkpoint between each stage"; its Checkpoints paragraph ends
  checkpoints at the go in unattended mode. The Ship text moves out to `## 8. Ship`.
- New `## 7. Verify`, `## 8. Ship`, `## 9. Close-out`.

### `run-modes.md` (new)

Modes; what the sitting settles and the gate-by-gate mapping (decision 2); the go's
pre-authorization (decision 3); Preflight (decision 4); Stop conditions and the green/failing split
(decision 5); notification (`PushNotification`, else the PR body or Run log plus the final message);
the Run log, and resume: refetch and diff per Controls, then continue from the Run log.

### `verify.md` (new) — step 7

1. **Repo checks** — full suite, lint, type checks as the repo names them.
2. **Each active AC** by its AC→test row: *automated* (run, quote the output line, record the
   commit); *red check* per decision 7; *live read* — read-only commands only (`az … show`,
   `kubectl get`, `terraform plan`), never apply or deploy; *person-only* — not run, unverified, with
   exact steps for the user.
3. **Definition of done** items, each with evidence or marked *post-merge* and carried to close-out.

On failure: up to 2 fix attempts, each logged, then step 7 re-runs in full; a third failure is a
stop. A wrong or untestable AC is an immediate stop, never fixed by editing the AC. Results:
**verified / failed / unverified / not delivered**; a verified row needs a quoted output line. Re-run
on the commit Ship pushes whenever the tree changed (decision 6).

| AC | Check | Kind | Result | Evidence | Base / head / time |
|---|---|---|---|---|---|
| AC-1 | `pytest tests/test_retention.py::test_purge_after_90d` | automated, new | verified | base: `AssertionError: 30 != 90`; head ×2: `1 passed` | `9f8e7d6` / `a1b2c3d` 14:02 |
| AC-2 | `pytest tests/test_export.py::test_csv_header` | automated, new | verified (red n/a — new interface) | base: `ImportError: export`; head ×2: `1 passed` | `9f8e7d6` / `a1b2c3d` 14:03 |
| AC-3 | log in as read-only user, open /admin | person-only | unverified | steps at close-out | — |
| AC-4 | — | deferred | not delivered | "<user's words>" | — |

### `checklist.md`

- Row 9 Present only with the AC→test table filled (AC-n → kind → test name → location) and each AC
  tagged **agent-verifiable** or **person-only**.
- New row 14 **Access and environment**. Unmet or skipped ⇒ unattended unavailable.

### `template.md`

`**Run mode:**` header; Status `Draft | Ready | Partial | Delivered | Cancelled`; Test plan becomes
the AC→test table; new `## Verification evidence` and `## Run log` sections; the stub keeps both when
step 7 ran.

### Chain files

- Lines 3-4 and the closing "return to" lines point at step 7 (Verify), not step 6's Ship.
- `chain-superpowers.md`: design and plan approval in the sitting; the plan-approval question states
  the gate mapping and the pre-authorization; `plan-implementation` then runs without its stage
  checkpoints.
- `chain-mattpocock.md`: after the `to-tickets` coverage check, the "go unattended?" question; the
  Implement stage invokes `implement-spec` in intake mode (decision 9) with the attended fallback;
  "Never replicate these skills" stays, naming `implement-spec` in intake mode as the one skill
  intake invokes. The `/mattpocock-skills:implement` mentions at `SKILL.md:66-67` and
  `chain-mattpocock.md:71-76` are updated.

## Out of scope

- Editing `mattpocock-skills` plugin files, `plan-implementation`, `opening-pull-requests`, or `tdd`;
  intake passes them its recorded answers.
- Post-deploy verification beyond listing *post-merge* DoD items at close-out.
- Behavioural (scenario) tests of the skill; `run.sh` pins presence of each rule, and the full review
  chain judges the rules themselves.

## Testing

`dev-workflow/tests/run.sh` presence assertions, one per load-bearing rule, each string absent from
the skill today and quoted verbatim in the plan's content step: both new files linked; the run-mode
default and Skip rule; the gate mapping; `gh pr create --draft`; the green-baseline rule; the
green/failing stop split; re-verify on the shipped commit; the assertion-failure red rule and
`red n/a — new interface`; pass twice on head; `Partial`; the `implement-spec` intake mode and
attended fallback; the renumbered steps. Existing assertions stay green.

Review tier: **full chain** (skill definitions) — fresh-verifier and codex-adversary on the plan and
on the diff.
