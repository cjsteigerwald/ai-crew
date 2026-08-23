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
  otherwise accumulate forever and make `/codex:status` lie. Two further
  sweeps are opt-in, because they are destructive in ways the job sweep is not:
  - `--brokers` kills broker processes whose `--cwd` workspace no longer exists
    (delete a worktree and its broker stays resident forever), children first
    and **by pid only** — never a pattern kill, which would take out every
    other workspace's healthy broker — then removes `/tmp/cxc-*` socket dirs
    that nothing is holding. It REFUSES the whole sweep (exit 3) while any job
    anywhere is non-terminal: nothing maps a job to the broker serving it, so
    one live job makes every broker unprovable.
  - `--state` prunes state dirs whose recorded cwd is gone and that hold no
    non-terminal job. This deletes job history and logs — dry-run it first. A
    dir whose cwd cannot be parsed is reported `unresolved` and never pruned.
  Both compose with `--dry-run`, and plain `reap` behaves exactly as before.
  Main-thread housekeeping, not for crew agents mid-job.
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
  `~/.claude/plugins/data/codex-crew/jobs/<id>.{result.txt,meta.json,log}`,
  which the companion's 50-job pruner cannot delete. Jobs still die with the
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
