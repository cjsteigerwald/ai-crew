# Intake unattended run, AC verification, and close-out — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let `intaking-work-items` run unattended from the go to a draft PR, verify every agent-verifiable AC with evidence on the shipped commit, stop safely on blockers, and close out on the user's return.

**Architecture:** `SKILL.md` stays the outline: a new Run mode section, and steps renumbered to 6 Chain, 7 Verify, 8 Ship, 9 Close-out. Detail lives in two new reference files, `run-modes.md` and `verify.md`, linked one level deep like the chain files. Template and checklist carry the artifacts. Tests are `grep -qF` presence assertions (and a few negative ones) in the intake block of `dev-workflow/tests/run.sh`.

**Tech Stack:** Markdown skill files; bash test harness — run with `bash dev-workflow/tests/run.sh` (prints `PASSED` and exits 0 when clean).

**Spec:** `docs/superpowers/specs/2026-10-09-intake-agentic-run-design.md` (revision 3). Read its Decisions 1-12 before starting; every content step below cites them.

## Global Constraints

- **Every assertion string must appear verbatim in the content you write.** Each content step lists the exact phrases it must contain, in backticks; write them character for character.
- Run modes: exactly `unattended` (default) and `attended`; Skip on the run-mode question = attended.
- The go pre-authorizes exactly two outward actions: push the work branch; open one draft PR with `gh pr create --draft`, after verification and the full review chain.
- Fix attempts: up to 2, then step 7 re-runs in full; a third failure is a stop.
- Results vocabulary: verified / failed / unverified / not delivered. Status vocabulary: Draft | Ready | Partial | Delivered | Cancelled.
- `SKILL.md` under 500 lines (`run.sh:267`); description ≤ 1024 chars (`run.sh:264`).
- No organisation-specific terms: `run.sh:314` fails on the whole word `ces` anywhere in the skill dir.
- Every existing intake assertion (`run.sh:277-312`) stays green.
- Do not edit `plan-implementation`, `opening-pull-requests`, `tdd`, or any `mattpocock-skills` plugin file.
- `~/.claude/skills/implement-spec/SKILL.md` is edited only in Task 6, only after the user's explicit yes in chat.

## Review Focus

1. **A gate nobody pre-answered** stalls the run silently — `run-modes.md` must list the gate mapping and make "a gate the sitting did not answer" a stop condition (Task 2).
2. **Evidence for a different commit than the one shipped** — Ship's rebase or a review fix changes the tree; verify must re-run on the commit Ship pushes (Tasks 3, 4).
3. **Red-on-base passing for the wrong reason** — an import error on base is not behavioural evidence (Task 3).
4. **Cancel after a draft PR exists** — leave it untouched and report it (Task 2).
5. **mattpocock chain without the `implement-spec` edits** — falls back to attended with `/mattpocock-skills:implement`; the unedited `implement-spec` is never used in either mode (Task 4).

---

### Task 1: Checklist and template artifacts

**Files:** Modify `dev-workflow/skills/intaking-work-items/checklist.md`, `.../template.md`; Test `dev-workflow/tests/run.sh` (append inside the intake `if` block, before the `ces` check at ~line 312).

**Interfaces — Produces:** row `**Access and environment**`; AC tags `agent-verifiable` / `person-only`; template header `**Run mode:**`; sections `## Verification evidence`, `## Run log`; AC→test header `| AC | Kind | Seam | Catches / misses | Test name | Location |`; Status `Ready | Partial | Delivered`.

- [ ] **Step 1: Failing assertions**

