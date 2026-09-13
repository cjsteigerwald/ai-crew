# tech-research

An interrogative, evidence-tiered research protocol for high-stakes technology
and vendor decisions — a research partner, not a report generator. It finds
out what was already decided, interviews the user into a sharp question,
gathers verifiable evidence internal-first, attacks its own conclusions from
a position blind to the user's preferences, and leaves behind a cited
artifact plus a durable constraint register that makes the next run cheaper.

**Never touches the originals.** This plugin is a self-contained copy of the
protocol and its seven agents; nothing in it reads from or writes back to
wherever the source skill or agents originally lived.

## What it does

Runs a phased protocol, none of it skippable:

1. **Storage agreement** — confirms where the research root and the register
   live before writing anything.
2. **Internal sweep** — checks the research root for prior decisions before
   proposing anything new.
3. **First interview** — turns a vague ask into a sharp, bounded question;
   splits answers into CONSTRAINTS (passed to gathering lanes) and
   PREFERENCES (withheld from every lane).
4. **Evidence gathering** — the candidate set and framing are challenged
   *before* any gathering starts; tiered, symmetric retrieval across T0–T4
   sources; a disconfirmation quota (evidence against the leading option).
5. **Second interview** — comes back with what the evidence changed.
6. **Positions, not a verdict** — 2-4 genuinely distinct bets, each with what
   it optimizes for, forecloses, and costs to get wrong. No recommendation
   unless explicitly asked.
7. **Blind adversarial review** — an adversary attacks the positions and the
   framing having seen only evidence records and candidate positions (never
   the synthesis, the user's leanings, or either sealed prior); the
   orchestrator rebuts; an independent judge — not the orchestrator — rules
   on which objections survived.

Full detail, phase-by-phase gates, and the anti-capture rationale:
`skills/tech-research/SKILL.md` and `skills/tech-research/references/`.

## The seven agents

| Agent | Model | Role |
|---|---|---|
| `research-internal-sweep` | haiku | Owns Phase 0 — the internal record (T0), the research root tree only. Runs first, before any external gathering. |
| `research-framing-challenger` | opus | Attacks the candidate set and the question framing at the *start* of Phase 2, before any gathering lane runs and before the candidate set is locked. |
| `research-vendor-docs` | haiku | Gathers T1 primary-vendor evidence — official docs, API references, release notes, pricing, status history. |
| `research-code-and-issues` | haiku | Gathers T2 behavioral ground truth — source code, GitHub issues/PRs, specs/RFCs, incident writeups, independent benchmarks. The only lane with `gh` CLI access. |
| `research-operator-experience` | sonnet | Gathers T3 operator-experience evidence — engineering blogs, conference talks, peer-reviewed work from people who run the thing, not sell it. Carries primary responsibility for the disconfirmation quota. |
| `research-adversarial` | opus | Phase 5's blind adversary — attacks the candidate positions and the framing, having seen only evidence records, query logs, and positions. |
| `research-rebuttal-judge` | opus | Rules on which of the adversary's objections survived the orchestrator's rebuttal — an independent, mechanical check rather than the orchestrator scoring its own rebuttals. |

Every agent reads `source-tiers.md` and `anti-capture.md` before doing
anything else, and every dispatch is bound by an explicit blindness
constraint: gathering lanes never see PREFERENCES or the sealed prior;
`research-adversarial` and `research-rebuttal-judge` additionally never see
CONSTRAINTS.

## Configuration

Two crew config keys, read via `lib/crew-config.sh`:

| Key | Default | Holds |
|---|---|---|
| `research_root` | `~/Research` | The register and research artifacts. |
| `research_state_dir` | `~/.claude/tech-research-state` | Run state — constraints, preferences, both sealed priors, verbatim dispatch packets. Always outside `research_root`, and never committed there, because Phase 0's sweep reads every active register note as evidence — a prior or preference stored inside `research_root` would be laundered back in as evidence on the next run. |

Neither path is expected to pre-exist; both self-bootstrap with the user's
confirmation on first run (see SKILL.md's Phase -1 and
`references/register-schema.md` § First-run bootstrap). Run state is never
written under `${CLAUDE_PLUGIN_ROOT}`, since that path changes on every
plugin update — `research_state_dir` lives outside it by design.

`${CLAUDE_PLUGIN_ROOT}` is substituted wherever it appears in an agent's own
markdown, so each agent resolves its own references-directory path
(`${CLAUDE_PLUGIN_ROOT}/skills/tech-research/references/...`) without help.
`research_root` and `research_state_dir` are different: they come from crew
config, not the plugin's install location, so the orchestrator resolves both
itself and passes them as literal absolute paths inside every dispatch
prompt to a `tech-research:research-*` agent.

## How to run it

Install the plugin, then ask for a technology or vendor decision in plain
language — "should we use X", "X vs Y", "is X still maintained", "what are
our options for Z" — and the skill fires automatically. It never requires
the words "research," "evaluate," or "compare." Skip it for one-off factual
lookups with a single right answer, and for implementing a decision that has
already been made.

```bash
claude plugin marketplace add cjsteigerwald/ai-crew
# or from a local checkout
claude plugin marketplace add /path/to/ai-crew

claude plugin install tech-research@cjs-plugins
```

## Requirements

None beyond Claude Code itself — no external CLI, no runtime, no Node. The
`research-code-and-issues` agent uses the `gh` CLI when available for
maintenance-reality checks (commit recency, issue health), but the protocol
degrades gracefully without it.
