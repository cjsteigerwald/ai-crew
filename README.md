# claude-crew

A Claude Code plugin marketplace (`cjs-plugins`) hosting two complementary
delegate-agent packs:

| Plugin | Models | What it gives you |
|---|---|---|
| **claude-crew** | Haiku / Sonnet / Opus | Tiered Claude delegate agents (scout / reader / implementer lanes) so delegated subagent work stops inheriting the expensive session model |
| **codex-crew** | GPT-family (luna / terra / sol / astra) | Codex implementer lanes and a read-only reviewer, for cross-model implementation and adversarial review |
| **crew-gates** | N/A | PreToolUse gates that make an orchestrator delegate to cheaper lanes: delegation-gate, read-budget-gate, lane-model-gate, plus a per-prompt routing table |
| **harness-skills** | N/A | Crew configuration writer and the ai-crew-update plugin updater/reconciler. |
| **tech-research** | Varied | Interrogative, evidence-tiered research protocol for technology and vendor decisions, with seven specialised research agents |
| **repo-audit** | Haiku | Read-only repository audit suite: seven audit skills, an agentic-readiness roll-up, and an ai-readiness orchestrator, with sandboxing wrappers for gh and git |
| **dev-workflow** | Varied | Engineering workflow skills (PR gates, orchestrated plan implementation, incident investigation and write-ups, skill retrospectives, Copilot readiness) plus verifier, adversarial reviewer, worker, and specialist review agents |

Installing a plugin does not remove any same-named personal skill in `~/.claude/skills`; plugin skills are namespaced (`<plugin>:<skill>`) and the personal copy keeps the bare name.

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

## Update

```bash
# 1. refresh the marketplace catalogue (all marketplaces if no name given)
claude plugin marketplace update cjs-plugins

# 2. pull the new plugin versions
claude plugin update claude-crew@cjs-plugins
claude plugin update codex-crew@cjs-plugins

# 3. codex-crew wraps the official Codex plugin — update that too
claude plugin update codex@openai-codex
```

⚠️ **Restart Claude Code afterwards. Nothing takes effect until you do**, and the
CLI says so itself — `claude plugin update` prints *"restart required to apply"*.

Installs are **version-keyed**: each version unpacks into its own directory and
the old ones stay put, so a running session keeps calling the path it resolved at
startup for its whole life. Update mid-session and you are still running the old
version while `claude plugin list` reports the new one — the update succeeded and
did nothing, with nothing to indicate it.

