---
name: ai-crew-update
description: >
  Updates every installed Claude Code plugin from the configured crew
  marketplaces (read from each marketplace.json, so new plugins are covered
  automatically) plus the wrapped vendor codex plugin — syncs each local
  checkout to origin/main, runs each plugin's local test gate, refreshes the
  marketplace catalogues, installs the new versions, reconciles the user's
  settings.json / CLAUDE.md against what is installed, verifies every install
  actually landed, and flags the required restart. Use when the user says
  "update ai-crew", "update codex-crew", "update claude-crew", "update the plugins",
  "new codex-crew version", "bump codex-crew", "install the latest crew plugins",
  "is codex-crew up to date", or "is claude-crew up to date". Skip when moving a
  plugin between marketplaces or retiring a dead marketplace (see
  moving-plugin-marketplaces instead), authoring a plugin's own code, or doing a
  first-time install with no prior version.
---

# ai-crew Update

Update every plugin in every configured crew marketplace, plus the vendor
`codex@openai-codex` plugin that codex-crew wraps, end to end — then repair the
user's own configuration so the newly installed code is what actually runs.

**The plugin list is never hardcoded.** Every step enumerates each marketplace's
`.claude-plugin/marketplace.json` → `.plugins[]`. A plugin added to a repo is
picked up by every step without editing this skill. The vendor plugin is the one
explicit addition, because it lives outside the crew marketplaces.

**Running the script.** All mechanical steps live in `ai-crew.sh` beside this
file. When this skill runs from an installed plugin, invoke it as
`"${CLAUDE_PLUGIN_ROOT}/skills/ai-crew-update/ai-crew.sh"` — the harness sets
`CLAUDE_PLUGIN_ROOT` to the plugin's install directory. When running from a
checkout of the repo instead, use the script's own path in that checkout. The
commands below are written in the plugin form; substitute the checkout path when
that is where you are.

Every subcommand fails closed: if it cannot check something (missing file,
unparseable JSON, wrong shape, a marketplace entry with an invalid name or
source) it exits nonzero with an explicit message. It never prints success after
checking nothing. Run the subcommands below; do not hand-roll the loops. The
script's fixture suite is `test-ai-crew.sh` in the same directory, and it must
pass (`RESULT: N passed, 0 failed`) after any edit to the script.

All defaults hang off ONE config root, `${CLAUDE_CONFIG_DIR:-~/.claude}` —
`installed_plugins.json`, the marketplace clones, the plugin cache, the
snapshots and receipts, `settings.json` and `CLAUDE.md`. Setting
`CLAUDE_CONFIG_DIR` moves all of them together; nothing is left pointing at
`~/.claude`.

## Marketplace configuration

`ai-crew.sh` iterates a LIST of marketplaces. The list is resolved in this
order, first match wins:

1. `$AI_CREW_MARKETPLACES` — `name=repo-path;name=repo-path`.
2. The crew config file
   `${CLAUDE_CONFIG_DIR:-~/.claude}/plugins/data/crew/config.json`, key
   `marketplaces`: an array of `{"name": ..., "repo": ...}`. A leading `~` in
   `repo` is expanded. A config file that exists but is malformed is an ERROR,
   never a silent fall-back to the default.
3. The single default `cjs-plugins` → the marketplace repo path from config
   (`$AI_CREW_REPO`, default `~/repos/ai-crew`).

Derived paths: the DEFAULT marketplace (`cjs-plugins`) keeps the historical
single-marketplace file names, so a default install behaves exactly as before.
Every other marketplace `<name>` gets siblings keyed by name — clone
`<marketplaces-dir>/<name>`, receipt `gate-receipt.<name>.json`, snapshot
`pre-update.<name>.json`.

When `${CLAUDE_CONFIG_DIR:-~/.claude}/plugins/known_marketplaces.json` exists it
is cross-checked: a configured marketplace absent from it prints a WARNING (it
may simply not have been added to Claude Code yet) and does not fail anything.
`status` additionally lists any marketplace that appears in
`installed_plugins.json` but in no configured marketplace — this procedure
cannot gate what it was never told about.

The vendor `codex@openai-codex` is enumerated ONCE, with the first marketplace in
the list, not once per marketplace.

## Selective-install contract

A marketplace catalogues more plugins than any one user installs. The target set
therefore differs by step, deliberately:

- **`gate` and `bind` cover the whole catalogue** of each marketplace. That is
  release validation: an untested plugin in the catalogue is a defect even if
  nobody here has installed it.
- **`snapshot`, `update`, `verify` and `reconcile` cover only the plugins
  present in `installed_plugins.json`.** A catalogued plugin that is not
  installed prints `skip: <name>@<marketplace> not installed` — INFO, not a
  failure. There is nothing to update, no baseline to roll back to, and nothing
  to verify. Installing it later is picked up automatically on the next run;
  no configuration changes.
