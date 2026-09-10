# codex-crew

Purpose-built Codex delegate agents for Claude Code, invocable like native
subagents, each pinning a specific Codex model and posture. Rides the
official `codex@openai-codex` plugin's companion runtime (background jobs,
`/codex:status` / `/codex:result` / `/codex:cancel`, session-end cleanup)
instead of reimplementing it.

## Agents

Implementation is tiered across the GPT-5.6 ladder, plus one frontier tier
above it on GPT-6 Astra for the hardest work — the orchestrator picks the tier
per task; each agent's description carries the selection criteria:

| Agent | Model | Effort | Posture | Choose when |
|---|---|---|---|---|
| `codex-implementer-astra` | gpt-6-astra (frontier, one generation above the 5.6 ladder) | caller-chosen, default `medium` | write | Cross-cutting changes whose evidence is scattered across many files or subsystems, multi-hour jobs that will outlive a context window, debugging that Sol already needed a second round on, or logic spanning retries/ownership/persisted state |
| `codex-implementer-sol` | gpt-5.6-sol (flagship) | caller-chosen, default `medium` | write | Novel/intricate logic, cross-cutting multi-file changes, concurrency/money-path correctness, gnarly debugging — anything where mid-tier output would need rework |
| `codex-implementer-terra` | gpt-5.6-terra (balanced) | caller-chosen, default `medium` | write | Routine, well-specified implementation with clear spec and existing patterns; the default when a task is real work but not hard |
| `codex-implementer-luna` | gpt-5.6-luna (affordable) | caller-chosen, default `low` | write | Mechanical, repetitive, parallelizable chores with an exact recipe; fan out freely |
| `codex-reviewer` | gpt-5.6-sol | caller-chosen, default `medium` | read-only | Diff/branch reviews, adversarial reviews, independent diagnosis |

All efforts above are caller-chosen; the lane default is used only when a
dispatch names none — no lane is pinned to a fixed effort.

**Why Astra defaults to `medium`.** Medium is Astra's own registry default and
lands on the cost/quality sweet spot; raise to `high` or `xhigh` in the
dispatch only for a hard architectural call or a debugging loop that has
already resisted medium. GPT-6 Astra's cross-window note-taking — retaining
notes instead of compressing them as a context window fills — is, per
OpenAI's own announcement, experimental, opt-in, and only *planned* to become
default later; it must be enabled in `config.toml`, and this fork neither
enables nor documents that setting. **UNVERIFIED**: whether the feature is
active for any dispatch made through this fork has not been checked against
a live config. Treat multi-hour jobs as belonging on this lane on the
strength of Astra's own reasoning depth over a long-running detached job, not
on this unconfirmed persistence feature. Because Astra asks a clarifying
question instead of guessing when more input would change the result, and a
detached background job has nobody there to answer it, an Astra brief must be
self-contained — state the decisions and assumptions up front rather than
leaving them for Astra to infer.

List pricing per million tokens, input/output (September 2026): Astra
$10/$50, Sol $4/$20, Terra $2/$12, Luna $0.20/$1.20.

Rough cost ratio per token (input list price): Astra ≈ 2.5× Sol ≈ 5× Terra ≈
50× Luna; Sol ≈ 2× Terra ≈ 20× Luna; Terra ≈ 10× Luna. Pins are defaults — a
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

## Update

```bash
# 1. refresh the marketplace catalogue (all marketplaces if no name given)
claude plugin marketplace update cjs-plugins

# 2. pull the new plugin version
claude plugin update codex-crew@cjs-plugins

# 3. and the official Codex plugin this one wraps
claude plugin update codex@openai-codex
```

⚠️ **Restart Claude Code afterwards. Nothing takes effect until you do**, and the
CLI says so itself — `claude plugin update` prints *"restart required to apply"*.

This is not a cosmetic reload. Installs are **version-keyed**: each version is
unpacked into its own directory and the old ones stay put.

