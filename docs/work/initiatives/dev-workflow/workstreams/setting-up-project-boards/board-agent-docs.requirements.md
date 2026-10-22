---
id: dev-workflow-board-agent-docs-requirements
type: requirements
status: draft
owner: dev-workflow
representation: canonical
canonical: docs/work/initiatives/dev-workflow/workstreams/setting-up-project-boards/board-agent-docs.requirements.md
---

# board-agent-docs: `setting-up-project-boards` installs the board's agent docs

**Source:** [cjsteigerwald/ai-crew#48](https://github.com/cjsteigerwald/ai-crew/issues/48) (spec issue, published 2026-10-22 on the user's per-issue yes). Originating request, no ticket (2026-10-22): "add to the skill setting-up-project-boards … when this skill is invoked it should install the agents that have to do with the board: issue-tracker.md, phase-gates.md, triage-lables.md" (the last is `triage-labels.md`), from the source repo's `docs/agents/` (a local work checkout of the AI gateway repo).
**Linked items:** the source repo's `docs/agents/{issue-tracker,phase-gates,triage-labels}.md`: related context, generalized into templates. `dev-workflow/skills/setting-up-project-boards/SKILL.md` (dev-workflow 0.2.3): the skill being changed.
**Fetched:** 2026-10-22. Ticket status `n/a`, sprint `none`, estimate `none`
**Intake by:** Christopher Steigerwald with the `dev-workflow:intaking-work-items` skill
**Status:** Ready, revision 2.1. The plan pass returned revise; the user accepted R1–R6 on 2026-10-22 (decision 11); the bounded re-check's should-fix corrections (sv-1..sv-4) applied within that decision. No steps skipped.
**Chain:** sdlc-process

> Snapshot of the request on the fetched date plus the decisions below. If the scope changes,
> re-run intake for the changed rows rather than editing this doc by memory.

## Story

As an agent (and the human directing it) setting up a GitHub Projects board for a repo with
`dev-workflow:setting-up-project-boards`, I want the skill to also install the repo's board-governing
agent docs (issue tracker conventions with the label/Status lifecycle, triage label mapping, and
optionally phase gates), so that every later session in that repo moves issues across the board and
labels the same way, without hand-copying the source repo's docs and their repo-specific details.

## Scope

**In scope**
- New `dev-workflow/skills/setting-up-project-boards/templates/`: `issue-tracker.md`, `triage-labels.md`, `phase-gates.md`, generalized from the source docs.
- A read-only checkout preflight before the project is created, and an install step between "Copy and link" and "Add issues".
- Reconciling the rest of the skill with the installed lifecycle: step 1 reads, "Add issues" closed-item handling, the workflow advice, the triage mapping, the final verify rule, the global confirmation list and the frontmatter description (decision 11, R1).
- `dev-workflow/README.md` row for the skill. dev-workflow version bump to 0.2.4.
- New assertions in `dev-workflow/tests/run.sh`, plus the existing 0.2.3 version assertion updated in place.

**Out of scope**
- `docs/agents/domain.md`: not board-related (decision 6).
- Edits to the target's instruction files beyond an offered one-line pointer (decision 6).
- Any automation that moves labels or board Status.
- Committing through `gh api` without a checkout; cloning the target repo (decisions 3, 11).
- Creating or renaming project Status columns (decision 11, R3).
- Filling in a repo's real phase gates beyond those the user already knows at setup (decision 2).

## Requirements

### Functional

**Templates**
- **FR-1** Three templates with no source-repo specifics. Placeholders are strictly `{{name}}` with `name` matching `[a-z_]+`. Optional sections are wrapped in `<!-- optional: <key> -->` … `<!-- /optional -->`. Every placeholder is documented in a "Placeholders" table in SKILL.md: name, meaning, where its value comes from.
- **FR-2** The `issue-tracker.md` template keeps the source's structure: instruction precedence (generic: the target repo's own precedence, not a hard-coded file), repo rules, gh conventions, project board, Issue lifecycle, PRs as a triage surface (flag defaults to `no`), publish/fetch, wayfinding. Keep, adapt and drop as follows (decision 11, R5):
  - Always kept: adding every new issue to the project with Status and any required fields set.
  - Optional (`backlog`): every external-backlog reference, meaning the backlog section, the `**Ticket:**` rule, and the backlog parts of the reopen and completion rules.
  - Optional (`phase_gates`): every reference to `phase-gates.md`.
  - Optional (`wayfinding`): the wayfinding section. It states that a closed blocker is a dependency, not a gate pass, and that Resolve follows the repo's close rule.
  - Dropped: release labels and the source's CI-script reference. "Status and Priority" becomes "Status and any required fields".
  - Adapted: the source's "Nothing adds issues automatically", "Nothing moves labels or board Status either" and "Nothing automates these" become one rule: project workflows may set Status when an item is added or closed; every other label or Status move is made by the session at its lifecycle step and recorded in the handoff (sv-3).
  - Added: a "Handoff comment" paragraph defining `## Handoff` and its **Open / blocked** section, plus the evidence rule (names, ids, status codes; never secret values).
