# Intake unattended run, AC verification, and close-out — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let `intaking-work-items` run unattended from plan approval to a draft PR, with every active AC verified by recorded evidence, and a close-out step on the user's return.

**Architecture:** `SKILL.md` stays the outline and gains a Run mode section, step 7 (Verify) and step 8 (Close-out); detail lives in two new reference files, `run-modes.md` and `verify.md`, linked one level deep like the chain files. The template and checklist carry the new artifacts (AC→test table, Verification evidence, Run log). Tests are `grep -qF` presence assertions in `dev-workflow/tests/run.sh`, matching the existing intake block.

**Tech Stack:** Markdown skill files; bash test harness (`bash dev-workflow/tests/run.sh`).

**Spec:** `docs/superpowers/specs/2026-10-09-intake-agentic-run-design.md`

## Global Constraints

- Run modes are exactly `unattended` (default) and `attended`.
- Plan approval pre-authorizes exactly two outward actions: pushing the work branch and opening a **draft** PR, after the full review chain.
- Fix attempts: 2, then all of step 7 re-runs; a third failure is a blocker.
- A new test for an AC must fail on the base commit, checked in a throwaway worktree.
- Live reads are read-only (`az … show`, `kubectl get`, `terraform plan`); never apply or deploy.
- AC results are exactly: verified / failed / unverified / not delivered.
- A person-only AC keeps the PR in draft until confirmed at close-out.
- `SKILL.md` under 500 lines (`run.sh:267`); description ≤ 1024 chars (`run.sh:264`).
- No organisation-specific terms (`run.sh` greps the skill dir for the word `ces`).
- Every existing `run.sh` intake assertion keeps passing.
- The user-level `~/.claude/skills/implement-spec/SKILL.md` is edited only after the user explicitly confirms in chat.

## Review Focus

1. **Permission prompt mid-run** — an unattended session stalls silently on a tool prompt; preflight must tell the user before they leave (Task 3 asserts `permission mode`).
2. **Cancel after a draft PR exists** — the user returns and cancels; cancel must not delete or edit the already-open draft PR, and must report it as left open (Task 3 asserts `draft PR already open`).
3. **Plan skipped in unattended mode** — there is no plan approval to act as the go; the explicit go-ahead from the plan-skip rule must state the same pre-authorization (Task 3 asserts `plan-skip go-ahead`).
4. **Repo with no runnable tests or CI** — the baseline can't run; preflight treats it as a blocker for unattended mode and offers attended (Task 3 asserts `no runnable test suite`).
5. **Resume after a blocked run** — resume must still refetch and diff the ticket, then continue from the Run log, not from memory (Task 3 asserts `continue from the Run log`).

---

### Task 1: Checklist and template artifacts

**Files:**
- Modify: `dev-workflow/skills/intaking-work-items/checklist.md` (rows table; row 9; new row 14)
- Modify: `dev-workflow/skills/intaking-work-items/template.md` (header, Test plan, new sections, stub note)
- Test: `dev-workflow/tests/run.sh` (intake block, after line 311)

**Interfaces:**
- Produces (exact strings later tasks reference): checklist row `**Access and environment**`; AC tags `agent-verifiable` / `person-only`; template header `**Run mode:**`; template sections `## Verification evidence`, `## Run log`; AC→test table header `| AC | Kind | Test name | Location |`; Status value `Delivered`.

- [ ] **Step 1: Add the failing assertions to `run.sh`**

```bash
  grep -qF '**Access and environment**' "$INTAKE_DIR/checklist.md" || ifail "intaking-work-items/checklist.md: missing the Access and environment row"
  grep -qF 'agent-verifiable' "$INTAKE_DIR/checklist.md" || ifail "intaking-work-items/checklist.md: missing the agent-verifiable / person-only AC tag"
  grep -qF '| AC | Kind | Test name | Location |' "$INTAKE_DIR/template.md" || ifail "intaking-work-items/template.md: missing the AC→test table"
  grep -qF '**Run mode:**' "$INTAKE_DIR/template.md" || ifail "intaking-work-items/template.md: missing the Run mode header"
  grep -qF '## Verification evidence' "$INTAKE_DIR/template.md" || ifail "intaking-work-items/template.md: missing the Verification evidence section"
  grep -qF '## Run log' "$INTAKE_DIR/template.md" || ifail "intaking-work-items/template.md: missing the Run log section"
  grep -qF 'Delivered' "$INTAKE_DIR/template.md" || ifail "intaking-work-items/template.md: Status missing Delivered"
```