```
~/.claude/plugins/cache/cjs-plugins/codex-crew/
├── 0.4.2/
├── 0.5.0/
├── 0.5.1/
├── 0.6.0/
├── 0.7.0/
└── 0.8.0/   <- the update added this; it did not replace anything
```

Each session resolves its plugin `PATH` when it starts, and then keeps calling
that directory for its whole life. So an update mid-session leaves you running
the previous version while `claude plugin list` reports the new one — the update
succeeded and had no effect, with nothing to indicate it.

**Opening a new session is enough.** A session started after the update picks up
the new version on its own; you do not need to restart anything above it. If you
run Claude Code through a `claude remote-control` daemon, the daemon does not
need restarting either — sessions do not inherit a frozen `PATH` from it.

### Confirming which version is live

⚠️ **Run these inside a Claude Code session, not in a plain terminal.** The
plugin `bin` directories are injected into the environment of Claude Code's own
sessions; they are not added to your shell profile. In an ordinary terminal
`which crew-codex` returns nothing whether the update worked or not, so it tells
you nothing either way.

Inside a session:

```bash
# the version this session is actually bound to
echo "$PATH" | tr : '\n' | grep codex-crew

# and that the wrapper resolves the vendor companion
crew-codex --resolve
```

From anywhere, including a plain terminal — these read the files the resolver
reads, so they show what a NEW session will pick up (not what a running one is
bound to):

The shortest answer — resolve the install path, then read that version's own
manifest:

```bash
P=$(python3 -c "import json,os;d=json.load(open(os.path.expanduser('~/.claude/plugins/installed_plugins.json')));print(d['plugins']['codex-crew@cjs-plugins'][0]['installPath'])")
cat "$P/.claude-plugin/plugin.json"
```

```json
{
  "name": "codex-crew",
  "version": "0.8.0",
  ...
}
```

The manifest is the version's own declaration of itself, so it cannot disagree
with what is on disk the way a separate registry can.

For more context:

```bash
# the authoritative record: which version, installed when, from which commit sha
cat ~/.claude/plugins/installed_plugins.json

# every version still unpacked — they accumulate, they are not replaced
ls ~/.claude/plugins/cache/cjs-plugins/codex-crew/

# where the marketplace points, and when it was last refreshed
cat ~/.claude/plugins/known_marketplaces.json
```

⚠️ The marketplace file is `known_marketplaces.json`. There is **no**
`~/.claude/plugins/config.json` — a `cat` of it with stderr suppressed prints
nothing and looks exactly like an empty config, so a check built on it reports
success by printing nothing at all.

Old version directories are safe to leave; `claude plugin prune` removes
auto-installed dependencies that are no longer needed.

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

### Exit codes

```
crew-codex await <job-id> [--for <seconds>]
  exit 0  DONE completed      exit 1  DONE failed/cancelled
  exit 2  job not found       exit 3  STALE — died without reporting
  exit 4  HUNG — pid alive, log frozen
  exit 5  SUPERSEDED by a redirect (the line names the successor)
  exit 10 RUNNING — call again
```

⚠️ **Exit 5 is a deliberate divergence from upstream codex-crew, which returns
4 for SUPERSEDED.** Exit 4 has meant HUNG in this fork since v0.4.2 and
downstream agents key a confirm-then-recover protocol to it, so taking 4 for
SUPERSEDED would make an agent running against a not-yet-updated install read a
real hang as a redirect and chase a successor id that does not exist — silently,
and destructively. The divergence fails loudly in the other direction, which is
why it runs this way round.

`await` waits on the job's **own process** (`tail --pid`), so it wakes the
instant the job ends — not on a poll tick — and costs no CPU while blocked. It
falls back to a 5s poll when no live pid is available. If the process
disappears while the job still claims to be `running`, that's a silent death:
`await` reports `STALE` with exit 3 instead of waiting out the deadline.

**Correct a running job in flight.** A job going the wrong way does not have to
be thrown away, and does not have to be interrupted either:

```
cd <sandbox root> && crew-codex steer <job-id> "Stop adding files; switch to fixing the failing test"
STEERED task-abc-123 | thread 01a03e70-... | turn 01a03e70-... | the agent reads it at its next step
```

Steering interjects into the turn the job is running **right now**. Nothing is
stopped: the tool call in progress finishes normally, and the model reads the
message at its next step, so it can change course before doing all the wrong
work. The reply is part of the same turn, so it appears in the job's own result.

**A turn is the whole task, not one step.** That distinction is why steering
exists and why queueing is not a substitute — everything a job does is one turn,
so a message that waits for the turn to end arrives after the work is finished.

```
cd <sandbox root> && crew-codex queue <job-id> "When you are done, also update the changelog"
QUEUED task-abc-123 | id crew-task-abc-123-1 | the agent reads it when its current turn ends
```

Because the companion closes a job at its first `turn/completed`, the queued
turn's answer would otherwise be lost. `await` waits for it and folds it into
the archived result.

⚠️ The queued message **text is never archived** — only its client id and its
length. Upstream records the message verbatim; this fork does not, because the
crew archive deliberately outlives the vendor's session cleanup and a queued
message carries exactly the free-form operator text that the `.dispatch.json`
redaction and the `.meta.json` sanitizer exist to keep out of it. Nothing
downstream needs the text: `await` reads that file for its line count and
matches replies by client id.

**Redirect is the destructive one.** Reach for it only when a job is genuinely
off the rails:

```
cd <sandbox root> && crew-codex redirect <job-id> "Change of plan: <new instruction>"
```

That INTERRUPTS the live turn and resumes the *same* Codex thread with the new
text, so everything the job already did stays in context — but the interrupt
stops the turn wherever it stands, so an edit in progress can be left half
applied. It prints `REDIRECTED <old> -> <new>`; await the new id. The agent
awaiting the old id gets exit 5 (`SUPERSEDED`) naming the successor, so it
follows the thread rather than reporting a failure.

| | What it does | When the agent sees it |
|---|---|---|
| `steer` | Interjects into the running turn | At its next step, after the in-flight tool call |
| `queue` | Appends to the thread queue | After the turn completes, so after the whole task |
| `redirect` | Interrupts the turn, then resumes | Never sees it; work in flight is destroyed |

**Every job gets its own broker.** The companion runs one broker per working
directory, and a broker carries exactly one streaming turn. Its answer to a busy
broker is to run the whole job on a private stdio app-server, which has no
socket, so nothing can steer, queue or interrupt it, ever. In a shared parent
directory that means exactly one reachable job: whichever won the broker first.

So `crew-codex` starts a broker per launch, records the endpoint against the
job, and routes every later `steer`, `queue`, `await`, `status`, `result` and
`cancel` back to it. Each broker holds a codex app-server, so leaks are
expensive and retirement is deliberate: terminal state in `await` and a
successful `cancel` retire that job's broker immediately, every launch sweeps
first, and `crew-codex reap` does it on demand. `CREW_CODEX_NO_JOB_BROKER=1`
opts out.

Retiring these is safe in a way the report-only `reap --brokers` sweep is not:
`crew-codex` **started** them, and each sidecar records the pid together with
its start time, so it can prove it is signalling the same process it spawned
rather than a stranger that inherited a recycled pid. Brokers we did not start
are still never killed.

**Both `steer` and `queue` need the codex plugin patched.** Stock, the plugin
refuses on two counts: its broker forwards only `turn/interrupt` while a turn is
streaming, so `turn/steer` and `thread/queue/add` come back `-32001 Shared Codex
broker is busy`, and its client declares `experimentalApi: false`, which the
server requires for the queue method. Note what that left behind: interrupt, the
one destructive option, was the only thing that got through.

```
crew-codex patch --status     # PATCHED / UNPATCHED, for whatever version is installed
crew-codex patch --apply      # idempotent, keeps *.crew-orig backups
crew-codex patch --revert
```

