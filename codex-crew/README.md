# codex-crew

Purpose-built Codex delegate agents for Claude Code, invocable like native
subagents, each pinning a specific Codex model and posture. Rides the
official `codex@openai-codex` plugin's companion runtime (background jobs,
`/codex:status` / `/codex:result` / `/codex:cancel`, session-end cleanup)
instead of reimplementing it.

## Agents

Implementation is tiered across the GPT-5.6 ladder — the orchestrator picks
the tier per task; each agent's description carries the selection criteria:

| Agent | Model | Effort | Posture | Choose when |
|---|---|---|---|---|
| `codex-implementer-sol` | gpt-5.6-sol (flagship) | caller-chosen, default `high` | write | Novel/intricate logic, cross-cutting multi-file changes, concurrency/money-path correctness, gnarly debugging — anything where mid-tier output would need rework |
| `codex-implementer-terra` | gpt-5.6-terra (balanced) | caller-chosen, default `medium` | write | Routine, well-specified implementation with clear spec and existing patterns; the default when a task is real work but not hard |
| `codex-implementer-luna` | gpt-5.6-luna (affordable) | caller-chosen, default `low` | write | Mechanical, repetitive, parallelizable chores with an exact recipe; fan out freely |
| `codex-reviewer` | gpt-5.6-sol | caller-chosen, default `high` | read-only | Diff/branch reviews, adversarial reviews, independent diagnosis |

Rough cost ratio per token: Sol ≈ 2× Terra ≈ 5× Luna. Pins are defaults — a
dispatch brief that explicitly names a model or effort overrides them
(`spark` → `gpt-5.3-codex-spark`, `mini` → `gpt-5.4-mini`).

## Requirements

- Official Codex plugin installed: `/plugin install codex@openai-codex`
- Codex CLI installed and authenticated (`codex login`)
- Node.js

## Install

```bash
# from GitHub
claude plugin marketplace add cjsteigerwald/ai-crew
# or from a local checkout
claude plugin marketplace add /path/to/ai-crew

claude plugin install codex-crew@cjs-plugins
```

## How it works

`bin/crew-codex` (on PATH while enabled) resolves the codex plugin's
`codex-companion.mjs` from `~/.claude/plugins/installed_plugins.json` —
version-bump-proof — and execs it with `CLAUDE_PLUGIN_DATA` pointed at the
codex plugin's data dir, so crew-launched jobs share one job namespace with
the official plugin's commands and hooks. Each agent is a thin forwarder
(sonnet): one `crew-codex` call in, raw stdout back, no independent work.

**Long runs, owned end to end.** Codex jobs run for hours; Claude Code caps a
single Bash call at 600s. So a dispatch is three steps — launch detached,
loop `crew-codex await <id> --for 540`, return `crew-codex result <id>` — and
the agent owns the job for its whole life. "Subagent finished" therefore still
means the work is done, with no cap on how long the job takes. The waiting
happens inside a shell poll loop, so hours of supervision cost one short
status line per ~9 minutes rather than a streamed transcript.

```
crew-codex await <job-id> [--for <seconds>]
  exit 0  DONE completed      exit 1  DONE failed/cancelled
  exit 2  job not found       exit 3  STALE — died without reporting
  exit 10 RUNNING — call again
```

`await` waits on the job's **own process** (`tail --pid`), so it wakes the
instant the job ends — not on a poll tick — and costs no CPU while blocked. It
falls back to a 5s poll when no live pid is available. If the process
disappears while the job still claims to be `running`, that's a silent death:
`await` reports `STALE` with exit 3 instead of waiting out the deadline.

**Guarded flags.** codex-companion has no per-subcommand help handler, and its
review parser folds every argument it does not recognize into the review's
focus text. So `crew-codex adversarial-review --help` used to run a full review
against `main` (~10 minutes of wall clock, twice on 2026-08-22) and
`--effort high` used to be swallowed into the prompt while the turn ran at
whatever the codex config said. `crew-codex` now intercepts both before
dispatching:

```
crew-codex review|adversarial-review --help          usage, exit 0, no dispatch
crew-codex review|adversarial-review -h|help         same, but ONLY as the
                                                     first arg after the
                                                     subcommand
crew-codex task --help|-h                            usage, exit 0, no dispatch
                                                     (bare `help` still forwards:
                                                      it is a plausible prompt)
crew-codex review --effort <e>                        error,  exit 2, no dispatch
crew-codex adversarial-review --effort <bad>          error,  exit 2, no dispatch
crew-codex [--help|-h|help]                           top-level usage, exit 0
```

Scope differs by spelling, deliberately. `--help` is intercepted at any
position — nobody passes that literal token as review prose. A bare `help` or
`-h` is intercepted **only as the first argument after the subcommand**,
because focus text arrives as unquoted positionals the companion joins:
scanning every position would make `adversarial-review improve the help
wording` print usage and exit 0 without dispatching, silently swallowing a
real review while reporting success. Refusing to review is a worse failure
than printing usage one position later.

