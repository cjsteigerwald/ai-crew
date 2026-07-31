# claude-crew

Tiered Claude delegate agents for Claude Code, mirroring `codex-crew`'s lane
model on the Claude side. Each agent pins a specific Claude model via native
`model:` frontmatter, so delegated work runs on the right (cheaper) tier
instead of inheriting the session model — which, on a Fable session, is the
single most expensive model available.

Unlike `codex-crew`, no companion runtime or forwarding shim is needed:
Claude subagents are native, and the frontmatter pin is the whole mechanism.
The plugin is pure agent definitions.

## Why

Measured on real sessions: built-in agents dispatched without a model
override (`Explore`, `general-purpose`) inherit the session model. On a
Fable session that means paying $10/$50 per MTok for file searches a Haiku
agent handles at $1/$5. These lanes give the orchestrator named, pinned
alternatives with selection criteria in each description, so tier choice
happens automatically at dispatch time.

Note the honest caveat: in a typical session the orchestrator's own main
loop dominates token spend, not subagents. This plugin reduces spend only
for work that is actually delegated — the more the orchestrator hands
search/read/implement work to lanes, the more it saves.

## Agents

| Agent | Model | $/MTok in/out | Posture | Choose when |
|---|---|---|---|---|
| `claude-scout` | Haiku | $1 / $5 | read-only | Find/locate/inventory — Explore-style searches, "where is X defined", pattern sweeps |
| `claude-reader` | Haiku | $1 / $5 | read-only | Bulk read-and-digest — summarize logs/docs/transcripts, extract structured facts with citations |
| `claude-implementer-haiku` | Haiku | $1 / $5 | write | Mechanical, exact-recipe edits — renames, bulk replacements, config plumbing; fan out freely |
| `claude-implementer-sonnet` | Sonnet | $3 / $15 | write | Routine, well-specified implementation with existing patterns to follow; the default worker lane |
| `claude-implementer-opus` | Opus | $5 / $25 | write | Intricate logic, gnarly debugging, correctness-critical paths within one bounded subsystem |

Rough cost ratio per token: Fable ≈ 2× Opus ≈ 3.3× Sonnet ≈ 10× Haiku.
(Fable itself: $10/$50. Sonnet intro pricing $2/$10 through 2026-08-31.)

Deliberately **not** included: a Fable-tier lane (that's the orchestrator's
own loop, and cold-context Fable verification already exists as
`fresh-verifier` in the review architecture) and reviewer agents (the
project-level reviewer/verifier/adversary agents own that space).

## Relationship to codex-crew

The two crews are complementary, not competing:

- `codex-crew` (GPT ladder: Luna/Terra/Sol) — cross-model implementation
  lanes; when a Codex lane implements, Claude-side verification is
  independent in both directions.
- `claude-crew` (Claude ladder: Haiku/Sonnet/Opus) — same-family lanes for
  when you want Claude's tool-use conventions, no Codex dependency, or
  read-only research work the Codex lanes don't cover.

Lane-selection guidance for orchestrators: for implementation, either
family's tier ladder applies (pick by the same mechanical/routine/hard
split); for search and digest work, `claude-scout` / `claude-reader` are
the default because they're the cheapest way to keep raw file contents out
of the orchestrator's context.

## Install

```bash
# from GitHub
claude plugin marketplace add cjsteigerwald/claude-crew
# or from a local checkout
claude plugin marketplace add /path/to/claude-crew

claude plugin install claude-crew@cjs-plugins
```

## Requirements

None beyond Claude Code itself — no external CLI, no runtime, no Node.
