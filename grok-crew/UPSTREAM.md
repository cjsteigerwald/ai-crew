# Upstream sync record

`grok-crew` is vendored from [`sidkik/claude-plugins`](https://github.com/sidkik/claude-plugins)
(marketplace `sidkik-plugins`). Keep this file current: a port that does not
update it has not finished. `codex-crew/UPSTREAM.md` explains how to add the
`upstream` remote and why its URL, not just its name, must be checked.

## Current sync point

| | |
|---|---|
| Upstream repo | `sidkik/claude-plugins` |
| Synced to | upstream grok-crew **0.1.2**, commit `a57e81b` |
| Synced on | 2026-10-01 |
| This plugin's version | **0.2.0** |

```bash
git fetch upstream
git diff a57e81b upstream/main -- grok-crew/
```

## Version numbers do not line up

This copy starts at `0.2.0` so it never shares a version number with different
upstream code (`codex-crew` hit exactly that collision at `0.6.0`). Compare
against the commit above, never a tag or version.

## Deliberate divergences

| Area | Upstream | Here | Why |
|---|---|---|---|
| Install source | `grok-crew@sidkik-plugins` | `grok-crew@cjs-plugins` | This marketplace ships its own copy. |
| `timeout` on macOS | assumes GNU `timeout` for the optional soft probe and job deadlines | documents `gtimeout` (Homebrew `coreutils`) and skipping the optional probe when neither exists | Stock macOS has no `timeout`; ai-crew supports macOS and bash 3.2. A required deadline that cannot be enforced is reported instead of silently dropped. |
| Versions | `.claude-plugin` 0.1.2, `.codex-plugin` 0.1.1 | both `0.2.0` | One version per copy. |

Everything else is upstream text unchanged.
