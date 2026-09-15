# claude-crew

Tiered Claude delegate agents for Claude Code, mirroring `codex-crew`'s lane
model on the Claude side. Each agent pins a specific Claude model via native
`model:` frontmatter, so delegated work runs on the right (cheaper) tier
instead of inheriting the session model — which, on a Fable session, is the
single most expensive model available.

Unlike `codex-crew`, no companion runtime or forwarding shim is needed:
Claude subagents are native, and the frontmatter pin is the whole mechanism.
The plugin is agent definitions plus one enforcement hook (below).

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

## NEEDS_LOOKUP and the recipient hook

Lanes have no web access. When a lane needs an outside fact, its definition
tells it to send a `NEEDS_LOOKUP: …` line to the orchestrator with
`SendMessage`, addressed to `main`. `SendMessage` itself can reach other
agents and sessions, so the plugin ships a `PreToolUse` hook
(`hooks/sendmessage-recipient-gate.py`, registered in `hooks/hooks.json`) that
enforces the recipient. Plugin agents ignore `hooks` frontmatter, so the hook is
plugin-level.

- **Covered agents**: `claude-crew:claude-implementer-haiku`,
  `claude-crew:claude-implementer-sonnet`, `claude-crew:claude-implementer-opus`,
  `claude-crew:claude-scout`, `claude-crew:claude-reader`, and
  `dev-workflow:code-writer` (matched as `plugin:name`, or the bare name either
  exactly or as the `:`-suffix of any plugin's agent, `<other-plugin>:<bare name>`
  — never a substring or prefix). Enforcement for `code-writer` requires claude-crew to be installed.
- **Rule**: a covered agent's `SendMessage` is allowed only when `to` is exactly
  `main` (surrounding whitespace ignored) and any `recipient` field the harness
  adds is also `main`; anything else is denied. Main-session
  calls and agents of other types are not affected. Message content is not checked.
- **Caller detection**: the rule applies whenever the payload's `agent_type`
  names a covered agent, whether `agent_id` is present, missing, null, or empty.
  A payload whose `agent_type` is missing, empty, or not a string is treated as
  the main session and is allowed.
- **Failure**: an unparseable or non-object payload is allowed with
  `sendmessage-recipient-gate: internal error` on stderr. This is a known
  boundary: the caller cannot be identified, and failing closed would block
  `SendMessage` in every session, so such a payload is not confined even if it
  came from a covered agent. A covered agent's malformed `tool_input` is denied.
- **Off switch**: `CLAUDE_SENDMESSAGE_GATE=off`.
- **Debug**: `SENDMESSAGE_GATE_DEBUG=1` appends a sanitized record of each
  `SendMessage` payload to
  `${CLAUDE_CONFIG_DIR:-~/.claude}/state/sendmessage-gate/payloads.jsonl`. Only
  string values of `hook_event_name`, `tool_name`, `agent_type`, and
  `tool_input`'s `to`, `recipient`, and `type` are kept (truncated to 128
  characters), plus `agent_id_present` as a bool; every other value, including
  `session_id`, `transcript_path`, `cwd`, and a non-object `tool_input`, is
  replaced by a `<redacted:TYPE>` marker. Key names are kept, so the log is not
  a full-content guarantee.

## Install

```bash
# from GitHub
claude plugin marketplace add cjsteigerwald/ai-crew
# or from a local checkout
claude plugin marketplace add /path/to/ai-crew

claude plugin install claude-crew@cjs-plugins
```

## Requirements

Claude Code and `python3` (standard library only, for the recipient hook) —
no external CLI, no Node.
