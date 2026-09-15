# dev-workflow

Engineering workflow skills — PR gates, orchestrated plan implementation,
incident investigation and write-ups, skill retrospectives, and Copilot
readiness — plus the review agents those skills dispatch: a cold-context
verifier, an adversarial cross-model reviewer, a general-purpose worker, and
two domain specialists.

## Skills

| Skill | Purpose |
|---|---|
| `opening-pull-requests` | The ordered gate sequence before and during PR creation: branch hygiene, sync, lint/test, CI mirror, review-tier decision, review chain, ticket references, confirm, create, verify. |
| `plan-implementation` | Orchestrated implementation of an approved plan through tiered worker lanes — decompose, route, spec, verify, close. |
| `authoring-incident-docs` | Produces RCA, findings, and runbook artifacts with correct placement, metadata, and section structure. |
| `investigating-incidents` | Orchestrates a root-cause investigation: ticket gate, evidence ordering, hypothesis refutation, confidence gates, artifact production, close-out. |
| `skill-retrospective` | Capture-and-consolidate loop that keeps a skill library self-improving. |
| `copilot-agent-readiness` | Audits and remediates a repo to maximize GitHub Copilot coding agent output quality. |
| `review-policy` | The tiered review policy (Exempt / Routine / Full chain, codex-adversary governance, evidence rule) that the other skills and agents here cite. |

## Agents

| Agent | Model | Purpose |
|---|---|---|
| `fresh-verifier` | Fable (cold context) | Cold-context verification of a diff or plan against its stated objective — no author bias. |
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