```bash
  grep -qF '**Access and environment**' "$INTAKE_DIR/checklist.md" || ifail "intaking-work-items/checklist.md: missing the Access and environment row"
  grep -qF 'agent-verifiable' "$INTAKE_DIR/checklist.md" || ifail "intaking-work-items/checklist.md: missing the agent-verifiable / person-only AC tag"
  grep -qF 'unattended unavailable' "$INTAKE_DIR/checklist.md" || ifail "intaking-work-items/checklist.md: row 14 missing the unattended-unavailable rule"
  grep -qF '| AC | Kind | Seam | Catches / misses | Test name | Location |' "$INTAKE_DIR/template.md" || ifail "intaking-work-items/template.md: missing the AC→test table"
  grep -qF '**Run mode:**' "$INTAKE_DIR/template.md" || ifail "intaking-work-items/template.md: missing the Run mode header"
  grep -qF '## Verification evidence' "$INTAKE_DIR/template.md" || ifail "intaking-work-items/template.md: missing the Verification evidence section"
  grep -qF '## Run log' "$INTAKE_DIR/template.md" || ifail "intaking-work-items/template.md: missing the Run log section"
  grep -qF 'Ready | Partial | Delivered' "$INTAKE_DIR/template.md" || ifail "intaking-work-items/template.md: Status missing Partial / Delivered"
```

- [ ] **Step 2: Run** — `bash dev-workflow/tests/run.sh` → FAIL listing these 8 messages.
- [ ] **Step 3: `checklist.md`**
  - Row 9 "Present means": the AC→test table is filled for every active AC (AC-n → kind: unit / integration / live read / person-only → seam, the public interface the test goes through → what it catches and misses → test name → location) and each AC is tagged `agent-verifiable` or `person-only`. This table is what step 4 approves as the `tdd` seam confirmation (spec decision 2).
  - New row 14 `**Access and environment**`: Present = the agent can run the suite and reach every environment, credential, and cloud read the checks need, each named with how it was confirmed. Signals: "needs prod access" unchecked; tests that only run in CI.
  - Rating rules bullet: "Row 14 unmet or skipped ⇒ `unattended unavailable`; offer attended."
- [ ] **Step 4: `template.md`**
  - Header: `**Run mode:** <unattended | attended>` after `**Chain:**`; Status line becomes `<Draft | Ready | Partial | Delivered | Cancelled>`.
  - `## Test plan`: the table `| AC | Kind | Seam | Catches / misses | Test name | Location |`, plus one line naming the repo-wide checks (suite, lint, types).
  - `## Verification evidence`: columns `| AC | Check | Kind | Result | Evidence | Base / head / time |` with the four example rows from spec § `verify.md`; placeholder "None — step 7 not run".
  - `## Run log`: `| Time | Step | Event | Attempt | Blocker |`; placeholder "None — run not started".
  - Stub note: the stub keeps Verification evidence and Run log when step 7 ran.
- [ ] **Step 5: Run** → `PASSED`.
- [ ] **Step 6: Commit** — `feat(dev-workflow): intake template/checklist carry AC→test table, evidence, run log`.

### Task 2: `run-modes.md`, Run mode section, Controls

**Files:** Create `.../intaking-work-items/run-modes.md`; Modify `SKILL.md` (new `## Run mode` after `## Controls: skip and cancel`, ~line 102; step 3 end, ~line 199; Controls plan-skip bullet ~line 62 and cancel bullet ~line 82); Test `run.sh`.

**Interfaces — Consumes:** Task 1 `**Run mode:**`, `## Run log`, row 14. **Produces:** `## Run mode`; `run-modes.md` headings `## Preflight`, `## Stop conditions`; phrase `pre-authorizes exactly two outward actions`.

- [ ] **Step 1: Failing assertions** — add `run-modes.md` to the support-file loop at `run.sh:270`, and:

