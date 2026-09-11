---
description: Audit this repository's CI/CD quality gates and report evidence-backed findings on what can reach main and prod unchecked
argument-hint: "[full|triage|<workflow-path>]"
disable-model-invocation: true
allowed-tools: Read, Glob, Write(~/repo-audits/**), Bash(git-read:*), Bash(gh-read:*), Bash(ls:*)
---

# Pipeline Quality Gates Audit

You are auditing the CI/CD quality gates of this repository. Your goal is to answer
one question with evidence: **what is the cheapest path from an unreviewed, untested
change to the default branch — and from there to production?**

Read the contract shipped with this plugin (`${CLAUDE_PLUGIN_ROOT}/contract.md`) (v2.1) now; its tools, evidence, secret,
safety, redaction, and reporting rules apply throughout. Git only via `git-read`,
GitHub only via `gh-read`; what they cannot read is `UNVERIFIED`. Read and report
only — the report file is the one write. `actionlint`/`zizmor` only via the permission
prompt, read-only (`actionlint -no-color`, `zizmor --offline .github/workflows`);
else use the manual checklists. `gh-read` rejects a literal `>`: write date filters
as `%3E%3D` (`merged:%3E%3D2026-08-12`, `created=%3E%3D2026-08-12`).

## Scope

Requested scope: `$ARGUMENTS`

- empty or `full` — audit the whole repository, all phases.
- `triage` — Phases 1, 2 (rules only, no history sample), 3 (required checks only),
  4 and 9, within the contract's triage budget (~5 minutes, ~25 wrapper calls); when
  it runs out, stop and mark the rest `UNKNOWN — not assessed`. Dimensions depending
  on skipped phases are `NOT ASSESSED — triage`; `ungated-prod-path` is
  `UNKNOWN — not assessed` because Phase 7 does not run.
- anything else — a workflow or environment: narrow to it, its gates, and shared CI.

## Pre-gathered facts

Verify anything you build a finding on. `ERROR:`/`gh:` error = `UNVERIFIED`;
`(no matches)` = ran, found nothing; `(showing L of N lines)` = **incomplete**, never
support for absence or `CLEARED`. Inventory lines are path, line, and matched keyword
only — no values — and describe the local checkout, not necessarily the default branch.

Repository, default branch, merge settings:
!`gh-read 'repos/{owner}/{repo}' --jq '{full_name, default_branch, visibility, fork, allow_merge_commit, allow_squash_merge, allow_rebase_merge, delete_branch_on_merge}'`
Local checkout SHA:
!`git-read rev-parse HEAD`
Rulesets (repo and inherited; detail and `bypass_actors` need `rulesets/<id>`):
!`gh-read 'repos/{owner}/{repo}/rulesets?includes_parents=true' --paginate --jq 'map({id, name, target, enforcement, source_type, source})'`
Environments and their protection rules:
!`gh-read 'repos/{owner}/{repo}/environments?per_page=100' --jq '{total_count, environments: [.environments[]? | {name, rules: [.protection_rules[]? | {type, wait_timer, prevent_self_review, reviewers: [.reviewers[]? | (.reviewer.login // .reviewer.slug)]}], branch_policy: .deployment_branch_policy}]}'`
Default workflow token permissions:
!`gh-read 'repos/{owner}/{repo}/actions/permissions/workflow' --jq '.'`
Registered workflows and their state:
!`gh-read 'repos/{owner}/{repo}/actions/workflows?per_page=100' --jq '{total_count, workflows: [.workflows[] | {path, state}]}'`
CI, deploy, and gate-implementation files (GitHub Actions and other systems):
!`git-read ls-files --match '^\.github/(workflows|actions)/|(^|/)action\.ya?ml$|(^|/)(azure-pipelines[^/]*\.ya?ml|\.gitlab-ci\.yml|Jenkinsfile[^/]*|bitbucket-pipelines\.yml)$|^\.circleci/|^\.buildkite/|(^|/)(argocd|flux|spinnaker|octopus)[^/]*/' --exclude '(^|/)(AGENTS|CLAUDE)\.md$' --limit 60`
Trigger and filter keys per workflow:
!`git-read grep -nIoE '^[[:space:]]*"?(on|push|pull_request|pull_request_target|merge_group|workflow_dispatch|workflow_run|workflow_call|repository_dispatch|schedule|release|issue_comment|branches|branches-ignore|tags|paths|paths-ignore)"?:' -- .github/workflows --limit 80`
Failure-masking constructs (inventory — classify each in Phase 4):
!`git-read grep -nIoE 'continue-on-error:[[:space:]]*[^[:space:]#]+|\|\|[[:space:]]*(true|:)|set \+e|set \+o errexit|exit 0|soft_fail|--exit-code[= ]0|fail-on-severity|always\(\)|failure\(\)|if:[[:space:]]*[>|]' -- .github --exclude '(^|/)(AGENTS|CLAUDE)\.md:' --limit 40`
Path filters and job-level conditions that can skip work:
!`git-read grep -nIoE 'paths-ignore:|paths:|dorny/paths-filter[^[:space:]]*|changed-files[^[:space:]]*|if:[^#]*(changes|outputs|needs\.)[^#]*' -- .github --exclude '(^|/)(AGENTS|CLAUDE)\.md:' --limit 40`
High-risk triggers and permissions:
!`git-read grep -nIoE 'pull_request_target|workflow_run|workflow_dispatch|repository_dispatch|issue_comment|permissions:[^#]*|write-all|id-token:[[:space:]]*[a-z]+' -- .github --exclude '(^|/)(AGENTS|CLAUDE)\.md:' --limit 40`
`uses:` refs not a full SHA (incl. commented-out, `docker://`; `./local` → Phase 3):
!`git-read grep -nIoE 'uses:[[:space:]]*[^[:space:]#]+' -- .github --exclude '@[0-9a-f]{40}$|(^|/)(AGENTS|CLAUDE)\.md:' --limit 40`
Gate implementations — reusable workflows and scripts (misses `run: |` bodies):
!`git-read grep -nIoE 'uses:[[:space:]]*[^[:space:]]*\.github/workflows/[^[:space:]]+|run:[[:space:]]*(\./|bash |sh |pwsh |python[0-9.]* |node |make |npm (run|test)|pnpm |yarn )[^[:space:]]*' -- .github --exclude '(^|/)(AGENTS|CLAUDE)\.md:' --limit 40`
CODEOWNERS files and GitHub's parse errors:
!`git-read ls-files --match '^(\.github/|docs/)?CODEOWNERS$'`
!`gh-read 'repos/{owner}/{repo}/codeowners/errors' --jq '[.errors[]? | {line, kind, message}]'`

## Ground rules

- Keyword hits above are inventories; a finding needs the construct traced to its
  effect on a required check or a deploy.
- Capture-time secrets: read workflow lines with `git-read grep -n` on the keys you
  need, or `git-read show <sha>:<path>` for `run:` logic you must reason about. Never
  print `env:`/`with:` blocks holding credentials, `.env*`, or registry configs; cite
  `path:line` and the key name.
- Skip semantics, stated precisely — do not collapse them:
  - A job skipped by a job-level `if:` reports **success** and satisfies a required
    check. It is a **false green only when** the skipped work was necessary for that
    change (construct the change) **and** a merge with that skip was accepted.
  - A workflow that never triggers, or is excluded by workflow-level
    `paths`/`paths-ignore`, reports **no** status: the required check stays pending
    and **blocks — unless another producer supplies the same required context**.
  - A failed step fails its job (later steps skip unless `if: always()`/`failure()`);
    a `needs:`-skipped job differs. Show the propagation before calling a false green.
- Regex cannot see masking in called scripts, folded `if: >-` expressions, or
  composite action bodies: read them, or list them as not inspected. **Remote
  reusable workflows and remote actions cannot be read** (`gh-read` has no contents
  endpoint): a check whose pass/fail depends on one is `UNKNOWN — remote
  implementation <owner/repo/path@ref> not readable`.

## Phase 1 — Map the paths to production (do this FIRST)

Pin the audited revision: `gh-read 'repos/{owner}/{repo}/branches/<default>' --jq
'.commit.sha' --raw`. If it differs from the local SHA, check `git-read cat-file -e
<sha>` and read workflows at it (`git-read show <sha>:<path>`, `git-read grep -n
<pattern> <sha> -- .github`). If that SHA is not local, workflow contents are
`UNVERIFIED — default-branch SHA not in local checkout` and the pre-gathers describe
the local branch only.

Then record every path into production: protected branches and what deploys where;
build/release/deploy workflows and their triggers (push, tag, release, dispatch,
`workflow_run`, schedule); CI or deploy outside Actions (Azure Pipelines, Jenkins, Argo
CD/Flux — unreadable enforcement is `UNVERIFIED`); who triggers workflows holding
secrets or write tokens; unofficial paths (manual dispatch, tag push, non-default
branch). An ungated path to prod outranks every other finding.

## Phase 2 — Establish what is enforced (today)

For the default and every deploying branch, read the **effective** rules via
`gh-read 'repos/{owner}/{repo}/rules/branches/<branch>' --paginate`, then
`rulesets/<id>` per ruleset — `bypass_actors` is returned only to callers with write
access to it, so its absence is `UNVERIFIED`, not "no bypass". Classic
`branches/<branch>/protection` needs Administration read; a 404 there is ambiguous.
Report: PR required; approval count; stale-approval dismissal; code-owner review;
approval of the most recent push; conversation resolution; required checks (exact
names, strict, `integration_id` if pinned); required workflows (trace in Phase 3);
bypass actors, admin enforcement, force push, deletion; merge queue and whether
required-check workflows run on `merge_group`; CODEOWNERS coverage of Phase 1 risky
paths (workflows, actions, IaC, deploy config).

Fill this actor-capability table from that evidence (unreadable cell = `UNVERIFIED`).
It decides who a `gate-bypassable` witness may be.

| Actor | Can merge to default? | Can edit a gate implementation in the PR? | Needs whose approval? |
|---|---|---|---|
| PR author (write access) | only through the rules | yes, unless owned + code-owner review required | required approvers; a code owner if the path is owned and that rule is on |
| Code owner (authoring) | only through the rules | yes | a *different* approver; cannot self-approve |
| Repo admin | yes if admin enforcement is off | yes | none when bypassing |
| Named bypass actor | yes, via bypass | yes | none (excluded from `gate-bypassable`) |

**History sample (full runs only) — observed facts, not enforcement.** Draw merged
PRs by merge date: `gh-read 'search/issues?q=repo:{owner}/{repo}+is:pr+is:merged+base:<default>+merged:%3E%3D<date 30 days ago>&per_page=100'
--paginate`. For up to 10, read `pulls/<n>` (`merged_at`, `merged_by`, head SHA),
`pulls/<n>/reviews`, `pulls/<n>/commits`, `commits/<head>/check-runs` and
`commits/<head>/status`. Report what was **observed**: a non-author approval
submitted before merge on the final head; required-named checks completed (with
conclusion) before merge. This does not show a rule was enforced — today's rules may
postdate the merge. Historical enforcement is `UNKNOWN` unless the rule is shown to
predate the merge (e.g. `created_at`/`updated_at` from `rulesets/<id>`, where
returned). Self-merge is not self-approval; an empty `commits/<sha>/pulls` is a
candidate direct push, not proof.

## Phase 3 — Reconcile required checks with their producers and implementations

For every required status check:

- **Producer.** Read both `commits/<sha>/check-runs` (`name`, `app.slug`) and
  `commits/<sha>/status` (`context`, `creator`) on a recent default-branch or PR head.
  Classify each producer as **GitHub Actions** or **external**; trace an external one
  if its config is readable here, else `UNVERIFIED — external producer <name>`. For
  Actions, find the job with that exact reported name (`name:` overrides, matrix
  suffixes like `test (3.12)`). A name with no producer blocks every merge or is
  being bypassed — Phase 2 says which.
- **Source pinning.** Unpinned: any app or token with statuses write can post it.
  Pinned only to GitHub Actions: any workflow in the repo — including one added or
  renamed in the PR under test — can post the same job name (same-app substitution);
  a witness only if that workflow path is not under required code-owner review.
- **Trigger.** On `pull_request` (+ `merge_group` if queued) for every relevant path?
- **Implementation — gate integrity.** Follow the check to what decides pass/fail:
  local reusable workflows, composite actions (`.github/actions/**/action.yml`), every
  script `run:` invokes. Under `pull_request`, a required job running
  `./scripts/test.sh` from the PR branch can be swapped for a no-op — is that path
  under required code-owner review? Under `pull_request_target` the base workflow
  runs; the risk shifts to executing PR code. Remote implementations → `UNKNOWN`;
  org-required workflows not readable at source → `UNVERIFIED`.
- **Not required.** Tests, scans, `terraform plan` present but not required.

## Phase 4 — Hunt for false greens

Classify each pre-gathered construct and Phase 3 finding as harmless or masking:
required jobs behind a job-level `if:` that can be false for a change they should test
(construct that change); `continue-on-error: true`, `|| true`, `set +e`, forced
`exit 0`, masking in called scripts, scanners with a non-failing exit code or lax
threshold; a result hinging on an `if: always()` step or downstream summary job (trace
how upstream failure reaches the reported conclusion); retries that hide flakes;
comment-only checks; `paths-ignore` "docs-only" paths that hold behavioural files.

## Phase 5 — Gate coverage matrix

Rows: build, lint, typecheck, unit, integration, dependency review, SAST, secret
scanning/push protection, IaC scan or `terraform plan`, image scan, license,
migrations, domain-specific. Columns: **present / runs on PRs / required / blocks on
failure**; for each absent row, say if it is needed.

## Phase 6 — Pipeline security

Token permissions (default, top-level read-only, `write-all`); the agent's identity
where determinable from repo config or `collaborators`; third-party actions pinned to
a full SHA, `docker://` by digest (`@main` is a finding even with a SHA comment);
`pull_request_target`/`workflow_run`/`issue_comment` running untrusted code with
secrets; template injection (`${{ github.event.* }}`, `github.head_ref` in `run:`);
cache poisoning; long-lived cloud secrets vs OIDC; secrets or self-hosted runners
reachable from fork PRs. Lockfiles/provenance: only whether gated.

## Phase 7 — Deployment gating

Per Phase 1 prod path: `environment:` with required reviewers, `prevent_self_review`,
wait timer, branch/tag restrictions? (Adding `environment:` changes the OIDC subject
and can break federated login — check auth first.) Deployable from a non-default
branch, an unmerged PR, or by any writer via `workflow_dispatch`? Break-glass with a
named approver and audit trail? Build-once-promote? `concurrency:` on deploys?

## Phase 8 — Pipeline health

Window: 30 days. Cap: **20 `gh-read` calls**; report short or truncated samples; no logs.

- **PR feedback latency, joined to the audit:** `gh-read
  'repos/{owner}/{repo}/actions/workflows/<file>/runs?event=pull_request&created=%3E%3D<date>&per_page=100'`
  per required-check workflow. Keep runs whose `head_sha` matches a Phase 2 sampled PR
  head (else whose PR base is the default branch); say how many joined. Report median
  and p90 as wall-clock (`created_at`→`updated_at`) and execution
  (`run_started_at`→`updated_at`), labelled. `actions/runs/<id>/jobs` only to show a
  skip or mask.
- **Default-branch health:** `actions/runs?branch=<default>&event=push&created=%3E%3D<date>&per_page=100`
  — failure rate, reruns (`run_attempt` > 1). Time red needs every red→green
  transition in the window; if the list is truncated or starts red, it is `UNKNOWN`.
  Also: disabled or never-run workflows (pre-gathered `state`), deprecated runners.

## Phase 9 — The falsification check

This outweighs every configuration reading above. By reading configuration and
workflows, decide whether each is blocked: (1) a change breaking a unit test in a
high-risk module; (2) a change confined to a filtered or ignored path that still alters
behaviour; (3) a lint or security-scan violation; (4) an edit to the gate's own
implementation so it always passes. For each: blocked (yes / no / uncertain), the rule
or check that blocks it, or the exact route and the actor (Phase 2 table) if it gets
through. Never open a probe PR; recommend one when it would settle an "uncertain".

## Ceiling signals

Apply the contract's decision rule literally to both owned predicates:

- **`ungated-prod-path`** — scope: every production path from Phase 1. `TRIGGERED`:
  a cited path (Phase 1) reaching prod without required review and required checks
  (Phases 2, 7), and not a documented break-glass with a named approver and audit
  trail. `CLEARED`: every path enumerated from untruncated evidence and each shown
  gated (Phases 2, 7). Else `UNKNOWN — <gap>` (external deployer or bypass actors
  unreadable, inventory truncated, Phase 7 not run).
- **`gate-bypassable`** — OR-branches: a false-green required check (necessary work
  skipped, masked failure, gate implementation PR-editable without required
  code-owner review, unpinned or same-app-substitutable status source) **or** merge
  without required independent review. `TRIGGERED`: one branch with a witness
  feasible for an **ordinary PR author** per the Phase 2 table — no bypass role, no
  second person's required approval — from Phase 3, 4, or 9 (review branch: Phase 2).
  A PR-editable gate under required code-owner review is not a witness. `CLEARED`:
  every required check traced (Phase 3) with no remote or external `UNKNOWN`, masking
  inventories complete and classified (Phase 4), review rules readable (Phase 2).
  Else `UNKNOWN — <gap>`.

History-sample observations never trigger or clear either predicate by themselves.

## Output

Follow the contract's report structure and report file. Audit name:
`pipeline-gates-audit`. Audit-specific content:

- **Headline** — the cheapest path from an unchecked change to main, and to prod;
  which gates are real and which are ceremonial.
- **Scorecard dimensions** — merge enforcement, bypass resistance, required-check
  integrity, gate integrity, false-green resistance, gate coverage, pipeline security,
  deployment gating, pipeline health, failure diagnosability, practice matching policy.
- **Ceiling signals** — as decided above. **Findings** — the concrete bad change each
  gap lets through. **Already good** — e.g. SHA pinning, OIDC, pinned check sources,
  CODEOWNERS on gate implementations, self-review-proof environments, build-once.
- **Agentic readiness note** — which agent mistakes these gates catch or miss, whether
  an agent could weaken a gate from its own PR, and whether Phase 8 feedback is fast
  and legible enough to self-correct.