- **FR-3** Lifecycle Status cells are placeholders, one per lifecycle step: not yet triaged, refining, ready for an agent, ready for a human, building, validating, done, won't do. The rule "merging a PR does not finish an issue" is kept. Blocked returns an issue to Refining and removes `ready-for-*`. Won't do carries `wontfix`.
- **FR-4** The `phase-gates.md` template is a skeleton: a gate passes only by a `## Handoff` that records a pass with evidence; a closed issue alone is not a pass; an unmet gate means a handoff with the blocker under **Open / blocked**, then end the session. It then has a `## Gates` heading followed only by a comment line. Installed only if the user says the repo has phase gates; the skill offers to fill in gates the user already knows (decision 2).
- **FR-5** The `triage-labels.md` template maps the five canonical roles to label strings, under the header "Canonical role".

**Preflight (before "Copy and link"; read-only)** (decision 11, R2)
- **FR-6** Resolve the checkout: a path the user names, or cwd only if its `git remote -v` resolves to `<org>/<repo>` (ssh or https). Run `gh auth status` and `gh api user` from that directory and confirm the account. Detect a dirty tree and the repo's default branch (`gh repo view --json defaultBranchRef`). Never clone. With no usable checkout, record "install skipped" and continue.

**Install (between "Copy and link" and "Add issues")** (decisions 3, 4, 11)
- **FR-7** Ask about phase gates first.
- **FR-8** Read the Status options from the **copied** project. Show the lifecycle step → option mapping table for the user's review. For an unmatched step, the user picks an existing option or the cell reads "no column; label only". Never invent or create a column. The same mapping is used by install, triage and verify.
- **FR-9** Branch from the default branch after `git fetch`, in a `git worktree` when the tree is dirty, with a collision-free branch name. Never reset existing work.
- **FR-10** For each target file that exists: show a diff and ask merge / overwrite / skip. For `issue-tracker.md` the default is to append only the missing board sections. Show conflicting rules in the diff. Keep the target's instruction precedence and resolve label strings through its triage-labels mapping. If a conflicting section is skipped, the existing policy keeps governing and the report says the install is incomplete.
- **FR-11** No unresolved `{{…}}` remains in a written file. The batch is confirmed before writing. "Push and open the PR" (base = default branch) is one separate confirmed action; declining leaves the branch local. A one-line pointer in `AGENTS.md` (or `CLAUDE.md` when there is no `AGENTS.md`) is a separate confirmed edit.
- **FR-12** With no usable checkout, skip the install, note it in the final report, and continue with "Add issues".

**Reconciliation** (decision 11, R1, R4)
- **FR-13** Step 1 reads `docs/agents/phase-gates.md` alongside the other two.
- **FR-14** The triage step defers to the lifecycle in the repo's `docs/agents/issue-tracker.md` when one is present (installed, merged or pre-existing); otherwise it uses its default table (sv-4). The default table has Blocked → Refining (remove the ready label) and a Won't-do row, and no "keeps its ready label" rule.
- **FR-15** "Add issues" sends closed items to Done, or to Won't do (when mapped) for issues closed as not planned or labelled `wontfix`. The note under "List board items" in `references/queries.md` says the same (sv-2).
- **FR-16** The workflow advice no longer recommends "Pull request merged" → Done. "Item closed" → Done carries the Won't-do caveat.
- **FR-17** Verify checks that each issue has at most one state label and that the label matches the lifecycle row for its Status. A "label only" step (no mapped column) is checked by label alone. The "exactly one state label" and "label counts add up to the triaged total" rules are removed.
- **FR-18** The global confirmation list names writing docs, push and PR, and the instruction-file edit. The frontmatter description mentions installing the board's agent docs and no longer says closed items go only to Done (sv-4).