```bash
  grep -qF '## Run mode' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: missing the Run mode section"
  grep -qF 'Skip on the run-mode question means attended' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: missing the run-mode Skip rule"
  grep -qF '`unattended` is the default' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: missing the run-mode default"
  grep -qF 'plan-skip go-ahead' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: plan-skip rule missing the pre-authorization"
  grep -qF 'draft PR already open' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: cancel rule missing the open-draft-PR case"
  grep -qF 'pre-authorizes exactly two outward actions' "$INTAKE_DIR/run-modes.md" || ifail "intaking-work-items/run-modes.md: missing the go's pre-authorization"
  grep -qF 'gh pr create --draft' "$INTAKE_DIR/run-modes.md" || ifail "intaking-work-items/run-modes.md: missing the draft PR command"
  grep -qF 'is the seam confirmation' "$INTAKE_DIR/run-modes.md" || ifail "intaking-work-items/run-modes.md: gate mapping missing the tdd seam answer"
  grep -qF 'answers gate 8' "$INTAKE_DIR/run-modes.md" || ifail "intaking-work-items/run-modes.md: gate mapping missing opening-pull-requests gate 8"
  grep -qF 'a gate the sitting did not answer' "$INTAKE_DIR/run-modes.md" || ifail "intaking-work-items/run-modes.md: missing the unanswered-gate stop"
  grep -qF '## Preflight' "$INTAKE_DIR/run-modes.md" || ifail "intaking-work-items/run-modes.md: missing Preflight"
  grep -qF 'baseline is green' "$INTAKE_DIR/run-modes.md" || ifail "intaking-work-items/run-modes.md: missing the green-baseline rule"
  grep -qF 'permission mode' "$INTAKE_DIR/run-modes.md" || ifail "intaking-work-items/run-modes.md: preflight missing the permission-mode check"
  grep -qF '## Stop conditions' "$INTAKE_DIR/run-modes.md" || ifail "intaking-work-items/run-modes.md: missing Stop conditions"
  grep -qF 'implementation blocker' "$INTAKE_DIR/run-modes.md" || ifail "intaking-work-items/run-modes.md: missing the implementation-blocker path"
  grep -qF 'publication blocker' "$INTAKE_DIR/run-modes.md" || ifail "intaking-work-items/run-modes.md: missing the publication-blocker path"
  grep -qF 'a seam not in the AC→test table' "$INTAKE_DIR/run-modes.md" || ifail "intaking-work-items/run-modes.md: missing the missing-seam stop"
  grep -qF 'before every go' "$INTAKE_DIR/run-modes.md" || ifail "intaking-work-items/run-modes.md: preflight not required before every go"
  grep -qF 'stop locally' "$INTAKE_DIR/run-modes.md" || ifail "intaking-work-items/run-modes.md: missing the local-stop path"
  grep -qF 'PushNotification' "$INTAKE_DIR/run-modes.md" || ifail "intaking-work-items/run-modes.md: missing the notification channel"
  grep -qF 'continue from the Run log' "$INTAKE_DIR/run-modes.md" || ifail "intaking-work-items/run-modes.md: missing resume-from-Run-log"
```

- [ ] **Step 2: Run** → FAIL with these messages plus the loop's two `run-modes.md` messages.
- [ ] **Step 3: Write `run-modes.md`** (spec decisions 1-5), sections and required phrases:
  - `## Modes` — unattended default, attended = today's checkpoints.
  - `## What the sitting settles` — the gate mapping: "the approved AC→test table `is the seam confirmation` `tdd` requires; it is handed to every implementer as the confirmed seam list"; "plan approval answers `plan-implementation`'s commit/push/PR prompt and `answers gate 8` of `opening-pull-requests`"; the mattpocock "go unattended?" question; each answer recorded in the Run log. Then: "The go `pre-authorizes exactly two outward actions`: pushing the work branch, and opening one draft PR with `gh pr create --draft` after step 7 and the full review chain pass." List what stays forbidden until close-out.
  - `## Preflight` — while the user is present; it runs `before every go` (plan approval, the mattpocock go question, the plan-skip or chain-skip go-ahead): row 14 Present; row 9 Present — the AC→test table approved (a skipped row 9 means attended only); "the `baseline is green`" — full suite and lint pass on the base commit; red baseline or no runnable suite ⇒ attended only; the `permission mode` won't stall on prompts (say so before the user leaves); `PushNotification` available, else the fallback (PR body or Run log + final message) accepted.
  - `## Stop conditions` — the six from decision 5, including "`a gate the sitting did not answer`" and "`a seam not in the AC→test table`". Then the two kinds: "`implementation blocker` (scope, a wrong or untestable AC, a person-only gap, a missing seam) with checks green: run the review chain, push, open the draft PR with the blocker in its body, notify — only if every publication gate is satisfied" / "`publication blocker` (a repo gate, missing push or PR access, an unanswered publication gate) or failing checks: `stop locally` — commits stay on the branch, the Run log and final message carry the blocker, notify; nothing is pushed. Repo gates keep step 0's precedence."
  - `## Run log` — append as the run goes (time, step, event, attempt, blocker); on resume, refetch and diff per Controls, then "`continue from the Run log`".