**Opening a new session is enough** — a session started after the update resolves
the new version itself. See
[`codex-crew/README.md`](codex-crew/README.md#update) for how to confirm which
version is live — including checks that work from an ordinary terminal, and why
the `crew-codex` one does not.

## Contributing plugins

This repository is **public**. Before adding or editing any plugin:

- Run `scripts/scrub-check.sh <changed paths>` and confirm it exits **0**
  (exit **4** means the scan is clean of denylist hits but found dangling
  `[[wikilink]]` references in a `*.md` — a warning, not a hard failure).
  It denylists **generic** classes only — home paths, RDP-share paths,
  UUIDs and credential shapes — because this file, and everything beside
  it, is published. It is fail-closed: a target path that doesn't exist, a
  temp-directory failure, or a `grep` failure aborts with exit **2** rather
  than silently scanning nothing. A deliberate, reviewed exception goes in
  an `--allow` file next to the scan, never a silent tweak to the scanner
  or a filename exclusion.
- **Organisation-specific terms must never be committed to this repo** —
  not in a script, not in a test fixture, not in the denylist itself. A
  denylist that spells out the employer names, internal hostnames, ticket
  prefixes, system code names and personal handles it hides *publishes
  exactly those strings*. They live in a **private denylist** outside the
  repository:

  ```
  ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/data/crew/scrub-denylist.txt
  ```

  Override the path with `$SCRUB_DENYLIST`. The format is one entry per
  line, three TAB-separated fields — `<name><TAB><flags><TAB><POSIX-ERE>`,
  where `flags` is `i` for case-insensitive or `-` for case-sensitive — and
  [`scripts/scrub-denylist.example.txt`](scripts/scrub-denylist.example.txt)
  ships the shape with **synthetic entries only**. Copy it to the path
  above and fill in your own terms *there*.

  Both scanners load the generic classes **plus** the private file. If the
  private file is absent they print
  `scrub: no private denylist at <path> (generic classes only)` once on
  stderr and continue; pass `--require-private` to make that exit **2**
  instead. A file that *exists but defines no entries* fails
  `--require-private` the same way (`private denylist has no entries`) —
  "the file is there" is exactly the false assurance the flag exists to
  prevent.

  Run the scan **locally with `--require-private`** before you push. The
  plain CI run is the generic classes only and **is not identity
  enforcement**; treat a green CI as saying nothing about employer names or
  handles. CI enforces them once the maintainer sets the repository
  secret **`SCRUB_DENYLIST_B64`** (the private denylist, base64-encoded):
  the `Scrub check with the private denylist` step decodes it into a temp
  file, runs `--require-private --check-allowlist`, and deletes it, never
  echoing the plaintext. GitHub does not expose secrets to pull requests
  **from forks**, so on a fork PR that step is **skipped** outright; on
  every other event a missing secret **fails** the job with
  `SCRUB_DENYLIST_B64 not configured`. A step that passed while enforcing
  nothing would be worse than no step at all — a green check asserting an
  identity scan that never ran — so there is no such branch. The local
  pass remains the real gate.
- `--allow` entries are `<pattern-name>:<path-regex>[:<match-regex>]`. The
  optional third field scopes an exception to a **value** rather than a
  whole file: the hit is allowed only if deleting every `<match-regex>`
  occurrence from the line leaves nothing the denylist pattern still
  matches, so a second, different secret — even on the same line — still
  fails **provided the third field names the value it excuses**. A
  wildcard there (`.*`, `[A-Z0-9]+`) deletes every secret on the line
  before the re-match, and the scan itself cannot tell that apart from a
  tight regex. For the credential-shaped classes — `secret-shape` and
  `home-path` — the third field is **required**: a bare path there excuses
  every present *and future* value of that class in the file. Run
  `scripts/scrub-check.sh --allow scripts/scrub-allow.txt --require-private --check-allowlist .`
  to list `unused-allow:` entries that suppressed nothing,
  `unscoped-allow:` entries missing that required third field, and
  `wildcard-allow:` entries whose third field is broad enough to swallow a
  freshly generated value of its own class — that last one is a canary
  test, and it is the only thing standing between the value-scoping
  promise above and a blanket exemption wearing careful syntax. All three
  are a failure, not clutter. **An allowlist that has never been linted
  carries no value-scoping guarantee.** The exemption an allow file gets
  for its own third fields is bound to the pattern being scanned, too: an
  entry named for one class never excuses a value during another class's
  scan.
- Before a **release** (publishing a private history, adding a mirror/fork
  remote, etc.), also run `scripts/scrub-history.sh --require-private` from
  inside the repo. `scrub-check.sh` only sees the working tree as checked
  out now; `scrub-history.sh` runs the same pattern table over
  `git log --all -p -m` — every ref, every parent of every merge, every
  diff line — so a secret or internal name that was committed and later
  deleted still gets caught. It exits **4** when a blob could not be
  text-scanned at all (binary, UTF-16, any NUL-containing blob), listing
  each as `unscanned-binary: <path> (commit <sha>)` for manual inspection;
  its header comment documents what the scan cannot see. It's a separate,
  heavier pass, not wired into any plugin's test suite; run it by hand.
- For content that exists **only in git history** (already-published
  commits, not the working tree), the exception goes in a **private**
  history allowlist — never in this repo. Excusing such content means
  naming it, the entry can never expire, and a committed file naming it
  re-publishes exactly what the denylist exists to hide:

  ```
  ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/data/crew/scrub-allow-history.txt
  ```

  Override with `$SCRUB_ALLOW_HISTORY`;
  [`scripts/scrub-allow-history.example.txt`](scripts/scrub-allow-history.example.txt)
  ships the shape with **synthetic entries only**. `scrub-history.sh`
  concatenates `scripts/scrub-allow.txt` with that private file (and warns
  `scrub: no private history allowlist at <path>` when it is absent).
  Neither scanner reads a `scripts/scrub-allow-history.txt` **inside** the
  repository: that path is ordinary content, scanned like any other file
  and listed in `.gitignore`. It used to be registered as an allow file by
  fixed name, which exempted its third fields from `scrub-check.sh` while
  nothing ever read them — real values parked there were invisible to the
  scan and staged for the next `git add -A`.
- **Allow files are scanned, field by field — never skipped.** Skipping
  them wholesale would make them a laundering channel: park a credential in
  a comment of `scrub-allow.txt` and no scanner would ever look at it
  again. An allow file (anything passed to `--allow`, plus
  `scripts/scrub-allow.txt` by fixed name under a scanned root) is read
  line by line, and **only the third field — the match-regex — of an entry
  line is exempt**, and only during a scan of the pattern that entry
  itself names, because that field necessarily spells out the value it
  excuses. Comments, blank lines, two-field entries, and the name and path
  fields of every entry are scanned exactly like any other file.
  `scrub-history.sh` applies the same rule to diff hunks touching those
  paths. The **private denylist** is a different thing and is not an allow
  file: if it resolves inside a scanned target, `scrub-check.sh` exits
  **2** rather than excluding it and carrying on.
- Each plugin that needs `lib/crew-config.sh` **vendors its own copy** rather
  than referencing a sibling path — plugins install and version
  independently, so a cross-plugin relative path would break on install.
  `scripts/check-vendored-libs.sh` asserts every vendored copy stays
  byte-identical to the canonical copy at `lib/crew-config.sh`; run it after
  touching the canonical file.
- All shipped shell scripts must run under **bash 3.2** (macOS's stock
  `/bin/bash`): no associative arrays, no `mapfile`, no `${var,,}` /
  `${var^^}`.

## Requirements

**claude-crew** — none beyond Claude Code itself: no external CLI, no runtime,
no Node. The agents are pure native subagent definitions; the `model:`
frontmatter pin is the entire mechanism.

**codex-crew** — the official Codex plugin (`/plugin install codex@openai-codex`),
the Codex CLI installed and authenticated (`codex login`), and Node.js. Its
`bin/crew-codex` wrapper must also be on `PATH`.