### Non-functional
- **NFR-1** No source-repo identity in any committed file of this change. The templates are guarded by a shape check (AC-2); identity literals are left to `scripts/scrub-check.sh` with the private denylist and are never written into tests (decision 11, fv-1).
- **NFR-2** Every outward write stays confirmed (`SKILL.md:19` rule, extended by FR-18).
- **NFR-3** New run.sh assertions are bash 3.2 compatible (CI runs `/bin/bash`, `tests.yml:102`).
- **NFR-4** Static checks are structural evidence only; behaviour is covered by AC-14's person-only scenarios.

## Acceptance criteria (revision 2)

Automated checks are scoped to the named section (heading to next same-level heading) or table, not whole-file greps. Sections are found by heading title, not step number.

- **AC-1** (FR-1) `templates/` contains `issue-tracker.md`, `triage-labels.md`, `phase-gates.md`.
- **AC-2** (FR-1, NFR-1) Shape check over `templates/`: zero matches for `--repo [^{]`, `--owner [^{]`, `github\.com/(orgs|users)/[^{]`, `/projects/[0-9]`, `\.jira\.com`, `[A-Z]{2,}-[0-9]+` (template prose avoids tokens like `UTF-8`). No identity literal appears in the test (NFR-1; sv-1).
- **AC-3** (FR-1) Every `{{…}}` in the templates matches `{{[a-z_]+}}`. The set used equals the set in the rows of SKILL.md's "Placeholders" table, and that table has at least one row. Optional markers are balanced in each template.
- **AC-4** (FR-2, FR-3) In the `issue-tracker.md` template:
  - **Required section headings present:** instruction precedence, conventions, project board, issue lifecycle, PRs as a triage surface, publish, fetch, wayfinding, handoff comment.
  - **Lifecycle table:** at least 8 rows, and every row's Status cell matches `^{{[a-z_]+}}$`. A Won't-do row carries `wontfix`.
  - **Lifecycle rules:** Blocked → Refining and remove `ready-for-*`; "Merging a PR does not finish an issue"; the adapted automation rule (project workflows may set Status on add and close), and no "Nothing adds issues automatically".
  - **Optional markers:** backlog parts inside `optional: backlog`; `phase-gates.md` references inside `optional: phase_gates`; the wayfinding section inside `optional: wayfinding`. The wayfinding section states that a closed blocker is not a gate pass.
  - **Removed content:** no `release:`, no "Priority".
- **AC-5** (FR-4) The `phase-gates.md` template states the three gate rules, and its `## Gates` heading is followed only by a comment line.
- **AC-6** (FR-5) The `triage-labels.md` template has the header "Canonical role" and all five roles mapped.
- **AC-7** (FR-6) A preflight section in SKILL.md, placed before "Copy and link" (by heading line numbers), says each of these:
  - the user-named path, or cwd whose remote matches `<org>/<repo>`
  - account check from that directory
  - dirty-tree detection
  - default branch
  - never clone
  - read-only
- **AC-8** (FR-7–FR-12) The install section, placed between "Copy and link" and "Add issues" by heading line numbers, says each of these:
  - phase gates asked first
  - Status options read from the copied project
  - the mapping reviewed by the user
  - an unmatched step gets an existing option or "label only"
  - never create a column
  - branch from the default branch
  - worktree when dirty
  - collision-free branch name
  - diff, then merge / overwrite / skip
  - default append for `issue-tracker.md`
  - conflicts surfaced in the diff, and a skipped conflict is reported as an incomplete install
  - no unresolved placeholders
  - confirm before writing
  - push and PR as one confirmed action
  - the pointer to `AGENTS.md`, else `CLAUDE.md`, as a separate confirmed edit
  - no checkout means skip and continue
- **AC-9** (FR-13, FR-14) Step 1 names `docs/agents/phase-gates.md`. The triage section defers to the repo's `docs/agents/issue-tracker.md` lifecycle when present (installed, merged or pre-existing), and its default table has Blocked → Refining and a Won't-do row, with no "keeps its ready label".
- **AC-10** (FR-15–FR-18) Each change sits in its own section:
  - **Add issues:** closed items go to Done or Won't do.
  - **`references/queries.md`, "List board items" note:** says Done or Won't do.
  - **Workflows:** no "Pull request merged" → Done recommendation.
  - **Verify:** no "exactly one state label" (matched whitespace-tolerantly over the joined section, since the source sentence wraps) and no "label counts add up"; says "at most one" and the lifecycle row.
  - **Intro confirmation list:** names the doc write, push/PR and the instruction-file edit.
  - **Frontmatter description:** mentions the agent docs, and no "moving closed items to Done" without Won't do.
