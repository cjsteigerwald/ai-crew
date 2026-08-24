---
name: crew-runtime
description: Internal contract for invoking the shared codex-companion runtime from codex-crew agents
user-invocable: false
---

# Crew Runtime

Use this skill only inside `codex-crew` agents (`codex-implementer-sol`,
`codex-implementer-terra`, `codex-implementer-luna`, `codex-reviewer`).

Primary helper — `crew-codex`, on PATH while the plugin is enabled:

- `crew-codex task [--background] [--write] [--resume-last] [--model <m>] [--effort <none|minimal|low|medium|high|xhigh>] "<prompt>"`
- `crew-codex review [--wait|--background] [--base <ref>] [--scope <auto|working-tree|branch>] [--model <m>]`
- `crew-codex adversarial-review [--wait|--background] [--base <ref>] [--scope <...>] [--model <m>] [--effort <none|minimal|low|medium|high|xhigh>] [focus text]`
  **`--effort` is honored on `adversarial-review` only.** codex-companion still
  cannot set reasoning effort on any review path, so when (and only when)
  `--effort` is present `crew-codex` runs the dispatch through its own driver,
  `lib/review-with-effort.mjs`, which composes the codex plugin's *exported*
  modules — no vendor file is patched — and threads the effort into the turn the
  companion leaves `null`. Without `--effort` the dispatch is a verbatim
  companion passthrough that runs at `model_reasoning_effort` from
  `${CODEX_HOME:-~/.codex}/config.toml`, exactly as before.
  The driver also detaches properly under `--background` (the vendor's
  adversarial review is foreground-only, so a plain Bash call to it dies at the
  120s tool timeout and orphans the job), and stamps the effort and model into
  the job record itself.
  If a codex plugin upgrade renames one of the modules it imports, the driver
  fails **loudly** — naming the version, module and symbol — and exits non-zero.
  It never silently falls back to the vendor path, because that would run the
  review at an effort you did not ask for while reporting success. Re-run
  without `--effort` to use the vendor path deliberately.
- `crew-codex review` (the native reviewer) still takes **no `--effort`** and
  rejects it with exit 2: it runs through a different companion code path
  (`runAppServerReview`) that the driver does not model.
- `crew-codex task --help` / `-h` — intercepted too: the companion has no help
  handler for `task` either, so this used to dispatch a real job whose prompt was
  the literal string `--help`. A bare `help` is NOT intercepted for `task` — a
  prompt is a positional, so `task help` is a plausible real dispatch.
- `crew-codex review --help` / `adversarial-review --help` (also `-h`, `help`)
  prints the real flag list and exits 0 **without dispatching**. The companion
  has no help handler, so before this guard `--help` became review focus text
  and ran a full review against `main` — ~10 minutes, twice on 2026-08-22.
  Bare `crew-codex` and `crew-codex --help|-h|help` print top-level usage the
  same way, forwarding nothing.
