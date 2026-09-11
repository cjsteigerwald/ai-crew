---
description: Audit this repository's test suite and report evidence-backed findings on testing quality
argument-hint: "[full|triage|<path>]"
disable-model-invocation: true
allowed-tools: Read, Glob, Write(~/repo-audits/**), Bash(git-read:*), Bash(gh-read:*), Bash(ls:*)
---

# Test Suite Audit

You are auditing the testing practices of this repository. Your goal is to answer
one question with evidence: **when this test suite is green, what do we actually
know?**

Read the contract shipped with this plugin (`${CLAUDE_PLUGIN_ROOT}/contract.md`) now. Its target-identity, tools, evidence,
capture-time secret, safety, redaction, and reporting rules apply throughout. This
audit is static: do not modify the repository, and do not write or fix tests. The
only write is the report file.

## Scope

Requested scope: `$ARGUMENTS`

- empty or `full` — audit the whole repository, all phases.
- `triage` — run Phases 1, 2, 3 and 7 only, within the contract's triage budget
  (~5 minutes, ~25 wrapper calls), on up to the three riskiest modules — fewer if the
  budget runs out. Dimensions that depend on skipped phases are
  `NOT ASSESSED — triage`; see Ceiling signals for how a short run decides the
  predicate.
- anything else — a path or module: narrow every phase to it, its tests wherever
  they live, and the governing root and shared config (runner config, lockfiles, CI).

## Pre-gathered facts

A starting point — verify anything you build a finding on. `ERROR:` = collection
failed (`UNVERIFIED`); `(no matches)` = found nothing; `(showing L of N lines)` = the
list is **incomplete** — take totals from `--count`, never argue absence from it.
Empty `gh-read` output means the call succeeded with zero items.

Target identity and default branch (phases use this branch; never infer it):
!`gh-read 'repos/{owner}/{repo}' --jq '.full_name + " (default: " + .default_branch + ")"' --raw`

Tracked files (total):
!`git-read ls-files --count`

Ecosystem manifests:
!`git-read ls-files --match '(^|/)(package\.json|pyproject\.toml|setup\.(cfg|py)|requirements[^/]*\.txt|go\.mod|pom\.xml|build\.gradle(\.kts)?|[^/]+\.(csproj|sln)|Cargo\.toml|Gemfile|composer\.json|databricks\.yml|Chart\.yaml|main\.tf)$' --exclude '(^|/)(AGENTS|CLAUDE)\.md$' --limit 40`

Test runner, coverage, and mutation configuration:
!`git-read ls-files --match '(^|/)(jest\.config\.[^/]+|vitest\.config\.[^/]+|pytest\.ini|tox\.ini|noxfile\.py|conftest\.py|\.coveragerc|karma\.conf\.[^/]+|playwright\.config\.[^/]+|cypress\.config\.[^/]+|phpunit\.xml|\.mocharc[^/]*|Makefile|justfile|Taskfile\.ya?ml|stryker\.conf[^/]*|setup\.cfg|[^/]+\.tftest\.hcl|[^/]+\.runsettings|Directory\.Build\.props)$' --exclude '(^|/)(AGENTS|CLAUDE)\.md$' --limit 40`

Test files — total, then a sample (case-sensitive filename inventory including .NET
`*.Tests/` projects and JVM `src/test/`; the runner's own configuration decides what
actually runs):
!`git-read ls-files --match '(^|/)([Tt]ests?|[Ss]pecs?|__tests__|e2e|integration)/|(^|/)[^/]+\.Tests?/|(^|/)src/test/|(^|/)test_[^/]+$|[._-](test|spec|tests)\.[a-z]+$|_test\.go$|Tests?\.(java|kt|cs)$' --exclude '(^|/)(AGENTS|CLAUDE)\.md$' --count`
!`git-read ls-files --match '(^|/)([Tt]ests?|[Ss]pecs?|__tests__|e2e|integration)/|(^|/)[^/]+\.Tests?/|(^|/)src/test/|(^|/)test_[^/]+$|[._-](test|spec|tests)\.[a-z]+$|_test\.go$|Tests?\.(java|kt|cs)$' --exclude '(^|/)(AGENTS|CLAUDE)\.md$' --limit 60`

Skipped, ignored, or disabled test markers (path, line, marker only):
!`git-read grep -noIE 'it\.skip|(^|[^A-Za-z0-9_.])xit\(|describe\.skip|test\.skip|@Ignore|@Disabled|pytest\.mark\.(skip|xfail)|#\[ignore\]|t\.Skip\(|\[Ignore\]|Skip *= *"' --exclude '(^|/)(AGENTS|CLAUDE)\.md:' --limit 40`

Recent fix commits (check whether these shipped with tests):
!`git-read log --oneline -i -E --grep='^(fix|hotfix)|bug' -15 --exclude '(AGENTS|CLAUDE)\.md'`

CI and pipeline definitions:
!`git-read ls-files --match '^(\.github/workflows/|\.github/actions/|\.gitlab-ci\.yml|\.circleci/|\.buildkite/|bitbucket-pipelines\.yml)|(^|/)azure-pipelines[^/]*\.ya?ml$|(^|/)Jenkinsfile$' --exclude '(^|/)(AGENTS|CLAUDE)\.md$' --limit 40`

Retry, flake tolerance, and failure masking in CI (path, line, keyword only):
!`git-read grep -noIE 'retries|rerun|retry|flaky|--repeat|continue-on-error|\|\| *(true|:)|set \+e' -- .github/workflows .github/actions .gitlab-ci.yml .circleci '*azure-pipelines*' '*Jenkinsfile' --exclude '(^|/)(AGENTS|CLAUDE)\.md:' --limit 40`

Recent pull-request CI runs (id, workflow, conclusion, attempt, head SHA):
!`gh-read 'repos/{owner}/{repo}/actions/runs?event=pull_request&per_page=20' --jq '.workflow_runs[] | [.id, .name, .conclusion, .run_attempt, .head_sha[0:7]] | @tsv' --raw`

## Ground rules

- Contract evidence rules apply; prefer counting to guessing — if you assert "most
  tests are happy-path," show the sample and its size.
- **Tools:** only `git-read`, `gh-read`, `ls`, Read, Glob; filter with the wrappers'
  flags, never a pipe. What they cannot do is `UNVERIFIED — <what>`, not a new tool.
- **Capture-time secrets:** emit paths, line numbers, key names, counts
  (`git-read grep -l`/`-c`/`-noE '<key-pattern>'`). Read whole lines only from source
  and test code; from CI env blocks, configs, package scripts, and registry files
  Read only the lines you need and never quote values.
- **Allow-listed-org repos:** add `--exclude '(^|/)(AGENTS|CLAUDE)\.md$'` to every listing call.
- Line-coverage percentage is never a headline finding — it is the weakest signal.
- Discover tests from the runners' own configuration (testpaths, globs, markers,
  project files), not only the filename inventory. State the inventory size (the
  `--count` line), what the runner excludes, and how you drew any sample.
- Runtime and pass/fail come from CI history via `gh-read`. Job logs are not
  readable through it, so per-run test counts are `UNVERIFIED` unless a committed or
  configured report states them. Local runs follow the contract's local-execution
  rule: request, never assume.

## Phase 1 — Map the risk surface (do this FIRST)

Before reading any test, identify the 5-10 modules where a defect would be most
costly: auth, money, data migrations, deletion, external integrations, untrusted
input parsing, concurrency — and, where the product is scripts, hooks, validators,
or pipelines, those.

**Rank them** (1 = riskiest) and state the ranking criterion. Phases 5 and 7 take the
top three of this ranking. Say whether the candidate list is complete (built from an
untruncated `git-read ls-files`) — an incomplete list limits what Phase 7 can clear.

For each, record whether tests exist at all, and at what level
(`git-read grep -l '<module symbol>' -- <test paths>`). Untested risk is the finding
that outranks everything else in this audit.

## Phase 2 — Establish the facts

- How the suite is invoked, taken from configuration rather than the README, and
  whether the local and CI invocations differ.
- What it needs to run: database, network, secrets, VPN, a shared environment — name
  the requirement and `path:line`, never the value.
- Wall-clock runtime from CI job durations:
  `gh-read 'repos/{owner}/{repo}/actions/runs/<id>/jobs' --jq '.jobs[] | [.name, .conclusion, .started_at, .completed_at] | @tsv' --raw`.
- Test counts by level: unit, integration, contract, end-to-end, smoke
  (`git-read ls-files --match '<level path>' --count`). State how you classified
  them — if `tests/unit/` contains tests that touch a database, say so.
- Skipped and disabled test count (`git-read grep -cIE '<marker pattern>'`), with the
  age of the oldest (`git-read blame -L <n>,<n> --date=short -- <path>`).
- Test-to-source ratio by directory, by file count
  (`git-read ls-files --match '^<dir>/' --count` for source and tests); line ratios
  from `git-read grep -cI '' -- <dir>` only where that output is not truncated.

## Phase 3 — What does "green" mean?

A green run only means something if the right tests ran against the right code and
failures propagate. Establish, from configuration and CI run history:

- **What ran:** does the CI invocation select the tests you inventoried, or can
  filters, markers, path conditions, or an empty match make it run zero tests and
  still pass? Does the runner fail on "no tests collected"?
- **Against what:** does it test the working tree of the change, or an installed
  package, a cached build, or a previously published artifact?
- **Failure propagation:** can a failing test end green — `continue-on-error`,
  `|| true`, retries, a wrapper script that swallows the exit code, a reporting step
  that decides the status? Cite `path:line`. Observed behaviour: step conclusions from
  `.../actions/runs/<id>/jobs` (`--jq '.jobs[] | .name as $j | .steps[] | [$j, .name, .conclusion] | @tsv'`),
  and default-branch history from
  `gh-read 'repos/{owner}/{repo}/actions/runs?branch=<default>&per_page=20' --jq '.workflow_runs[] | [.id, .name, .event, .conclusion] | @tsv' --raw`.
- **Gating:** is the test job a required check? This audit reads workflows only;
  cite `pipeline-gates-audit` for branch rules, or mark gating `UNVERIFIED`.

Distinguish configured from observed behaviour. A zero-test pass, wrong-target run,
or masked failure here is a `green-not-meaningful` witness on its own; this phase
also decides whether a Phase 7 "caught" failure would reach CI as red.

## Phase 4 — Assess along four axes

Treat these as independent. A single test carries one label from each.

**Scope** — unit, integration, contract, end-to-end, smoke. Is the distribution sane
for this system, or is there a missing middle?

**Purpose** — regression, acceptance, characterization. Using the fix commits listed
above, report what fraction shipped with a corresponding test change
(`git-read show --name-only --format= <sha>`). This measures the team's actual
habit, not its stated policy.

**Style** — behavioral versus implementation-coupled; example-based versus
table-driven versus property-based; snapshot and approval usage. Broad assertions
(`toBeTruthy`, `assertNotNull` alone), mock-invocation assertions, and tests without
an explicit assertion are **cues to investigate, not defects**. Report one as a
finding only when you can name a concrete wrong implementation the test would still
pass.

**Non-functional** — performance, concurrency and races, security and authorization,
resilience, migration and upgrade, compatibility, accessibility, fuzzing, mutation
testing. Report which are present; for each absent one, does this system need it?

## Phase 5 — Probe depth on a sample

Take the three riskiest modules from Phase 1. For each, report which are covered:
empty / zero / one / many; boundary values and one step either side; null or absent
versus explicitly empty; invalid input rejected with the correct error; error paths
actually executed (timeouts, retries, partial failure, the catch block); for
authorization, that user A cannot access user B's resources. Quote covering tests
minimally (contract redaction rule); name the missing ones.

## Phase 6 — Testability of the production code

Tests are downstream of design. Are dependencies injected or reached through
singletons and statics? Are time, randomness, UUIDs, and environment variables
injected or read directly? Is decision logic separated from I/O? Long arrange blocks
indicate coupling in the source, not laziness in the tests. If the architecture is
charging the team heavily for tests, say so — it changes the recommendation.

## Phase 7 — The falsification check

This step outweighs every metric above. Take **one mutation in each of the three
riskiest modules** from the Phase 1 ranking; if fewer than three modules are eligible
(non-trivial code on a risky path), take all of them. Choose deterministically:

- **Function:** within the module, the largest non-trivial function on the risky path
  (by line count from Read). Name it with `path:line`.
- **Mutation:** the first plausible one in this order — invert a comparison, drop a
  guard clause, change a boundary from `<` to `<=`, return early, swap two arguments.

Determine by reading whether an existing test would fail. **Caught** means both: a
named test's assertion would fail under the mutation, **and** Phase 3 shows CI runs
that test and propagates its failure as a red result. Report for each: module rank,
function, mutation, caught (yes / no / uncertain), which test, the Phase 3 evidence
for propagation, and whether the failure would be diagnosable from its name and
message. "No" needs the tests you read for that module listed; if you could not rule
out another test exercising the path, answer "uncertain".

An existing mutation-testing report is **supplementary** only: record its revision,
scope, exclusions, and outcomes (killed, survived, timeout, no coverage).

## Output

Follow the contract's report structure and report file. Audit name: `test-audit`.
Audit-specific content:

- **Headline** — when this suite is green, what do we know, and what does it not
  establish? Say if the triage budget cut the run short.
- **Scorecard dimensions** — risk coverage, green-run integrity, scope balance,
  assertion quality, edge-case depth, determinism and isolation, failure
  diagnosability, maintainability, non-functional coverage, testability of source,
  process discipline.
- **Ceiling signals** — you own `green-not-meaningful`. Apply the contract's decision
  rule; it has two OR-branches and one proven branch triggers it:
  - **Masking branch (Phase 3):** `TRIGGERED` on a cited witness that the default CI
    test run can pass having run zero tests, against something other than the change
    under test, or with test failures masked. Cleared only when every CI definition is
    enumerated untruncated and the test invocation's selection, target, and failure
    propagation are each cited.
  - **Mutation branch (Phase 7):** `TRIGGERED` when at least two of the mutations are
    "no" (not caught). Cleared only when the Phase 1 candidate list is complete and
    every assessed mutation is "yes" — three modules, or all eligible modules when
    fewer than three exist.
  - `CLEARED` needs both branches cleared. Otherwise `UNKNOWN`, naming the gap
    ("uncertain" mutations, unreadable run history, truncated inventory).
  - A triage or narrowed run that assessed fewer than three modules (with three or
    more eligible) reports `UNKNOWN — scope` unless a witness triggers it; a run
    that never reached Phases 3 and 7 reports `UNKNOWN — not assessed`.
- **Findings** — the concrete failure each gap would permit to reach production.
- **What is already good** — call out property-based or characterization tests,
  in-memory fakes, contract tests, mutation testing, diff-coverage gates.
- **Agentic readiness note** — could an AI agent rely on this suite to tell it that
  its change broke something, fast enough and legibly enough to self-correct?