- **AC-11** dev-workflow is `0.2.4` in `plugin.json` and the dev-workflow entry of `marketplace.json`. The old `0.2.3` assertion (`run.sh:901-917`) is updated in place.
- **AC-12** The `setting-up-project-boards` row in `dev-workflow/README.md` mentions installing the board's agent docs.
- **AC-13** (NFR-1, NFR-3) `/bin/bash dev-workflow/tests/run.sh` exits 0, and `bash scripts/scrub-check.sh --allow scripts/scrub-allow.txt` over every changed file (including this doc) reports no hits.
- **AC-14** (FR-6–FR-12, person-only, **deferred**) Live runs on sandbox repos of four scenarios: (a) a fresh repo; (b) existing, conflicting `docs/agents/` files; (c) renamed or missing Status columns; (d) phase gates declined. Named as not done in the PR (decision 11, R6).

## Definition of done

- [ ] AC-1–AC-13 verified with recorded evidence. AC-14 listed as deferred.
- [ ] Merged to `main` via a draft PR marked ready
- [ ] dev-workflow at 0.2.4; README row updated
- [ ] No CHANGELOG to update (precedent: pr-body-template DoD)

## Dependencies and gates

| Item | Kind | State on fetched date |
|---|---|---|
| Spec issue | informs | cjsteigerwald/ai-crew#48, single delivery ticket (decision 9b); edited to rev 2 on the user's instruction |
| Source repo `docs/agents/` | informs | read locally 2026-10-22; generalized, not depended on |
| Existing version assertion (`dev-workflow/tests/run.sh:900-916`) | blocks green suite | pins 0.2.3; moves to 0.2.4 in the same change |
| CI scrub step with private denylist (`.github/workflows/tests.yml`) | blocks green CI | this doc scrubbed in rev 2 |

## Test plan

| AC | Kind | Seam | Catches / misses | Test name | Location |
|---|---|---|---|---|---|
| AC-1 | unit (static), agent-verifiable | `templates/` | missing template / — | board-docs templates exist | `dev-workflow/tests/run.sh` |
| AC-2 | unit (static), agent-verifiable | template files | hard-coded repo, owner, project, Jira, ticket keys / prose identity (left to scrub-check) | templates shape-scrubbed | `dev-workflow/tests/run.sh` |
| AC-3 | unit (static), agent-verifiable | templates ↔ Placeholders table | undocumented, dead or malformed placeholders; unbalanced optional markers / wrong descriptions | placeholder parity | `dev-workflow/tests/run.sh` |
| AC-4 | unit (static), agent-verifiable | issue-tracker template sections | truncated template, literal Status names, lost lifecycle rules, unconditioned backlog/gate refs / semantics beyond the asserted phrases | issue-tracker template | `dev-workflow/tests/run.sh` |
| AC-5 | unit (static), agent-verifiable | phase-gates template | dropped gate rules, leftover gates / — | phase-gates skeleton | `dev-workflow/tests/run.sh` |
| AC-6 | unit (static), agent-verifiable | triage-labels template | empty or partial mapping / — | triage-labels template | `dev-workflow/tests/run.sh` |
| AC-7 | unit (static), agent-verifiable | SKILL.md preflight section | missing preflight or wrong placement / whether agents follow it | preflight | `dev-workflow/tests/run.sh` |
| AC-8 | unit (static), agent-verifiable | SKILL.md install section | lost confirmation, mapping or branch rules; wrong placement / ordering of operations within the section | install step | `dev-workflow/tests/run.sh` |
| AC-9 | unit (static), agent-verifiable | SKILL.md step 1 and triage section | the contradiction returning / — | triage defers to lifecycle | `dev-workflow/tests/run.sh` |
| AC-10 | unit (static), agent-verifiable | Add issues, Workflows, Verify, intro, frontmatter | leftover conflicting rules / — | skill reconciled | `dev-workflow/tests/run.sh` |
| AC-11 | unit (static), agent-verifiable | parsed manifests | missed bump / — | version 0.2.4 | `dev-workflow/tests/run.sh` |
| AC-12 | unit (static), agent-verifiable | README row | stale row / — | README row | `dev-workflow/tests/run.sh` |
| AC-13 | suite, agent-verifiable | run.sh + scrub-check | regressions, identity leaks / — | whole suite + scrub | local + CI |
| AC-14 | person-only, deferred | sandbox repos | real install behaviour in four scenarios / — | — | — |