- **`status` lists both sets**, ending with
  `status: N catalogued, I installed, S not installed`.

## When to Use This Skill

- "update ai-crew", "update codex-crew", "update claude-crew", "update the plugins"
- "new codex-crew version", "bump codex-crew", "install the latest crew plugins"
- "is codex-crew / claude-crew up to date"

## When *Not* to Use This Skill

- Moving a plugin between marketplaces, or retiring a dead marketplace —
  that's the `moving-plugin-marketplaces` skill.
- Authoring or changing a plugin's own code — that's normal repo work in the
  marketplace repo, not an update.
- First-time install with no prior version — there's nothing to verify a
  bump against. (A plugin newly added to a marketplace shows as
  `NOT INSTALLED` in the status check; install it with
  `claude plugin install <name>@<marketplace>`, not with this procedure.)

## Status check (no persistent writes)

Answers "is it up to date" for every catalogued plugin without changing
anything that outlives the run. Like `verify` and `reconcile --dry-run`, it
makes **no persistent or configuration write** — it touches neither
`settings.json`, `CLAUDE.md`, the snapshots, the receipts nor the
acknowledgement list — but it is not write-free: it stages its analysis in a
temp directory (`$TMPDIR`, or `/tmp`, created 0700), so it needs a writable
TMPDIR. A `SIGKILL` mid-run can leave an `ai-crew.XXXXXX` directory there.
```
"${CLAUDE_PLUGIN_ROOT}/skills/ai-crew-update/ai-crew.sh" status
```
It prints a `== marketplace <name> (<repo>)` banner per marketplace, then
`<name>  installed=<v|NOT INSTALLED>  available=<v>` for each plugin, plus a
`vendor codex@openai-codex` row, the `skip:` lines for catalogued-but-not-
installed plugins, the counts line, any unconfigured marketplace, and finally
`reconcile: needed|clean` (see step 3.5). A plugin missing from
`installed_plugins.json` is `NOT INSTALLED`. An unreadable or invalid
`installed_plugins.json`, or a missing manifest, is an ERROR (exit 1). The
script keeps those two cases separate. For why the jq reads `.plugins[<key>][0]`
and uses `-e`, see the header comment in `ai-crew.sh`. In short, each entry is
an array, and a jq path without `-e` prints `null` and exits 0, so a broken
check reads as a successful one.

A marketplace clone's `.version` may itself be stale until
`claude plugin marketplace update <name>` is run. This check does not run it, so
treat a match as "up to date as of the last refresh," not an absolute guarantee.
The same holds for the vendor row's `available`: it is read from the vendor
marketplace clone as of its last refresh. Whether a newer vendor version exists
is decided by `claude plugin update` in step 3.

## Procedure

0. **Sync each local checkout to what will actually be installed.**
   ```
   git -C <marketplace repo path> fetch origin
   git -C <marketplace repo path> status -sb
   ```
   For every configured marketplace repo. Each must be on `main`, clean, and not
   behind `origin/main`. A marketplace clone under
   `~/.claude/plugins/marketplaces/<name>` is its own git clone of `origin/main`
   on GitHub — it does NOT read the local checkout. Testing a feature branch, a
   dirty tree, or a checkout behind `origin/main` means testing code that is not
   what gets installed. Uncommitted or unpushed work is never installed, no
   matter how green the local suite is.

1. **Gate — never install before every suite passes.**
   ```
   "${CLAUDE_PLUGIN_ROOT}/skills/ai-crew-update/ai-crew.sh" gate
   ```
   For each marketplace it enumerates the LOCAL repo's marketplace.json and runs
   each catalogued plugin's `tests/run.sh` from the repo root — installed or
   not. A `run.sh` that exists but is not a regular executable file is a FAIL,
   not a skip. Requirement: exit 0 with a per-marketplace summary
   `gate: plugins=N suites_run=R ungated=U failed=0`, where `R + U = N`. Each
   suite's own final line should also show `0 failed` (form:
   `463 passed, 0 failed, 0 skipped`). Do not hardcode a passing count, because
   suites grow.
   - **Gate receipt, one per marketplace.** Every gate run first deletes ALL
     existing receipts. Only a fully passing run on a **clean** tree writes a
     new one, atomically, to `gate-receipt.json` (default marketplace) or
     `gate-receipt.<name>.json` beside the snapshot:
     `{repoHead, marketplaceSha256, marketplace, targets, suitesRun, ungated, ts}`.
     A dirty tree fails the gate even when every suite passed, because the
     tested code is not HEAD and so is not what installs. A HEAD that moved
     while the suites ran fails it too ("HEAD moved during the run"). The
     receipt records the HEAD captured before the suites started. `update`
     refuses to run without a receipt per marketplace matching that
     marketplace's bound HEAD and its clone's marketplace.json (step 3).
   - **Secret scrub.** If a marketplace repo ships `scripts/scrub-check.sh`, the
     gate runs it (`--require-private`, plus `--allow scripts/scrub-allow.txt`
     when that file exists, honouring `$SCRUB_DENYLIST`) and a finding — exit 1
     or 2, or any code other than 0 and 4 — fails the gate with no receipt,
     because a secret that reaches a published marketplace cannot be recalled by
     a later commit; exit 4 is reported as a warning and does not fail, and a
     repo without the script prints `scrub: ... (skipped)`. The outcome is
     recorded in the receipt as `scrub: pass|warn|absent`.
   - **Report every `NO TEST SUITE — installs UNGATED` line to the user.** It
     is not a failure, but it means that plugin's changes reach the install
     with nothing having tested them.
   - If a marketplace repo has no CI workflows, these local suites are the ONLY
     gate — there is no CI backstop.
   - Safe to run concurrently: codex-crew's suite uses a throwaway
     `CLAUDE_CONFIG_DIR` and never touches the real `~/.claude`. A new
     plugin's suite has not been audited for this — read its header before
     running it alongside other sessions.