- [ ] **Step 4: Edit `SKILL.md`**
  - `## Run mode` (≤ 8 lines): two modes, "`unattended` is the default", link `[run-modes.md](run-modes.md)`, recorded in the doc's `**Run mode:**`.
  - Step 3, after the gate: one `AskUserQuestion` — unattended (recommended) / attended / Skip; add "`Skip on the run-mode question means attended`."
  - Plan-skip bullet: "In unattended mode the `plan-skip go-ahead` comes after Preflight passes and carries the same pre-authorization and gate answers as plan approval."
  - Cancel bullet: "If a `draft PR already open` exists, cancel leaves it untouched and names it in the report; closing it needs a separate yes."
- [ ] **Step 5: Run** → `PASSED`.
- [ ] **Step 6: Commit** — `feat(dev-workflow): intake unattended run mode, gate mapping, preflight, stop conditions`.

### Task 3: `verify.md` and step 7

**Files:** Create `.../intaking-work-items/verify.md`; Modify `SKILL.md` (insert `## 7. Verify` immediately before `## Gotchas` for now — Task 4 places Ship after it); Test `run.sh`.

**Interfaces — Consumes:** Task 1 table/section names; Task 2 `## Stop conditions`. **Produces:** `## 7. Verify`; phrase `the commit Ship pushes`.

- [ ] **Step 1: Failing assertions** — add `verify.md` to the support-file loop, and:

```bash
  grep -qF '## 7. Verify' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: missing step 7 Verify"
  grep -qF 'fail on an assertion' "$INTAKE_DIR/verify.md" || ifail "intaking-work-items/verify.md: red check not limited to assertion failures"
  grep -qF 'red n/a — new interface' "$INTAKE_DIR/verify.md" || ifail "intaking-work-items/verify.md: missing the new-interface red rule"
  grep -qF 'names a module or symbol the branch adds' "$INTAKE_DIR/verify.md" || ifail "intaking-work-items/verify.md: new-interface exception too broad"
  grep -qF 'only test files and fixtures' "$INTAKE_DIR/verify.md" || ifail "intaking-work-items/verify.md: missing what is copied to the base worktree"
  grep -qF 'pass twice on head' "$INTAKE_DIR/verify.md" || ifail "intaking-work-items/verify.md: missing the flake check"
  grep -qF 'up to 2 fix attempts' "$INTAKE_DIR/verify.md" || ifail "intaking-work-items/verify.md: missing the 2-attempt rule"
  grep -qF 'verified / failed / unverified / not delivered' "$INTAKE_DIR/verify.md" || ifail "intaking-work-items/verify.md: missing the result vocabulary"
  grep -qF 'read-only commands only' "$INTAKE_DIR/verify.md" || ifail "intaking-work-items/verify.md: missing the read-only live-check rule"
  grep -qF 'post-merge' "$INTAKE_DIR/verify.md" || ifail "intaking-work-items/verify.md: missing post-merge DoD handling"
  grep -qF 'quoted output line' "$INTAKE_DIR/verify.md" || ifail "intaking-work-items/verify.md: missing the evidence rule"
  grep -qF "never trust a worker's report" "$INTAKE_DIR/verify.md" || ifail "intaking-work-items/verify.md: missing the re-run rule"
  grep -qF 'the commit Ship pushes' "$INTAKE_DIR/verify.md" || ifail "intaking-work-items/verify.md: missing re-verify on the shipped commit"
```