Repo-wide checks: `/bin/bash dev-workflow/tests/run.sh`; `bash scripts/scrub-check.sh --allow scripts/scrub-allow.txt <changed files>`.

## Verification evidence

Not started.

## Run log

| Time | Step | Event | Attempt | Blocker |
|---|---|---|---|---|
| — | 0 | Read `AGENTS.md`; no start procedure beyond tracker/labels/domain pointers | 1 | — |
| — | 1–2 | Read the skill and the three source docs; gap table: 6 rows Missing/Vague, 1 contradiction (blocked-issue rule; missing Won't-do) | 1 | — |
| — | 3 | Entry loaded (sdlc-process → orchestrator), grill-with-docs (grilling + domain-modeling); two rounds, all recommendations accepted; gate passed | 1 | — |
| — | 4 | Requirements doc written (uncommitted); user approved | 1 | — |
| — | 5 | Writeback skipped by user (no ticket): "Skip writeback (no ticket)" | 1 | — |
| — | 6 | Branch `feat/board-agent-docs` from `origin/main`; review base `0386a11`; spec drafted via `sdlc-process:to-spec`; seams = AC→test table (approved at step 4) | 1 | — |
| — | 6 | Policy review (publication): HOLD on unpushed-branch link in line 1; fixed; published cjsteigerwald/ai-crew#48 with `ready-for-agent`; readback OK | 1 | — |
| — | 6 | #48 is the single delivery ticket (no to-tickets); ledger linked `plan:ai-crew-48` → `branch:feat/board-agent-docs` (count 0) | 1 | — |
| — | 6 | Plan pass: fresh-verifier revise (fv-1..fv-16), codex-adversary round 1 revise (6 must-fix, 2 should-fix); merged into R1–R6; user accepted all; doc rev 2 (scrubbed of denylisted literals per fv-1) | 1 | — |
| — | 6 | Policy review (edit #48 + implementation start): A PASS; B HOLD pending bounded re-check + F1–F3. #48 body replaced with rev 2 (sha256 `3401952a…`); readback identical, label kept, 0 comments | 1 | — |
| — | 6 | Bounded fresh-verifier on rev 2: approve with comments, bounded-eligible (no NEEDS FULL PASS; churn n/a for an untracked plan doc; trust boundary unchanged from rev 1); should-fix sv-1..sv-4 applied as rev 2.1 corrections within decision 11's scope; #48 body re-edited to match | 1 | — |

## Risks

- The skill now writes into a repo checkout, where before it was API-only. Blast radius: the target repo's `docs/agents/` and instruction file, on a branch, behind confirmations and a read-only preflight. Two-way door: discard the branch or worktree.
- A merge into an existing `issue-tracker.md` could contradict hand-tuned sections. Mitigated by showing conflicts in the diff and reporting a skipped conflict as an incomplete install (FR-10).
- Static checks prove structure, not behaviour. The four AC-14 scenarios stay deferred, so real-run defects can reach users before they run. Named in the PR.
- Review tier **Full** (touches a skill definition): fresh-verifier + codex-adversary on the plan and on the diff.

## Decision log

| # | Question | Answer | Who / date |
|---|---|---|---|
| 1 | Ship the docs as placeholder templates, verbatim copies, or generate fresh each run? | Templates under `templates/` with placeholders; Status names from the project; backlog parts optional | user, 2026-10-22 |
| 2 | `phase-gates.md` is all project-specific: skeleton, interview, or optional? | Optional: ask once; if yes install the skeleton and offer to fill known gates | user, 2026-10-22 |
| 3 | Where in the flow, and how is it written? | New step after Copy and link; local checkout on a new branch; PR a separate confirmed action; no checkout handled (refined by 11) | user, 2026-10-22 |
| 4 | Target file already exists? | Diff and ask merge/overwrite/skip per file; `issue-tracker.md` default appends missing board sections | user, 2026-10-22 |
| 5 | Contradiction: the skill's triage step put a blocked issue in Backlog keeping its ready label, while the source lifecycle keeps it in Refining and removes `ready-for-*`; the source's Won't do / `wontfix` row is absent from the skill's mapping | The installed lifecycle is the source of truth; the triage step defers to it; default table → Refining, remove ready label, add Won't-do row | user, 2026-10-22 |
| 6 | Out of scope; instruction-file pointer? | `domain.md`, broader instruction-file edits and label/Status automation out; pointer offered as a separate confirmed edit | user, 2026-10-22 |
| 7 | Acceptance criteria as drafted (rev 1, AC-1–AC-10)? | Accepted; superseded by rev 2 (decision 11) | user, 2026-10-22 |
| 8 | Test plan? | Static run.sh assertions; live sandbox run person-only and deferred | user, 2026-10-22 |
| 9 | Version? | 0.2.4 (patch, additive) | user, 2026-10-22 |
| 9b | Decompose #48 with to-tickets? | "Treat #48 as the single delivery ticket (no to-tickets), then run the Full-tier plan pass." | user, 2026-10-22 |
| 10 | Contradiction: intake's `docs/specs/<KEY>-requirements.md` vs repo precedent `docs/work/initiatives/…`; the sdlc-process adapter puts planning docs in `sidkik/planning` | This path, KEY `board-agent-docs`, per repo precedent (personal repo; noted deviation) | user, 2026-10-22 |
| 11 | Plan pass (fresh-verifier: revise; codex-adversary round 1: revise), merged as R1–R6. R1: reconcile Add issues, workflow advice, verify, confirmation list, description. R2: read-only preflight before copy; checkout = named path or matching cwd; default-branch base, worktree if dirty, collision-free name; no checkout → skip and continue; push+PR one confirmed action. R3: user-reviewed Status mapping from the copied project, unmatched → existing option or "label only", never create columns. R4: keep target precedence, labels via its mapping, conflicts surfaced, skipped conflict = incomplete install, triage defers only when installed. R5: keep/adapt/drop checklist, Handoff paragraph, wayfinding gate fix. R6: stronger static checks; AC-14 deferred as four person-only scenarios. Plus the fv-1 scrub (not a choice). | "Accept the recommended answers for R1–R6. Revise the requirements doc and #48 to match, then continue." | user, 2026-10-22 |

## Deferred and out-of-scope items

| Item | Status | Source | User's words | Gap left open | Follow-up |
|---|---|---|---|---|---|
| AC-14 live sandbox scenarios (a)–(d) | deferred | decisions 8, 11 | "Accept the recommended answers for R1–R6." | real install behaviour unverified | person-only check after merge |
| `domain.md`, broader instruction-file edits, label/Status automation, `gh api` commits, cloning, creating columns | out of scope | decisions 3, 6, 11 | "Accept the recommended answers for Q1–Q6." / "… R1–R6." | none | none |

## Gap table at skip

None. Step 3 completed.

## Chain artifacts

Wayfinding: none. `CONTEXT.md` / ADR changes: none. No new domain terms, and the decisions are reversible, so no ADR.
Review tier: Full.
Spec issue: cjsteigerwald/ai-crew#48 (published 2026-10-22 on the user's per-issue yes; label `ready-for-agent`; readback: body byte-identical to the policy-reviewed draft). Single delivery ticket.
Policy review: publication HOLD → line-1 link fix → PASS (2026-10-22).
Records:
- `plan pass @#48 rev 1 + requirements rev 1`: fresh-verifier revise; codex-adversary round 1 revise (ledger `branch:feat/board-agent-docs`). Findings folded into rev 2 (decision 11).
- `bounded plan re-check @#48 rev 2 + requirements rev 2 (sha256 abdb3f5a…)`: approve with comments; prior findings resolved except fv-1/C2/C7 partial, closed by sv-1..sv-3 in rev 2.1; sv-4 applied.
- Policy review 2026-10-22: (A) #48 body edit PASS; (B) implementation start HOLD → conditions F1 (bounded re-check with eligibility stated: met), F2 (these records), F3 (writer brief hygiene).
- Rev 2.1 digests: #48 body sha256 `401bd36e…` (readback identical, label kept, 0 comments). This doc changes with every record, so its digest is recorded in the Run log at each assessment rather than here.
- Codex rounds used: 1 of 3.
**Last completed stage:** Plan pass (stage 4), revision 2.1.
