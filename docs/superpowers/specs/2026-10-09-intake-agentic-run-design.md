# intaking-work-items: unattended run, AC verification, and close-out — design

- **Date:** 2026-10-09
- **Skill:** `dev-workflow/skills/intaking-work-items/`
- **Status:** Approved design, pending implementation plan

## Problem

Intake settles requirements well, but everything after step 6 assumes a human at every checkpoint,
and nothing between implementation and Ship checks the work against the acceptance criteria:

- The template has a `*Verify:*` line per AC and a Definition of done (`template.md:45-47`, `:49-52`),
  but no step runs them. Step 6 goes straight from the implement stage to Ship (`SKILL.md:280`).
- Checklist row 9 "Test plan" (`checklist.md:24`) asks how each AC will be verified, but nothing ties
  an AC to a concrete test that is shown to fail first and pass after.
- Every stage of step 6 ends in a user checkpoint (`SKILL.md:260-263`), so a ticket cannot be
  intaken and then left to run.

## Goal

Pull a ticket, answer every question in one sitting, approve design and plan in that same sitting,
then walk away. The run builds, verifies each AC with recorded evidence, and opens a **draft** PR.
Everything else outward-facing waits for the user's return.

Success: one intake sitting, then a draft PR whose body carries a per-AC evidence table, with any
blocker stated in the PR and the requirements doc and the user notified.

## Facts this design relies on (verified 2026-10-09)

- `mattpocock-skills` 1.2.3 is the only installed version; `implement-spec` and `retro` live under
  its `skills/in-progress/` group, not the stable set.
- The user keeps user-level copies at `~/.claude/skills/implement-spec/` and `~/.claude/skills/retro/`.
  `retro` is byte-identical to the plugin copy. `implement-spec` differs: description
  "Implement the result of /to-spec and /to-tickets in code."; per-ticket worktrees whose implementer
  calls the `tdd` skill; an integration branch; a draft PR only when the tracker closes work through
  PRs or the user asks; `code-review` via the Skill tool; step 8 marks the PR ready or closes the
  tickets. Both copies carry `disable-model-invocation: true`.
- `retro` writes nothing: it reads session logs and returns ranked suggestions (navigation,
  automated checks, coding standards, AGENTS.md, tool economy, information access).
- `dev-workflow:skill-retrospective` routes learnings to memory, a per-repo overlay, or skills; it
  never touches AGENTS.md, hooks, or lint (`skill-retrospective/SKILL.md:46-48`).
- The mattpocock chain today ends with the user typing `/mattpocock-skills:implement`
  (`chain-mattpocock.md`). `dev-workflow/tests/run.sh:270` asserts the chain files exist; `:309` asserts
  `chain-mattpocock.md` keeps the "Never replicate these skills" rule; `:310` asserts the GitHub-only gate.
- `SKILL.md` is 305 lines, at the ~300-line progressive-disclosure limit the repo's skill
  conventions use.

## Decisions

1. **Run modes: `unattended` (default) and `attended`.** Attended is today's behaviour. Unattended
   front-loads every human decision: gap questions, run mode, chain, requirements OK, writebacks,
   design approval, plan approval. After plan approval the run proceeds without checkpoints.
2. **Plan approval is the go, and pre-authorizes exactly two outward actions:** pushing the work
   branch and opening a **draft** PR, after the full review chain. Nothing else — marking ready,
   ticket comments, Jira transitions, closing tickets — happens before the user returns.
3. **Stop conditions** end the run with a draft PR (if there is a branch to push), the blocker
   recorded in the requirements doc and PR body, and a notification:
   - a check still failing after 2 fix attempts;
   - an AC found wrong or untestable (immediate stop; never "fixed" by editing the AC);
   - work growing beyond the agreed scope;
   - a repo gate or missing access;
   - any outward write beyond decision 2.
4. **A person-only AC keeps the PR in draft** until the user confirms it at close-out.
5. **Verification gate (new step 7)** runs on the final branch, re-running everything rather than
   trusting worker reports. A new test written for an AC must **fail on the base commit** (checked
   in a throwaway worktree); a test that passes there counts as failed.
6. **mattpocock chain uses the user's `implement-spec` copy**, not the plugin's `implement`. Two
   edits to `~/.claude/skills/implement-spec/SKILL.md` (outside the repo, applied only on the user's
   confirmation): drop `disable-model-invocation`, and make step 8 leave the PR draft and close no
   tickets when called from intake. A hand-off instruction alone is too weak against the skill's own
   step 8.
7. **Close-out (new step 8)** runs on the user's return and offers `/retro`. Skill and memory
   findings go to `dev-workflow:skill-retrospective`; accepted environment changes go on a separate
   branch and PR, never into the ticket's PR.
8. **Layout: thin `SKILL.md`, detail in reference files** (`run-modes.md`, `verify.md`), as the chain
   files already do. Rejected: a standalone verifying skill (no second caller yet), and inlining
   everything (~450 lines, buries the gate).

## Flow

| Step | Who | What |
|---|---|---|
| 0–2 | user | Repo procedure, fetch, gap analysis — now with the access row and the person-only AC tag |
| 3 | user | Close gaps; choose run mode (default unattended) and chain |
| 4–5 | user | Requirements doc with the AC→test table; confirmed writebacks |
| 6a | user | superpowers: design and plan approved in the sitting. mattpocock: user types `to-spec`, `to-tickets`. **Plan approval = go** (decision 2) |
| 6b | unattended | Implement: `plan-implementation`, or `implement-spec` in intake mode |
| 7 | unattended | Verify (below); 2 fix attempts, then blocker |
| Ship | unattended | Full review chain, push, draft PR with the per-AC table; on a blocker, draft PR + blocker + notification |
| 8 | user, on return | Close-out (below) |

