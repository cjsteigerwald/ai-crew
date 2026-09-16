# crew-gates

PreToolUse gates that make an orchestrator delegate to cheaper lanes instead of doing
everything itself, plus a UserPromptSubmit hook that keeps the routing policy in front
of the model every turn. All four hooks fail open: a broken gate must never brick a
session. The two PreToolUse edit/read gates (`delegation-gate.py`, `read-budget-gate.py`)
never fire inside a subagent, while `lane-model-gate.py` and `routing-table.py` apply to
the main session's Agent dispatches and prompts.

## Hooks

| Hook | Fires on | What it does |
|---|---|---|
| `delegation-gate.py` | PreToolUse, `Edit\|Write\|NotebookEdit\|Bash` | Blocks an edit/write (including a file-writing Bash command) until the transcript carries a classification token since the last genuine user message. |
| `read-budget-gate.py` | PreToolUse, `Read\|Grep\|Glob\|Bash` | Caps inline bulk reading in the main session (call count + byte total, plus a one-call overdraft) since the last task boundary — a user message, a slash command, or a `Skill` launch. |
| `lane-model-gate.py` | PreToolUse, `Agent\|Task` | Denies dispatching the frontier-tier model to any lane except the configured verifier lane, and denies `model: opus` without an `escalate:` reason. |
| `routing-table.py` | UserPromptSubmit | Injects a compact routing table (lane names, disqualifiers, evidence rules) into context every turn, so the policy doesn't rely on a large doc the model has to remember to read. |

### Classification tokens (`delegation-gate.py`)

After every genuine user message, before the first edit, the transcript must carry one
of:

- `dispatching <lane>` — work was routed to a subagent lane. Must be line-initial or
  arrow-preceded and name an actual lane (`dispatching my-scout-lane`,
  `mechanical -> dispatching my-writer-lane`). Passing mentions of the word do not count.
- `solo: D<n>` — kept inline, citing exactly one disqualifier:
  - **D1** single file, under ~40 changed lines
  - **D2** files share mutable state or a contract changing in this task
  - **D3** needs live cloud reads (kubectl/az/aws/gcloud/terraform) interleaved with edits
  - **D4** needs a user decision mid-task

Also accepted: a Bash tool call whose command is exactly `:` and whose `description` is
the token, run on its own with a non-error result, edit made in a later step. This
recovers sessions where mid-turn assistant text is not persisted at hook time.

Bash is covered too, but only commands that write a file need a classification.

**Detected as writes:**

- Output redirections, spaced or not: `>`, `>>`, `>|`, `&>`, `&>>`, `>&FILE`, `<>`
  (including on a line that starts a heredoc). `2>&1`, `>&2`, `1>&-` and `>(cmd)` are
  not writes.
- A heredoc script body that calls a file-write API (`open(..., "w")`, `.write(`,
  `write_text`, `writeFileSync`, `shutil.copy`/`move`, `os.replace`/`rename`/`remove`).
  Heredoc terminators match bash: `<<EOF` ends only on a line that is exactly `EOF`,
  `<<-EOF` strips leading tabs only. `<<<` is a herestring, not a heredoc, and a `<<`
  inside quotes or a `# comment` opens nothing.
- A heredoc read as a script by a shell (`bash <<EOF`, `sh -s <<EOF`, `cat <<EOF | sh`),
  analysed like top-level shell text.
- Command substitutions (`$(...)`, backticks) inside `[[ ]]`, `(( ))`, and `$(( ))`,
  analysed like top-level shell: `[[ -n $(echo x > f) ]]` is a write.