Everyone installs their own copy of `codex@openai-codex` at their own version,
so the fix ships as a patch in `patches/` applied by context matching rather
than line numbers, which absorbs the drift between releases. It refuses to
half-apply if upstream moves the code out from under it. A SessionStart hook
re-applies it after the codex plugin updates; set `CREW_CODEX_NO_AUTO_PATCH=1`
to opt out.

⚠️ `redirect`'s relaunch is **not** dispatch-stamped. It calls the companion
directly rather than going through the shared dispatch path, so the successor
job gets no `.dispatch.json`. Same class of gap as the vendor-review one below:
tracked, not done.

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

- **Without `--effort` the review runs at `medium`**, sent explicitly. Since
  2026-09-10 every `adversarial-review` goes through the driver, `--effort` or
  not: the vendor path can only run at the codex config's
  `model_reasoning_effort`, an effort nobody chose for the dispatch (user
  decision: "If NO effort is passed in then default to medium").
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
  GPT-5.6 family *and* `gpt-6-astra` 400 on `reasoning.effort` for `none` and
  `minimal`, so those two are accepted but warned about on stderr when paired
  with a `gpt-5.6*` model, `gpt-6-astra`, or no `--model` at all — the warning
  never blocks the dispatch, and the job then fails at the API instead.
- These imports are internal vendor modules that merely happen to be exported,
  so an upstream rename can break them. If any import or symbol is missing the
  driver **fails loudly** — naming the installed plugin version, the module and
  the symbol — and exits non-zero. It never silently falls back to the vendor
  path: that would run a review at an effort the caller did not ask for while
  reporting success, the exact failure this feature exists to prevent.

**Effort is the caller's; sensitivity is a label.** The review runs at exactly
the `--effort` passed, or `medium` when none is — nothing raises or lowers it.
`high` and `xhigh` are levels the orchestrator may request per dispatch (an
auth change, extremely complex code); a choice, never a rule or a floor (user
decision 2026-09-10: "the orchestrator should have ability to call effort
required"). Before the turn starts, the driver still classifies the changed
files of the very diff it is about to review — Terraform, Bicep/ARM,
CloudFormation, Kubernetes RBAC/NetworkPolicy manifests, CI/CD pipeline
definitions, key/cert/dotenv-shaped secret material, and auth/identity source
paths — and names any matched rule(s) and paths on stderr and in the job
record, as information for the reader. Until 2026-09-10 a match RAISED the
effort to `xhigh`; that floor and its `CREW_CODEX_SENSITIVITY_OVERRIDE` escape
hatch are gone, and a still-set override variable is reported as ignored.
⚠️ **Scope limit**: labels are produced only on `adversarial-review`; the
`task` path is not classified.

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
vendor review path (the native `review`) runs foreground and prints **no job
id**, so those dispatches get **no sidecar** — exactly the reviews with no
other audit trail. Driver dispatches (every `adversarial-review`, with or
without `--effort`; the sidecar records a no-flag one as `effortSource:
default`, `effortEffective: medium`) and `task` dispatches do print an id and
are stamped. Closing the vendor-path gap needs an id minted before dispatch rather
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
unbounded, at that depth only), `summary` is kept only for job kinds known to
put model output there (`review-`) and capped like any other scalar, and a
fixed set of ids, timings, status and routing fields is kept as length-capped
scalars. A new vendor field, and a job kind under an unrecognized id prefix,
therefore fail **closed**.

Every one of those comparisons is against the **exact** key spelling. An
earlier version normalized keys first (lowercase, strip punctuation), which
reads as defensive and is the opposite: normalization tightens a denylist but
can only loosen an allowlist, so `r-e-s-u-l-t` reached the verbatim-output
branch and `t-h-r-e-a-d-I-d` reached the metadata allowlist. A vendor alias is
added to those sets by hand or not at all. A payload that cannot be parsed, or that is not a
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