Attended mode is the same flow with today's checkpoint between every stage.

## Components

### `SKILL.md`

- New **Run mode** section after **Controls**: the two modes, a pointer to `run-modes.md`.
- Step 3 gains the run-mode choice; step 6 keeps chain choice and points the unattended stretch at
  `run-modes.md`.
- New **7. Verify** → `verify.md`. New **8. Close-out**.
- Ship: the PR is opened as a draft in unattended mode; the PR body carries the step-7 table.
- Stays near its current length; the detail moves out.

### `run-modes.md` (new)

- What the sitting must produce before the run starts, and what plan approval pre-authorizes.
- **Preflight** while the user is still present:
  1. checklist access row passed;
  2. baseline: run the suite once on the base commit and record pre-existing failures so they are
     not blamed on this work;
  3. permission mode will not stall on prompts — if it would, say so before the user leaves;
  4. notification available (`PushNotification`), else fall back to the draft PR body plus the
     final message.
- Stop conditions (decision 3), the 2-attempt rule, and what a blocked run leaves behind.
- The **Run log**: timestamped stage, attempts, and blockers, written to the requirements doc as
  the run goes. Resume (existing **Controls** rules) starts from it.

### `verify.md` (new) — step 7

Order:
1. **Repo checks** — full suite, lint, type checks as the repo's AGENTS.md or CI names them. A
   failure counts as failed.
2. **Each active AC**, by its row in the AC→test table:
   - *automated*: run the named test or command; quote the output line; record the commit;
   - *red check*: each new test also runs against the base commit in a throwaway worktree and must
     fail there;
   - *live read*: read-only commands only (`az … show`, `kubectl get`, `terraform plan`); never
     apply or deploy;
   - *person-only*: not run; marked unverified, with exact steps for the user at close-out.
3. **Definition of done** items, each with evidence, or marked *post-merge* (e.g. "deployed to
   prod") and carried to close-out, not counted as failed.

On failure: up to 2 fix attempts, each logged, then all of step 7 re-runs. A third failure is a
blocker. Results: **verified / failed / unverified / not delivered**. A verified row needs a quoted
output line; prose like "tests pass" is not evidence.

Evidence table (requirements doc **Verification evidence** section and PR body):

| AC | Check | Kind | Result | Evidence | Commit / time |
|---|---|---|---|---|---|
| AC-1 | `pytest tests/test_retention.py::test_purge_after_90d` | automated, new | verified (red on base) | `1 passed in 0.4s` | `a1b2c3d` 2026-10-09 14:02 |
| AC-3 | log in as read-only user, open /admin | person-only | unverified | steps at close-out | — |
| AC-4 | — | deferred | not delivered | "<user's words>" | — |

### `checklist.md`

- Row 9 "Test plan" becomes Present only with the AC→test table filled: AC-n → kind (unit /
  integration / live read / person-only) → planned test name and location.
- Each AC is tagged **agent-verifiable** or **person-only**.
- New row **Access and environment**: the agent can run the tests and reach every environment,
  credential, and cloud read the checks need. Unmet access is a blocker in unattended mode.

### `template.md`

- **Run mode** header line.
- **Test plan** becomes the AC→test table.
- New **Verification evidence** and **Run log** sections.
- Status gains `Delivered`, set at close-out.
- Stub doc keeps the evidence table when step 7 ran.

### `chain-superpowers.md`

- Unattended: brainstorming's spec review and writing-plans' approval both happen in the sitting.
  The plan-approval question states what it pre-authorizes (decision 2).
- `plan-implementation` then runs without its stage checkpoints, stopping only on the stop
  conditions.

### `chain-mattpocock.md`

- The Implement stage invokes the user's `implement-spec` (Skill tool) in intake mode, replacing
  `/mattpocock-skills:implement`. `to-spec` and `to-tickets` stay user-typed, in the sitting.
- If the user's `implement-spec` still carries `disable-model-invocation`, intake says so and the
  user types it — unattended then begins after that command.

### Step 8 — close-out

1. Show the Run log, the evidence table, and any blocker.
2. Walk each person-only AC with the user and record the result.
3. Offer each outward action separately, per the existing step-5 rule:
   - mark the PR ready — stating any failed or unverified AC first;
   - Jira transition; ticket comment; close tickets as the repo allows.
4. Set Status to `Delivered`.
5. Offer `/retro` on the session. Route skill/memory findings to `skill-retrospective`; accepted
   environment changes go on a separate branch and PR.

## Out of scope

- Editing `mattpocock-skills` plugin files, or vendoring the user's `implement-spec` into this repo.
- Post-deploy verification beyond listing *post-merge* DoD items at close-out.
- Changing `plan-implementation` or `opening-pull-requests` themselves; intake only passes them
  the pre-authorization and the draft flag.

## Testing

`dev-workflow/tests/run.sh` assertions:
- `run-modes.md` and `verify.md` exist and contain: "fails on the base commit", the 2-attempt rule,
  the draft-only pre-authorization, and the stop conditions.
- `SKILL.md` has the Run mode section and steps 7 and 8.
- `template.md` has Verification evidence, Run log, and the AC→test table; `checklist.md` has the
  access row.
- `chain-mattpocock.md` names `implement-spec` and intake mode (draft, no ticket closes).
- Existing assertions (`run.sh:270`, `:309-310`) keep passing: the "Never replicate these skills" rule
  stays, with `implement-spec` in intake mode named as the one skill intake may invoke.
- Update the version pin reference in `2026-10-07-intake-chain-choice-design.md:23`.

Review tier: **full chain** (skill definitions) — fresh-verifier and codex-adversary on the plan and
on the diff.