- These commands in command position, including behind `sudo`/`env`/`nice`/`time`/
  `timeout`/`nohup`/`command`/`builtin`/`exec`/`xargs` (their options are skipped) and
  after `find -exec`/`-execdir`/`-ok`/`-okdir`: `tee FILE`, `dd of=`, `sed -i` (also
  `-i.bak`, `-Ei`, `--in-place`), `perl -i` / `ruby -i` (the flag must really be set, not
  just a letter `i` somewhere in `-MFile::Find`), `cp`/`mv`/`install`/`ln` (`-t DIR` /
  `--target-directory` honoured), `rsync` (the destination plus `--log-file`,
  `--write-batch`, `--only-write-batch`, and `-T`/`--temp-dir`/`--backup-dir`/
  `--partial-dir`), `touch`, `truncate`, `patch` (not `--dry-run`), `git apply` (not
  `--check`/`--stat`), `curl -o`/`-O` and its side files (`-D`/`--dump-header`,
  `-c`/`--cookie-jar`, `--trace`, `--trace-ascii`, `--stderr` (`-` is stdout for these),
  and `--etag-save`/`--hsts` (`-` is a file named `-`; an empty `--hsts ""` is
  in-memory)), `wget` (`-O`, or cwd/`-P`; also `-o`, `-a`, `--save-cookies`,
  `--warc-file`), `tar -x` (`-C` or cwd), `unzip` (`-d` or cwd).
- A wrapper's own output file: `time -o FILE` / `--output=FILE`.

**Never gated:** the `:` marker, and read-only commands, including `[[ a > b ]]`,
`[ a \> b ]`, `(( 3 > 2 ))`, quoted `>` (`awk '$1 > 5'`), a `>` inside an unquoted
`# comment`, `dd` without `of=`, `tee` with no file or only `/dev/null`, `sed`/`perl`
without an in-place flag, `curl`/`wget` to stdout, `tar -t`, `unzip -l`, and
`git apply --check`.

**Exemption rule:** a write passes only when every destination resolves (relative paths
against the payload `cwd`, `..` collapsed) to an absolute path under `/tmp`,
`/private/tmp`, `/var/tmp`, `/dev/`, or `$CLAUDE_CONFIG_DIR` (default `~/.claude`)
followed by `/projects/` or `/_backups/`. A destination that cannot be resolved (it
contains `$`, a backtick, or a leading `~`, or is relative with no `cwd`) is never
exempt, so such writes are gated. So is a write whose destination is unknown, such as a
heredoc script with no path literal, or `xargs touch` reading its files from stdin. A
heredoc script counts as exempt only if every path-like string literal in it is exempt.
A Bash payload never gets the Edit/Write `file_path` exemption.

**Known limits (not detected):** writes inside `python -c`, `node -e`, `awk`, `eval`, or
`sh -c` / `bash -c` / `zsh -c` strings (including `find -exec sh -c '...'`), and in
helper scripts or shell functions/aliases that write for the command; writes in a quoted
command substitution (`"$(cmd > f)"`); destinations reached through a symlink (paths are
compared lexically, with no realpath containment check); `tar -c`/`-f` archive
creation, `sort -o`, and `find -delete`/`-fprint`; `scp`, `sftp`, and `dd`/`cat` run
over `ssh` (not treated as writers); a command wrapped in literal `[[ ` ... ` ]]` words
on one line (`echo [[ ; cp a src/b ; ]]` is read as one `[[ ]]` span, so the `cp` is
missed); a `#` after whitespace inside `${...}` (`${x:- # } > f` is read as a
comment, hiding the redirect); an arithmetic shift written `<<WORD` (`(( a<<b ))`) is
read as a heredoc opener and hides the lines after it; and a command substitution
nested deeper than four levels inside `[[ ]]`/`(( ))`, a `find -exec` nested deeper than
eight, or a shell-fed heredoc nested deeper than eight is not analysed further (it is
treated as an unknown destination, so gated); a line with more than 64 heredoc openers
is likewise treated as an unclassifiable write, so gated.