2. **Refresh the marketplace catalogues, then bind them to what you tested.**
   ```
   claude plugin marketplace update <each configured marketplace>
   claude plugin marketplace update openai-codex
   "${CLAUDE_PLUGIN_ROOT}/skills/ai-crew-update/ai-crew.sh" bind
   ```
   Every refresh must succeed. If any exits nonzero, stop. The vendor refresh is
   what makes `verify`'s vendor check meaningful: the vendor is checked against
   the refreshed `openai-codex` marketplace clone. `bind` then confirms the
   refresh actually pulled the commit you just tested, for EVERY marketplace.
   This is what binds tested code to installed code; skip it and the gate above
   proves nothing. Per marketplace it requires all of the following, printing
   each check:
   - `git status --porcelain -uall` is empty in both the local repo and the
     marketplace clone.
   - Both HEADs are equal.
   - Both `.claude-plugin/marketplace.json` files are byte-identical.

   If any check fails, that marketplace's refresh didn't land or its local
   checkout drifted. Re-sync (step 0), re-run the gate (step 1), and refresh
   again. Do not proceed to step 3 on a failure. `update` re-runs `bind` itself
   and refuses to proceed if it fails.

3. **Update the plugins.** First record the pre-update state. Step 4 needs it
   to tell a no-op from a failure, and it is the rollback target:
   ```
   "${CLAUDE_PLUGIN_ROOT}/skills/ai-crew-update/ai-crew.sh" snapshot
   "${CLAUDE_PLUGIN_ROOT}/skills/ai-crew-update/ai-crew.sh" update
   ```
   `snapshot` writes `{key: {version, gitCommitSha, installPath}}` for every
   INSTALLED plugin of each marketplace (plus the vendor) to that marketplace's
   snapshot file; catalogued-but-not-installed plugins are reported as `skip:`
   and simply absent. An installed entry missing `version`, `gitCommitSha` or
   `installPath` makes `snapshot` refuse to write.
   `update` then does the following, in order, aborting with exit 1 at the
   first failure:
   - Takes one exclusive non-blocking lock on `update.lock` beside the default
     snapshot, covering every marketplace (they all write the same
     `installed_plugins.json`). `flock` is used when installed; on a host
     without it (stock macOS) an atomic `mkdir` lock directory is used instead,
     removed on exit. If another update holds it: `another update in progress`.
   - Re-runs `bind` for every marketplace.
   - Requires, per marketplace, the snapshot and a gate receipt whose
     `repoHead` equals the HEAD bind just confirmed and whose
     `marketplaceSha256` equals that clone's `marketplace.json`.
   - Records the bound clone HEAD and the vendor clone HEAD in each snapshot
     under the reserved key `_bound`.
   - Before each `claude plugin update`, re-checks that the plugin's own clone
     HEAD still equals its bound HEAD and that its tree is still clean
     (`git status --porcelain -uall` empty). It aborts on either kind of
     drift. Each `claude plugin update` runs with the lock fd closed, so a
     lingering child process cannot keep holding the lock.

   It runs `claude plugin update <name>@<marketplace>` for each INSTALLED
   plugin, then `claude plugin update codex@openai-codex`. A failing update does
   not stop the run: it continues through the whole list and then exits 1 naming
   every failed key.
   The vendor update is not optional: `codex-crew` wraps the official Codex
   plugin, so updating only the crew plugins leaves the vendor runtime behind.
   It is a separate entry because it is not in any crew marketplace.

