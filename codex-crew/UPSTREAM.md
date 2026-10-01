# Upstream sync record

`codex-crew` began as a vendored snapshot of [`sidkik/claude-plugins`](https://github.com/sidkik/claude-plugins)
and has since diverged substantially in its runtime. Since 0.10.0 it **follows
upstream** for every agent, skill, README and test decision, and diverges only
where the fork's runtime (`bin/crew-codex`, `lib/`) differs — see
[Deliberate divergences](#deliberate-divergences). This file exists because the last port had
to be reconstructed by archaeology: nothing recorded where the fork stood, so
working out what was already here cost more than applying the changes did.

**Keep it current. A port that does not update this file has not finished.**

## Current sync point

| | |
|---|---|
| Upstream repo | `sidkik/claude-plugins` (marketplace `sidkik-plugins`) |
| Synced to | upstream codex-crew **0.8.2**, commit `a57e81b` |
| Synced on | 2026-10-01 |
| This plugin's version | **0.10.0** |

Upstream is **not** wired up for you. Git remotes are per-clone: they are never
committed and never travel with the repo, so every fresh checkout of this fork
starts with `origin` alone. Add it once and the next port is a diff instead of an
investigation:

```bash
# once per clone — `git remote add` errors if `upstream` already exists
git remote add upstream https://github.com/sidkik/claude-plugins.git

# confirm the URL, not just the name: an `upstream` left over from something
# else still satisfies any check that only looks for the word
git remote get-url upstream   # must print https://github.com/sidkik/claude-plugins.git

git fetch upstream --tags
git diff a57e81b upstream/main -- codex-crew/
```

Two failure modes share one signature, which is why the check above reads the
URL. If the remote is missing, `git fetch upstream` aborts with
`fatal: 'upstream' does not appear to be a git repository` (exit 128). If it
exists but points at an unrelated repo, `git remote add` errors with
`error: remote upstream already exists.` (exit 3), a pasted block runs straight
past it, and the fetch then succeeds — but `a57e81b` is reachable only from
upstream's history, so the diff aborts with `fatal: bad revision 'a57e81b'`
(exit 128) in that case too. Identical message, opposite causes; neither ever
returns a misleadingly empty diff.

The one genuinely silent case is an `upstream` pointing at some *other* fork of
`sidkik/claude-plugins`. It carries `965b419`, so every command succeeds and the
diff quietly compares against the wrong repository. Reading the URL is what
catches it.

## Version numbers do not line up, and never will

Both projects independently reached `0.6.0` with **completely different code**.
This fork jumped to `0.7.0` to get clear of the collision. It reached `0.8.0`
porting upstream v0.7.0, and `0.10.0` following upstream 0.8.2. Never assume a shared version number means shared code —
compare against the commit in the table above, never against a tag name.

## Deliberate divergences

Anything in this list is a decision, not drift. Do not "fix" one during a port
without changing the decision first.

| Area | Upstream | Here | Why |
|---|---|---|---|
| `await` SUPERSEDED exit code | `4` | **`5`** | `4` has meant HUNG here since v0.4.2, and downstream agents key a confirm-then-recover protocol to it. Taking `4` would make an agent on a not-yet-updated install read a real hang as a redirect and chase a successor id that does not exist — silent and destructive. The divergence fails loudly the other way. |
| `queue` message text in the archive | recorded verbatim in `<job>.queued.txt` | **redacted** to client id + length | The crew archive deliberately outlives the vendor's session cleanup. A queued message is free-form operator text carrying exactly what `.dispatch.json` redaction and the `.meta.json` sanitizer exist to keep out. Nothing downstream needs the text: `await` uses the line count and matches replies by client id. |
| queued follow-ups | appended to the **archived** `.result.txt` after the fact | appended to the **private staged render**, before sanitizing | Follow-ups are raw model output and must pass through the sanitizer. Appending after the fact also invalidates the `.sanitized` SHA-256 sentinel, which would make a later transient sanitizer failure destroy a good result. |
| default `reap` output | prints `REAPED \| n job broker(s)` | silent; count reported under `--brokers` | `reap`'s default output is a fixed contract here — the opt-in sweeps add lines, the default does not. Crew-owned broker retirement is the same automatic housekeeping that already runs on every launch and terminal `await`. |
| broker spawn failure | always warns | warns only when `app-server-broker.mjs` exists | A codex plugin without it has no broker support at all — a fact about the install, not a failure of the dispatch. Warning unconditionally puts a line on the stderr of every call on such an install. |
| `crew_pid_starttime` | `/proc/<pid>/stat` only | `/proc` with a `ps -o lstart=` fallback | `/proc` is Linux-only and this plugin is installed on darwin too, where upstream's version returns empty — which makes `crew_kill_broker` skip its ownership check and signal whatever now holds the pid. |
| `crew_lock_acquire` key | `md5sum` | `md5sum` → `md5` → `cksum` | `md5sum` is GNU; darwin ships `md5`. Upstream fails open, so the per-cwd launch lock was silently skipped on a whole platform. |
| `CREW_ROOT` | `readlink -f` | `cd ... && pwd` | `readlink -f` is GNU-only; resolution failure would take the patch file, the app-server bridge and every steer/queue call with it. |

**Deliberate divergence: macOS portability (v0.9.1).** Each row below is GNU/Linux-only upstream and broke silently on darwin (BSD userland). Linux keeps the upstream code path wherever one exists; darwin gets a fallback, not a replacement.

| Area | Upstream | Here | Why |
|---|---|---|---|
| `crew_patch_state` | reverse dry-run first; exit 0 = applied | `-N` and `-i FILE </dev/null` on every `patch` call, and forward/reverse dry-runs must disagree | Apple `patch` auto-answers "Ignore -R? [y]", so an UNPATCHED install read as PATCHED and the SessionStart `patch --apply` printed "already patched" and never applied it. The patch file is passed with `-i`, never on stdin, so the `</dev/null` guard (which keeps any prompt from waiting on a tty) cannot displace it: bash keeps only the last stdin redirect, and `<FILE </dev/null` would feed `patch` an empty stdin. |
| `await` pid wait | `timeout N tail --pid=` | same when both GNU tools exist, else a `kill -0` / `sleep 0.2` loop (`crew_wait_pid`) | Neither tool exists on stock darwin; the command failed instantly and `await` busy-polled the companion. |
| `await` hung-turn log age | `stat -c %Y` | `stat -c %Y` → `stat -f %m` (`crew_mtime`) | BSD `stat` has no `-c`; every log looked brand new, so HUNG could never fire. |
| `await` queued count | `$(wc -l <file)` | `$(( $(wc -l <file) ))` | BSD `wc` left-pads: output read `QUEUED-REPLIES 1/       1`. |
| `reap --brokers` ppid / argv | `/proc/<pid>/status`, `/proc/<pid>/cmdline` | `/proc` when present, else `ps -o ppid=` and `sysctl KERN_PROCARGS2` | No `/proc` on darwin: every broker read as vanished and the sweep reported zero candidates. KERN_PROCARGS2 is NUL-separated like `/proc` cmdline; `ps -o command=` was rejected because it is space-joined and would truncate a `--cwd` containing a space into a false candidate. |
| `reap --brokers` candidate identity | `serve` anywhere in argv plus a `--cwd` | only the vendor's exact invocation shape (`broker-lifecycle.mjs`: `spawn(process.execPath, [scriptPath, "serve", …])`): argv[0] basename matches `^node(js)?(-?N(.N)*)?$`, argv[1] basename is exactly `app-server-broker.mjs`, argv[2] is exactly `serve` (no node flags are allowed before the script, because the vendor passes none); anything else is `SKIP … not the codex broker script` — **on Linux too** | pgrep matches a substring of the joined command line, so an unrelated `bash app-server-broker-check.sh serve --cwd /gone` was reported as a candidate with a paste-ready kill command, and so was `python3 -c '…' app-server-broker.mjs serve --cwd /gone`, which passed a "some argv element is the script" check. This can only turn a would-be candidate into a skip. |
| `sanitize-archive` id de-dup | `declare -A` associative array | indexed array plus an exact quoted-string comparison loop | macOS `/bin/bash` is 3.2, which has no `declare -A`; every sweep aborted with `declare: -A: invalid option`. The comparison is exact and order-preserving, so ids with spaces, glob characters or newlines stay one id (no `sort -u` over a joined string). |
| `reap --brokers` reaper and registry survey | `python3 - … <<'PY'` inside `<(…)` / `$(…)` | Python loaded by a top-level `IFS= read -r -d '' VAR <<'PY' \|\| true`, then `python3 -c "$VAR" …` inside the substitution; Python text unchanged | bash 3.2 mis-parses a here-document inside a substitution whose body holds parens, quotes or backticks (`bad substitution: no closing ')'`), and only at runtime — `bash -n` passes. The reaper hit it; the survey was one edit away. |
| bash 3.2 test coverage (case B32) | — | B32 drives `sanitize-archive` and `reap --brokers` through `/bin/bash` and records an explicit SKIP where `/bin/bash` is not 3.x | ai-crew has no CI, so the bash 3.2 gate is the local suite run on a Mac, where `/bin/bash` is 3.2 and B32 always runs. A Linux-only run passing does **not** cover bash 3.2. Deferred follow-up: a macOS CI job that asserts `/bin/bash` is 3.x. |
| `patch --revert` on a `stale` install | any non-`applied` state prints "nothing to revert", exit 0 | `appliable` → no-op, exit 0; `stale` → exit 1 on stderr, nothing changed, points at the `*.crew-orig` backups | A half-applied install (one target patched) reads as `stale`; reporting it clean left the patched hunks in place while telling the operator there was nothing to undo. |

### Agent, skill and test text (0.10.0)

Since 0.10.0 the agents, `crew-runtime` skill, README and tests take upstream's
decisions: GPT-6 Sol and Luna, `xhigh` lane pins (Astra `medium`), Terra only
when a brief names it, the reviewer's isolated regression-proof route and the
**Review evidence** contract, the retired `mini` alias, and upstream's lane-pin
test block. Earlier fork decisions that contradicted these — caller-chosen
lane effort with `medium`/`low` defaults, and not porting the lane-pin tests —
are retired. What remains differs only because this fork's runtime differs:

| Area | Upstream | Here | Why |
|---|---|---|---|
| SUPERSEDED in agent text | exit `4` | exit `5` | Runtime exit codes (see the first table). |
| Supervision cwd | every call prefixed `cd <sandbox root> && `, plus two manual probes on exit 2 | run every call from the launch directory; `crew-codex` probes sibling state directories on a miss and names the cwd to re-run from | The fork runtime does the probing itself. The reviewer's regression-proof route still launches with `cd <isolated review checkout> && ` because that route must run in the isolated checkout. |
| Generic adversarial review | `adversarial-review` with no model or effort | `adversarial-review --model gpt-6-sol --effort xhigh`, routed through `lib/review-with-effort.mjs`, with the driver-filename capability probe | Only this runtime can set effort on a review; the agent passes the lane pin explicitly so the review matches the lane. |
| Astra `none`/`minimal` | forwarded | treated as `low` | Astra rejects both at the API. |
| Astra note-taking claim | "keeps notes across windows" | marked UNVERIFIED (experimental, opt-in `config.toml` setting this fork does not set) | Factual correction; not a reason to pick the lane. |
| GPT-6 Sol/Luna `none`/`minimal` warning | none | `lib/review-with-effort.mjs` warns, like the 5.6 family and Astra | The Codex model registry lists no `none`/`minimal` for either; without a row, the lanes' own default models slipped past the guard. |

## Fork-only features (upstream has none of these)

Do not expect a port to touch them, and do not let one regress them:

- `adversarial-review --effort` and `lib/review-with-effort.mjs`
- the deterministic sensitivity classifier (`lib/review-with-effort.mjs`,
  `SENSITIVE_PATH_RULES` / `SENSITIVE_CONTENT_RULES` /
  `classifyReviewSensitivity`): labels the changed files of every
  `adversarial-review` dispatch (Terraform, Bicep/ARM, CloudFormation,
  Kubernetes RBAC/NetworkPolicy, CI/CD, secret material, auth-ish source
  paths) on stderr and in the job record. Informational only since
  2026-09-10 — it used to RAISE a match to `xhigh`; that floor and
  `CREW_CODEX_SENSITIVITY_OVERRIDE` are gone. Upstream has nothing like it.
- runtime-level review effort: every `adversarial-review` routes to the
  driver, `--effort` or not, so a review never inherits the codex config's
  `model_reasoning_effort` (a bare `crew-codex adversarial-review` with no
  `--effort` runs at `medium`; the reviewer agent passes its `xhigh` pin). The `task` path
  is unchanged (the companion parses `--effort` there itself).
- dispatch stamping (`<job>.dispatch.json`)
- the archive sanitizer, the `.sanitized` provenance sentinel, and `sanitize-archive`
- `reap`'s report-only `--brokers` / `--state` sweeps and its exit-3 "incomplete" contract
- `await` exit 4 (HUNG)
- the help/`--effort` guards that stop a help request becoming a 10-minute review
- the `claude-crew` plugin

## Known gaps

- `redirect`'s relaunch is not dispatch-stamped: it calls the companion directly
  rather than through the shared dispatch path, so the successor gets no
  `.dispatch.json`.
- `sanitize-archive` resolves the codex companion before running, so it cannot
  run on a machine without the codex plugin installed even though it only
  touches local archive files. Pre-existing; it is why 15 suite cases fail in a
  container with no codex plugin.
- **FIXED.** `lib/review-with-effort.mjs` used to gate the "`none`/`minimal` are
  rejected" check behind `GPT_5_6_MODEL_PATTERN` (`/^gpt-5\.6/i`) alone, so
  `--model gpt-6-astra --effort none` slipped past the local guard and only
  failed at the API. That pattern is gone; `modelRejectsMinimalEfforts()` now
  checks a table covering both the GPT-5.6 family and `gpt-6-astra` (verified
  against `codex-crew/lib/review-with-effort.mjs` and exercised by
  `codex-crew/tests/run.sh` Case 59, "the none/minimal guard covers the Astra
  lane").
- **RESOLVED 2026-09-10** — three gaps closed by removing the sensitivity
  floor: `adversarial-review` with no `--effort` no longer bypasses the driver
  (it runs there at `medium`); `CREW_CODEX_SENSITIVITY_OVERRIDE`, whose
  "reason" was only ever checked for emptiness, no longer exists; and the
  audit sidecar no longer scrapes `sensitivity gate: raising --effort` off
  stderr, so an override reason can no longer spoof `effortEffective`.
- **Classification/review race (TOCTOU), now labels only.** The classifier
  resolves the review target and classifies it in the parent process, in
  `classifyReviewSensitivity()` in `lib/review-with-effort.mjs` (the call that
  forces `{ includeDiff: true }`), but the detached worker's
  `executeAdversarialReviewRun()` in the same file re-resolves the target and
  re-collects the diff content independently. With an `auto` scope, or a HEAD
  that moves between dispatch and execution, the labels can describe a
  slightly different diff than the one reviewed. Since labels no longer drive
  the effort, the cost is a misleading label, not an under-reviewed change.
  Deferred: fixing it needs worker-side reclassification or an immutable
  snapshot persisted at dispatch time.

## Open questions

- **RESOLVED 2026-10-01**: `gpt-5.4-mini` is retired. Codex CLI 0.159.3's model
  registry no longer lists it, so the `mini` alias is removed from the agents,
  README and skill, and the suite asserts it stays gone.
- **Not yet adopted**: the registry also lists `gpt-6.1-sol`. Neither upstream
  nor this fork pins it; the effort-floor warning already covers it.