- [ ] **Step 2: Run** → FAIL with these plus the loop's `verify.md` messages.
- [ ] **Step 3: Write `verify.md`** per spec § `verify.md` and decisions 6-7, with every phrase above verbatim: when ("once on the final branch after all merges; `never trust a worker's report` — re-run it"; "again on `the commit Ship pushes` whenever a rebase or review fix changed the tree; evidence is stale once the tree changes"); order (repo checks → each active AC → DoD with `post-merge`); red check ("copy `only test files and fixtures` from the branch to the base commit in a throwaway worktree — never implementation files; the test must `fail on an assertion` about the AC's behaviour; a collection, import, or compile failure is recorded as `red n/a — new interface` only when the error `names a module or symbol the branch adds`, and the AC then rests on the head run plus the reviewers' check that the test asserts the AC; any other setup failure is a failed check"; "each new test must `pass twice on head`; differing results are a failure"; record base SHA, command, failure reason); live reads ("`read-only commands only` — `az … show`, `kubectl get`, `terraform plan`; never apply or deploy"); failure loop ("`up to 2 fix attempts`, each in the Run log, then step 7 re-runs in full; a third failure is a stop — see [run-modes.md](run-modes.md)"); a wrong/untestable AC is an immediate stop, never fixed by editing the AC; results `verified / failed / unverified / not delivered`; "a verified row needs a `quoted output line`"; the evidence table from the spec.
- [ ] **Step 4: `SKILL.md`** — `## 7. Verify` (≤ 8 lines): both modes; link `[verify.md](verify.md)`; writes Verification evidence; nothing ships until it passes or a stop condition applies.
- [ ] **Step 5: Run** → `PASSED`.
- [ ] **Step 6: Commit** — `feat(dev-workflow): intake step 7 verifies every active AC with evidence`.

### Task 4: Step 8 Ship, step 6 rewiring, chain files

**Files:** Modify `dev-workflow/README.md:13`; `SKILL.md` (description lines 3-16; `## 6.` title ~line 233; lines 235-236; chain-choice item 4 ~line 254-257; Checkpoints ~line 260; Ship text ~lines 280-290 moves to a new `## 8. Ship` after `## 7. Verify`; plan-skip bullet `/mattpocock-skills:implement` at ~66-67); `chain-superpowers.md` (lines 1-4, stage 2 approval, stage 3, line 60); `chain-mattpocock.md` (lines 1-4; lines 6-17 "why the user types each command" — add one line: `implement-spec` in intake mode is the exception intake invokes itself; after the to-tickets coverage check ~line 52, Implement ~53-60, line 62, skip-to-tickets ~71-76); Test `run.sh`.

**Interfaces — Consumes:** Task 2 gate mapping and `## Stop conditions`; Task 3 `## 7. Verify`, `the commit Ship pushes`.

- [ ] **Step 1: Failing assertions**

```bash
  grep -qF '## 8. Ship' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: missing step 8 Ship"
  grep -qF 'a user checkpoint between each' "$INTAKE_SKILL" && ifail "intaking-work-items/SKILL.md: still claims a checkpoint between every stage"
  grep -qF "step 6's **Ship**" "$INTAKE_DIR/chain-superpowers.md" "$INTAKE_DIR/chain-mattpocock.md" && ifail "intaking-work-items/chain-*.md: still return to step 6's Ship"
  grep -qF 'without its stage checkpoints' "$INTAKE_DIR/chain-superpowers.md" || ifail "intaking-work-items/chain-superpowers.md: missing the unattended implement rule"
  grep -qF 'pre-authorizes' "$INTAKE_DIR/chain-superpowers.md" || ifail "intaking-work-items/chain-superpowers.md: plan approval missing the pre-authorization"
  grep -qF 'go unattended?' "$INTAKE_DIR/chain-mattpocock.md" || ifail "intaking-work-items/chain-mattpocock.md: missing the go question"
  grep -qF 'implement-spec' "$INTAKE_DIR/chain-mattpocock.md" || ifail "intaking-work-items/chain-mattpocock.md: Implement stage does not use implement-spec"
  grep -qF 'intake mode publishes nothing' "$INTAKE_DIR/chain-mattpocock.md" || ifail "intaking-work-items/chain-mattpocock.md: missing intake mode"
  grep -qF 'attended only' "$INTAKE_DIR/chain-mattpocock.md" || ifail "intaking-work-items/chain-mattpocock.md: missing the attended fallback"
  grep -qF 'confirmed seam list' "$INTAKE_DIR/chain-mattpocock.md" || ifail "intaking-work-items/chain-mattpocock.md: implement-spec handoff missing the seam list"
  grep -qF 'confirmed seam list' "$INTAKE_DIR/chain-superpowers.md" || ifail "intaking-work-items/chain-superpowers.md: implementer handoff missing the seam list"
```