**Known false blocks:** any heredoc body is scanned for write APIs regardless of the
command consuming it, so `cat <<'EOF'` that merely displays code containing
`open(..., 'w')` is gated; a `>` in a parameter expansion (`${VAR:->}`) reads as a
redirect; a relative `rsync` `--temp-dir`/`--backup-dir`/`--partial-dir` (which rsync
resolves against the destination) is treated as unknown and gated; `ls;# > f` (a
comment not preceded by whitespace) still reads the `>`; `cd DIR && <relative write>`
resolves the write against the payload `cwd`, not `DIR` (`cd /tmp && echo x > a.py` is
gated); a read-only command nested five `[[ $( ... ) ]]` levels deep is gated as an
unknown destination. **Known asymmetry:** the Edit/Write path still uses an unanchored substring test (`/.claude/projects/` anywhere
in `file_path`), while Bash destinations are anchored to the real config dir.

### Read budget (`read-budget-gate.py`)

Default budget: 8 counted read calls or ~35 KB of read output since the last task
boundary. A `solo: D<n>` classification in the window raises the tier to 25 calls /
100 KB — `dispatching` does not, because the lane does the reading, not the orchestrator.

The pairs are calibrated against measured local history (193 transcripts, 1070 windows,
4233 read results classified by the hook's own `is_read_shaped`): per-result size median
858 chars and mean 1909, with 66% at or under the 1500-char threshold and therefore free;
per window, counted calls median 1 / p95 5 / p99 11 and read bytes median 2806 / p95
31638 / p99 60986. Against that corpus the old default (3/20000) interrupted 13.6% of
windows with the CALL cap binding first, leaving the byte cap vestigial; 8/35000
interrupts 4.4% with the BYTE cap binding first (4.0% vs 2.0%), which is the intended
order since bytes are what cost context. Solo at 25/100000 clears the p99 window while
still being a real ceiling: it binds 0.2% of windows, where 40/150000 bound 0.1% —
i.e. nothing.
The corpus is censored (it was produced under the old gate, so blocked and delegated
reads are absent and true demand is higher), so re-measure before retuning.

**One-call overdraft.** The small-read exemption is decided from a result that does not
exist yet at PreToolUse time, so at the cap even a 50-byte read used to be blocked before
it could prove itself small. Exactly one call is therefore allowed past the CALL cap. It
is charged normally: if it came back large the next call hard-blocks, and if it came back
small it cost nothing and the overdraft is available again — so at most one oversized
read slips through per block, and two consecutive large overdrafts are impossible. The
byte cap has no overdraft. This is also what lets the small local commands that set up an
(ungated) cloud command through — `command -v tilt`, `cat tilt_config.json`, `tail -40
<logfile>` — with no second exemption mechanism.

**Known limits of the byte cap.** It is *retrospective*: a result's size is only known
once it lands, so the cap blocks the NEXT call rather than the one that overshot it. A
parallel batch is admitted before any of its results land, so a window can exceed the cap
by up to one full batch, and the raised caps amplify that worst case proportionally.
Statically exempt Reads (memory files, files under 4 KB, re-reads after an edit) return
before the byte check, so they are not bounded by it at all. Relatedly, a ledger file
that fails to parse is recovered by starting its entry list over, which silently discards
any in-flight reservations — the window's parallel-admission ceiling briefly doubles and
nothing is printed. All three predate the
round-4 caps and none is a regression — but do not read the byte cap as a hard ceiling.

**Task boundary.** The window resets on a genuine user message, on a slash-command
invocation (the harness's `<command-name>…</command-name>` user record), and on a `Skill`
tool_use. A slash command like `/implement` is explicitly a multi-phase task that runs
inside one user message, so a per-message budget would starve it. Task notifications
still do not reset it: the slash-command match is anchored to the start of the record's
content and harness envelopes are excluded, because a notification is also a user record
with string content and it carries a subagent's authored text — and the stall notifier
appends raw background stdout after the envelope — so an unanchored match would let a
lane be instructed to emit the wrapper and refill the orchestrator's budget. A `Skill`
launch must also have not errored.

**Deliberate property (user decision):** the model emits `Skill` itself, so it can reset
its own window at will by launching a skill. This is accepted: the gate is enforcing
against accidental bulk reading, not against a determined agent. Both caps still bind
inside each window, and every other boundary is harness-controlled.

Exempt from the call count: small-output reads, memory files, files under 4 KB, and
re-reads of files just edited successfully in the window (bytes still count). Never
gated: `git diff`/`git status`/summary-only `git log`, and live cloud CLIs
(kubectl/az/aws/gcloud/terraform — by policy they stay in the main loop).

### Model tier (`lane-model-gate.py`)

No lane may run on the frontier-tier model alias except the configured verifier lane
(default `fresh-verifier`); `model: opus` requires an `escalate: <reason>` first line in
the dispatch prompt so the escalation is visible in the transcript.

## Crew config

`routing-table.py` and `lane-model-gate.py` read lane names from
`${CLAUDE_CONFIG_DIR:-~/.claude}/plugins/data/crew/config.json`, key `lanes` — an object
with any of these keys: `scout`, `reader`, `implementer_haiku`, `implementer_sonnet`,
`implementer_opus`, `writer`, `verifier`, `adversary`. Any key that is absent, or whose
value isn't a non-empty string, falls back to its default. A missing or malformed
config file falls back to all defaults; the gates never crash on it.

Lane names may be plugin-qualified (`<plugin>:<name>`, e.g. `dev-workflow:fresh-verifier`)
— a verifier that itself ships inside a plugin arrives at `lane-model-gate.py` with that
prefix. If `lanes.verifier` is set qualified, only that exact `<plugin>:<name>` string is
exempt (not the bare name, not a different plugin's copy); if it's left unqualified
(the default `fresh-verifier`), both the bare name and any `<plugin>:fresh-verifier` are
exempt — but never as a substring: `other:fresh-verifier-x` does NOT match
`fresh-verifier`.

Defaults:

```json
{
  "scout": "claude-crew:claude-scout",
  "reader": "claude-crew:claude-reader",
  "implementer_haiku": "claude-crew:claude-implementer-haiku",
  "implementer_sonnet": "claude-crew:claude-implementer-sonnet",
  "implementer_opus": "claude-crew:claude-implementer-opus",
  "writer": "code-writer",
  "verifier": "fresh-verifier",
  "adversary": "codex-adversary"
}
```

## Off switches

Each gate can be disabled independently, per session:

- `CLAUDE_DELEGATION_GATE=off`
- `CLAUDE_READ_BUDGET=off`
- `CLAUDE_LANE_MODEL_GATE=off`

## Install

Enable the plugin and let `ai-crew-update` reconcile settings.json — it merges
`settings.fragment.json` (currently just the `CLAUDE_CODE_SUBAGENT_MODEL` env default)
and removes any legacy hook entries so hooks stay resolved from this plugin's
`hooks/hooks.json` rather than a version-pinned path.

### Manual install

1. Enable the plugin — hooks load from `hooks/hooks.json` automatically once the
   plugin is active; you do not need to add PreToolUse/UserPromptSubmit entries by hand.
2. Add the env default from `settings.fragment.json` to your `settings.json`:

   ```json
   {
     "env": { "CLAUDE_CODE_SUBAGENT_MODEL": "sonnet" }
   }
   ```

3. If your `settings.json` has older, absolute-path hook entries pointing directly at
   `<plugin-root>/hooks/*.py` (from before hooks.json-based loading), remove them —
   run `"${CLAUDE_PLUGIN_ROOT}/skills/ai-crew-update/ai-crew.sh" reconcile --dry-run`
   first to preview, then the same without `--dry-run` to apply. Version-keyed install
   paths written into settings.json go stale on update, since the harness sweeps old
   version directories; `hooks.json` is resolved per session by the harness instead.
4. Run `/reload-plugins` to pick up the hooks, or open a new session. The `env` change needs a full restart.

The off-switch env vars above still work regardless of install method.
