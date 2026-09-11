---
description: Audit this repository's code ownership, activity, and responsiveness and report evidence-backed findings on bus factor and who would catch a bad change
argument-hint: "[full|triage|<path>]"
disable-model-invocation: true
allowed-tools: Read, Glob, Write(~/repo-audits/**), Bash(git-read:*), Bash(gh-read:*), Bash(ls:*)
---

# Ownership and Activity Audit

You are auditing who owns this repository and how alive it is. Your goal is to
answer one question with evidence: **is anyone home — who owns this code, would they
notice and respond to a bad change, and does the knowledge live in more than one
head?**

Read the contract shipped with this plugin (`${CLAUDE_PLUGIN_ROOT}/contract.md`) (v2.1) now; its identity, tools, evidence,
safety, redaction, and reporting rules apply throughout. Modify nothing; do not
comment, assign, label, close, or fetch. git goes through `git-read`, GitHub through
`gh-read`; never pipe their output. The only write is the report file.

## Scope

Requested scope: `$ARGUMENTS`

- empty or `full` — audit the whole repository, all phases.
- `triage` — run Phases 0, 1, 2, 3 and 7 only, within the contract's triage budget,
  and produce a condensed report. Dimensions that depend on skipped phases are
  `NOT ASSESSED — triage`.
- anything else — treat it as a path; narrow every phase to history, owners, and
  reviews for the code under it, plus the governing root and shared configuration.

## Pre-gathered facts

A starting point — verify anything you build a finding on. Read results literally per
the contract (`ERROR:`, `(no matches)`, `(showing L of N lines)`); a `gh-read` list
with no output returned an empty list; a `gh-read` `gh: ...` line is a failed call
(`UNVERIFIED`; a 404 is ambiguous). git runs on `origin/HEAD`, the **local**
default-branch ref, which may be stale; Phase 0 settles the audited SHA.

Identity, default branch, archived, issues setting:
!`gh-read 'repos/{owner}/{repo}' --jq '"\(.full_name) default=\(.default_branch) archived=\(.archived) has_issues=\(.has_issues) created=\(.created_at[:10]) pushed=\(.pushed_at[:10])"' --raw`

Checkout HEAD, local default ref and its SHA, shallow status, oldest available commit:
!`git-read rev-parse HEAD`
!`git-read rev-parse --abbrev-ref origin/HEAD`
!`git-read rev-parse origin/HEAD`
!`git-read rev-parse --is-shallow-repository`
!`git-read log --max-parents=0 --format='%h %ad root-or-shallow-boundary' --date=short origin/HEAD --limit 5`

Last non-merge commit; non-merge commits per month over 12 months (ordered by count);
authors over 12 months and 90 days (non-merge, working-tree mailmap applied):
!`git-read log -1 --no-merges --format='%h %ad %aN' --date=short origin/HEAD`
!`git-read shortlog -sn --no-merges --since='12 months ago' --group=format:%ad --date=format:%Y-%m origin/HEAD`
!`git-read shortlog -sn --no-merges --since='12 months ago' origin/HEAD --limit 20`
!`git-read shortlog -sn --no-merges --since='90 days ago' origin/HEAD --limit 15`

Mailmap presence and commits with co-author trailers, last 12 months:
!`git-read ls-files --match '^\.mailmap$'`
!`git-read log --since='12 months ago' --format='%(trailers:key=Co-authored-by,valueonly,separator=%x2C)' origin/HEAD --match . --count`

Candidate risky directories (inventory to judge, not a finding):
!`git-read ls-tree -d -r --name-only origin/HEAD --match '(^|/)(\.github|workflows|terraform|infra|infrastructure|deploy|deployment|helm|charts|k8s|kubernetes|auth|security|\.claude|agents|hooks|pipelines|scripts|migrations)$' --limit 40`

Releases and tags:
!`gh-read 'repos/{owner}/{repo}/releases?per_page=10' --jq '.[] | "\(.published_at // .created_at | .[:10]) \(.tag_name)\(if .draft then " draft" elif .prerelease then " pre" else "" end)"' --raw`
!`git-read for-each-ref --sort=-creatordate --count=10 --format='%(creatordate:short) %(refname:short)' refs/tags`

CODEOWNERS files at the local default ref, and API validation errors (default branch):
!`git-read ls-tree --name-only origin/HEAD .github/CODEOWNERS CODEOWNERS docs/CODEOWNERS`
!`gh-read 'repos/{owner}/{repo}/codeowners/errors' --jq '"errors: \(.errors | length)", (.errors[:20][] | "\(.path):\(.line) \(.kind)")' --raw`

Open issue and PR backlog (search totals are exact; oldest item shown):
!`gh-read 'search/issues?q=repo:{owner}/{repo}+is:issue+is:open&sort=created&order=asc&per_page=1' --jq '"open issues: \(.total_count); oldest: \(.items[0].created_at // "n/a")"' --raw`
!`gh-read 'search/issues?q=repo:{owner}/{repo}+is:pr+is:open+draft:false&sort=created&order=asc&per_page=1' --jq '"open non-draft PRs: \(.total_count); oldest: \(.items[0].created_at // "n/a")"' --raw`
!`gh-read 'search/issues?q=repo:{owner}/{repo}+is:pr+is:open+draft:false+review:none' --jq '"open non-draft PRs with no review: \(.total_count)"' --raw`

Remote-tracking branches (local refs, not fetched), total and the 15 oldest:
!`git-read for-each-ref --format='%(refname:short)' refs/remotes --count`
!`git-read for-each-ref --sort=committerdate --format='%(committerdate:short) %(refname:short)' refs/remotes --limit 15`

Operational ownership documents and external-tracker references (path:line:match only):
!`git-read ls-files --match '^(\.github/)?(README|SECURITY|SUPPORT|CONTRIBUTING)\.md$|^(docs/)?runbooks/' --icase --limit 20`
!`git-read grep -noIiE 'jira|atlassian\.net|linear\.app|youtrack|servicenow|dev\.azure\.com' -- 'README*' 'CONTRIBUTING*' '.github/*.md' '.github/ISSUE_TEMPLATE/*' --limit 15`

## Ground rules

- **Audit the API default-branch tip.** Phase 0 fixes the audited SHA; later phases use it.
- **History completeness.** Only a **shallow clone** truncates history: if shallow,
  windows past the boundary are `UNVERIFIED — truncated history` (name the deepening
  fetch; do not run it). A sparse checkout or a young repo is not truncated — a young
  repo just has short windows. Never infer a quiet year from missing history.
- **Attribution.** Count non-merge commits by `%aN`; count merges separately.
  `git-read check-mailmap '<Name> <email>'` uses the **working-tree** `.mailmap`, not
  the audited SHA's — state that limitation. Identity merges beyond it need evidence
  (same login, noreply address, a doc). `Co-authored-by` trailers count toward
  **distinct contributors** (bus factor), never commit share. Exclude bots (`[bot]`,
  `github-actions`, `dependabot`, `renovate`) and state how many commits that removed.
- **Exclusions.** State churn exclusions (at least lockfiles, `vendor/`,
  `node_modules/`, generated code, bulk formatting commits); keep them identical.
- **Tallies.** The wrappers list and count but do not group or sort. Group or rank
  listed rows yourself only when the list is complete; over a truncated list, `UNVERIFIED`.
- Commit count measures activity, not knowledge. A one-person repo is a fact, not a
  failure by itself; the finding is whether the risk is acknowledged and mitigated.

## Phase 0 — Identity and audited SHA (before interpreting counts)

1. Target identity per the contract; default branch `<b>` from the repo `gh-read`.
2. API tip: `gh-read 'repos/{owner}/{repo}/branches/<b>' --jq '.commit.sha' --raw`.
   Local tip: `git-read rev-parse origin/<b>`. If they match, that SHA is audited. If
   they differ or the local ref is missing, local history is a **stale snapshot**:
   the API tip is the audited SHA, history queries are labelled "stale snapshot at
   `<local sha>`", and current-state comparisons (latest activity, owners' recent
   commits) are `UNVERIFIED`.
3. Front-matter `commit:` is the **audited SHA**; note the checkout HEAD separately
   (Headline or Execution log). Record shallow status, oldest available commit, and
   the span each window (90/180/365 days, 24 months) actually covers.

## Phase 1 — Knowledge concentration on risky code

Pick 5-10 risky directories — CI/CD, IaC, auth and credential handling, deploy
config, agent and automation definitions, anything production-privileged. Select by
risk, not churn; include stable risky paths. For **each** directory, over 180 days:

- Human authors: `git-read log --no-merges --since='180 days ago' --format='%aN'
  <ref> -- <dir> --exclude '\[bot\]|github-actions|dependabot|renovate'`, tallied
  over the listed rows (truncated → `UNVERIFIED`). Add co-authors from
  `--format='%(trailers:key=Co-authored-by,valueonly)'` on the same path.
- Top author's share, with the denominator stated (human, non-merge, non-excluded
  commits touching that directory). Extend to 365 days if the window has fewer than
  five commits, and say so; for a directory with none, name the last author and date
  (`git-read log -1 --format='%h %ad %aN' --date=short <ref> -- <dir>`).

## Phase 2 — Activity

Cadence from monthly counts (steady, bursty, decaying, gaps) within Phase 0's span;
last commit; active humans in 90 days; release cadence, or how changes ship otherwise.

## Phase 3 — CODEOWNERS

- Read it at the audited ref: `git-read show <sha>:.github/CODEOWNERS`, then
  `<sha>:CODEOWNERS`, then `<sha>:docs/CODEOWNERS` (GitHub uses the first found).
  Validate at the same ref: `gh-read 'repos/{owner}/{repo}/codeowners/errors?ref=<sha>'`.
  Distinguish: file absent; validation errors; an API error (`UNVERIFIED`).
- Coverage: which Phase 1 directories match a rule, and which fall through to a
  catch-all or nothing. Last match wins — check ordering.
- Owner eligibility: `gh-read 'repos/{owner}/{repo}/collaborators' --paginate
  --jq '.[] | "\(.login) \(.role_name)"' --raw` where readable. Org team endpoints are
  not allow-listed, and collaborators are not team membership: a **team** owner's
  membership and activity are `UNVERIFIED — endpoint not allow-listed`.
- Enforcement, lightly: rulesets (`gh-read 'repos/{owner}/{repo}/rules/branches/<b>'
  --paginate`, then `rulesets/<id>`) **or** classic protection
  (`branches/<b>/protection`; a 404 is ambiguous). Classic fields: `enforce_admins.enabled`;
  under `required_pull_request_reviews`: `require_code_owner_reviews`,
  `required_approving_review_count`, `bypass_pull_request_allowances`. A ruleset
  without `bypass_actors` is `UNVERIFIED`, not "no bypass". Depth belongs to
  `pipeline-gates-audit`; unenforced CODEOWNERS is a routing hint, not a control.

## Phase 4 — Responsiveness

- **Tracker first.** From `has_issues`, the tracker-reference pre-gather, and issue
  templates, establish where work is tracked. If work lives in an external or
  mirrored tracker, issue responsiveness is `NOT ASSESSED — external tracker`, citing
  the evidence (`path:line` or `has_issues=false`). Until established, an empty list
  reads "zero GitHub issues observed; tracker applicability unverified".
- PRs: `gh-read 'search/issues?q=repo:{owner}/{repo}+is:pr+is:merged+-author:app/dependabot+-author:app/renovate&sort=updated&per_page=30'`
  (last 30 merged) plus open non-draft PRs; drop `user.type == "Bot"`. Time to first
  non-author human response from `pulls/<n>/reviews` and `issues/<n>/comments`; a PR
  with no response yet is reported with its age, not dropped. State any cap.
- Issues (where applicable): first non-author response on up to 30 recent issues;
  backlog size and age from the pre-gathers.
- Abandoned branches: remote-tracking refs idle 90 days, as candidates only (local
  refs may be stale; squash-merged branches still show unique commits).

## Phase 5 — Operational ownership

Who would a stranger contact when this breaks? Check README contacts, SECURITY.md,
SUPPORT/CONTRIBUTING, escalation references, and runbooks; record whether the named
people or channels appear in recent history. Quote roles or channels, not handles.

## Phase 6 — Dominant author inactive

List file changes for 24 months: `git-read log --no-merges --since='24 months ago'
--format= --name-only <ref> --exclude '(^|/)(AGENTS|CLAUDE)\.md$|(^|/)(vendor|node_modules)/|\.lock$|package-lock\.json$'`.
Complete list: tally the 20 most-changed files yourself; truncated: the ranking is
`UNVERIFIED`, use the Phase 1 risky files only. Per file, the dominant author
(`git-read shortlog -sn --no-merges <ref> -- <file>`) and their last repo commit.
Flag files whose dominant author has no commit in 180 days and no substantive later
change by others; check their reviews, docs, and CODEOWNERS entries. Say
**departed** only with affirmative evidence; a second account is a common cause.

## Phase 7 — The falsification check

This outweighs every count above. Deep-dive the three riskiest Phase 1 directories:

1. **Population:** `gh-read 'search/issues?q=repo:{owner}/{repo}+is:pr+is:merged+base:<b>+merged:>=<date-90d>&per_page=100' --paginate --jq '.items[] | select(.user.type != "Bot" and (.draft | not)) | "\(.number) \(.user.login) \(.closed_at[:10])"' --raw`
   (extend to 365 days if empty, and say so). Keep PRs whose `pulls/<n>/files
   --paginate` include the directory. Report the denominator and exclusions (bot,
   draft); a search `total_count` over 1000 is a truncated population.
2. For each eligible PR, `pulls/<n>/reviews` and `pulls/<n>/comments`. A review
   counts only if its `submitted_at` is inside the window and its author is not the PR
   author. **Coverage evidence** is such a review that engages the directory: review
   comments on its paths, or an approval on a PR touching only that area. An approval
   on a large mixed PR is not engagement. A possibly-same-human second account is
   uncertainty about independence, not a second reviewer.

Verdict per directory, with named reviewer, PR numbers, and dates: `covered`;
`nominal only` (approvals or a named owner, no engaged independent review); `nobody`
(eligible PRs, only self-merge or no review); `insufficient evidence` (no eligible
PRs even at 365 days — name the owner of record).

## Output

Follow the contract's report structure and report file. Audit name:
`ownership-activity-audit`. Front matter `commit:` = the Phase 0 audited SHA.

- **Headline** — is anyone home? Who owns the risky code, would they notice a bad
  change, how many heads hold the knowledge. State the audited ref and SHA, whether
  local history is a stale snapshot, the checkout HEAD if different, and any
  shallow-history truncation.
- **Scorecard dimensions** — knowledge distribution, risky-path ownership, activity
  and cadence, CODEOWNERS accuracy, owner presence, PR responsiveness, issue
  responsiveness, branch and backlog hygiene, operational contactability.
- **Ceiling signals** — you own `orphaned-risk`. For **every** Phase 1 risky
  directory, answer two three-state tests (true / false / unknown):
  - **Owner inactive** — no commit **and** no review touching that directory by any
    of its owners in the last 180 days. Owners are its CODEOWNERS entries; with no
    matching rule, its authors of record. False needs a cited owner commit
    (Phase 1 rows) or a cited owner review with `submitted_at` in the window. True
    needs the owner set fully known (no `UNVERIFIED` team) and complete, untruncated
    commit and review evidence. Otherwise unknown.
  - **Bus factor one** — exactly one distinct human author (co-authors included) in
    the window **and** no other reviewer covering that directory. False needs two or
    more distinct authors, or a second person's review engaging the directory. True
    needs one author on complete history plus a review search showing no other
    reviewer. Otherwise unknown.

  Every Phase 1 directory gets this light test from its author rows and any review
  evidence at hand; the three Phase 7 directories get deep review evidence. So a
  non-Phase-7 directory with one author and no review search is unknown on bus
  factor, not true.
  **TRIGGERED** if either test is true for any risky directory — name it and the
  witness. **CLEARED** only if both are false for every Phase 1 directory, with the
  enumeration cited. Otherwise **UNKNOWN**, naming the directories and the gap
  (stale snapshot, shallow history, team owner, truncated list).
- **Findings** — the failure each gap permits (unreviewed change, unanswered report);
  a risky directory with one author and no second reviewer outranks all others.
- **What is already good** — enforced accurate CODEOWNERS, an actively reviewing
  second maintainer, documented escalation, prompt triage, a regular release rhythm.
- **Agentic readiness note** — if an AI agent opened PRs here, would an owner see
  them, spot a wrong change, and respond before they go stale or merge unexamined?
- **Execution log** — audited SHA vs checkout HEAD, and every `UNVERIFIED` call.