- `crew-codex await <job-id> [--for <seconds>]` — block until the job leaves
  `running`, or until the deadline; prints ONE line. Exit 0 completed,
  1 failed/cancelled, 2 job not found, 3 job died silently, 4 job hung,
  10 still running (call again). It waits on the job's own process
  (`tail --pid`), so it wakes the instant the job ends rather than on a poll
  timer.
  Exit 3 (STALE) means the process vanished without ever reporting terminal —
  report it verbatim; that job needs a resume or re-dispatch, not more waiting.
  Exit 4 (HUNG) means the pid is alive but the job log has not moved for
  `CREW_CODEX_HUNG_SECS` (default 900) — the signature of a lost model turn
  (app-server keeps the pid alive forever; cancel later says "thread not
  found"). Recovery: `cancel` the job, kill leftover `app-server`/`broker`/
  `code-mode-host` processes so the wedged runtime is not reused by the next
  dispatch, then re-dispatch ONCE on the fresh runtime; if that also hangs,
  report HUNG verbatim and stop.
- `crew-codex reap [--dry-run] [--brokers] [--state]` — sweep every state dir
  for jobs stuck in `running`/`queued` whose process is dead or whose log has
  been frozen past `CREW_CODEX_REAP_LOG_AGE` (default 3600s), and mark them
  failed in place. The companion never does this itself, so stuck entries
  otherwise accumulate forever and make `/codex:status` lie. A workspace that
  holds a live-pid job, or whose records cannot be read, is skipped whole —
  the state dir is shared with every other Claude Code session on the machine.
  Two further sweeps are opt-in:
  - `--brokers` **reports only — it kills nothing.** It lists broker processes
    whose `--cwd` workspace no longer exists (delete a worktree and its broker
    stays resident forever) and prints a paste-ready
    `pkill -P <pid>; kill -TERM <pid>` for a human to run after confirming the
    pid. A cwd that cannot be *proven* absent is reported `unknown`, never as a
    candidate, and no socket dir is removed. The automated kill was withdrawn
    after failing open five distinct times (permission-denied reading as
    "workspace gone" twice over) plus an unclosable scan-then-kill race; a
    candidate may be another session's live broker. `--dry-run` is accepted
    here and has no effect.
  - `--state` **reports only — it deletes nothing.** It lists state dirs whose
    recorded cwd is gone, that hold no non-terminal job and no live pid, and
    whose records were all read and parsed, and prints a paste-ready
    `rm -rf <dir>` for a human to run after confirming the registry is not
    another session's. A dir whose cwd cannot be parsed is `unresolved`; one
    that cannot be read or parsed is `blocked`. The delete was withdrawn for
    the same reason the broker kill was: the dir is the registry the companion
    serves `status`/`result`/`cancel` from, the state root is shared with every
    other Claude Code session, and nothing locks it between the scan and the
    delete. `--dry-run` is accepted here and has no effect.
  Exit codes: `0` everything was classified, `2` usage error, `3` the sweep ran
  but at least one entry was **blocked, unresolved or skipped** (read the lines
  — do NOT treat exit 3 as a clean sweep), `1` reap itself failed. Plain `reap`
  behaves exactly as before apart from that exit code. Main-thread
  housekeeping, not for crew agents mid-job.
- `crew-codex result <job-id>` — the finished job's output (plus its resume id)
- `crew-codex --resolve` — print the resolved companion script path (diagnostics only)

What it does: resolves the official `codex@openai-codex` plugin's
`codex-companion.mjs` via `installed_plugins.json` and execs it, ensuring
`CLAUDE_PLUGIN_DATA` points at the codex plugin's data dir so all jobs share
one state namespace with `/codex:status`, `/codex:result`, `/codex:cancel`
and the codex plugin's session-end cleanup.

Execution rules:

- **Launch → await → report.** Codex jobs run for hours; Claude Code caps a
  single Bash call at 600s. So every dispatch detaches the job
  (`--background`), then loops `crew-codex await <id> --for 540` (each call
  made with Bash `timeout: 600000`) until it stops returning exit 10, then
  returns `crew-codex result <id>`. The agent owns the job for its entire
  life — a launch handle is NEVER a result, and the loop has no iteration
  limit. Waiting happens inside the shell, so hours of supervision cost only
  one short status line per ~9 minutes.
- Each agent's model/effort/write pins are defaults; only an explicit
  model or effort named in the request overrides them. `spark` maps to
  `--model gpt-5.3-codex-spark`.
- `cancel` and cross-job triage belong to the main thread (`/codex:status`,
  `/codex:cancel`); a crew agent only awaits the one job it launched.
- Every `task`/`review`/`adversarial-review` dispatch also drops
  `<id>.dispatch.json` in the crew archive below, recording the model, the requested
  effort and the `model_reasoning_effort` actually in force. Companion-written
  review job records carry neither model nor effort (task records do, under
  `storedJob.request`), so for a vendor-path review this sidecar is the sole
  proof of what it ran at. An `adversarial-review --effort` dispatch is stamped
  twice over: the sidecar records it flag-sourced, and the job record itself
  carries `effort`, `model` and `codexPluginVersion`.
- Results are archived by `await` on terminal state to
  `~/.claude/plugins/data/codex-crew/jobs/<id>.{result.txt,meta.json,sanitized,log}`,
  which the companion's 50-job pruner cannot delete. `<id>.sanitized` is a
  provenance sentinel — a SHA-256 of the archived `result.txt` and nothing else.
  It is what lets a later `await` tell "this result was already sanitized" from
  "this is a legacy unsanitized render", so a transient sanitizer failure fails
  closed without destroying an unrepeatable model answer. Jobs still die with the
  Claude session by design (its SessionEnd hook terminates them); the archived
  transcript and the `threadId` in the meta file survive, so interrupted work
  resumes (`--resume-last` / `codex resume <threadId>`) instead of restarting.
- Failures are loud: relay raw stderr and exit code verbatim; never return
  empty output on error.
- Model-capacity rejections are retried automatically by `crew-codex` itself
  (3 attempts, jittered 5/15/45s backoff — write-safe because capacity is an
  admission-time rejection; the turn never started). Retry notices appear on
  stderr; relay them like any other output. If it still fails after retries,
  report that verbatim — the orchestrator decides whether to re-dispatch on
  another tier. Do NOT add your own retry loop on top.

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

⚠️ The archived `<id>.meta.json` is **sanitized the same way, for the same
reason**. `result --json` returns `storedJob` verbatim, and that record carries
the request: a background task's prompt (`storedJob.request.prompt`), a
background effort review's focus text (`storedJob.request.focusText`) and a
task's prompt-derived `summary`.

The rule is a **structural allowlist**, not a key-shape filter: a field is kept
because of **where it sits**, and anything unrecognized is replaced by a
`<redacted: N chars>` marker regardless of its name or its length. Only `job`
and `storedJob` are recognized at the top; inside them, `request` keeps a
routing allowlist, `result` and `rendered` are the **only** preserved output
subtrees (verbatim, unbounded, at that exact depth), `summary` is kept only for
job kinds known to put model output there (`review-`) and capped like any other
scalar, and a fixed list of ids, timings, status and routing fields is kept as
length-capped scalars. Everything else is markered. A new vendor field — and a
job kind under an unrecognized id prefix — therefore fails **closed** until
somebody adds it here deliberately.

⚠️ Those comparisons are against the **exact** key spelling, with no
normalization step. Normalizing first tightens a denylist but can only loosen an
allowlist: `r-e-s-u-l-t` would alias into the verbatim-output branch and
`t-h-r-e-a-d-I-d` into the metadata allowlist. Over-redaction is a bug report;
under-redaction is a disclosure nobody notices.

⚠️ Marker trust is a privilege of `sanitize-archive` alone (`CREW_TRUST_MARKERS`),
because that is the one caller re-reading this script's own output — which is
all idempotence ever needed. The live `await` path reads companion data that is
user-controlled end to end, so a prompt that IS a canonical marker is still
re-markered there rather than passed through.

A payload that cannot be parsed, or that is not a mapping, is withheld rather
than archived raw. `.log` files are copied verbatim and are **not** sanitized by
any path. Do not read a prompt back out of the archive; it is not there by
design.

`crew-codex sanitize-archive [--dir <path>] [--dry-run]` applies the identical
sanitizer to what is already on disk, for jobs archived by an earlier version.
It never deletes an archived job, rewrites only when the sanitized bytes differ,
and a second pass is byte-for-byte a no-op.

GPT-5.6 family ladder (per OpenAI's own model registry): **sol** = flagship
frontier coding tier, **terra** = balanced everyday mid tier, **luna** =
fast/affordable low tier. Other known models (Codex CLI 0.144.0): gpt-5.5,
gpt-5.4, gpt-5.4-mini, gpt-5.3-codex-spark. All listed models accept up to
`xhigh`; the companion runtime rejects the registry's higher `max`/`ultra`
efforts — `xhigh` is the ceiling through this plugin, and `crew-codex`'s effort
driver keeps that same ceiling rather than widening it.

The practical **floor** is narrower than the validator's: the GPT-5.6 family
(sol/terra/luna) returns a 400 on `reasoning.effort` for `none` and `minimal`,
so the usable ladder there is `low|medium|high|xhigh`. Both values are still
accepted — the validator mirrors the runtime's contract, not one family's — but
`crew-codex` warns on stderr before dispatching when `none`/`minimal` is paired
with a `gpt-5.6*` model or with no `--model` at all (the config default is a
5.6 model). The job then fails at the API, not in the wrapper.
