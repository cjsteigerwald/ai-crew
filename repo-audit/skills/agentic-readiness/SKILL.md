---
description: Roll up this repository's audit-suite reports into an evidence-backed verdict on how much autonomy an AI coding agent can safely be given here, plus a Director/VP executive summary
argument-hint: "[<org/repo>] [--in <repo-dir>]"
disable-model-invocation: true
allowed-tools: Read, Glob, Write(~/repo-audits/**), Bash(repo-fetch:*), Bash(git-read:*), Bash(gh-read:*), Bash(ls:*)
---

# Agentic Readiness Verdict

You are combining the repo audit suite's reports into one verdict. Your goal is to
answer one question with evidence: **how much autonomy can an AI coding agent safely
be given in this repository today, for which kinds of task, and what would raise that
ceiling?** You produce two documents: the detailed verdict and a one-page executive
summary for a Director/VP audience.

Read the contract shipped with this plugin (`${CLAUDE_PLUGIN_ROOT}/contract.md`)
now; this skill parses the sections it
defines, above all `## Ceiling signals`. Do not run the audits and do not re-audit
the repository. Where evidence is missing, the answer is `UNKNOWN` — never a guess.
The only writes are this skill's two documents.

## Scope and target

Requested target: `$ARGUMENTS`

- empty — the contract's target-identity rule applied to the current directory.
- `<org/repo>` — that identity, whatever the current directory is.
- `--in <repo-dir>` (used by `/ai-readiness`) — the target checkout. Append `--in
  <repo-dir>` to every wrapper call and ignore the pre-gathered facts below, which
  describe the current directory.

Target HEAD is known only when the checkout you read (the `--in` directory, or the
current directory) resolves to the target identity; otherwise it is `unknown`. The
folder id is `<org>-<repo>`; reports live in `<AUDIT_OUTPUT_ROOT>/<org>-<repo>/<date>/`
— `<AUDIT_OUTPUT_ROOT>` is the resolved `audit_output_root` config key (default
`~/repo-audits`), taken from the Pre-gathered facts below when running standalone.
When dispatched by `/ai-readiness` with `--in`, the caller's instructions already
name the concrete path to write to — use that verbatim instead of re-resolving it.
If `AUDIT_OUTPUT_ROOT` is not `~/repo-audits`, this skill's own `allowed-tools`
`Write(~/repo-audits/**)` line must already have been hand-edited to match, or the
writes below will be denied — Claude Code's permission syntax cannot reference a
config value, so this one step cannot be automated (see the README's Limitations).

## Pre-gathered facts

Current directory identity and HEAD:
!`gh-read 'repos/{owner}/{repo}' --jq '.full_name + " (default: " + .default_branch + ")"' --raw`
!`git-read rev-parse HEAD`

Resolved audit output root for the current directory (ignore this when `--in` is
used — see Scope and target above; take `<AUDIT_OUTPUT_ROOT>` from the
`AUDIT_OUTPUT_ROOT=` line below):
!`repo-fetch . 2>&1`

If that printed `ERROR: …` with no `AUDIT_OUTPUT_ROOT=` line — standalone `--in` run
from a directory that is not itself a repo — run `repo-fetch <repo-dir>` against the
`--in` directory instead; if that also errors, fall back to the documented default
`~/repo-audits`.

Once `<AUDIT_OUTPUT_ROOT>` is known, list audit history yourself — one folder per
repository, one sub-folder per run date — with `ls -1 <AUDIT_OUTPUT_ROOT>/`.

## The suite

| Audit | Owns predicates | Plain-language area (for the summary) |
|---|---|---|
| `pipeline-gates-audit` | `ungated-prod-path`, `gate-bypassable` | Merge and deploy safeguards |
| `test-audit` | `green-not-meaningful` | Automated tests |
| `feedback-loop-audit` | `no-local-signal` | Self-check before submitting |
| `pr-review-audit` | `review-not-a-control` | Human code review |
| `security-supply-chain-audit` | `secret-exposure`, `vuln-intake-unmanaged` | Security and dependencies |
| `change-safety-audit` | `no-rollback` | Recovery from bad releases |
| `context-legibility-audit` | `docs-mislead` | Documentation and clarity |
| `ownership-activity-audit` | `orphaned-risk` | Ownership and coverage |

Predicate definitions live in the contract. Do not reinterpret them.
`context-legibility-audit` ships separately from this plugin; if its skill or
reports are unavailable, mark `docs-mislead` `UNKNOWN — not installed`, not a
failure of this roll-up.

## Phase 1 — Select and qualify one report per audit

Under `<AUDIT_OUTPUT_ROOT>/<org>-<repo>/`, list the dated folders (Glob). For each audit,
take the newest **full** report (`<date>/<audit>.md`) across all dated folders. Use a
triage or narrowed report (`<audit>--…`) only when no full report exists. Discard any
report whose front matter `repo:` or `audit:` does not match, and say so. A report
without `contract: v2`, `v2.1`, or `v2.2` predates ceiling signals: its predicates
are `UNKNOWN — pre-v2 report`.

Classify freshness by the first rule that matches:

1. **missing** — no report.
2. **unknown** — target HEAD is unknown, or the report's commit is not an ancestor of
   HEAD (`git-read merge-base --is-ancestor <commit> HEAD` prints `false` or `ERROR`).
3. **stale** — the report's folder date is more than 30 days before today, **or**
   `git-read rev-list --count <commit>..HEAD` exceeds 50.
4. **current** — otherwise.

## Phase 2 — Build the predicate table

For every predicate, take the state from its owning report's `## Ceiling signals`
table, then apply, in order:

- report **missing** → `UNKNOWN — no report`.
- reported `TRIGGERED` → stays `TRIGGERED` whatever the freshness; append `(stale)`
  or `(unknown freshness)` when applicable. Age is not remediation: a triggered
  ceiling lifts only when a newer report clears it.
- reported `CLEARED` from a **stale** or **unknown**-freshness report → `UNKNOWN`
  (`was CLEARED, stale`).
- reported `CLEARED` from a triage or narrowed report → `UNKNOWN — scope`, unless the
  report states its scope covered the predicate's whole scope.
- predicate absent from the table, or marked not assessed → `UNKNOWN`.
- otherwise → the reported state, with its evidence.

Do not change any audit's scores. If two reports contradict each other on a fact that
decides a predicate, record the contradiction and use the state backed by the more
direct evidence — name which, and why. If neither is more direct, the predicate is
`UNKNOWN`.

## Phase 3 — Apply the ceilings

Levels are defined by what an agent may do and where a human must sign off:

- **Not ready** — agents may read, explain, and comment. No agent-authored change
  merges.
- **Assisted** — an agent may draft changes inside a developer's own session (IDE,
  local Claude Code). The developer edits, owns, and opens the PR as its author.
  Agent-opened PRs (e.g. the Copilot coding agent) stay disabled for the repository.
- **Supervised** — agents may open PRs. Every agent PR gets a full review by a code
  owner before merge; no auto-merge. Paths under a stricter ceiling are excluded.
- **Autonomous (bounded)** — for the task classes listed in the verdict only, agent
  PRs may merge on green required gates plus a lightweight human approval. All other
  work stays Supervised.

| Predicate | If TRIGGERED | If UNKNOWN |
|---|---|---|
| `ungated-prod-path` | Not ready | Assisted |
| `secret-exposure` | Assisted | Supervised |
| `gate-bypassable` | Assisted | Supervised |
| `no-local-signal` | Assisted | Supervised |
| `green-not-meaningful` | Supervised | Supervised |
| `review-not-a-control` | Supervised | Supervised |
| `no-rollback` | Supervised | Supervised |
| `docs-mislead` | Supervised | Supervised |
| `vuln-intake-unmanaged` | Supervised | Supervised |
| `orphaned-risk` | Supervised for the named paths | Supervised |

The verdict is the **lowest** level any row allows. *Autonomous (bounded)* requires
every predicate `CLEARED`. The verdict is **PROVISIONAL** whenever any predicate is
`UNKNOWN` — unknown risk caps autonomy without claiming the control is absent. A
committed live credential is also an incident: call it out in the Verdict whatever
the level.

## Phase 4 — Task-class fit

For each class, state *fit / fit with guardrails / not fit* and the predicate or
finding that decides it: dependency and security bumps; adding tests to existing
code; documentation and comment changes; bug fixes inside well-tested modules; bug
fixes inside poorly tested or risky modules; new features; refactors across module
boundaries; CI/CD workflow changes; infrastructure-as-code, deployment, and
production configuration; data migrations.

A class is *not fit* where it touches paths under a stricter ceiling than the
verdict (for example, `orphaned-risk` paths), or where the deciding evidence for that
class is `UNKNOWN`.

## Phase 5 — Raise the ceiling

List candidate actions from the owning reports' findings and "Next three things",
plus "run or re-run <audit>" for each `UNKNOWN` row. For each action, record **every**
predicate it would plausibly flip to `CLEARED` (one action can clear several). Then
recompute the verdict with those predicates cleared and all others unchanged:

- The highest-leverage action is the one whose recompute raises the level most; ties
  go to the action named in more reports' "Next three things".
- If no single action raises the level, name the smallest set that does, and say
  plainly that no single change is enough.
- An audit re-run is modelled as "may clear" — say the level it could reach.

Emit fewer than three actions when the evidence supports fewer.

## Phase 6 — Trend

Find the most recent earlier dated folder containing `agentic-readiness.md`. If one
exists, compare: level then → now, and each predicate whose state changed, with the
report that changed it. If none exists, this is the baseline run — say so.

## Output — two documents

Print both, then write them to `<AUDIT_OUTPUT_ROOT>/<org>-<repo>/<today>/` with contract
front matter (`audit: agentic-readiness` / `audit: executive-summary`, `commit:`
target HEAD or `unknown`, `contract: v2.2`). The contract's evidence, redaction, and
allow-listed-org rules apply to both.

### `agentic-readiness.md` — the detailed verdict

1. `## Verdict` — the level, PROVISIONAL if applicable, the task classes it covers,
   and the binding predicate(s).
2. `## Evidence base` — `| Audit | Report | Scope | Freshness | Date | Commit |`.
3. `## Predicate table` — `| Predicate | State | Ceiling | Source report | Evidence |`,
   all ten rows.
4. `## Task-class fit` — the Phase 4 table.
5. `## Contradictions between reports` — or "none found".
6. `## What already works in the agent's favour` — from the reports' "What is
   already good" sections.
7. `## Raise the ceiling` — up to three actions, each with the predicates it clears
   and the level the repo would reach after the recompute.
8. `## Trend` — Phase 6.
9. `## Missing evidence` — audits to run or re-run, ordered by how much each could
   change the verdict.

### `executive-summary.md` — one page for a Director/VP

Audience: engineering leadership deciding whether and how to use AI coding agents on
this repository. Write in plain business language: no predicate IDs, no file paths
or commands, no tool names except the agent products themselves. At most ~450 words.
Every statement must trace to the detailed verdict — no new claims.

1. `## Bottom line` — two or three sentences: the readiness level in plain words
   (what AI agents may and may not do here), and whether the assessment is
   provisional because some evidence could not be verified.
2. `## Readiness by area` — a table of the eight plain-language areas above:
   `| Area | Status | Why, in one line |`. Status: 🔴 a triggered ceiling in that
   area; 🟡 an unknown ceiling, or the area's mean audit score below 3; 🟢 all its
   ceilings cleared and mean score 3.5 or higher; ⚪ not assessed. Anything else 🟡.
3. `## Top risks` — up to three, each as the business consequence ("a change can
   reach production without review"), not the mechanism.
4. `## Recommended investments` — up to three, from Phase 5, each with rough effort
   (S / M / L) and what it unlocks ("moves the repo to Supervised").
5. `## Since last assessment` — from Phase 6: level then → now and what moved, or
   "Baseline assessment — future runs will show change against this one."
6. `## Confidence` — one or two sentences on what could not be verified and how to
   close that gap.

End with one line: `Detail: agentic-readiness.md and the eight audit reports in this
folder.`
