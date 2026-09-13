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

The skills and agents in this plugin assume a tiered review policy. Adopt it as-is, or
substitute your own and update the cross-references in each skill/agent.

### Tiers (check in order — first match wins)

1. **Exempt** — pure docs with no behavioral or factual load (README, meeting notes),
   pure-judgment ADRs (scope/appetite decisions asserting no facts about existing
   systems), typo/comment-only edits. **Not exempt**: your project's own instructions
   file(s) and any repo-overlay-style file (they alter agent behavior like skill
   definitions do — Routine minimum; any behavioral change to review governance itself is
   Full chain — a gate must not approve its own weakening), and incident write-ups with
   operational content (a common credential/hostname leak surface — Routine minimum plus
   a `fresh-verifier` security-lens dispatch on the pasted-excerpt checklist).
2. **Full chain** — touches Terraform, CI/workflows, auth/credential handling,
   hooks/settings that gate behavior, or agent/command/skill definitions; OR >3 files
   changed; OR >~150 changed lines; OR cross-cutting/architectural. Dispatch
   `dev-workflow:fresh-verifier` + `dev-workflow:codex-adversary` in one message, both in
   plan mode (on the plan) and again before `gh pr create` (on `git diff main...HEAD`).
   At least one adversarial pass is required; cap three per PR in aggregate; every pass
   beyond the first declares its trigger in the transcript **before** dispatch.
3. **Routine** — everything else: small, low-blast-radius changes (≤3 files, ≤~150
   lines, none of the sensitive surfaces above). A single code-review pass is enough.

When in doubt between Routine and Full, run Full. The tier is re-checked against the
**actual diff** at pre-PR time — a Routine-planned change that grew past the thresholds
gets Full then.

### Evidence rule

A finding from `fresh-verifier` or `codex-adversary` cannot be dismissed without written
evidence — independently verifiable evidence (code, command output, a cited artifact a
reader can re-check) or explicit human adjudication, recorded with who decided and why. A
later adversarial pass disagreeing with an earlier one is analysis, not evidence, on its
own; where two passes disagree and neither is backed by such evidence, the finding stands
open.

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
