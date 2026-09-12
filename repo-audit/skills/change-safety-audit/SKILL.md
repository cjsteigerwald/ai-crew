---
description: Audit this repository's blast radius, progressive delivery, detection, and rollback, and report evidence-backed findings on how much damage a bad change can do in production
argument-hint: "[full|triage|<service-path>]"
disable-model-invocation: true
allowed-tools: Read, Glob, Write(~/repo-audits/**), Bash(git-read:*), Bash(gh-read:*), Bash(ls:*)
---

# Change Safety Audit

You are auditing what happens after a bad change gets past the gates. Your goal is to
answer one question with evidence: **when a wrong change does reach production, how
much damage can it do, how fast is it detected, and how fast and safely can it be
undone?**

Read the contract shipped with this plugin (`${CLAUDE_PLUGIN_ROOT}/contract.md`) now. Its target-identity, tools, evidence,
safety, redaction, and reporting rules apply throughout. This audit is static: do not
deploy, roll back, re-run, cancel, or dispatch anything, and never run `terraform`,
migration, or state commands. Git reads go through `git-read`, GitHub reads through
`gh-read`; what they cannot reach is `UNVERIFIED`. The only write is the report file.

## Scope

Requested scope: `$ARGUMENTS`

- empty or `full` — audit the whole repository, all phases.
- `triage` — Phases 1, 2, 4 and 9 only, condensed report, within the contract's
  triage budget. Dimensions from skipped phases are `NOT ASSESSED — triage`.
- anything else — a service directory or deployable name; narrow every phase to it,
  its deploy workflow, its per-environment config, and its data stores, plus the
  governing root and shared configuration.

## Pre-gathered facts

A starting point — verify anything you build a finding on. Read `ERROR:`, `(no
matches)`, `(showing L of N lines)`, and empty `gh-read` lists as the contract says.

Repository and revision:
!`gh-read 'repos/{owner}/{repo}' --jq '.full_name + " (default: " + .default_branch + ", " + .visibility + ")"' --raw`
!`git-read rev-parse HEAD`

Workflows that deploy, release, or apply:
!`git-read grep -lIiE 'deploy|helm (upgrade|install)|kubectl (apply|rollout)|terraform apply|argocd|webapps-deploy|containerapp|az functionapp|bundle deploy|release' -- .github/workflows --limit 30`

Environment-specific config files (compare for drift):
!`git-read ls-files --match '(\.tfvars|(^|/)values[^/]*\.ya?ml|(^|/)appsettings\.[^/]+\.json|(^|/)\.env\.[^/]+|(^|/)application-[^/]+\.(ya?ml|properties)|(^|/)databricks\.ya?ml|(^|/)kustomization\.ya?ml)$' --limit 40`

Evidence that may live outside this repo (deploy controllers, config providers, flag
SaaS, monitoring, Terraform backends):
!`git-read grep -lIiE 'argoproj\.io|kind: *(Application|ApplicationSet|HelmRelease|Kustomization)|fluxcd|azurerm_app_configuration|appconfig|key_?vault|launchdarkly|unleash|flagsmith|dynatrace|datadog|backend "|cloud \{' --exclude '(^|/)(AGENTS|CLAUDE)\.md$' --limit 30`

Incident, RCA, postmortem, and runbook documents:
!`git-read ls-files --match '(^|/)[^/]*([Rr][Cc][Aa]|RCA|[Pp]ost-?[Mm]ortem|POSTMORTEM|[Ii]ncident|INCIDENT|[Rr]unbook|RUNBOOK|[Pp]laybook|PLAYBOOK)' --exclude '(^|/)(AGENTS|CLAUDE)\.md$' --limit 40`

Feature flags and progressive delivery:
!`git-read grep -lIiE 'launchdarkly|unleash|flagsmith|openfeature|growthbook|featuremanagement|feature_flag|featureflag|kill.?switch|kind: *Rollout|AnalysisTemplate|canary|bluegreen|blue-green|trafficsplit|traffic_weight|maxSurge' -- ':(exclude)*.lock' --exclude '(^|/)(AGENTS|CLAUDE)\.md$' --limit 30`

Migration tooling and migration files:
!`git-read ls-files --match '(^|/)(migrations?|db/migrate)/|(^|/)(alembic\.ini|flyway[^/]*\.conf|liquibase[^/]*\.properties|[^/]*changelog[^/]*\.xml|schema\.prisma)$' --limit 40`

Terraform lifecycle, refactor, and state-surgery signals (keywords only):
!`git-read grep -noIE 'prevent_destroy|create_before_destroy|ignore_changes|replace_triggered_by|deletion_protection|delete_protection|^ *(moved|removed|import) *\{|destroy *= *false' -- '*.tf' --limit 40`
!`git-read grep -noIE 'terraform +(state +(mv|rm)|import)|-target[= ]|terraform +workspace +(select|new)|-backend-config' --exclude '(^|/)(AGENTS|CLAUDE)\.md:' --limit 20`

Artifact identity — tokens only, never registry hosts. An `image` key whose line has
no `@sha256:` or `:latest` token is a non-digest tag:
!`git-read grep -noIE '@sha256:|:latest\b|(^|[[:space:]"-])image"? *[:=]|imageTagMutability|image_tag_mutability|tag_mutability' -- ':(exclude)*.md' ':(exclude)*.lock' --limit 40`

Health checks and probes (keywords only), then observability instrumentation:
!`git-read grep -noIE 'readinessProbe|livenessProbe|startupProbe|HEALTHCHECK|health_check|healthcheck|/healthz|/readyz' -- ':(exclude)*.md' --limit 30`
!`git-read grep -lIiE 'opentelemetry|otel_|otlp|applicationinsights|dynatrace|datadog|prometheus|newrelic|sentry' -- ':(exclude)*.md' ':(exclude)*.lock' --limit 25`

Rollback documentation, then revert/hotfix/rollback commits (discovery candidates only):
!`git-read grep -lIiE 'rollback|roll back|revert a deploy|redeploy previous' -- '*.md' --exclude '(^|/)(AGENTS|CLAUDE)\.md$' --limit 20`
!`git-read log --oneline -i -E --grep=^revert --grep=hotfix --grep=rollback --grep='roll back' -25 --exclude '(AGENTS|CLAUDE)\.md'`

Tags, releases, deployments, environments, then recent workflow runs (newest first):
!`git-read tag -l --sort=-creatordate --limit 15`
!`gh-read 'repos/{owner}/{repo}/releases?per_page=15' --jq '.[] | [.tag_name, ((.published_at // "draft")[:10]), (if .prerelease then "prerelease" else "release" end)] | @tsv' --raw`
!`gh-read 'repos/{owner}/{repo}/deployments?per_page=20' --jq '.[] | [.created_at[:16], .environment, .sha[0:7]] | @tsv' --raw`
!`gh-read 'repos/{owner}/{repo}/environments' --jq '"total: \(.total_count)", (.environments[] | [.name, ((.protection_rules // []) | map(.type) | join(","))] | @tsv)' --raw`
!`gh-read 'repos/{owner}/{repo}/actions/runs?per_page=40' --jq '.workflow_runs[] | [.created_at[:16], .name, .event, .head_branch, (.conclusion // "running")] | @tsv' --raw`

## Ground rules

- Mark every rollback and detection step **documented** (a runbook or workflow says
  so — cite it), **inferred** (the mechanism exists but no one wrote or exercised the
  procedure), or **unknown**. Most of this audit's value is in that distinction.
- For **scoring**, a control earns 4-5 only with execution evidence (a run, event,
  drill, or incident where it fired); configuration alone scores as inferred. The
  `no-rollback` predicate has its own rule below and does not require execution.
- Change safety usually lives partly elsewhere; what you cannot read is `UNVERIFIED`,
  and externally supplied secrets or config are not "missing". Capture key names,
  paths, and classifications — never values, raw health-check commands, backend
  configuration blocks, or registry hosts.
- Branch protection, environment approvals, and required checks belong to
  `pipeline-gates-audit`: cite its report under `~/repo-audits/`, do not re-derive.

## Phase 1 — Evidence map (do this FIRST)

Map where this system's change-safety evidence lives and whether you can read it:
this repo, the deployment controller (Argo CD, Flux, Helm releases, pipeline-only),
charts, infrastructure repos and Terraform workspaces/backends; config providers (App
Configuration, Key Vault, flag SaaS — changes there bypass app deployment);
monitoring (alerts, SLOs, deploy events); incident records (RCAs, tickets, runbooks).
Follow references you can read (a sibling checkout via `Read`/`Glob`, `gh-read` on a
named repo). Record each location as read or `UNVERIFIED — <why>`. Identify the
workload type — request-serving, batch/data, streaming, infrastructure-only,
library — later phases branch on it.

## Phase 2 — Blast radius and promotion

- Deploy units: what one deploy changes. A shared library, chart, or module that
  redeploys many units is the widest blast radius. This list is the scope of
  `no-rollback` component (a).
- Environments and promotion path: whether prod receives the **same artifact**
  non-prod ran (build-once-promote) or a rebuild; any path to prod that skips a lower
  environment.
- Shared state: stores, queues, caches, or cloud resources shared across units or envs.

## Phase 3 — Non-prod fidelity

Resolve config provenance per environment first (tfvars, CLI `-var`, environment
variables, Terraform Cloud variables, Helm values layering, App Configuration
labels). A value whose source you cannot resolve is unknown, not equal. Compare key
names and structure; do not print values from environment or credential files.

Classify each difference as intentional or not (sizing, hostnames, credential
references, staged image tags are usually deliberate) and by its effect on test
fidelity (smaller data hides locking and slow migrations; different endpoints hide
auth and network failures; smaller sizing hides saturation; a timeout, retry, or
probe present in one env only hides its failure). Allege non-compliance only against
a cited standard. Otherwise report a difference only when it leaves a material
failure mode untested, and name the bad change it would let through.

## Phase 4 — Rollback and artifact immutability

- Documented procedure: where, for which deploy units, last touched
  (`git-read log -1 --format=%cs -- <runbook>`), and whether it is **current and
  applicable** — the workflows, paths, and commands it names still exist at the
  audited revision and fit this deploy unit.
- Artifact identity: tags (including SHA-named tags) are mutable. Check digest
  pinning, registry tag immutability (evidence, not assumption), build-once
  promotion, retention, and whether the previous artifact still exists (registry
  contents are usually `UNVERIFIED`). A version input to a deploy workflow shows
  selection capability, not reproducible rollback.
- Terraform: `prevent_destroy` on stateful resources (removing the resource block
  removes the protection too); `moved` blocks and `state mv` history; `removed`
  blocks (destroy versus `destroy = false` relinquish); `state rm` / `import` in
  scripts or docs; routine `-target`; workspace/backend selection logic;
  `ignore_changes` masking drift; force-replacement attributes. CI plan logs are not
  readable through `gh-read` — `UNVERIFIED`.
- Non-reversible surfaces (applies, data writes, published messages, external calls).

## Phase 5 — Data changes

- **Migrations:** engine, version, and the tool's transaction behaviour first; then
  when they run (pipeline, startup, by hand), lock and statement timeouts,
  representative-volume testing, backfill throttling, expand/contract across
  releases, and partial-failure recovery. For PostgreSQL `CREATE INDEX CONCURRENTLY`:
  runs outside a transaction block and can leave an INVALID index on failure; verify
  restrictions for the actual engine, version, and statement. A down script may lose
  data: credit reversibility only with evidence of data-preserving reversal, or a
  restore or forward-fix procedure with its duration and data-loss implications.
  Sample the last ten migrations; flag destructive statements without a guard or
  backup step.
- **Databricks / data workloads:** bundle targets, artifact or notebook identity per
  deploy, schedules and active runs during deploy, retries, failure and duration
  alerts, freshness and quality checks, checkpoint/state handling. Separate rollback
  of job definitions from recovery of written data and downstream consumers.
- **Other batch / streaming:** idempotency and replay, offsets on redeploy,
  dead-letter paths, backfill procedure, what consumers see from a bad run.

Destructive surfaces from Phases 4 and 5 are the scope of `no-rollback` component (b).

## Phase 6 — Detection

- Probes per deployable. Readiness that checks shared dependencies can amplify an
  outage; credit readiness semantics that match what admitted traffic needs.
- Post-deploy verification: smoke tests, analysis, or nothing after `apply` returns.
  `kubectl rollout status` proves availability, not correctness.
- Observability, alerts, SLOs, and deploy markers on the paths that matter (external
  ones `UNVERIFIED`): would a bad deploy stand out, or would a user report it first?

## Phase 7 — Progressive delivery and containment

- Rollout strategy: `maxSurge`/`maxUnavailable`, canary, blue-green, Argo Rollouts.
  PodDisruptionBudgets do not constrain rolling updates — no rollout credit.
- Argo Rollouts: the analysis templates actually attached, their queries,
  thresholds, windows, inconclusive handling, and abort. Dry-run metrics do not gate.
- Flags: separate retired release flags from operational kill switches; for kill
  switches check dynamic control, propagation delay, failure default when the
  provider is unreachable, and whether the off path is tested.

## Phase 8 — Config and secret change safety

Config validated at startup (fail fast) versus failing at first use; for changes that
bypass app deployment (App Configuration, Key Vault, flag SaaS), promotion,
versioning, reload semantics, rollout scope, and restoring the previous version;
secret rotation overlap and consumers caching old values. Keys with no visible
provenance for an environment are `UNVERIFIED`, not missing.

## Phase 9 — The falsification check

This step outweighs every configuration reading above.

**Classify candidates.** Reverts, hotfixes, reruns, older-tag deploys, and RCA
mentions are **discovery candidates**. Promote one to a **corroborated production
incident** (production activation, impact, and incident or recovery records agree)
or a **corroborated rollback exercise** (a drill or real rollback with execution and
verification evidence; no impact needed — rollback-effectiveness evidence, not an
incident). Anything else is an **unresolved candidate**.

**Actual incidents.** Take the most recent up to three corroborated production
incidents in readable sources within the last 12 months, newest first. Trace each:
change identity → production activation (deploy, config publish, flag change,
credential rotation, job run) → impact → detection → mitigation → verified recovery.
Cite evidence per step, mark it documented / inferred / unknown, and mark
inapplicable steps `n/a`. Report impact→detection and detection→verified recovery as
separate intervals from step timestamps (commit-to-run-complete measures neither).
Fewer than three is a coverage limitation stated in the Headline, not a finding; a
traceability finding needs an actual incident whose record is missing or broken.

**Hypothetical supplement** — label each `HYPOTHESIS`. Trace three plausible bad
changes for the workload type (a prod-only bad config value; a slow or locking change
on the largest store; a wrong-results logic bug on the hottest path or output): which
environment catches it first (or none), how it is detected, and the recovery steps,
each documented / inferred / unknown.

## Ceiling signal: `no-rollback`

Decide it from Phases 2, 4, 5 and 9 with the contract's decision rule:

- **(a) Restore path.** Satisfied for a production deploy unit by a current,
  applicable documented procedure, **or** evidence of one (a corroborated rollback
  exercise or incident rollback). Proven failure: a named unit whose only procedure
  is stale or inapplicable, or whose previous version is shown unrecoverable (mutable
  tag overwritten with no retained artifact, rebuild from unpinned inputs) with no
  alternative anywhere in the Phase 1 evidence map.
- **(b) Destructive changes.** Satisfied when every enumerated destructive data or
  infrastructure surface has a guard (`prevent_destroy`, deletion protection, backup
  step, expand/contract policy, `destroy = false` relinquish) or a reversal path.
  Proven failure: a named migration, resource, or workflow that can ship a
  destructive change with neither.

Either component proven failed → `TRIGGERED`, naming the witness. Both affirmatively
satisfied over complete, untruncated enumerations → `CLEARED`. Otherwise `UNKNOWN`,
naming the gap. Execution evidence raises the rollback readiness score; the predicate
does not require it.

## Output

Follow the contract's report structure and report file. Audit name:
`change-safety-audit`. Audit-specific content:

- **Headline** — damage, time to notice, and time to undo; say which are evidenced,
  and state any Phase 9 coverage limitation.
- **Scorecard dimensions** — evidence accessibility, blast radius containment,
  non-prod fidelity, promotion discipline, rollback readiness, artifact immutability,
  migration and data-recovery safety, IaC destruction guards, detection and
  observability, progressive delivery, config and secret change safety.
- **Ceiling signals** — the `no-rollback` row, decided as above.
- **Findings** — each is either an observed incident with citations or a failure
  scenario labelled `HYPOTHESIS`. Give impact→detection and detection→verified
  recovery separately, each measured (cite timestamps), estimated (cite the
  assumptions), or unknown.
- **What is already good** — e.g. digest-pinned, build-once-promoted artifacts; an
  exercised rollback with recorded recovery; `prevent_destroy` on stateful
  resources; analysis-gated rollouts with execution evidence; tested kill switches.
- **Agentic readiness note** — how far an agent's bad change would spread, who would
  notice, and whether it could be undone from the repo's own documentation.
