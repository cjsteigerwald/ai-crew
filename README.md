# claude-crew

A Claude Code plugin marketplace hosting a single plugin: **claude-crew** —
tiered Claude delegate agents (scout / reader / implementer lanes) with
pinned Haiku/Sonnet/Opus models, so delegated subagent work stops inheriting
the expensive session model.

See [`claude-crew/README.md`](claude-crew/README.md) for the agent roster,
cost ratios, and design rationale.

## Install

```bash
# from GitHub
claude plugin marketplace add cjsteigerwald/claude-crew
# or from a local checkout
claude plugin marketplace add /path/to/claude-crew

claude plugin install claude-crew@cjs-plugins
```

## Requirements

None beyond Claude Code itself — no external CLI, no runtime, no Node. The
agents are pure native subagent definitions; the `model:` frontmatter pin is
the entire mechanism.

## Related

Pairs with [codex-crew](https://github.com/sidkik/claude-plugins) (GPT-family
implementation lanes via the official Codex plugin's companion runtime). The
two crews are complementary: Codex lanes give cross-model implementation and
adversarial independence; Claude lanes give cheap same-family search, digest,
and implementation tiers with no external dependency.
