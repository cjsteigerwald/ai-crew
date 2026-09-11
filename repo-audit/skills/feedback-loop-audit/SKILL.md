---
description: Audit whether a newcomer or AI agent can get a correct, fast, local signal that a change works, from a fresh clone
argument-hint: "[full|triage|<path>]"
disable-model-invocation: true
allowed-tools: Read, Glob, Write(~/repo-audits/**), Bash(git-read:*), Bash(gh-read:*), Bash(ls:*)
---

# Developer Feedback Loop Audit

You are auditing the developer feedback loop of this repository. Your goal is to
answer one question with evidence: **can a newcomer — human or AI agent — get a
correct, fast, local signal that their change works, from a fresh clone, without
tribal knowledge?**

Read the contract shipped with this plugin (`${CLAUDE_PLUGIN_ROOT}/contract.md`) now. Its target-identity, tools, evidence,
safety, auditor-environment, redaction, and reporting rules apply throughout. Use
only `git-read` and `gh-read` for git and GitHub, without pipes; the only write is
the report file. **Honest limits:** this audit reads files and CI metadata; it does
not reproduce a fresh clone, read logs, or measure local speed. Say so where a verdict
rests on those gaps instead of compensating with procedure. Whatever the wrappers
cannot establish (private remote actions, libraries, registries) is `UNVERIFIED`.

## Scope

Requested scope: `$ARGUMENTS`

- empty or `full`: the whole repository, all phases.
- `triage`: Phases 1, 2, 3 and 7 only, statically, within the contract's triage
  budget. Dimensions that depend on skipped phases are `NOT ASSESSED — triage`.
- anything else: a path, package, or service name. Resolve it to paths with
  `git-read ls-files --match '<name>' --limit 50`, listing candidates if ambiguous.
  Re-run the relevant pre-gathers on those paths **plus** the governing root and
  shared configuration (root manifests, lockfiles, toolchain pins, task runners, CI).
  State this search boundary in the Headline. `no-local-signal` can be `CLEARED`
  only if the boundary covers the documented path.

## Pre-gathered facts

A starting point; read results literally, per the contract. Paths, line numbers, and
key names only. Hits are inventory to verify; an empty search never implies absence.

Identity (with default branch), audited revision, manifests and toolchain pins, lockfiles:
!`gh-read 'repos/{owner}/{repo}' --jq '.full_name + " (default: " + .default_branch + ")"' --raw`
!`git-read rev-parse HEAD`
!`git-read ls-files --match '(^|/)(Makefile|GNUmakefile|[Jj]ustfile|Taskfile\.ya?ml|package\.json|devcontainer\.json|flake\.nix|shell\.nix|\.?mise\.toml|\.tool-versions|\.nvmrc|\.node-version|\.python-version|pyproject\.toml|tox\.ini|noxfile\.py|go\.mod|global\.json|rust-toolchain(\.toml)?|Cargo\.toml|\.terraform-version|versions\.tf|gradlew|mvnw|gradle-wrapper\.properties|maven-wrapper\.properties|build\.gradle(\.kts)?|pom\.xml|[^/]+\.csproj|databricks\.yml|Chart\.yaml|Brewfile)$' --limit 60`
!`git-read ls-files --match '(^|/)(package-lock\.json|npm-shrinkwrap\.json|yarn\.lock|pnpm-lock\.yaml|bun\.lockb?|poetry\.lock|uv\.lock|pdm\.lock|Pipfile\.lock|requirements[^/]*\.txt|go\.sum|Cargo\.lock|Gemfile\.lock|composer\.lock|packages\.lock\.json|\.terraform\.lock\.hcl|gradle\.lockfile|verification-metadata\.xml|Chart\.lock|flake\.lock)$' --limit 50`

Task-runner target names and package-script key names (never script bodies):
!`git-read grep -noIE '^[A-Za-z0-9_.-]+:' -- '*Makefile' '*[Jj]ustfile' '*.mk' --limit 40`
!`git-read grep -noE '"(test|lint|format|fmt|check|typecheck|build|setup|bootstrap|ci|prepare|preinstall|postinstall|pretest)[A-Za-z0-9:_-]*" *:' -- '*package.json' --limit 40`

CI and agent-environment definitions (all providers), command-step counts, references, and environment key names. Read every CI file in full regardless:
!`git-read ls-files --match '^\.github/workflows/|^\.github/actions/|(^|/)action\.ya?ml$|(^|/)azure-pipelines[^/]*\.ya?ml$|^\.azure-pipelines/|^\.gitlab-ci\.yml$|(^|/)Jenkinsfile[^/]*$|^\.circleci/|^\.buildkite/|^bitbucket-pipelines\.yml$|^\.drone\.ya?ml$|^\.travis\.yml$|^\.tekton/|(^|/)cloudbuild\.ya?ml$|(^|/)buildspec\.ya?ml$' --limit 80`
!`git-read ls-files --match '^\.github/workflows/copilot-setup-steps\.ya?ml$|^\.github/copilot-instructions\.md$|^\.devcontainer/'`
!`git-read grep -cE '^\s*(-\s*)?(run|script|bash|pwsh|powershell|inlineScript|command):|^\s*(sh|bat|powershell)[ (]' -- .github '*azure-pipelines*' .gitlab-ci.yml .circleci .buildkite '*Jenkinsfile*' --limit 60`
!`git-read grep -noE 'uses: *\./[^ @]*|uses: *[^ ]+/\.github/workflows/[^ @]*|^\s*(-\s*)?template: *[^ #]+|^\s*extends:|^\s*(-\s*)?include:|@Library|^\s*load[ (]' -- .github '*azure-pipelines*' .gitlab-ci.yml .circleci .buildkite '*Jenkinsfile*' --limit 40`
!`git-read grep -noE 'setup-(node|python|go|java|dotnet|terraform|gradle)|(node|python|go|java|dotnet|terraform)-version:|UsePythonVersion|NodeTool|UseDotNet|secrets\.[A-Za-z0-9_]+|vars\.[A-Za-z0-9_]+|services:|container:|matrix:|runs-on: *[[ ]*.?(ubuntu|windows|macos)-[A-Za-z0-9.-]+|runs-on:|self-hosted|pool:|vmImage:|environment:|azure/login|AzureCLI@[0-9]+|aws-actions/configure-aws-credentials|google-github-actions/auth' -- .github '*azure-pipelines*' .gitlab-ci.yml .circleci .buildkite --limit 80`

Hooks, local fakes, containers, env templates (Read compose files; never print `.env*` contents):
!`git-read ls-files --match '(^|/)(\.pre-commit-config\.yaml|\.husky/|\.?lefthook\.ya?ml|\.lintstagedrc[^/]*|lint-staged\.config\.[^/]+|\.githooks/)' --limit 20`
!`git-read ls-files --match '(^|/)(docker-compose[^/]*\.ya?ml|compose[^/]*\.ya?ml|\.env\.(example|sample|template)|Dockerfile[^/]*|Tiltfile)$' --limit 30`
!`git-read grep -lIiE 'testcontainers|localstack|azurite|\bmoto\b|wiremock|httptest|\bnock\b|\bmsw\b' --exclude '(^|/)(AGENTS|CLAUDE)\.md$' --limit 20`

Setup and test headings in markdown docs:
!`git-read grep -nIiE '^#{1,4} .*(setup|set up|install|getting started|prerequisite|local|develop|build|test|lint|run)' -- '*.md' --exclude '(^|/)(AGENTS|CLAUDE)\.md:' --limit 40`

Workflows known to GitHub (including dynamic ones such as the Copilot agent), and recent runs on all branches. Elapsed is `run_started_at` to `updated_at` and includes job queueing:
!`gh-read 'repos/{owner}/{repo}/actions/workflows?per_page=100' --jq '.workflows[] | "\(.id)\t\(.state)\t\(.path)"' --raw`
!`gh-read 'repos/{owner}/{repo}/actions/runs?per_page=20' --jq '.workflow_runs[] | "\(.id)\t\(.name)\t\(.event)\t\(.conclusion)\tattempt=\(.run_attempt)\t\(.head_branch)\t\(.head_sha[0:7])\t\((.updated_at|fromdate)-(.run_started_at|fromdate))s"' --raw`

## Ground rules

- **Provenance and outcome are separate.** Every Phase 1 step, inner-loop claim, and
  Headline verdict records both. Provenance is `static` (read, nothing run), `warm`
  (the auditor's checkout, with its tools, caches, generated files, and ambient
  credentials), or `clean`. Outcome is `passed`, `failed`, `contradicted` (the doc
  disagrees with config or code), or `unknown`. Static reading can show
  `contradicted` or `unknown — consistent with config`, never `passed`. A warm pass
  never upgrades fresh-clone readiness.
- **Clean environment**: an ephemeral environment, built from a fresh checkout, that
  successfully ran the documented lint and test commands at the audited revision or
  one with the same build configuration (manifests, lockfiles, pins, CI definition).
  Two kinds count. One is a GitHub-hosted runner (`runs-on: ubuntu-*/windows-*/
  macos-*`), confirmed by the job's `labels` / `runner_group_name` in
  `actions/runs/<id>/jobs`, or by `vmImage` in Azure Pipelines. The other is an
  agent sandbox, such as the Copilot coding agent via `copilot-setup-steps`.
  Self-hosted or persistent runners (ARC, named pools) are **warm**. Running
  commands other than the documented ones supports parity, not the documented path.
- **Auditor environment**: never inventory home, credential stores, or runtimes; a
  local run records only "ambient credentials not isolated — warm evidence only".
- **Neither a runner name (`test`, `check`) nor a script body is safety evidence.**
  A script's dependencies, lifecycle hooks, fixtures, and Make prerequisites also run.
- **Local runs** follow the contract's local-execution rule. Request each one through
  the permission prompt: documented test or lint commands only, deps already
  installed, `timeout 600`, no watch mode. Log each; the result is warm at best.
- **CI evidence** is run and job metadata, never logs:
  `actions/runs?branch=<default>&per_page=30`, `actions/workflows/<file>/runs`, and
  `actions/runs/<id>/jobs` (steps, conclusions, timestamps, runner labels).
- **Timing, never conflated.** Run elapsed includes queueing. **CI execution time**
  is job and step `started_at`/`completed_at`, on CI hardware with CI caches; it is
  neither an upper bound on local time nor a proxy for it. Setup cost is a job's
  install, cache, and toolchain steps. Local latency is `UNVERIFIED` unless a
  permitted local run reported its own duration; cite that as warm.

## Phase 1 — Walk the documented path from a fresh clone (do this FIRST)

This phase outranks every other. Simulate the newcomer: start from the README, then
CONTRIBUTING, then what they link to. In allow-listed-org repos (contract list),
include the Copilot surfaces the contract names. Follow **only** what the repository writes down, in
order, until you reach "I have a lint result and a test result". Label each step
with a kind, a provenance, and an outcome:

- **stated and correct**: stated, and the outcome is `passed` (warm or clean). A step
  that is only statically consistent is **stated, unconfirmed**.
- **stated and wrong**: stated, and the outcome is `contradicted` (doc line vs
  config: a script the manifest lacks, a version the pin contradicts, a missing
  path) or `failed` (cite the run or step conclusion).
- **unstated**: needed but not written down, **and** the repository holds the answer
  (a pin, a manifest, a CI step). Cite where the answer lives.
- **tribal**: needs knowledge or access the repository cannot give: a VPN, a person
  to ask, a shared dev database, a vault secret, a private registry login.

Report the walk as a numbered list with counts per kind, and walk each alternative
path the docs offer. The first **tribal** or **stated and wrong** step before a lint
and test result is the headline candidate.

## Phase 2 — Setup and toolchain reproducibility

Look for a one-command bootstrap (task runner, script, devcontainer, Nix, mise/asdf)
that does what the docs say without mutating global state. Check that local
toolchain pins agree with what CI installs (`setup-*` inputs, container or pool
images); a mismatch is a finding. Check that CI installs strictly from the lock
(`npm ci`, `--frozen-lockfile`, `uv sync --locked`, `--require-hashes`,
`--locked-mode`, `cargo --locked`). File presence is an inventory signal, not a
verdict: judge each column separately for every ecosystem present, and name any
uncovered ecosystem as a coverage limit.

| Ecosystem | Toolchain selection | Dependency selection | Integrity verification |
|---|---|---|---|
| Node | `engines`, `packageManager`, `.nvmrc`/`.node-version` | lockfile for the manager in use, strict install | lockfile `integrity` hashes |
| Python | `.python-version`; `requires-python` is a range, not a pin | `poetry`/`uv`/`pdm`/`Pipfile` lock, or fully pinned requirements; a ranged `requirements.txt` is not a lock | lock hashes or `--require-hashes` |
| Go | `go`/`toolchain` directive | `go.mod` (minimal version selection); `go.sum` is **not** a lockfile | `go.sum`, required only when there are dependencies |
| Maven | wrapper pins **Maven only**; JDK via toolchains or CI | explicit `pom.xml` versions; ranges and SNAPSHOTs still float | none by default |
| Gradle | wrapper (`distributionSha256Sum`), JDK toolchain | dependency locking (`gradle.lockfile`) | `verification-metadata.xml` checks checksums, does **not** lock versions |
| .NET | `global.json` | `packages.lock.json` with locked restore | lock `contentHash` |
| Rust | `rust-toolchain(.toml)` | `Cargo.lock` with `--locked` | `Cargo.lock` checksums |
| Terraform | `required_version`, `.terraform-version` | `.terraform.lock.hcl` locks providers; modules need pinned versions or refs | lock hashes |
| Databricks | `spark_version`/runtime in `databricks.yml` | per the code's ecosystem | per ecosystem, plus a local test path that needs no workspace |
| Helm | Helm version in CI | `Chart.lock` | `Chart.lock` digest |

## Phase 3 — External dependencies for build and test

List everything the build and tests reach outside the checkout (databases, queues,
caches, cloud APIs and credentials, VPN-only hosts, private registries, secrets,
shared environments) from config, env templates, fixtures, and CI key names — names
only. For each: is there a documented local fake or container? Do unit tests run without it?

## Phase 4 — Local and CI parity

**Read every discovered CI definition in full.** Key searches miss commands in
multi-line blocks, anchors, matrices, and script files, so an empty search never
means "no commands". Follow references recursively: reusable workflows, local and
remote composite actions, templates, `extends`, includes, and each job's matrix,
container, and services context. In Jenkins, that means `sh`/`bat`/`powershell`
steps, `load`-ed scripts, and `@Library` shared libraries. Mark `UNVERIFIED`, with
no parity verdict, any reference you cannot read (a private or remote library, a
missing file, a computed path) and any provider whose steps you cannot reliably
extract (such as Tekton or dynamic Buildkite).

Build a table per PR-triggered job: **CI step / local equivalent / documented? /
same flags, versions, and env?** Flag CI-only steps, the same tool with different
flags, config, or versions, env vars, services, OS, or runner image that make
verdicts diverge, and pre-commit hooks that CI does not enforce.

## Phase 5 — The fast inner loop

Using the actual commands, determine whether a developer can lint and format-check
one file or the whole repo, typecheck, run a single test file or named test (and
whether that is documented), and rebuild incrementally. Give each a provenance, an
outcome, and a timing class. Save-to-signal seconds are `UNVERIFIED` unless measured
locally.

## Phase 6 — Signal quality and determinism

- **Failure messages.** Keep configured reporting (reporters, formatters, JUnit or
  annotation output, verbosity, `|| true`, `continue-on-error`) separate from
  observed diagnostics, which are `UNVERIFIED` unless step conclusions or check-run
  annotations (`commits/<sha>/check-runs`) show them; logs are not read.
- Warnings-as-errors or buried failures; determinism (reruns with `attempt` > 1, CI
  retries, time/network/order dependence). Leave test quality to `test-audit`.

## Phase 7 — Agent environment and falsification walk

**Agent environment.** If `copilot-setup-steps` exists (always check in
allow-listed-org repos), Read it: runner (hosted or self-hosted), runtimes, services, and secret and
variable names. Trace whether the documented verification command runs there;
credentials provisioned to the agent's own environment count as ones it has. Report
this apart from CI predictiveness; with no file and no documented setup, `UNKNOWN`.

**Falsification walk.** Pick the riskiest module and a **HYPOTHETICAL** small change,
which you do not make. Walk as an AI agent with no memory, no chat, and no one to
ask. At each step, record what the docs say to do next (**discoverable from docs**)
and what config confirms or refutes it (**config evidence**). An **unstated** step
the agent can recover from config (a pin, a CI step, a target) is a legibility
finding, and the walk continues, marked `config-derived`. A **tribal** step
(knowledge or access absent from the repository) stops the walk. Determine how the agent would know which command verifies its change, whether it runs
without credentials the agent lacks, and whether a local pass predicts CI (Phase 4).
Say where it would guess, and the plausible wrong guess: skip the test, run the whole
suite, invent a command, or give up.

## Ceiling signal — `no-local-signal`

Apply the contract's definition and decision rule exactly, using Phases 1, 3 and 7.

- **TRIGGERED** needs a witness that the documented path from a fresh clone to a
  lint and test result is missing (no documented path, shown by an untruncated doc
  search), broken (a **stated and wrong** step), or blocked (a **tribal** step, or a
  credential the agent's environment would lack). Every documented alternative must
  be shown missing, broken, or blocked too. An alternative of unknown status leaves
  the predicate `UNKNOWN`.
- **CLEARED** needs a cited successful clean-environment run of the documented lint
  **and** test commands, at the audited revision or one with the same build
  configuration. Cite the run ID, job, runner labels, and step conclusions, and show
  that there is no witness. A clean run that relies on secrets the agent would not
  have is a blocked-path witness. Static or warm evidence never clears.
- **UNKNOWN** is everything else, with the gap named: no clean run cited, the build
  configuration drifted since the last clean run, or an alternative unverified.

## Output

Follow the contract's report structure and report file. Audit name:
`feedback-loop-audit`. Audit-specific content:

- **Headline**: the answer to the audit question, the first step where it becomes no,
  the strongest provenance reached for the documented path, and (narrowed runs) the
  search boundary.
- **Scorecard dimensions**: setup documentation accuracy, bootstrap automation,
  toolchain pinning, dependency reproducibility, external-dependency isolation,
  local–CI parity, agent-environment readiness, inner-loop speed, targeted-test
  ergonomics, signal clarity, determinism.
- **Ceiling signals**: the `no-local-signal` row, as above. **Findings**: the moment
  each gap stalls a newcomer or lets an agent ship unverified.
- **What is already good**: e.g. a one-command bootstrap, a devcontainer/Nix shell CI
  also uses, pins matching CI, strict locked installs, local fakes, a documented
  single-test command, CI calling developers' targets, agent setup mirroring CI.
- **Agentic readiness note**: from a fresh clone and the docs alone, could an agent
  find and run its verification command, and trust it to predict CI?
- **Execution log**: `UNVERIFIED` wrapper calls, and any local run with its "ambient
  credentials not isolated — warm evidence only" note.
