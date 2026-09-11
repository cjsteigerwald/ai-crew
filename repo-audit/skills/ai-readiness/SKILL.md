---
description: Run the full repo audit suite against a repository (URL, org/repo, or local path), roll the results up into an AI-readiness verdict and Director/VP executive summary, and deliver the package to ~/ai-readiness/<org>-<repo>/<date>/ and, if configured, a mirror directory
argument-hint: "<repo-url | org/repo | local-path> [--only <audit,...>] [--run]"
disable-model-invocation: true
allowed-tools: Read, Glob, Agent, Write(~/repo-audits/**), Bash(repo-fetch:*), Bash(git-read:*), Bash(gh-read:*), Bash(ai-readiness-package:*), Bash(ls:*), Bash(grep -c:*)
---

# AI Readiness — full assessment

You are orchestrating the repo audit suite for one repository and producing an
AI-readiness package. Your goal: **a dated, evidence-backed readiness assessment
that a Director/VP can read in two minutes and an engineer can verify line by
line.**

The eight audits are ordinary, individually runnable skills (`/test-audit`,
`/pipeline-gates-audit`, …) and are useful whether or not a team uses AI. This
command runs them all against one target, then adds the AI-readiness roll-up. Do
not read the contract, the audit skills, or the finished reports into this session
— every subagent reads what it needs itself, and this session only dispatches,
checks, packages, and relays. That is what keeps the orchestrator's context
small.

## Arguments

Requested: `$ARGUMENTS`

- First argument (required): a GitHub URL, `org/repo`, or a local directory. A local
  directory is audited as-is — use this to assess a branch in progress.
- `--only a,b` — re-run only these audits (short names such as `test`, `pipeline-gates`);
  the roll-up uses the newest existing reports for the rest.
- `--run` — audits may *request* documented local test/lint runs through the normal
  permission prompt, runtime pinned per the contract. Without it, no project code
  runs at all.

If the first argument is missing, stop and ask for it.

## Step 1 — Resolve the target

Run `repo-fetch <first argument>`. It prints `REPO_DIR`, `IDENTITY`, `ID`
(`<org>-<repo>`), `SHA`, `SOURCE` (`clone` / `cache` / `local`), and
`AUDIT_OUTPUT_ROOT` (the resolved `audit_output_root` config key, default
`~/repo-audits` — the same key `ai-readiness-package` reads in Step 4, so the two
are guaranteed to agree), plus `AUTH=` when a per-org token was used. A remote
target is a blobless partial clone cached at the configured cache directory
(default `~/.cache/repo-audit/<org>-<repo>`) — full history, contents on demand —
refreshed and checked out detached at the default-branch tip. If it prints
`ERROR:`, stop and report it verbatim (it names the token variable, and some orgs'
trap of rejecting expired classic PATs with 404 instead of 403, when relevant).

Record `DATE` = today's date (YYYY-MM-DD) from your environment. Reports go to
`<AUDIT_OUTPUT_ROOT>/<ID>/<DATE>/`. If `AUDIT_OUTPUT_ROOT` is not `~/repo-audits`,
every dispatched skill's `allowed-tools` `Write(~/repo-audits/**)` line (and this
skill's own) must already have been hand-edited to match, or the writes below will
be denied — Claude Code's permission syntax cannot reference a config value, so this
one step cannot be automated (see the README's Limitations).

## Step 2 — Run the audits

Audits, in two waves of four so GitHub's search rate limit is not tripped by eight
concurrent runs (skip any not selected by `--only`):

- Wave 1: `pipeline-gates-audit`, `test-audit`, `context-legibility-audit`,
  `change-safety-audit`
- Wave 2: `pr-review-audit`, `security-supply-chain-audit`,
  `ownership-activity-audit`, `feedback-loop-audit`

`context-legibility-audit` ships separately from this plugin. Before dispatching it,
check whether `${CLAUDE_PLUGIN_ROOT}/skills/context-legibility-audit/SKILL.md`
exists; if not, skip the dispatch and report it as `not installed`, not a failure —
the roll-up marks `docs-mislead` `UNKNOWN — not installed`.

Dispatch each wave as parallel `Agent` calls (`general-purpose` with `model: sonnet`), then wait for the
whole wave before starting the next. Use this prompt, filling the placeholders:

> You are running the `<AUDIT>` repository audit. Read the contract shipped with
> this plugin (`${CLAUDE_PLUGIN_ROOT}/contract.md`), then
> `${CLAUDE_PLUGIN_ROOT}/skills/<AUDIT>/SKILL.md`, and
> follow the skill exactly as if it had been invoked with the argument `full`, with
> these adaptations. The target repository is checked out at `<REPO_DIR>` (identity
> `<IDENTITY>`, audited commit `<SHA>`). Append `--in <REPO_DIR>` to every
> `git-read` and `gh-read` call; run the skill's pre-gathered `!` commands yourself
> first, with `--in <REPO_DIR>` added; Read files by absolute path under
> `<REPO_DIR>`. Use only `git-read`, `gh-read`, Read, and Glob — never raw `git`,
> `gh`, `grep`, or `find`. <IF --run: You may request documented test/lint runs
> through the permission prompt, following the contract's local-execution and
> runtime-pinning rules; do not run anything if the declared runtime is not
> installed. | ELSE: Do not run any project code.> Write the report to
> `<AUDIT_OUTPUT_ROOT>/<ID>/<DATE>/<AUDIT>.md` exactly per the contract. Reply with only:
> the report path, its Headline, and its Ceiling signals table.

After each wave, confirm its reports without reading them, in **one** Bash call for
the whole wave (not one per report — parallel per-report calls trip the read budget):
`grep -c '^## Ceiling signals' <AUDIT_OUTPUT_ROOT>/<ID>/<DATE>/{<AUDIT1>,<AUDIT2>,<AUDIT3>,<AUDIT4>}.md`.
Each report must print `:1`; any other count, or a "No such file" line, is a failure.
Re-dispatch a failed audit once; if it fails again, continue without it — the roll-up
will mark its ceilings `UNKNOWN`.

## Step 3 — Roll up

Dispatch one `Agent` call (`general-purpose` with `model: sonnet`) with this prompt, filling the
placeholders:

> Read the contract shipped with this plugin (`${CLAUDE_PLUGIN_ROOT}/contract.md`),
> then `${CLAUDE_PLUGIN_ROOT}/skills/agentic-readiness/SKILL.md`,
> and follow it for target `<IDENTITY>` with `--in <REPO_DIR>` (target HEAD = `<SHA>`,
> today = `<DATE>`). Write `agentic-readiness.md` and `executive-summary.md` to
> `<AUDIT_OUTPUT_ROOT>/<ID>/<DATE>/` exactly as that skill specifies. Reply with only: the
> readiness level (and PROVISIONAL if applicable) in one sentence, the executive
> summary's "Readiness by area" table, the "Raise the ceiling" actions with the level
> each reaches, and any report you discarded or found contradictory.

Check both files exist with `ls` — do not Read them. Re-dispatch once on failure. Use
the agent's reply, not the files, for Step 5.

## Step 4 — Package and deliver

Run `ai-readiness-package <ID> <DATE>`. It copies the executive summary, the verdict,
and the newest report for each audit into `<package_output_root>/<ID>/<DATE>/`
(the `package_output_root` config key, default `~/ai-readiness`) with an index
`README.md`, then, only when the `delivery_dir` config key is set, mirrors the folder
there and lists it. Earlier dated folders are never touched, so each run adds to the
history. If it prints `ERROR:`, report it; if it prints `LAPTOP=not configured`, say
the package is local only and how to enable a mirror (set `delivery_dir` in config —
see the README).

## Step 5 — Report back

Reply with:

- the readiness level (and PROVISIONAL if applicable) in one sentence;
- the executive summary's "Readiness by area" table;
- the package path (`<package_output_root>/<ID>/<DATE>/`, default `~/ai-readiness/<ID>/<DATE>/`) and, if `LAPTOP=` printed a
  mirror path, that path too;
- any audit that failed or was skipped, and any `AUTH=` note from Step 1.

Do not paste the full reports; they are in the package.