- [ ] **Step 2: Run, expect FAIL** — `bash dev-workflow/tests/run.sh` → output names each of the 7 messages above.

- [ ] **Step 3: Edit `checklist.md`**
  - Row 9 "Present means": the AC→test table is filled for every active AC (AC-n → kind: unit / integration / live read / person-only → test name → location), and each AC is tagged `agent-verifiable` or `person-only`.
  - New row 14 `**Access and environment**`: Present = the agent can run the test suite and reach every environment, credential, and cloud read the checks need, named with how it was confirmed. Signal: "needs prod access" with no check; tests that only run in CI.
  - Rating rules: in unattended mode an unmet row 14 is a blocker, like rows 7/12.

- [ ] **Step 4: Edit `template.md`**
  - Header: add `**Run mode:** <unattended | attended>` after `**Chain:**`; Status gains `Delivered` (`Draft | Ready | Delivered | Cancelled`).
  - `## Test plan` becomes the AC→test table with header `| AC | Kind | Test name | Location |`, plus a line for repo-wide checks (suite, lint, types).
  - New `## Verification evidence` section: the table from spec § verify.md (columns `| AC | Check | Kind | Result | Evidence | Commit / time |`), before step 7: "None — step 7 not run".
  - New `## Run log` section: `| Time | Stage | Event | Attempts | Blocker |`, before the run: "None — run not started".
  - Stub note: the stub keeps **Verification evidence** and **Run log** when step 7 ran.

- [ ] **Step 5: Run, expect PASS** — `bash dev-workflow/tests/run.sh` → no intake failures; exit 0.

- [ ] **Step 6: Commit** — `git add` the three files; `feat(dev-workflow): intake template/checklist carry AC→test table, evidence, run log`.

### Task 2: `verify.md` and step 7

