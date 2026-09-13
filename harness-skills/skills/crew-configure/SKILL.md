---
name: crew-configure
description: Configures the crew's shared JSON settings file — research root, state/cache/delivery directories, token map path, org allowlist, marketplace list, and lane-to-agent mappings. Trigger phrases — "configure the crew", "set my research root", "where does the crew store config", "crew config".
---

# crew-configure

Reads and writes the crew's shared config file so other skills, scripts, and
hooks pick up the user's preferences without per-invocation flags.

All reads and writes go through the plugin's own tooling — never hand-roll a
`jq` recipe against the config file. The reader is `lib/crew-config.sh`
(sourced by scripts); the writer is the `crew-configure` binary shipped in
this plugin.

## Procedure

1. **Show the current config.**
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/bin/crew-configure" show
   ```
   This prints the resolved config file path, then either its contents
   (pretty-printed) or `absent` if nothing has been written yet.

2. **Ask or accept `key=value` pairs.** Accept either an interactive request
   ("what would you like to set?") or `key=value` pairs already given in the
   user's message (e.g. `research_root=~/Notes`). For nested keys use dotted
   form (`lanes.scout=my-org:my-scout`).

3. **Write with the binary — never construct JSON by hand.**
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/bin/crew-configure" set research_root=~/Notes lanes.scout=my-org:my-scout
   "${CLAUDE_PLUGIN_ROOT}/bin/crew-configure" set-list org_allowlist acme,example-org
   "${CLAUDE_PLUGIN_ROOT}/bin/crew-configure" set-list marketplaces cjs-plugins:~/repos/ai-crew,other:~/repos/other
   "${CLAUDE_PLUGIN_ROOT}/bin/crew-configure" unset lanes.scout
   ```
   `crew-configure` already does everything an ad hoc jq recipe would get
   wrong: it starts a fresh file from `{}` rather than `jq . /dev/null`
   (which succeeds with empty output and would silently write a zero-byte
   config), it refuses an existing-but-malformed file untouched rather than
   overwriting it, it refuses unknown keys (listing the valid ones) rather
   than accepting a typo, it validates array vs. scalar shape per key, it
   writes atomically (temp file + `mv`), and it takes an exclusive lock for
   the duration of the read-modify-write so two concurrent writers cannot
   lose an update. Do not reimplement any of this in prose — call the
   binary.

4. **The binary itself prints the resulting file** after a successful
   `set`/`set-list`/`unset` — relay that output to the user rather than
   re-reading the file separately.

5. **What "takes effect immediately" actually means.** Do not claim every
   hook and skill re-reads the config live — only say this for the specific
   consumers that do:
   - `routing-table.py` (UserPromptSubmit) and `lane-model-gate.py` (PreToolUse on Agent) parse `config.json` directly each time they run; shell scripts read it via `lib/crew-config.sh` when they run. No restart is needed after a config change.
   - This is unrelated to, and does not override, the separate rule that
     plugin *code* changes (new versions of scripts, skills, or hooks
     themselves) need a new session to take effect.

## Schema (top-level keys)

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

`org_allowlist` and `marketplaces` are arrays and can only be written with
`set-list` — `crew-configure` refuses `set org_allowlist=...` and tells you
so. See `lib/crew-config.example.json` for the full defaults as one
document.

## Never store secrets here

`token_map` is a **path to a file** the crew reads tokens from — it is never
itself a token, and no key in this schema is ever a credential value. If a
user asks to "set a token" in this config, redirect them to the token-map
file itself, not this config.