Matching is otherwise exact: focus text may still contain the word `help` or any other
`--`-prefixed token, and those forward untouched.

**Per-dispatch reasoning effort on adversarial reviews.** codex-companion
cannot set reasoning effort on any review: its review parser knows only
`--base/--scope/--model/--cwd`, and its adversarial branch calls
`runAppServerTurn` without an effort, so the turn is started with `effort: null`
and runs at whatever `model_reasoning_effort` the codex config carries. The wire
protocol accepts an effort — only the companion's plumbing is missing.

So `crew-codex adversarial-review --effort <e>` routes to a small driver of our
own, `lib/review-with-effort.mjs`, which imports the same *public exports*
`executeReviewRun` uses and re-composes them with the effort attached. **No
vendor file is patched or forked** — nothing under `~/.claude/plugins/` is
touched. Same target resolution, same context collection, same prompt template,
same output schema and same job-record shape, so `status`, `await`, `result` and
`cancel` treat these jobs exactly like companion-created ones.

- **Without `--effort` nothing changes**: the dispatch is a verbatim companion
  passthrough, so the default path carries no blast radius.
- `crew-codex review` (the native reviewer) still rejects `--effort` with
  exit 2 — it runs through `runAppServerReview`, a different code path the
  driver does not model.
- `--background` on the driver truly detaches (`detached`, `stdio: "ignore"`,
  `unref`) and returns a job id. The vendor's adversarial review is
  foreground-only with buffered output, which is why a plain Bash call to it
  dies at the 120s default tool timeout and leaves the review orphaned as a
  STALE record.
- Valid efforts are `none|minimal|low|medium|high|xhigh`, validated against a
  deliberate copy of the companion's own (non-exported) `VALID_REASONING_EFFORTS`.
  **`xhigh` stays the ceiling** — the registry's `max`/`ultra` tiers are refused,
  because the driver bypasses the vendor validator and nothing has proven the
  app-server accepts them. The practical **floor** is narrower still: the
  GPT-5.6 family 400s on `reasoning.effort` for `none` and `minimal`, so those
  two are accepted but warned about on stderr when paired with a `gpt-5.6*`
  model or no `--model` at all.
- These imports are internal vendor modules that merely happen to be exported,
  so an upstream rename can break them. If any import or symbol is missing the
  driver **fails loudly** — naming the installed plugin version, the module and
  the symbol — and exits non-zero. It never silently falls back to the vendor
  path: that would run a review at an effort the caller did not ask for while
  reporting success, the exact failure this feature exists to prevent.

**Dispatch stamping.** Each `task`/`review`/`adversarial-review` dispatch writes
`<job-id>.dispatch.json` into the crew archive
(`~/.claude/plugins/data/codex-crew/jobs/`) with the model, the requested effort,
the config's `model_reasoning_effort` and the full argv. Companion-written review
records carry neither model nor effort (task records carry both, under
`storedJob.request`), so this sidecar is the only audit trail of what a past
vendor-path review actually ran at. A driver-run `adversarial-review --effort`
is stamped in both places: the sidecar records it flag-sourced, and the job
record itself carries `effort`, `model` and `codexPluginVersion`. Stamping is
best-effort: it can never change a dispatch's exit code, stdout or stderr.

⚠️ **Coverage is not universal, and the gap runs the wrong way.** The stamp is
written after the dispatch returns, by scraping a job id out of its output. The
vendor review path (`review`, and `adversarial-review` **without** `--effort`)
runs foreground and prints **no job id**, so those dispatches get **no
sidecar** — exactly the reviews with no other audit trail. Driver dispatches
(`adversarial-review --effort ...`) and `task` dispatches do print an id and are
stamped. Closing the vendor-path gap needs an id minted before dispatch rather
than scraped after it: tracked, not done.

⚠️ The sidecar stores **routing metadata only**. Positionals — review focus text
and task prompts — are replaced by a `<redacted: N positional token(s)>` marker,
because focus text routinely carries pasted incident logs, internal hostnames and
secret-bearing commands, and this archive deliberately outlives the vendor's
session cleanup.

**Housekeeping.** `crew-codex reap [--dry-run]` marks stuck `running`/`queued`
job records failed once their process is dead or their log has frozen. Two
opt-in sweeps handle what dies around them:

- `--brokers` **reports and never kills.** It finds brokers whose `--cwd`
  workspace is gone (a deleted worktree leaves its broker resident forever) and
  prints the pid, the cwd and a paste-ready `pkill -P <pid>; kill -TERM <pid>`
  for you to run yourself. A cwd that cannot be *proven* absent is reported
  `unknown`, never as a candidate. It removes no socket dirs.
  Why no kill: the automated version failed open five distinct times in five
  review rounds (each fix reintroducing the fault one level up — `isdir`, then
  `exists`, both of which return False for permission-denied), and the
  scan-then-kill race cannot be closed from outside the broker. On a machine
  running several Claude Code sessions at once, a candidate may be serving
  another session's in-flight review. The decision is yours; the evidence is
  printed. `--dry-run` is accepted with `--brokers` but has nothing to change.
- `--state` **reports and never deletes.** It finds state dirs whose recorded
  cwd is gone and that hold no non-terminal job and no live pid, and prints the
  dir, the resolved cwd, why it qualifies and a paste-ready `rm -rf <dir>` for
  you to run yourself — with the warning that the registry may belong to another
  concurrent session. A dir whose cwd cannot be parsed is reported `unresolved`;
  one whose records cannot be read or parsed — including an unreadable directory
  or an unrecognized `state.json` shape — is reported `blocked`.
  Why no delete: the dir is the registry the companion serves
  `status`/`result`/`cancel` from, in a state root **shared by every Claude Code
  session on this machine**, and the scan that clears it carries the same
  irreducible TOCTOU as the broker kill — another session can queue a job into
  that workspace, or recreate the cwd, between the scan and the delete. Three
  further fail-open paths (a dangling symlink read as absence, a malformed pid
  laundered into a terminal record by the preliminary job sweep, and only the
  *first* recorded cwd being checked) mattered only because a delete followed
  them; with the delete gone each is at worst one misclassified line of report
  that a human reads before running anything. `--dry-run` is accepted with
  `--state` but has nothing to change.

**Exit codes for `reap`:** `0` every entry was classified, `2` usage error,
`3` the sweep ran but at least one entry was **blocked, unresolved or skipped**,
`1` reap itself failed. Exit `3` is not a failure to fix — it is a sweep that
walked past entries a human still has to decide about, and it exists because a
uniform `exit 0` told automation that such a sweep had finished the job.

**Results survive.** On terminal state `await` archives the result, metadata
and log to `~/.claude/plugins/data/codex-crew/jobs/`, which the companion's
50-job pruner cannot delete. Jobs still stop when the Claude session ends (by
design), but the archived transcript and `threadId` remain, so interrupted
work is resumed rather than re-run from scratch.

⚠️ The archived `<job-id>.meta.json` is **sanitized before it is written**. The
companion's `result --json` returns `storedJob` verbatim, and a stored job
carries its request: a background task keeps its prompt in
`storedJob.request.prompt`, a background effort review keeps its focus text in
`storedJob.request.focusText`, and a task's `summary` is the first 96 characters
of the prompt. Unsanitized, that put the original incident text, credentials,
hostnames and paths in the same directory as a carefully redacted
`.dispatch.json` — an archive that exists precisely to outlive the vendor's
session cleanup.

The sanitizer is a **structural allowlist**: a field survives because of *where
it sits*, and anything unrecognized is replaced by a `<redacted: N chars>`
marker regardless of its name or its length. Only `job` and `storedJob` are
recognized at the top level; inside them `request` keeps a routing allowlist,
`result` and `rendered` are the only preserved output subtrees (verbatim and
unbounded, at that depth only), a `task-` job's prompt-derived `summary` goes
while a review's finding summary stays, and a fixed set of ids, timings, status
and routing fields is kept as length-capped scalars. A new vendor field
therefore fails **closed**. A payload that cannot be parsed, or that is not a
mapping, is **withheld** rather than archived raw. Sanitization is best-effort
in the same sense as stamping: it never changes `await`'s exit code or its
single stdout line.

Alongside the result, `await` writes `<job-id>.sanitized` — a SHA-256 of the
archived `result.txt` and nothing else. It is what lets a later run tell an
already-sanitized result from a legacy unsanitized one, so a transient
sanitizer failure still fails closed without destroying an unrepeatable model
answer. `crew-codex sanitize-archive [--dir <path>] [--dry-run]` applies the
identical sanitizer to jobs archived by an earlier version; it never deletes,
rewrites only when the bytes differ, and a second pass is a byte-for-byte
no-op. `.log` files are copied verbatim and are **not** sanitized by any path.

**Capacity retries**: "model is at capacity" rejections are retried by
`crew-codex` automatically — up to 3 attempts with jittered 5/15/45s backoff
(override via `CREW_CODEX_RETRY_DELAYS`). This is write-safe: capacity is an
admission-time rejection, so no partial work exists to double-apply. Retries
are announced on stderr, never silent. Any other failure passes through
untouched on the first attempt, and there is no automatic tier fallback —
substituting a cheaper model is an orchestrator decision, made in the open.

## Tests

```bash
bash tests/run.sh
```
