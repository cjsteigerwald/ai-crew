# harness-skills

Crew configuration writer and the ai-crew-update plugin updater/reconciler.

## What ships

**Skills:**
- `crew-configure` — read and write the crew's shared JSON settings file
- `ai-crew-update` — update and reconcile crew plugins

**Binaries:**
- `crew-configure` — CLI for reading/writing config

**Libraries:**
- `lib/crew-config.sh` (vendored) — POSIX-compliant crew config reader used by shell scripts

## What `ai-crew-update` writes

`ai-crew.sh status`, `verify` and `reconcile --dry-run` make **no persistent or
configuration write**: they never touch `settings.json`, `CLAUDE.md`, the
snapshots, the gate receipts, the ambiguous-acknowledgement list or the
migration record. They are not
write-free, though — they stage their analysis (jq programs, hook/fragment
indexes, rendered CLAUDE.md candidates) in a temp directory created 0700 under
`$TMPDIR` (default `/tmp`), so they require a writable TMPDIR, and a hard kill
mid-run can leave an `ai-crew.XXXXXX` directory behind.

`reconcile` (without `--dry-run`) and `update` are the only subcommands that
change the user's configuration, and both back up what they replace.
`reconcile --accept-ambiguous` and `reconcile --record-migrated` write only
their own record files (`ambiguous-ack.json`, `migrated-hooks.json`).

## What `reconcile` will and will not delete

`reconcile` removes `settings.json` hook entries that duplicate a hook the
plugin already registers through its own `hooks/hooks.json`. It removes one
only with **provenance** — positive proof the registered file is the plugin's:

1. the path resolves inside that plugin's own installed directory, or
2. the file's sha256 equals the plugin-shipped hook of the same basename, or
3. the user recorded the exact path with `reconcile --record-migrated <path>`.

A basename collision is **not** proof, and neither is the directory a path sits
in: a project's own `.claude/hooks/read-budget-gate.py` is a different file
doing a different job, and is KEPT and reported
`AMBIGUOUS ... (kept; basename matches a plugin hook but provenance is
unproven ...)`, with the copy-pasteable `--accept-ambiguous` remedy. Kept
entries fail `verify` until a human resolves or acknowledges them; that is the
intended trade against deleting a hook nobody asked us to touch.

## Install

```bash
claude plugin install harness-skills@cjs-plugins
```

## Configuration

The crew's shared config file is read and written via `lib/crew-config.sh` and the `crew-configure` binary. Never hand-roll jq recipes against it.

| Key | Type | Default |
|---|---|---|
| `research_root` | string | `~/Research` |
| `research_state_dir` | string | `~/.claude/tech-research-state` |
| `audit_output_root` | string | `~/repo-audits` |
| `audit_cache_dir` | string | `~/.cache/repo-audit` |
| `package_output_root` | string | `~/ai-readiness` |
| `delivery_dir` | string | `""` (empty = disabled) |
| `token_map` | string | `~/.claude/plugins/data/crew/token-map` |
| `org_allowlist` | array of string | `[]` |
| `marketplaces` | array of `{name, repo}` | `[{"name":"cjs-plugins","repo":"~/repos/ai-crew"}]` |
| `lanes.scout` | string | `claude-crew:claude-scout` |
| `lanes.reader` | string | `claude-crew:claude-reader` |
| `lanes.implementer_haiku` | string | `claude-crew:claude-implementer-haiku` |
| `lanes.implementer_sonnet` | string | `claude-crew:claude-implementer-sonnet` |
| `lanes.implementer_opus` | string | `claude-crew:claude-implementer-opus` |
| `lanes.writer` | string | `code-writer` |
| `lanes.verifier` | string | `fresh-verifier` |
| `lanes.adversary` | string | `codex-adversary` |

See the config keys table above; the canonical example file is `lib/crew-config.example.json` in the ai-crew repository (not shipped in the plugin).

## Planned

- Skill author / scaffolder (compose skills from templates, manage dependencies)
- Session handoff (capture session state, restore in a new session)
- Plugin marketplace operations (add, list, update marketplaces)
- Remote Control teardown (safe cleanup of abandoned sessions)
