# claude-crew

A Claude Code plugin marketplace (`cjs-plugins`) hosting two complementary
delegate-agent packs:

| Plugin | Models | What it gives you |
|---|---|---|
| **claude-crew** | Haiku / Sonnet / Opus | Tiered Claude delegate agents (scout / reader / implementer lanes) so delegated subagent work stops inheriting the expensive session model |
| **codex-crew** | GPT-family (luna / terra / sol) | Codex implementer lanes and a read-only reviewer, for cross-model implementation and adversarial review |

The two crews are complementary: Codex lanes give cross-model implementation
and adversarial independence; Claude lanes give cheap same-family search,
digest, and implementation tiers with no external dependency.

See [`claude-crew/README.md`](claude-crew/README.md) and
[`codex-crew/README.md`](codex-crew/README.md) for the agent rosters, cost
ratios, and design rationale.

## Install

```bash
# from GitHub
claude plugin marketplace add cjsteigerwald/ai-crew
# or from a local checkout
claude plugin marketplace add /path/to/ai-crew

claude plugin install claude-crew@cjs-plugins
claude plugin install codex-crew@cjs-plugins
```

## Requirements

**claude-crew** — none beyond Claude Code itself: no external CLI, no runtime,
no Node. The agents are pure native subagent definitions; the `model:`
frontmatter pin is the entire mechanism.

**codex-crew** — the official Codex plugin (`/plugin install codex@openai-codex`),
the Codex CLI installed and authenticated (`codex login`), and Node.js. Its
`bin/crew-codex` wrapper must also be on `PATH`.