3.5 **Reconcile — make the user's own config point at what was just installed.**
   **Dry run first, every time.** Removing hook entries is the one destructive
   thing this procedure does, and it is keyed on a script BASENAME:
   ```
   "${CLAUDE_PLUGIN_ROOT}/skills/ai-crew-update/ai-crew.sh" reconcile --dry-run
   ```
   `--dry-run` performs the whole merge and reports every action — writing
   nothing at all, no backup and no target file. **Read the
   `settings: removed legacy hook ...` lines before proceeding.** Each names the
   event, the basename and the ORIGINAL command. Every one of them carries
   PROVENANCE (below): the file is inside the plugin's own install directory,
   or hashes identical to the shipped hook, or the user recorded it. A hook of
   the user's own that merely shares a basename is never on that list — it is
   reported AMBIGUOUS and kept. Only once the list is understood:
   ```
   "${CLAUDE_PLUGIN_ROOT}/skills/ai-crew-update/ai-crew.sh" reconcile
   ```
   `update` runs this step itself after its own verify pass, so when you drive
   the procedure through `update` the dry run is the thing to do BEFORE it, not
   after.

   Plugins register their hooks through their own `hooks/hooks.json`, which the
   harness resolves against `${CLAUDE_PLUGIN_ROOT}`. A copy of the same hook
   script in `settings.json` is therefore a **double registration**: the hook
   fires twice, or — because installs are version-keyed directories — the
   settings copy keeps running the OLD version's file while the plugin runs the
   new one. Both are silent. `reconcile` is what removes them.

   For every INSTALLED plugin whose installPath carries a
   `hooks/hooks.json`, a `settings.fragment.json` or a
   `claude-md.fragment.md`, it does the following, processing plugins in
   installed order (later fragments win on identical keys):

   - **`settings.json` — hooks are REMOVED, never added.** It reads the
     plugin's `hooks/hooks.json` and collects the basename of every script it
     names (tokens of `command`, plus every element of an exec-form `args`
     array, whose basename ends `.py`, `.sh`, `.mjs` or `.js`).

     A settings.json hook entry **references** one of those scripts when one of
     its tokens — again including `args` — contains a path separator (`/` or a
     Windows `\`, which is normalised) **and** its basename equals an owned
     one. The path-separator requirement is what keeps `echo read-budget-gate.py`
     out of it: a bare word is an argument, not a script path.

     A referencing entry is **removed** only when all of the following hold:

     - **Every referencing token has PROVENANCE** — positive proof that the
       file it names is the plugin's, not the user's. Exactly three things
       count, tried in this order:
       1. **It resolves inside the plugin's own installed directory** — the
          `installPath` recorded in `installed_plugins.json` for that plugin,
          with BOTH sides symlink-resolved first. Containment is judged on the
          resolved spelling and on nothing else: a path written under the
          plugin root can still pass through a symlinked component and land on
          a file of the user's outside the plugin, and the spelling alone would
          then "prove" ownership of somebody else's hook. This is the ordinary
          case for a registration an older version of this tool wrote. The file
          itself need not still exist, but the path must be resolvable — if it
          is not (a component that does not exist, or a host with neither
          `realpath` nor `readlink -f`), this proof is simply unavailable and
          the entry falls through to 2 and 3, which keeps it unless one of them
          holds.
       2. **Its content hashes equal to the plugin-shipped hook** of that
          basename (sha256, read from the manifest's own
          `${CLAUDE_PLUGIN_ROOT}/...` path). The same file, copied or moved:
          the duplicate registration provably runs the same code. A file that
          cannot be hashed — absent, unreadable, or no hash tool installed — is
          **not proven**, never "assumed to match".
       3. **A migration record names that exact path** —
          `reconcile --record-migrated <path>`, stored in
          `<data dir>/migrated-hooks.json`, the user stating that this tool
          registered it and it may be removed. Never written by a run.

       What a path *looks like* is not proof and never was. A hook at
       `/srv/project/.claude/hooks/read-budget-gate.py` is in a directory named
       `.claude/hooks`, but it is a different file, in a different project,
       doing a different job; so is one under `<CLAUDE_CONFIG_DIR>/hooks/`.
       Those are AMBIGUOUS and are kept.
     - No token walks back out of that location. A path still containing `..`
       after normalisation — `/x/plugins/cache/../../custom/h.py` — only looks
       like a plugin path.
     - The entry is a **standalone invocation**: an optional interpreter
       (`python3`, `python`, `bash`, `sh`, `node`) plus exactly one script
       token, and nothing else. Anything that composes or takes arguments —
       `&&`, `;`, `|`, a redirection, an extra flag, or an exec-form `args`
       array with more than the script path — is a command whose meaning would
       change, not a duplicate registration being deleted.
     - The command contains no shell syntax at all: no newline, `$`, backtick,
       `(`/`)`, `{`/`}`, `[`/`]`, `*`, `?` or `!`, no `~` anywhere but the
       start of a token, and no backslash outside a Windows path. This is not a
       shell parser — it is a refusal to touch anything that would need one, so
       `$(touch${IFS}/tmp/x)/.claude/hooks/h.py` is kept and reported, never
       rewritten.

     Reported as `settings: removed legacy hook <event>/<basename> (<command>)`.

     A referencing entry that fails any of those — `python3 /custom/x.py`,
     `python3 ~/.claude/hooks/x.py && /opt/audit.sh`, or a project hook that
     merely shares a basename — is **kept**, and reported with the REASON it was
     kept:
     `settings: AMBIGUOUS legacy hook <event>/<basename> (<command>) (kept;
     <reason>; remove by hand, or acknowledge it)`, followed — when the reason
     is unproven provenance — by the `reconcile --record-migrated '<path>'`
     remedy that removes it instead.
     The reason is one of:
     - `basename matches a plugin hook but provenance is unproven — the path is
       not inside the installed plugin's own directory, its content does not
       match the shipped hook (or could not be read), and no migration record
       claims it` — almost always a hook of the user's own. Read it before
       acknowledging anything.
     - `a path walks out of its own directory with ..` .
     - `not a standalone [interpreter] script invocation ...` — removing it
       would change what the command does.

     Which reason you get matters: an unproven-provenance entry is one you
     probably want to KEEP forever (acknowledge it), while the other two are
     usually genuine duplicates written in a form this tool will not rewrite.

     **An AMBIGUOUS entry fails `verify`.** It is a genuine double-registration
     risk that this procedure will not resolve on its own, so it needs a human
     decision, not a silent pass. Two ways to clear it: delete the entry from
     `settings.json` by hand, or acknowledge it —
     ```
     ai-crew.sh reconcile --accept-ambiguous '<event>/<basename>=<exact command>' \
       [--args '<json array>'] [--matcher '<matcher>']
     ```
     which records the exact `(event, basename, command, args, matcher)`
     identity in `<data dir>/ambiguous-ack.json`. The exec-form `args` array and
     the matcher of the group the entry sits in are both stored structurally, so
     two entries differing only in their arguments — or only in their matcher —
     cannot share one acknowledgement. Two `PreToolUse` groups with different
     matchers and the same command are two registrations, and acknowledging the
     one you reviewed must not clear the one you did not. The remedy line prints
     the matching `--args '<json>'` and `--matcher '<matcher>'` when the entry
     has them; copy it verbatim — the spec, the args JSON and the matcher are
     printed SINGLE-QUOTED (an embedded `'` as `'\''`), because every form this
     tool matches contains a space and an unquoted paste would split into
     separate words. A whole `--accept-ambiguous` argument list is all-or-
     nothing: every spec is parsed and validated before the list file is
     created or touched, so a paste that fails records nothing at all rather
     than leaving the specs before the failure behind. An omitted `--matcher` records JSON `null`,
     which matches a group with **no** matcher key and nothing else — a matcher
     of `""` is a distinct identity and needs `--matcher ''`.

     **If the entry really is one of ours** and neither of the first two proofs
     can be had — the old install directory is long gone and the file was
     edited since — record it deliberately. The UNPROVEN-PROVENANCE message
     names this remedy too, with the path quoted ready to paste, and says why
     it differs from acknowledging: `--record-migrated` lets reconcile REMOVE
     the registration, while `--accept-ambiguous` keeps it and silences it. A
     kept `plugins/cache/<old-version>/` path is the case that matters — the
     day those versions are pruned it is a hook that cannot run.
     ```
     ai-crew.sh reconcile --record-migrated '<absolute path>'
     ```
     The path is stored verbatim in `<data dir>/migrated-hooks.json` (a JSON
     array of path strings) and matched after `~` expansion; a relative path is
     refused. That file is never written by a run and never read as anything
     but a list of strings — a malformed one is an error, not a shrug. It is
     the weakest of the three proofs, because nothing about the file itself
     corroborates it, which is exactly why only the user can create it.

     **Acknowledgements recorded before the matcher became part of the identity
     no longer match anything** — an entry with no `matcher` key has an unknown
     matcher, not a known-absent one, and a matcher-less group is the broadest
     one there is. Such an entry expires: verify fails again and prints the
     remedy to re-record it, which is the safe direction. The file is created only by
     `--accept-ambiguous`: `verify`, `status` and `--dry-run` read it without
     creating anything, so they still work when the data directory is absent or
     unwritable. From then on the entry is reported
     `ambiguous (acknowledged)` and does not fail verify. The acknowledgement is
     for that exact identity only: **editing the command, the args, or the
     group's matcher invalidates it**, and verify fails again — which is the
     point, since any of those changes makes it a different hook.

     A matcher group left with no hooks is dropped, and an event left with no
     groups is dropped. **Hooks whose script no installed plugin owns are never
     touched** — the user's own hooks survive byte for byte.
   - **`settings.json` — env is set only if absent.** Each key in the
     fragment's `env` is set only when `settings.json` does not already have it,
     so an explicit user value is never overwritten. Reported as
     `settings: env <KEY> set` or `... kept`. (The fragment carries `env` only;
     it must not carry hooks.)
   - **`CLAUDE.md` block.** The fragment must contain the marker lines
     `<!-- <plugin>:start -->` and `<!-- <plugin>:end -->`. If `CLAUDE.md`
     already has that pair, the region between them (markers included) is
     replaced by the fragment; otherwise the whole fragment is appended after a
     blank line. The file is created if missing. A `CLAUDE.md` carrying one
     marker but not the other, either of them twice, or the end marker BEFORE
     the start marker is an error, never a guess — the last of those would
     otherwise swallow the file from the start marker to EOF. Reported as
     `claude-md: block <plugin> replaced|appended|unchanged`. Every plugin's
     block is rendered — and validated — before anything is written, chaining
     onto the previous plugin's result, so one broken fragment aborts the whole
     run with nothing written to either file, and the file takes one backup and
     one write however many plugins contribute a block.
   - **Backups and idempotency.** Before the first write to either file, the
     current file is copied to `<file>.bak.<UTC timestamp>`. If the merged
     result is byte-identical to what is on disk, nothing is written and no
     backup is taken — a second run reports `settings: unchanged` /
     `claude-md: block <plugin> unchanged`.
   - **Fail closed.** A `settings.json` that is not valid JSON, or a
     `hooks/hooks.json` that does not parse (we could not know what to remove),
     exits nonzero having written nothing.
   - **Concurrency.** A real run takes the same exclusive lock `update` uses, so
     two reconciles — or a reconcile and an update — cannot interleave their
     read/merge/write. (`--dry-run` makes no persistent or configuration write,
     so it does not take the lock. `update` already holds it when it calls reconcile, and does not
     re-take it.) Both files are fingerprinted when they are read and re-checked
     immediately before anything is installed: if either changed in between, the
     run aborts with `settings: changed underneath us — rerun` and writes
     nothing, because everything it computed describes a state that no longer
     exists.
   - **Symlinks are preserved.** If `settings.json` or `CLAUDE.md` is a symlink
     (dotfiles repos do this), the content is staged beside — and renamed onto —
     the final REFERENT, so no link in the chain is replaced by a regular file.
     The whole chain is followed, bounded at 16 hops with explicit cycle
     detection; a cycle or a deeper chain is an error with nothing written.

   Ends with `reconcile: ok` (or `reconcile: DRY RUN`). **The changes are not
   live yet** — see step 5. Reconcile changes files on disk; the running session
   already read them.

   Where `update` fits: after its `claude plugin update` calls succeed, `update`
   runs `verify`'s install checks, then `reconcile`, then re-runs the
   reconcile-related checks (7–9 below) once. If they still fail after
   reconciling, `update` exits nonzero — the configuration is inconsistent in a
   way reconcile cannot fix, and that needs a human.

4. **Verify the install actually landed — do not trust the success message.**
   ```
   "${CLAUDE_PLUGIN_ROOT}/skills/ai-crew-update/ai-crew.sh" verify
   ```
   **What it proves.** The final install state matches the tested, bound
   manifests: version, installPath, the payload's own manifest, and the SHA
   rule below — and that the user's config is consistent with it. It does
   **not** prove which run produced that state. For the vendor, it proves the
   install matches the refreshed `openai-codex` marketplace clone, not
   upstream's latest release.

   First, per marketplace, `verify` requires the snapshot's `_bound` record. If
   it is absent, `update` was never run for that snapshot, and verify fails. It
   also fails if that clone's HEAD no longer equals `_bound.boundHead` ("clone
   moved after bind; gate proved nothing about the installed code"), or if the
   clone's working tree is dirty ("clone modified after bind").

   Then it checks **each INSTALLED plugin** AND `codex@openai-codex`
   (catalogued-but-not-installed plugins print `skip:` and are not failures).
   Checking only one misses the others silently going stale or failing while
   the run overall reports success. For every entry it requires:

   1. The entry exists in `installed_plugins.json` and has a non-empty
      `gitCommitSha`.
   2. The installed version equals that marketplace clone manifest's `.version`
      (`<clone>/<source>/.claude-plugin/plugin.json`).
   3. `installPath` equals
      `~/.claude/plugins/cache/<marketplace>/<name>/<version>`, and that
      directory exists.
   4. The payload `<installPath>/.claude-plugin/plugin.json` exists and its
      `.version` equals the expected version. An empty or partial install
      fails here.
   5. Only if the version changed from the snapshot should `gitCommitSha`
      have moved. It is compared to that marketplace clone's current HEAD (or
      the `openai-codex` clone for the vendor), not to the local checkout's
      HEAD.
   6. **If a repo has new commits but a plugin's version is unchanged,
      `claude plugin update` correctly does nothing and `gitCommitSha` stays
      at the older commit — that is success, not failure.** `verify` reports it
      as `PASS <v> — no-op (version unchanged)`, but only if `gitCommitSha`
      still equals the snapshot's. A SHA that moved without a version change
      is a FAIL ("sha changed without a version change"). Do not loop back to
      step 2 just because `gitCommitSha` doesn't equal the local checkout's
      HEAD. That equality only holds when every commit since the last update
      bumped the version, which is not guaranteed.

   **`verify` makes no persistent or configuration write.** It never writes
   settings.json or CLAUDE.md, never takes a backup, and never repairs
   anything: it reports and fails, and the remedy is to run `reconcile` and
   verify again. It does stage its analysis in a temp directory (see the status
   check above), so it needs a writable TMPDIR. It then runs the reconcile
   checks, and FAILS on any of:

   7. A plugin's `hooks/hooks.json` is missing from the current installPath or
      does not parse (`... does not parse — reinstall <plugin>`).
   8. Any `settings.json` entry still references a script that an installed
      plugin owns. If reconcile would remove it:
      `legacy hook entries present — ... — run reconcile`. If it is AMBIGUOUS:
      `AMBIGUOUS legacy hook ... — <why it was kept>; remove by hand, or
      acknowledge with reconcile --accept-ambiguous
      '<event>/<basename>=<exact command>' [--args '...'] [--matcher '...']`,
      shell-quoted and ready to paste verbatim, with the reason (unproven
      provenance, a `..` traversal, or a non-standalone command) named first.
      Unproven provenance — and only that reason — also names
      `reconcile --record-migrated '<path>'`, the remedy that REMOVES the
      registration instead of silencing it. Both
      are failures — this is the double-registration guard, and a duplicate
      fires twice or runs old code. Only an acknowledged entry passes.
   9. A fragment-declared env var is not set in `settings.json`.

   Any failure exits 1 with every failing key listed. A snapshot that
   violates the schema fails with an `ai-crew: ERROR` message, not a raw jq
   error. The schema is: every entry is `null` or
   `{version, gitCommitSha, installPath}` strings, plus the one reserved
   `_bound` key.

   Once everything passes it prints `verify: PASS (N entries)` and the restart
   reminder. Nothing on disk has changed.

5. **Reload (or restart). This is a hard requirement, and it's silent if skipped.**
   Installs are version-keyed — each version unpacks into its own directory
   (`~/.claude/plugins/cache/<marketplace>/<name>/<version>/`) and old versions
   are left in place, never replaced. A running session resolved its plugin
   path at startup and keeps calling that directory for its whole life.
   Updating mid-session leaves the session running the OLD code while
   `claude plugin list` reports the NEW version — the update succeeded and
   did nothing, with no indication anything is wrong. The same applies to the
   settings and `CLAUDE.md` changes reconcile makes.

   What is enough depends on what changed:
   - **`/reload-plugins`** picks up hook and MCP changes — the plugin payloads,
     `hooks/hooks.json`, and the settings hook entries reconcile removed.
   - **A new session** is needed for anything the session read at startup,
     which includes `CLAUDE.md`.
   - **A full restart** is needed for environment variables (`env` in
     settings.json, e.g. `CLAUDE_CODE_SUBAGENT_MODEL`): a running process does
     not re-read its environment.

   When in doubt, open a new session — it covers every case except the env one.
   `verify` ends with this reminder. Pass it on to the user.

## Limitations

- **No rollback is documented.** Old version directories are retained under
  `~/.claude/plugins/cache/<marketplace>/<name>/<version>/`, but the manifest
  selects the new one, so retention alone is not a rollback. The pre-update
  version/sha/installPath in the step 3 snapshot gives a rollback target, but
  no uninstall/pin command has been verified — don't invent one. For the config
  side, reconcile's `.bak.<timestamp>` copies are the rollback target.
- **The updates in step 3 are not transactional.** If one plugin succeeds and
  another fails, the install is left mixed; re-run the failed one and
  re-verify rather than assuming success. Don't run this procedure from two
  sessions at once — they write the same `installed_plugins.json` (and the
  same snapshot files).
- **Take a fresh snapshot every run.** `verify` compares against whatever
  snapshot is on disk. A snapshot left over from an earlier run makes the
  no-op-vs-failure call against the wrong baseline. Taking a new snapshot
  also drops the old `_bound`, so `verify` fails until `update` has run
  against it.
- **What the chain does and does not bind.** Each receipt binds one gate run to
  one HEAD and one marketplace.json hash. `_bound` and the per-update drift
  check bind the install to that HEAD. The lock only serialises `update`
  invocations. It does not stop a second session from running
  `claude plugin update` by hand, or from running `snapshot` or `gate` and
  rewriting those files mid-run. Nothing binds the vendor to a tested state:
  it has no suite here. `_bound.vendorHead` is recorded for the audit trail
  only.
- **`verify` proves state, not provenance.** A passing verify means the
  current install matches the bound manifests. It does not show that this
  run's `update` produced that state rather than an earlier one.
- **The `mkdir` lock (hosts without `flock`) can be recovered, and recovery is
  a judgement call the script makes for you.** A LIVE holder is never displaced,
  at any age — a long update is not a dead one. The lock is reclaimed only when
  the recorded pid is not alive, or when there is still no pid file after a
  short backoff (10 × 0.2s, because the winner of the `mkdir` race writes its
  pid a moment after creating the directory, so a missing pid file is what a
  lock taken microseconds ago looks like) AND the directory is over 30 minutes
  old. Reclaiming is a RENAME, not a delete-then-create: two contenders that
  both read the same dead pid would otherwise both remove and both create, and
  the second would be destroying the first's live lock. Only one rename can
  succeed; the loser refuses without having removed anything. Recovery prints
  `lock: recovered stale lock (pid N)`. A pid can in
  principle be recycled by an unrelated process, in which case a genuinely stale
  lock is kept — the failure mode is refusing to run, not running twice.
- **A lock is released by TOKEN, never by pathname.** `update.lock.d` names a
  place, not an owner, and a pathname can change hands while a run holds it (a
  displaced contender renames the live lock away, fails to put it back, and a
  third process finds the name free and creates its own). Each claim therefore
  writes an ownership token into the directory and remembers it; release
  removes the directory only while that token is still the one on disk. If it
  is not, release removes NOTHING and warns
  `lock: <dir> no longer carries this process's ownership token` — a leaked
  directory is recoverable by hand, a deleted live lock is not.
- **Removing hook entries is the one destructive behaviour — always dry-run
  first.** `reconcile` FINDS a plugin's hooks by script BASENAME, because that
  is the only thing a legacy absolute path, an interpreter-prefixed `~` path
  and a stale older-version plugin path have in common. A basename match is
  only a candidate, never a licence to delete: an entry is REMOVED only with
  provenance (inside the plugin's install directory, content hash equal to the
  shipped hook, or an explicit `--record-migrated`). A hook the user wrote in
  `~/.claude/hooks/` named exactly like a plugin's script is therefore KEPT and
  reported `AMBIGUOUS ... provenance is unproven` — the collision that used to
  delete it no longer can.
  The trade is in the other direction, and it is deliberate: **reconcile is now
  more conservative, so entries it used to remove are kept as AMBIGUOUS**, and
  an AMBIGUOUS entry fails `verify` until a human resolves or acknowledges it.
  A genuine legacy registration whose file has been edited since, or whose old
  install directory is gone, needs `--record-migrated` (or `--accept-ambiguous`
  if the answer is "keep it"). Mitigations, in order: run `reconcile --dry-run`
  and read both the `removed legacy hook` and the `AMBIGUOUS ...` lines before
  every real run (step 3.5) — the AMBIGUOUS reason tells you which kind you
  have; give plugin hook scripts distinctive names; keep the `.bak.<timestamp>`
  copy, which is the rollback. Hooks whose basename no installed plugin
  declares are never touched at all.

## Repo-Hygiene Gotchas

- **codex-crew's UPSTREAM.md is load-bearing.** `codex-crew/UPSTREAM.md`
  records the upstream sync point (`sidkik/claude-plugins`) and the deliberate
  divergences. A port that doesn't update it hasn't finished. The `upstream`
  git remote is NOT configured in a fresh clone — remotes are per-clone and
  never travel with the repo — so add it, then confirm with
  `git remote get-url upstream` (check the URL, not just the name: a stale
  `upstream` pointing elsewhere satisfies a name-only check).

- **Merge style is mixed — "ahead N" proves nothing either way.** ai-crew has
  used both merge styles: PRs #1–#6 are true merge commits (two parents),
  PRs #7 onward are squash merges. A merged branch's SHA MAY OR MAY NOT be an
  ancestor of `main`, and `git branch -vv` reporting it "ahead N" forever
  does not mean it's unmerged. Test properly with
  `git merge-base --is-ancestor <branch> main`; if that passes, plain
  `git branch -d` is safe — git's own merge check certifies it. If it
  fails, the branch may be squash-merged or may be genuinely unmerged, and
  `-D` is unconditional and destructive — do not eyeball a content diff and
  delete it yourself. Record the SHA and stop; surface it to the user for a
  decision rather than deleting it autonomously.

- **Worktree-checked-out branches can't be deleted directly.** Remove the
  worktree first (`git worktree remove <path>`), after confirming it's
  clean with `git status --porcelain -uall`.

## References

- `${CLAUDE_PLUGIN_ROOT}/skills/ai-crew-update/ai-crew.sh` (+ `test-ai-crew.sh`)
- The marketplace repo's `README.md` § Update
- `codex-crew/README.md` § Update — has terminal-based version checks
- `codex-crew/UPSTREAM.md`
- the `moving-plugin-marketplaces` skill