(The two `&& ifail` lines are negative assertions: they fail while the old text exists. The existing `run.sh:309` "Never replicate these skills" assertion stays green.)

- [ ] **Step 2: Run** → FAIL with these messages.
- [ ] **Step 3: `SKILL.md`**
  - Description (frontmatter): replace "with a user checkpoint between each" with "— unattended after one sitting by default — verifies each AC, opens a draft PR, closes out on return" (1001 bytes; `run.sh:264` caps at 1024). Mirror the meaning in `dev-workflow/README.md:13`.
  - `## 6.` title → `## 6. Chain — design, plan, implement`; lines 235-236 → "…then goes to step 7 (Verify) and step 8 (Ship)"; chain-choice item 4 → keep its existing sentence (warn once, record "Intake: chain skipped — no design/plan", implement directly against the settled AC list, active AC only, same verification standard) and change only its ending to "after Preflight passes and the go-ahead is given; then go to step 7"; Checkpoints paragraph: in unattended mode checkpoints end at the go; after it only [run-modes.md](run-modes.md) § Stop conditions halt the run.
  - Move the Ship text into `## 8. Ship` after `## 7. Verify`, and add: in unattended mode `opening-pull-requests` gate 8 is pre-answered by the go (recorded in the Run log), gate 9 runs `gh pr create --draft`, a lint/test failure inside it is a step-7 failure, and if gate 2's rebase or a review fix changes the tree, step 7 re-runs on the commit Ship pushes; the PR body carries the step-7 evidence table; the PR stays draft while any AC is failed or person-only unverified.
  - Plan-skip bullet: "the Implement stage still runs" as [chain-mattpocock.md](chain-mattpocock.md) defines it (`implement-spec` in intake mode, or `/mattpocock-skills:implement` on the attended fallback).
- [ ] **Step 4: `chain-superpowers.md`** — lines 1-4 and 60: return to SKILL.md **step 7** (Verify). Stage 2: the plan-approval question states the gate mapping and that it `pre-authorizes` the two actions (link `run-modes.md`), and runs Preflight first. Stage 3: in unattended mode `plan-implementation` runs `without its stage checkpoints`, stopping only on the stop conditions; every implementer it dispatches receives the AC→test table as the `confirmed seam list`. Keep the existing sentence containing `except when the user skipped the plan` (`run.sh:301`).
- [ ] **Step 5: `chain-mattpocock.md`** — lines 1-4 and 62: return to step 7. After the to-tickets coverage check: Preflight, then one `AskUserQuestion` "`go unattended?`" (states it `pre-authorizes exactly two outward actions`; recorded in the Run log). Implement stage: invoke the Skill identifier `implement-spec` (bare, not `mattpocock-skills:implement-spec`) with the spec issue URL, "intake mode", and the AC→test table as the `confirmed seam list` for every implementer's `tdd` call; "`intake mode publishes nothing`: no draft PR at its step 3, no ready or close at step 8, no closing keywords; it returns the integration branch." Replace line 57 ("Its `tdd` seam confirmation … run as that skill defines") with that seam-list rule. In both modes the handoff intake states before the Implement stage (today's "First state the handoff", ~lines 53-56) carries the AC→test table as the pre-agreed seams. If the Skill call errors (e.g. `disable-model-invocation`), the chain runs `attended only` with today's command: the user types `/mattpocock-skills:implement <spec-url>` (it opens no PR); the unedited `implement-spec` is never used, in either mode. Keep "Never replicate these skills" and name `implement-spec` in intake mode as the one skill intake invokes. Lines 71-76: name both commands per the same rule.
- [ ] **Step 6: Run** → `PASSED`; `grep -n 'Ship' dev-workflow/skills/intaking-work-items/*.md` — every hit refers to step 8 or the Ship stage by name, none to step 6.
- [ ] **Step 7: Commit** — `feat(dev-workflow): intake step 8 Ship drafts unattended; chains hand off to verify; mattpocock uses implement-spec`.

