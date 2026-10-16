# dev-workflow

Engineering workflow skills — ticket intake, PR gates, orchestrated plan
implementation, incident investigation and write-ups, skill retrospectives, and Copilot
readiness — plus the review agents those skills dispatch: a cold-context
verifier, an adversarial cross-model reviewer, a general-purpose worker, and
two domain specialists.

## Skills

| Skill | Purpose |
|---|---|
| `intaking-work-items` | Takes a Jira ticket or GitHub issue to ready-to-build: fetch context, gap-analyze story/scope/requirements/AC, block on clarifying questions, write `docs/specs/<KEY>-requirements.md`, offer confirmed writebacks, then chain spec → tickets → implement through the sdlc-process (always recommended when installed) or mattpocock-skills chain (user's choice), with a checkpoint between stages, verify each AC, open a draft PR, and close out; at sdlc-process stage 5, with 2+ published issues, it runs them as pieces via orchestrating-pieces by default (inline only if the user opts out) |
| `opening-pull-requests` | The ordered gate sequence before and during PR creation: branch hygiene, sync, lint/test, CI mirror, review-tier decision, review chain, ticket references, confirm, create, verify. |
| `plan-implementation` | Orchestrated implementation of an approved plan through tiered worker lanes — decompose, route, spec, verify, close. |
| `authoring-incident-docs` | Produces RCA, findings, and runbook artifacts with correct placement, metadata, and section structure. |
| `investigating-incidents` | Orchestrates a root-cause investigation: ticket gate, evidence ordering, hypothesis refutation, confidence gates, artifact production, close-out. |
| `skill-retrospective` | Capture-and-consolidate loop that keeps a skill library self-improving. |
| `copilot-agent-readiness` | Audits and remediates a repo to maximize GitHub Copilot coding agent output quality. |
| `orchestrating-pieces` | Piece orchestration: builds a ticket's published GitHub issues, one piece agent (a `claude --bg` session) per issue, each in its own worktree and branch, talking to you directly. The orchestrating session tracks pieces with the `piece-track.sh` CLI, fast-forwards finished pieces into the ticket branch one at a time and hands back one draft PR. Needs `jq` and `perl` (the CLI locks its tracking file with `flock` through perl). |
| `review-policy` | The tiered review policy (Exempt / Routine / Full chain, codex-adversary governance, evidence rule) that the other skills and agents here cite. |

## Agents

| Agent | Model | Purpose |
|---|---|---|
| `fresh-verifier` | Fable, medium effort (cold context) | Cold-context verification of a diff or plan against its stated objective — no author bias. |
| `fresh-verifier-high` | Fable, high effort (cold context) | High-effort variant of `fresh-verifier` — dispatch only when deeper verification is explicitly requested. |
| `codex-adversary` | Sonnet (dispatcher) | Adversarial cross-model review via Codex (GPT family) — mandatory at least once per full-tier review. |
| `code-writer` | Sonnet | Focused implementer for a single well-scoped coding task. |
| `performance-reviewer` | Sonnet | Specialist reviewer for runtime performance and resource usage — opt-in. |
| `terraform-best-practices-reviewer` | Sonnet | Specialist Terraform reviewer for module structure, conventions, secrets, and cloud security posture. |

Invoke these with the `dev-workflow:` prefix, e.g. `dev-workflow:fresh-verifier`,
`dev-workflow:codex-adversary`.

`codex-adversary` needs the `codex-crew` plugin (or a plain Codex CLI install) to actually
dispatch a Codex job — without either, it returns a blocking message rather than
fabricating a review.

## Review policy

The tiered review policy (Exempt / Routine / Full chain, codex-adversary governance, and
the evidence rule) now lives in the `review-policy` skill
(`skills/review-policy/SKILL.md`), loadable by qualified name as
`dev-workflow:review-policy` from this or any other plugin.

## Piece orchestration

A **piece** is one GitHub issue. When intake's sdlc-process chain reaches stage 5 with two
or more published issues, pieces are the default, blocked chains included, and the
`orchestrating-pieces` skill takes over. The purpose is intake's context: each issue runs in
its own agent and only short reports come back. Running all issues inline is an explicit
opt-out the user must choose. Intake records `Implementation: pieces` or
`Implementation: inline (user chose)` in its run log before implementing, and does not call
`sdlc-process:implement` directly with 2+ issues unless the line reads inline.

- The orchestrator launches one piece agent per issue whose blockers are merged, as a
  `claude --bg` session handed a self-contained handoff prompt
  (`skills/orchestrating-pieces/references/handoff-prompt.md`).
- `skills/orchestrating-pieces/scripts/piece-track.sh` is the single reader and writer of the
  orchestrator's tracking file: `register`, `launchable`, `launch`, `record`, `merged`,
  `reconcile`, `summary` and the rest. Writes hold a per-file `flock`; `reconcile` rebuilds
  state after a restart from the session listing, GitHub and git.
- A piece agent runs intake in **piece mode** (`skills/intaking-work-items/piece-mode.md`):
  steps 0 to 7 against its own issue, attended, with you answering directly. It never pushes
  or opens a PR; it reports done with a branch and a full commit SHA.
- `ff-merge.sh` fast-forwards each finished piece into the ticket branch, one at a time. The
  top level then opens one draft PR through intake's ship step, after your go.
- A piece that turns out to be several issues becomes an orchestrator itself (depth cap 2, 3
  live children each).

## Install

```bash
# from GitHub
claude plugin marketplace add cjsteigerwald/ai-crew
# or from a local checkout
claude plugin marketplace add /path/to/ai-crew

claude plugin install dev-workflow@cjs-plugins
```

## Requirements

`codex-adversary` benefits from the `codex-crew` plugin (or a plain Codex CLI) being
installed; every other skill and agent here works standalone. The tiered worker lanes
named in `plan-implementation` (`claude-scout`, `claude-reader`,
`claude-implementer-*`) come from the separate `claude-crew` plugin.
The `NEEDS_LOOKUP` recipient enforcement for `code-writer` (only `main` may be
messaged) also comes from `claude-crew`'s `sendmessage-recipient-gate` hook;
without claude-crew installed, that rule is prose only.
