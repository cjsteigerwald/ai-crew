---
description: Audit this repository's secret, dependency, code-scanning, and supply-chain controls and report evidence-backed findings on what would catch a security defect before it ships
argument-hint: "[full|triage|<path>]"
disable-model-invocation: true
allowed-tools: Read, Glob, Write(~/repo-audits/**), Bash(git-read:*), Bash(gh-read:*), Bash(ls:*)
---

# Security and Supply Chain Audit

Answer one question with evidence: **if an agent or a human introduced a secret, a
vulnerable dependency, or an injection flaw, what would catch it before it shipped —
and what already has?**

Read the contract shipped with this plugin (`${CLAUDE_PLUGIN_ROOT}/contract.md`) now; its rules apply throughout. This audit is
static: change nothing, dismiss or comment on nothing. Git reads go through `git-read`,
GitHub reads through `gh-read`; what they cannot answer is `UNVERIFIED`. The only
write is the report file.

## Scope

Requested scope: `$ARGUMENTS` — empty or `full`: all phases. `triage`: Phases 1-4 and 9
within the contract's budget; other dimensions `NOT ASSESSED — triage`. Anything else is
a path: narrow Phases 6-7 to it, its manifests, and root configuration; repo-wide
controls (secret scanning, alerts, SECURITY.md) still apply.

## Pre-gathered facts

Verify anything you build a finding on. `ERROR:` = `UNVERIFIED` (a 403/404 is never
"off" or "no alerts"); `(no matches)` = ran, found nothing; `(showing L of N lines)` =
incomplete. `--paginate` prints one jq result per page.

Repository (full name, visibility, fork, default branch), commit, security settings
(`null`/missing keys usually mean no admin read), security updates, private reporting:
!`gh-read 'repos/{owner}/{repo}' --jq '[.full_name, .visibility, (.fork | tostring), .default_branch] | join(" ")' --raw`
!`git-read rev-parse HEAD`
!`gh-read 'repos/{owner}/{repo}' --jq '.security_and_analysis'`
!`gh-read 'repos/{owner}/{repo}/automated-security-fixes' --jq '.'`
!`gh-read 'repos/{owner}/{repo}/private-vulnerability-reporting' --jq '.'`

Secret-scanning alerts, open (number, type, opened, bypassed, validity, publicly leaked)
then resolved (number, type, resolution, opened, resolved, bypassed, has comment):
!`gh-read 'repos/{owner}/{repo}/secret-scanning/alerts?state=open&per_page=100' --paginate --jq '.[] | [.number, .secret_type, .created_at[:10], (.push_protection_bypassed // false), (.validity // "-"), (.publicly_leaked // "-")] | map(tostring) | join(" ")' --raw`
!`gh-read 'repos/{owner}/{repo}/secret-scanning/alerts?state=resolved&per_page=100' --paginate --jq '.[] | [.number, .secret_type, .resolution, .created_at[:10], ((.resolved_at // "-")[:10]), (.push_protection_bypassed // false), ((.resolution_comment // "") | test("\\S"))] | map(tostring) | join(" ")' --raw`

Open Dependabot alerts (number, severity, opened, ecosystem, package, manifest, advisory),
then open code-scanning alerts (number, severity, opened, tool, rule, path):
!`gh-read 'repos/{owner}/{repo}/dependabot/alerts?state=open&per_page=100' --paginate --jq '.[] | [.number, .security_advisory.severity, .created_at[:10], .dependency.package.ecosystem, .dependency.package.name, .dependency.manifest_path, .security_advisory.ghsa_id] | map(tostring) | join(" ")' --raw`
!`gh-read 'repos/{owner}/{repo}/code-scanning/alerts?state=open&per_page=100' --paginate --jq '.[] | [.number, (.rule.security_severity_level // .rule.severity), .created_at[:10], .tool.name, .rule.id, .most_recent_instance.location.path] | map(tostring) | join(" ")' --raw`

Secret-shaped paths — tracked, deleted but in history, holding a provider credential
shape (paths only; candidates, not findings):
!`git-read ls-files --match '(^|/)\.env($|\.)|\.(pem|key|p12|pfx|jks|keystore|ppk)$|(^|/)id_(rsa|dsa|ecdsa|ed25519)$|[Cc]redentials|[Ss]ecrets?\.(json|ya?ml|txt)$|\.tfstate' --limit 60`
!`git-read log --all --diff-filter=D --name-only --format= --match '(^|/)\.env($|\.)|\.(pem|key|p12|pfx|jks|keystore|ppk)$|(^|/)id_(rsa|dsa|ecdsa|ed25519)$|[Cc]redentials|[Ss]ecrets?\.(json|ya?ml|txt)$|\.tfstate' --limit 40`
!`git-read grep -lIE 'AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{40,}|xox[abprs]-[A-Za-z0-9-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|AccountKey=[A-Za-z0-9+/]{20}|sk_live_[A-Za-z0-9]{20}|AIza[0-9A-Za-z_-]{35}' --exclude '(^|/)(AGENTS|CLAUDE)\.md$' --limit 40`

Scanner, update-bot, pre-commit, registry, and policy configuration; manifests and lockfiles (paths only):
!`git-read ls-files --match '(^|/)(\.gitleaks\.toml|\.gitleaksignore|\.trufflehog[^/]*|\.secrets\.baseline|\.pre-commit-config\.yaml|dependabot\.ya?ml|renovate\.json5?|\.renovaterc(\.json)?|\.npmrc|\.yarnrc(\.yml)?|pip\.conf|\.pypirc|[Nn]u[Gg]et\.[Cc]onfig|settings\.xml|\.checkov\.ya?ml|\.tfsec[^/]*|\.trivyignore|trivy\.ya?ml|\.semgrep[^/]*|sonar-project\.properties|\.snyk|[^/]*\.sentinel|sentinel\.hcl|[^/]*\.rego|SECURITY\.md)$' --limit 60`
!`git-read ls-files --match '(^|/)(package\.json|package-lock\.json|npm-shrinkwrap\.json|yarn\.lock|pnpm-lock\.yaml|pnpm-workspace\.yaml|bun\.lockb?|pyproject\.toml|poetry\.lock|uv\.lock|Pipfile(\.lock)?|requirements[^/]*\.txt|go\.(mod|sum)|Cargo\.(toml|lock)|Gemfile(\.lock)?|composer\.(json|lock)|[^/]+\.csproj|packages\.lock\.json|pom\.xml|build\.gradle(\.kts)?|gradle\.lockfile|\.terraform\.lock\.hcl)$' --limit 80`

Security tooling and install commands in CI and hooks (path:line + tool name only):
!`git-read grep -noIiE '(gitleaks|trufflehog|detect-secrets|trivy|grype|snyk|codeql|semgrep|checkov|tfsec|kube-linter|kubescape|scorecard|dependency-review|attest-build-provenance|cosign|syft|cyclonedx|npm ci|--frozen-lockfile|--immutable|--require-hashes|uv sync --locked|poetry check --lock|poetry sync|go mod verify)' -- .github .gitlab-ci.yml .circleci 'azure-pipelines*' Jenkinsfile .pre-commit-config.yaml --exclude '(^|/)(AGENTS|CLAUDE)\.md:' --limit 80`

Open dependency-bot PR backlog, paginated to exhaustion (total, then number, opened, title):
!`gh-read 'search/issues?q=repo:{owner}/{repo}+is:pr+is:open+author:app/dependabot&sort=created&order=asc&per_page=100' --paginate --jq '"total=\(.total_count) incomplete=\(.incomplete_results)", (.items[] | [.number, .created_at[:10], .title] | map(tostring) | join(" "))' --raw`
!`gh-read 'search/issues?q=repo:{owner}/{repo}+is:pr+is:open+author:app/renovate&sort=created&order=asc&per_page=100' --paginate --jq '"total=\(.total_count) incomplete=\(.incomplete_results)", (.items[] | [.number, .created_at[:10], .title] | map(tostring) | join(" "))' --raw`

Container FROM/USER lines, digest-pinned and `:latest` markers (no image names or registry hosts):
!`git-read grep -noE '^[[:space:]]*(FROM|USER)[[:space:]]|@sha256:[0-9a-f]{64}|:latest\b|USER[[:space:]]+(root|0)\b' -- '*Dockerfile*' '*Containerfile*' --limit 60`

Kubernetes runtime posture (key names, and literal booleans only):
!`git-read grep -noE '(allowPrivilegeEscalation|privileged|runAsNonRoot|readOnlyRootFilesystem|hostNetwork|automountServiceAccountToken):[[:space:]]*(true|false)|runAsUser|hostPath|capabilities|seccompProfile' -- '*.yaml' '*.yml' '*.tpl' --exclude '(^|/)(AGENTS|CLAUDE)\.md:' --limit 60`

## Ground rules

- **No secret value enters tool output.** Emit paths, line numbers, key names, secret
  types. Never `Read` a suspected secret file, in full or in part. `git-read`'s masking
  is a backstop, not permission.
- **Key-name inspection** of a candidate file — line-start-anchored, so the match ends
  at `:`/`=` and cannot reach the value:
  `git-read grep -noiE '^[[:space:]]*"?[A-Za-z0-9_.-]*(KEY|SECRET|TOKEN|PASSWORD|PASSWD)[A-Za-z0-9_.-]*"?[[:space:]]*[:=]' -- <file>`.
  Report `path:line`, key name, secret type. Formats it cannot handle (single-line
  JSON, XML, `export KEY=`, PEM, `.tfstate`, keystores) stay **unresolved**.
- **Free text is not evidence to print**: project booleans or lengths for comments and
  PR bodies. PR titles only for known bot authors (Dependabot, Renovate, a named
  self-hosted bot).
- **Registry configs** (`.npmrc`, `.yarnrc*`, `pip.conf`, `.pypirc`, `nuget.config`,
  `settings.xml`): key names only, reported as opaque facts — "scoped registry for
  `@org`: yes/no; public fallback: yes/no/unknown" — never a host, URL, or auth value.
- **Populations are complete or labelled.** Paginate to exhaustion. A cap, a
  `(showing …)` line, `incomplete_results: true`, or >1000 search results makes a
  population incomplete: it can supply a witness, never `CLEARED`.
- No scanner is pre-approved (contract local-execution rule); recommend one where it
  would settle a question. CI workflow security and required-check data belong to
  `pipeline-gates-audit` — cite its report under `~/repo-audits/`, else `UNVERIFIED`.

## Phase 1 — Map what is worth attacking (do this FIRST)

Locate by path: deployables (images, packages, functions, IaC), credentials code and
pipeline hold (by variable name), where untrusted input enters, and where authn/authz is
decided. Weight every later phase by this map.

## Phase 2 — Secrets

Keep four facts apart; an alert can show several, and none alone is prevention:
**detector fired** (an alert exists; secret scanning covers history when enabled),
**push blocked** (a never-bypassed block leaves no alert — `UNVERIFIED` here),
**bypassed** (`push_protection_bypassed: true` — prevention existed and was overridden),
**post-merge detection / remediation** (`revoked` is remediation; `false_positive`,
`used_in_tests`, `wont_fix` are judgments — count those without a comment).

- **Push protection:** repo enablement, inherited org/enterprise policy (`UNVERIFIED` if
  unreadable), user-level (never assumable). Count bypasses over open and resolved
  alerts; say "no bypasses observed in this evidence", not "no bypasses".
- **CI/pre-commit scanners** (gitleaks, trufflehog, detect-secrets): PRs or local only,
  full history (`fetch-depth: 0`, `--log-opts`) or diff, fails on a finding, required,
  allowlist narrow or whole-path. Read workflow and scanner configs, never `.env*`.
- **Candidates:** list candidate files with
  `git-read grep -lIiE '(KEY|SECRET|TOKEN|PASSWORD|PASSWD)[A-Za-z0-9_.-]*"?[[:space:]]*[:=]' -- <paths>`,
  then key-name inspection per file. For a deleted path, find the deleting commit
  (`git-read log --all --diff-filter=D --format=%h -- <path>`) and inspect
  `git-read grep -noiE '<key pattern>' <sha>^ -- <path>`. Key names yield
  **candidates only**: they cannot show a credential is live or a template.

### `secret-exposure` decision rule — OR-branches: either proven branch triggers; `CLEARED` needs both cleared

- **Exposure branch** — a live-looking credential in tracked files or history.
  `TRIGGERED` needs **detector evidence**: an open secret-scanning alert (cite number,
  type, `validity`), or a CI scanner result on the default branch or history naming a
  finding. Report each as "potential credential exposure; rotation/validity
  unverified". `CLEARED` needs a detector that covers history (secret scanning shown
  enabled, or a full-history CI scan with visible results), the open-alert list read
  completely with none open, and every secret-shaped path either resolved by
  key-name/type evidence as non-credential or within the detector's coverage. No
  detector coverage, an unreadable alerts endpoint, or an unresolved candidate →
  `UNKNOWN`, naming the gap.
- **Prevention branch** — neither push protection nor a blocking PR secret scan.
  `CLEARED` when push protection reads `enabled`, or a PR secret scan is shown to fail
  on findings and be required. `TRIGGERED` when push protection reads `disabled` **and**
  the complete CI enumeration shows no PR secret scan, or only a non-blocking one.
  Missing `security_and_analysis`, or unknown required-check status, → `UNKNOWN`.

## Phase 3 — Dependencies

- **Lock inputs per deployable** and its CI install command: `npm ci`,
  `--frozen-lockfile`/`--immutable`, `pip install --require-hashes`, `uv sync --locked`,
  `go mod verify`, `poetry install` against a committed `poetry.lock` with
  `poetry check --lock` (or `poetry sync`) in CI. A bare `requirements.txt` locks only
  if fully pinned (hashed to be tamper-evident). Include Terraform `version` pins and
  `.terraform.lock.hcl`.
- **Update mechanism coverage:** ecosystems and directories configured versus manifests
  that exist; the actual bot identity (a self-hosted Renovate is named in its config).
- **Does the flow work?** Dated cohort, paginated to exhaustion:
  `gh-read 'search/issues?q=repo:{owner}/{repo}+is:pr+author:app/dependabot+created:>=<YYYY-MM-DD 180 days ago>&per_page=100' --paginate --jq '"total=\(.total_count) incomplete=\(.incomplete_results)", (.items[] | [.number, .state, .created_at[:10], ((.pull_request.merged_at // "-")[:10]), .title] | map(tostring) | join(" "))' --raw`
  (per bot). Count merged, closed-unmerged (superseded separately), open. Zero PRs may
  mean no bot, a broken bot, or nothing to update — state which evidence decides.
- **Alerts:** security updates enabled is not proof a fix PR exists — correlate each open
  critical/high alert with a bot PR naming the package. Critical/high open over 30 days
  is a finding (advisory; it does not decide the predicate).
- **Dependency review** on PRs: `fail-on-severity`, license config, required or not.
- **Package identity:** `git-read log -p --since=<date> --match '^\+' -- <manifest>`
  (never registry configs or `.env*`); look for typosquats and low-provenance packages.
- **Dependency confusion** by key name only (`registry`, `@scope:registry`,
  `extra-index-url`, `packageSourceMapping`, `mirrorOf`). **License policy** config.

### `vuln-intake-unmanaged` decision rule — OR-branches: either proven branch triggers; `CLEARED` needs both cleared

- **No update mechanism** — `TRIGGERED` when the complete config listing has no
  Dependabot/Renovate config covering the repo's ecosystems, no other updater is found
  in CI, and `automated-security-fixes` reads disabled. `CLEARED` when a config covers
  every ecosystem with manifests, or security updates read enabled with alerts on.
  An unreadable endpoint with no config → `UNKNOWN`.
- **Untriaged critical/high** — `TRIGGERED` by one witness: an open (so not dismissed)
  critical/high Dependabot or code-scanning alert opened more than 90 days ago with no
  linked fix PR (search the bot's PRs, and PRs referencing the alert number). `CLEARED`
  needs both alert lists read completely (no error, pagination exhausted) with no such
  alert. Either list unreadable or disabled → that half is `UNKNOWN`, and so is the
  branch unless the other list supplies a witness.

## Phase 4 — Code scanning

- CodeQL / Semgrep / SonarQube / Snyk Code: languages covered versus present, runs on
  PRs, required or advisory. Open alerts by severity and age feed the predicate above.
- Dismissed alerts, text never printed:
  `gh-read 'repos/{owner}/{repo}/code-scanning/alerts?state=dismissed&per_page=100' --paginate --jq '.[] | [.number, .rule.id, .dismissed_reason, ((.dismissed_comment // "") | test("\\S")), .dismissed_at[:10]] | map(tostring) | join(" ")' --raw`.
  Count "won't fix" and "false positive" dismissals without a comment. Fixed alerts
  (`state=fixed`) are what already caught something.

## Phase 5 — Supply chain and provenance

- SBOM generation (syft, cyclonedx, `sbom: true`) and where it goes. Signing and
  provenance (`attest-build-provenance`, cosign); recommend (permission prompt only)
  `gh attestation verify oci://<image>@<digest> --repo <owner>/<repo> --signer-workflow <owner>/<repo>/.github/workflows/<file>`;
  `--owner`-only verification proves less (any repo in the org).
- Base images from the FROM pre-gather: digest-pinned (`@sha256:` on that line),
  `:latest`, or tag-or-untagged (untagged is implicit `latest`; resolving it needs the
  image reference, which may name a private registry — leave it unresolved). A
  `FROM <earlier stage>` is not a base.
- **Container user:** a final stage with no `USER` is `UNKNOWN` until the base default
  and deployment overrides are resolved; `USER root`/`0` with no later `USER` and no
  override is a finding. **Runtime posture** per workload (incl. Helm defaults) from key
  names and literal booleans. OpenSSF Scorecard: recommend a run.

## Phase 6 — Application risk surface

Using the Phase 1 map, run per-language searches with
`git-read grep -nIE '<pattern>' -- <paths>` (source code only), then **trace source to
sink** for each sampled hit: is the input attacker-controlled, and what defences sit
between? Classify each as exploitable, guarded, or false positive. A parameterized
query is a false positive only after tracing **every** attacker-controlled contribution
to it — table and column names, `ORDER BY`/`LIMIT`, and concatenated fragments can
still be injected around bound parameters. State search, hit count, sample size and
draw, and verdict per sample. Code a search did not match is never "cleared".

- **Python:** `execute` with f-string/`%`/`.format`/`+`; `objects.raw`; `text(` from
  strings; `shell=True`; `os.system`; `eval`/`exec`. **JS/TS:** `query(` with `${`;
  `child_process.exec`; `eval`/`new Function`; `dangerouslySetInnerHTML`/`innerHTML`/`v-html`.
- **Go:** `db.Query`/`Exec` with `+`/`fmt.Sprintf`; `exec.Command` fed request data.
  **Java:** `executeQuery`/`createStatement` with `+`; `Runtime.exec`. **C#:**
  `ExecuteSqlRaw`/`FromSqlRaw` with `$"`; concatenated `SqlCommand`; `Process.Start`.
- **Databricks/Spark:** `spark.sql(f"`; `%sql` cells with `${` or widget values.
  **Cross-language:** path traversal, SSRF, XXE, unsafe deserialization (`pickle`,
  `yaml.load` without `SafeLoader`, `BinaryFormatter`, `ObjectInputStream`).
- **Authn/authz:** token validation (signature, audience, expiry); do handlers check
  resource ownership or only that the caller is logged in?

## Phase 7 — Infrastructure as code

Which IaC scanner (checkov, trivy config, tfsec, kube-linter, kubescape) runs, where,
and does it block (`soft_fail`, `--exit-code 0`, thresholds)? Outside policy (Sentinel,
OPA) is `UNVERIFIED` if not visible. Sample the riskiest resources (public network,
public or unencrypted storage, wildcard RBAC, privileged containers); attribute each
predicted detection to an enabled rule, or label it a manual finding.

## Phase 8 — Vulnerability reporting

SECURITY.md with a real channel and response time? Private reporting: see pre-gather.

## Phase 9 — Static counterfactual assessment

This outweighs every configuration reading above. For each fixture, predict from
configuration, settings, workflows, and alert history the first control to fire (push
protection / pre-commit / PR check / post-merge alert / nothing), whether it **blocks**
or only **alerts**, the route to production if it gets through, and the assumptions
left unverified. Fixtures: (1) a synthetic credential in a format the enabled detector
recognizes (e.g. a GitHub PAT format; type only, never a value); (2) a concrete
`package@version` with a named GHSA/CVE added to the main deployable's manifest;
(3) a concrete source-to-sink SQL or command injection in a named file from Phase 1.

Reserve "tested" for observed evidence (a bypassed-then-resolved alert, a failed
required check on a real PR, a fixed alert). Never push a probe; recommend one where it
would settle an uncertain prediction.

## Output

Follow the contract's report structure and report file. Audit name:
`security-supply-chain-audit`. Audit-specific content:

- **Headline** — what would catch a secret, a vulnerable dependency, and an injection
  before shipping, and what already slipped through; blocking versus alerting controls.
- **Scorecard dimensions** — secret prevention, secret detection and response,
  dependency hygiene, dependency update flow, code scanning coverage, alert triage
  discipline, supply-chain provenance, container and runtime hardening, IaC scanning,
  application input handling.
- **Ceiling signals** — both owned predicates by the rules above, naming the deciding
  branch and the gap for any `UNKNOWN` branch.
- **Findings** — the insecure change or exposure each gap permits; latent or present.
- **What is already good** — including what already caught something (fixed alerts,
  remediated secrets, failed checks).
- **Agentic readiness note** — would an agent's pasted credential, hallucinated or
  outdated dependency, or injectable query be stopped before merge, or only reported?