**Files:**
- Create: `dev-workflow/skills/intaking-work-items/verify.md`
- Modify: `dev-workflow/skills/intaking-work-items/SKILL.md` (new `## 7. Verify` after step 6's Ship-preceding text; Ship paragraph at ~line 280)
- Test: `dev-workflow/tests/run.sh` (support-file loop at line 270; new assertions)

**Interfaces:**
- Consumes: Task 1's `## Verification evidence`, AC→test table, `person-only`.
- Produces: heading `## 7. Verify` in SKILL.md; Ship text cites "the step-7 evidence table".

- [ ] **Step 1: Add failing assertions** — add `verify.md` to the support-file loop at `run.sh:270`, and:

```bash
  grep -qF '## 7. Verify' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: missing step 7 Verify"
  grep -qF 'fails on the base commit' "$INTAKE_DIR/verify.md" || ifail "intaking-work-items/verify.md: missing the red-on-base check"
  grep -qF '2 fix attempts' "$INTAKE_DIR/verify.md" || ifail "intaking-work-items/verify.md: missing the 2-attempt rule"
  grep -qF 'verified / failed / unverified / not delivered' "$INTAKE_DIR/verify.md" || ifail "intaking-work-items/verify.md: missing the result vocabulary"
  grep -qF 'read-only commands only' "$INTAKE_DIR/verify.md" || ifail "intaking-work-items/verify.md: missing the read-only live-check rule"
  grep -qF 'post-merge' "$INTAKE_DIR/verify.md" || ifail "intaking-work-items/verify.md: missing post-merge DoD handling"
  grep -qF 'quoted output line' "$INTAKE_DIR/verify.md" || ifail "intaking-work-items/verify.md: missing the evidence rule"
  grep -qF 'never trust a worker' "$INTAKE_DIR/verify.md" || ifail "intaking-work-items/verify.md: missing the re-run-on-final-branch rule"
```

- [ ] **Step 2: Run, expect FAIL** — every new message above, plus the loop's `verify.md not found` / `does not link verify.md`.

- [ ] **Step 3: Write `verify.md`** — content per spec § `verify.md`: when (once, final branch, after all merges, before the review chain; "never trust a worker's report — re-run it"); order (repo checks → each active AC by kind, including the red check in a throwaway worktree "a new test must fail on the base commit" → DoD with `post-merge`); failure loop ("up to 2 fix attempts", each logged in the Run log, then step 7 re-runs; third failure is a blocker → `run-modes.md`); a wrong/untestable AC is an immediate blocker, never fixed by editing the AC; result vocabulary; "a verified row needs a quoted output line"; the evidence table with the spec's example rows; attended mode runs the same step with the user present.

- [ ] **Step 4: Edit `SKILL.md`** — add `## 7. Verify` (≤8 lines: runs in both modes, link `[verify.md](verify.md)`, writes Verification evidence, gates Ship). Ship paragraph: the PR body carries the step-7 evidence table instead of only listing delivered AC numbers; failed/unverified rows are stated, not hidden.

- [ ] **Step 5: Run, expect PASS** — exit 0.

- [ ] **Step 6: Commit** — `feat(dev-workflow): intake step 7 verifies every active AC with evidence`.

### Task 3: `run-modes.md`, Run mode section, Controls interactions

**Files:**
- Create: `dev-workflow/skills/intaking-work-items/run-modes.md`
- Modify: `SKILL.md` — new `## Run mode` after `## Controls: skip and cancel` (~line 102); step 3 (run-mode question); Controls cancel bullet (~line 82) and plan-skip bullet (~line 62); Ship (draft in unattended mode)
- Test: `dev-workflow/tests/run.sh`

**Interfaces:**
- Consumes: Task 1 `**Run mode:**`, `## Run log`, row 14; Task 2 `## 7. Verify`.
- Produces: `## Run mode` heading; the phrase `pre-authorizes exactly two outward actions` (Task 4 cites it).

- [ ] **Step 1: Add failing assertions** — add `run-modes.md` to the support-file loop, and:

```bash
  grep -qF '## Run mode' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: missing the Run mode section"
  grep -qF 'pre-authorizes exactly two outward actions' "$INTAKE_DIR/run-modes.md" || ifail "intaking-work-items/run-modes.md: missing the draft-only pre-authorization"
  grep -qF '## Stop conditions' "$INTAKE_DIR/run-modes.md" || ifail "intaking-work-items/run-modes.md: missing Stop conditions"
  grep -qF '## Preflight' "$INTAKE_DIR/run-modes.md" || ifail "intaking-work-items/run-modes.md: missing Preflight"
  grep -qF 'permission mode' "$INTAKE_DIR/run-modes.md" || ifail "intaking-work-items/run-modes.md: preflight missing the permission-mode check"
  grep -qF 'no runnable test suite' "$INTAKE_DIR/run-modes.md" || ifail "intaking-work-items/run-modes.md: preflight missing the no-test-suite blocker"
  grep -qF 'PushNotification' "$INTAKE_DIR/run-modes.md" || ifail "intaking-work-items/run-modes.md: missing the notification channel"
  grep -qF 'continue from the Run log' "$INTAKE_DIR/run-modes.md" || ifail "intaking-work-items/run-modes.md: missing resume-from-Run-log"
  grep -qF 'draft PR already open' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: cancel rule missing the open-draft-PR case"
  grep -qF 'plan-skip go-ahead' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: plan-skip rule missing the unattended pre-authorization"
```

- [ ] **Step 2: Run, expect FAIL** — every new message above, plus the loop's `run-modes.md` messages.

- [ ] **Step 3: Write `run-modes.md`** — sections: `## Modes` (unattended default, attended = today's checkpoints); `## What the sitting settles` (gap questions, run mode, chain, requirements OK, writebacks, design approval, plan approval — "plan approval pre-authorizes exactly two outward actions: pushing the work branch and opening a draft PR, after the full review chain"; nothing else outward until close-out); `## Preflight` (user still present: row 14 passed; baseline suite on the base commit with pre-existing failures recorded — "no runnable test suite" is a blocker for unattended, offer attended; permission mode won't stall on prompts — say so before the user leaves; `PushNotification` available, else draft PR body + final message); `## Stop conditions` (the five from spec decision 3, each: push a draft PR if a branch exists, record blocker in Run log + PR body, notify, stop); `## Run log` (written as the run goes; on resume, refetch and diff per Controls, then "continue from the Run log").

- [ ] **Step 4: Edit `SKILL.md`**
  - `## Run mode` (≤8 lines): the two modes, default unattended, link `[run-modes.md](run-modes.md)`, record in the doc's `**Run mode:**`.
  - Step 3: after the gate passes, ask run mode (unattended recommended / attended / Skip) — one `AskUserQuestion`.
  - Plan-skip bullet: in unattended mode the explicit "plan-skip go-ahead" states the same pre-authorization as plan approval.
  - Cancel bullet: if a "draft PR already open" exists, cancel leaves it untouched and reports it in the summary; it is never closed or edited without a separate yes.
  - Ship: in unattended mode the PR is opened as a draft; it stays draft while any AC is failed or person-only unverified.
  - Step 6 **Checkpoints** paragraph (~line 260): in unattended mode the checkpoints end at plan approval; after it, only `run-modes.md` § Stop conditions halt the run.

- [ ] **Step 5: Run, expect PASS** — exit 0; `wc -l SKILL.md` < 500.

- [ ] **Step 6: Commit** — `feat(dev-workflow): intake unattended run mode with preflight and stop conditions`.

### Task 4: Chain files

**Files:**
- Modify: `dev-workflow/skills/intaking-work-items/chain-superpowers.md` (stages 1–3)
- Modify: `dev-workflow/skills/intaking-work-items/chain-mattpocock.md` (Implement stage ~lines 50-60; intro rule ~lines 8-17)
- Test: `dev-workflow/tests/run.sh`

**Interfaces:**
- Consumes: Task 3 `pre-authorizes exactly two outward actions`, `## Stop conditions`.

- [ ] **Step 1: Add failing assertions**

```bash
  grep -qF 'without its stage checkpoints' "$INTAKE_DIR/chain-superpowers.md" || ifail "intaking-work-items/chain-superpowers.md: missing the unattended implement rule"
  grep -qF 'pre-authorizes' "$INTAKE_DIR/chain-superpowers.md" || ifail "intaking-work-items/chain-superpowers.md: plan approval missing the pre-authorization"
  grep -qF 'implement-spec' "$INTAKE_DIR/chain-mattpocock.md" || ifail "intaking-work-items/chain-mattpocock.md: Implement stage does not use implement-spec"
  grep -qF 'leave the PR as a draft and close no tickets' "$INTAKE_DIR/chain-mattpocock.md" || ifail "intaking-work-items/chain-mattpocock.md: missing intake mode for implement-spec"
```

(The existing `Never replicate these skills` assertion at `run.sh:309` must stay green.)

- [ ] **Step 2: Run, expect FAIL** — the 4 messages.

- [ ] **Step 3: Edit `chain-superpowers.md`** — unattended: brainstorming's spec review and writing-plans' approval happen in the sitting; the plan-approval question names what it pre-authorizes (link `run-modes.md`); `plan-implementation` then runs "without its stage checkpoints", stopping only on `run-modes.md` § Stop conditions; then step 7.

- [ ] **Step 4: Edit `chain-mattpocock.md`** — Implement stage: invoke the user-level `implement-spec` skill via the Skill tool with the spec issue URL and the instruction "intake mode: leave the PR as a draft and close no tickets"; if it still carries `disable-model-invocation`, say so and the user types `/implement-spec <spec-url>` — the unattended stretch starts after that. `to-spec`/`to-tickets` stay user-typed, in the sitting. Keep "Never replicate these skills", adding that `implement-spec` in intake mode is the one skill intake invokes. After it returns: step 7, not Ship.

- [ ] **Step 5: Run, expect PASS** — exit 0.

- [ ] **Step 6: Commit** — `feat(dev-workflow): intake chains run unattended after plan approval; mattpocock uses implement-spec`.

### Task 5: Step 8 close-out, description, docs, version

**Files:**
- Modify: `SKILL.md` (new `## 8. Close-out` before `## Gotchas`; frontmatter description)
- Modify: `dev-workflow/README.md:13` (skills row)
- Modify: `docs/superpowers/specs/2026-10-07-intake-chain-choice-design.md:23` (append a dated note that intake now uses the user-level `implement-spec`, see the 2026-10-09 design)
- Modify: `dev-workflow/.claude-plugin/plugin.json:3` and `.claude-plugin/marketplace.json:51` → `0.1.6`
- Test: `dev-workflow/tests/run.sh`

- [ ] **Step 1: Add failing assertions**

```bash
  grep -qF '## 8. Close-out' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: missing step 8 Close-out"
  grep -qF '/retro' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: close-out missing the /retro offer"
  grep -qF 'skill-retrospective' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: close-out missing the skill-retrospective route"
  grep -qF 'separate branch' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: retro changes not kept off the ticket PR"
```

- [ ] **Step 2: Run, expect FAIL** — the 4 messages.

- [ ] **Step 3: Write `## 8. Close-out`** — per spec § Step 8: show Run log, evidence table, blockers; walk person-only AC and record results; offer each outward action separately under step 5's per-action rule (mark ready — state failed/unverified first; Jira transition; ticket comment; close tickets as the repo allows); set Status `Delivered`; offer `/retro` on the session, route skill/memory findings to `skill-retrospective`, accepted environment changes go on a separate branch and PR. Each offer has a Skip.

- [ ] **Step 4: Description** — add "verifies each AC with recorded evidence, runs unattended to a draft PR, and closes out on return" to the frontmatter description; stay ≤ 1024 chars. Mirror in `dev-workflow/README.md:13`.

- [ ] **Step 5: Docs and version** — the dated note at the 2026-10-07 design line 23; bump both version fields to `0.1.6`.

- [ ] **Step 6: Run, expect PASS** — `bash dev-workflow/tests/run.sh` exit 0; `grep -n '"version": "0.1.6"' dev-workflow/.claude-plugin/plugin.json .claude-plugin/marketplace.json` → 2 lines.

- [ ] **Step 7: Commit** — `feat(dev-workflow): intake step 8 close-out with /retro; bump 0.1.6`.

### Task 6: User-level `implement-spec` intake mode (outside the repo)

**Files:**
- Modify: `~/.claude/skills/implement-spec/SKILL.md` (frontmatter line 4; step 8)

- [ ] **Step 1: Ask the user** — show the exact two edits below and get an explicit yes in chat. No yes → skip this task; Task 4's fallback (user types the command) covers it.
- [ ] **Step 2: Edit** — delete `disable-model-invocation: true`; append to step 8: "When called from intake (intake mode), leave the PR as a draft and close no tickets; report the integration branch and the PR."
- [ ] **Step 3: Verify** — `grep -c 'disable-model-invocation' ~/.claude/skills/implement-spec/SKILL.md` → `0`; `grep -c 'intake mode' ~/.claude/skills/implement-spec/SKILL.md` → `1`. No commit (not in the repo).

### Final: review chain

- [ ] `bash dev-workflow/tests/run.sh` exit 0 on the branch tip.
- [ ] Full tier: dispatch `dev-workflow:fresh-verifier` and `dev-workflow:codex-adversary` in one message on `git diff main...HEAD` against the spec; fix findings; then `opening-pull-requests`.