### Task 5: Step 9 close-out, description, docs, version

**Files:** Modify `SKILL.md` (new `## 9. Close-out` before `## Gotchas`); `docs/superpowers/specs/2026-10-07-intake-chain-choice-design.md:23` (append a dated note: intake now invokes the user-level `implement-spec`, see the 2026-10-09 design); `dev-workflow/.claude-plugin/plugin.json:3` and `.claude-plugin/marketplace.json:51` → `0.1.6`; Test `run.sh`.

- [ ] **Step 1: Failing assertions**

```bash
  grep -qF '## 9. Close-out' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: missing step 9 Close-out"
  grep -qF '`/retro`' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: close-out missing the /retro offer"
  grep -qF 'skill-retrospective' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: close-out missing the skill-retrospective route"
  grep -qF 'separate branch and PR' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: retro changes not kept off the ticket PR"
  grep -qF 'Status becomes Delivered only if' "$INTAKE_SKILL" || ifail "intaking-work-items/SKILL.md: missing the Delivered rule"
```

- [ ] **Step 2: Run** → FAIL with these 5.
- [ ] **Step 3: `## 9. Close-out`** — show Run log, evidence table, blockers; walk each person-only AC and record the result; offer each outward action separately under step 5's per-action rule (mark ready — state failed or unverified AC first; Jira transition; ticket comment; close tickets as the repo allows), each with Skip; "Status becomes Delivered only if every active AC is verified and the PR is ready; otherwise Partial, listing the open AC" (no backticks — the assertion matches this text exactly); offer `` `/retro` `` on the session — skill and memory findings go to `dev-workflow:skill-retrospective`, accepted environment changes go on a `separate branch and PR`.
- [ ] **Step 4: Docs and version** — the dated note at 2026-10-07 design line 23; both version fields to `0.1.6`.
- [ ] **Step 5: Run** → `PASSED`; `grep -c '"version": "0.1.6"' dev-workflow/.claude-plugin/plugin.json .claude-plugin/marketplace.json` → `1` each.
- [ ] **Step 6: Commit** — `feat(dev-workflow): intake step 9 close-out with /retro; bump 0.1.6`.

### Task 6: User-level `implement-spec` intake mode (outside the repo)

**Files:** `~/.claude/skills/implement-spec/SKILL.md` (line 4; step 3; step 8).

- [ ] **Step 1: Ask the user** — show the three edits below verbatim; proceed only on an explicit yes. On no, stop: Task 4's attended-only fallback applies.
- [ ] **Step 2: Edit** — delete line 4 `disable-model-invocation: true`; append to step 3: "In intake mode, open no PR."; append to step 8: "In intake mode, mark nothing ready, close no tickets, and use no closing keywords; report the integration branch to the caller."
- [ ] **Step 3: Verify** — `grep -c 'disable-model-invocation' ~/.claude/skills/implement-spec/SKILL.md` → `0`; `grep -c 'In intake mode' ~/.claude/skills/implement-spec/SKILL.md` → `2`. After the next session start, confirm the skill listing shows `implement-spec` with the user copy's description ("Implement the result of /to-spec and /to-tickets in code."); if it shows the plugin's, the bare identifier resolves to the plugin and the attended fallback applies — tell the user. No commit (not in the repo).

### Final: review chain

- [ ] `bash dev-workflow/tests/run.sh` → `PASSED` on the branch tip.
- [ ] Full tier: dispatch `dev-workflow:fresh-verifier` and `dev-workflow:codex-adversary` in one message on `git diff main...HEAD` against the spec; fix findings; then `opening-pull-requests`.
