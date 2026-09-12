# repo-audit

A read-only repository audit suite: seven audit skills, an `agentic-readiness`
roll-up, and an `/ai-readiness` orchestrator that runs the whole suite against one
target and produces a Director/VP-readable verdict. Every read goes through
sandboxing wrappers (`gh-read`, `git-read`, `repo-fetch`) — the skills never call
`git`, `gh`, `rg`, or `find` directly.

## What's in the box

- `contract.md` — the shared contract every audit skill and the roll-ups follow
  (target identity, tool rules, evidence rules, report structure). Read it before
  changing anything; a change here changes every audit's behavior.
- `skills/` — nine skills: `change-safety-audit`, `feedback-loop-audit`,
  `ownership-activity-audit`, `pipeline-gates-audit`, `pr-review-audit`,
  `security-supply-chain-audit`, `test-audit`, `agentic-readiness` (the roll-up),
  and `ai-readiness` (the orchestrator, invoked as `/ai-readiness`).
- `bin/` — `gh-read`, `git-read`, `repo-fetch`, `ai-readiness-package` (the
  read-only wrappers the skills' `allowed-tools` reference by name), and
  `repo-audit-install-wrappers` (a helper that symlinks them onto PATH).
- `lib/crew-config.sh` — a vendored copy of the crew's shared config reader
  (byte-identical to the canonical copy in this repository's `lib/`). See
  `tests/run.sh` for the drift check.
- `token-map.example` — a template for the per-org GitHub token map. Never ship a
  real one with live org names in it.

## Usage

Run any audit as a slash command (e.g. `/test-audit <repo-url>`), or run the whole
suite plus the readiness roll-up with `/ai-readiness <repo-url | org/repo |
local-path> [--only <audit,...>] [--run]`.

### Put the wrappers on PATH

The skills' `allowed-tools` reference `gh-read`, `git-read`, `repo-fetch`, and
`ai-readiness-package` by bare command name, so they must resolve on PATH. Either:

- add `<plugin-root>/bin` to `PATH`, or
- run `<plugin-root>/bin/repo-audit-install-wrappers` once. It symlinks each
  wrapper into `~/.local/bin` (creating the directory if needed), is safe to
  re-run, and never overwrites a file it did not create itself.

## Configuration

Read via the vendored `lib/crew-config.sh` from
`${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/data/crew/config.json` (override with
`CREW_CONFIG_FILE`). All keys are optional; every default below is what the suite
uses with no config file at all.

| Key | Default | Meaning |
|---|---|---|
| `audit_output_root` | `~/repo-audits` | Where audit reports are written, under `<audit_output_root>/<org>-<repo>/<date>/`. |
| `audit_cache_dir` | `~/.cache/repo-audit` | Where `repo-fetch` caches blobless clones of remote targets. |
| `package_output_root` | `~/ai-readiness` | Where `ai-readiness-package` assembles the delivered package, under `<package_output_root>/<org>-<repo>/<date>/`. |
| `delivery_dir` | *(empty)* | Optional mirror destination for `ai-readiness-package`. Empty disables mirroring — the package stays under `<package_output_root>/<org>-<repo>/<date>/` only. Set this to a directory reachable from this environment (a mounted share, a synced folder) to also copy the package there. |
| `token_map` | `~/.claude/plugins/data/crew/token-map` | Path to the per-org GitHub token map (see `token-map.example`). |
| `org_allowlist` | `[]` (empty) | GitHub orgs where the contract's instruction-file rule applies (judge only GitHub Copilot instruction surfaces, never mention `AGENTS.md`/`CLAUDE.md`). Empty = the rule is off. |

## Limitations

- **`context-legibility-audit` is not included in this plugin.** It shipped as an
  employer-specific Phase 0 skill in the source install this plugin was extracted
  from. `agentic-readiness` and `ai-readiness` still list it in the eight-audit
  suite and its owned predicate (`docs-mislead`); if its skill or reports are
  unavailable, both mark that predicate `UNKNOWN — not installed` rather than
  treating the roll-up as a failure. Install a compatible `context-legibility-audit`
  skill alongside this plugin to restore full coverage.
- **The `allowed-tools` write permission is not config-aware.** Every skill's
  `allowed-tools` includes a literal `Write(~/repo-audits/**)` — Claude Code's
  permission syntax cannot reference a config value or environment variable, so
  this cannot be generated from `audit_output_root`. If you set `audit_output_root`
  to anything other than `~/repo-audits`, you must also edit that `Write(...)` line
  in every `skills/*/SKILL.md` file (and in `ai-readiness/SKILL.md`, which adds
  `Write(~/repo-audits/**)` too) to match, or writes will be denied.
- Wrapper scripts resolve their own directory through **one level** of symlink
  (no `readlink -f`, for bash 3.2 compatibility). A symlink whose target is itself
  a relative symlink, or a chain of more than one hop, is not supported —
  `repo-audit-install-wrappers` always creates direct, absolute-target symlinks, so
  this only matters if you construct your own PATH shims differently.
- Nothing in this plugin executes project code, writes to a target repository, or
  performs GitHub writes. See `contract.md` § Safety rules for the full read-only
  guarantee.

## Tests

`tests/run.sh` runs frontmatter lint on every `SKILL.md`, `bash -n` on every `bin/`
script, a functional check that each wrapper resolves `_auth.sh` and the vendored
config library through a symlink, the vendored-library identity check (if the
canonical `scripts/check-vendored-libs.sh` is present in this checkout), and the
repository's scrub-check for employer/internal-path hygiene (if
`scripts/scrub-check.sh` is present).
