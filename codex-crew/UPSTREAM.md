# Upstream sync record

`codex-crew` began as a vendored snapshot of [`sidkik/claude-plugins`](https://github.com/sidkik/claude-plugins)
and has since diverged substantially. This file exists because the last port had
to be reconstructed by archaeology: nothing recorded where the fork stood, so
working out what was already here cost more than applying the changes did.

**Keep it current. A port that does not update this file has not finished.**

## Current sync point

| | |
|---|---|
| Upstream repo | `sidkik/claude-plugins` (marketplace `sidkik-plugins`) |
| Synced to | **v0.7.0**, commit `4a68b5e` |
| Synced on | 2026-09-09 (ported from upstream 2026-09-08) |
| This plugin's version | **0.8.0** |

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
git diff 4a68b5e upstream/main -- codex-crew/
```

Two failure modes share one signature, which is why the check above reads the
URL. If the remote is missing, `git fetch upstream` aborts with
`fatal: 'upstream' does not appear to be a git repository` (exit 128). If it
exists but points at an unrelated repo, `git remote add` errors with
`error: remote upstream already exists.` (exit 3), a pasted block runs straight
past it, and the fetch then succeeds — but `4a68b5e` is reachable only from
upstream's history, so the diff aborts with `fatal: bad revision '4a68b5e'`
(exit 128) in that case too. Identical message, opposite causes; neither ever
returns a misleadingly empty diff.

The one genuinely silent case is an `upstream` pointing at some *other* fork of
`sidkik/claude-plugins`. It carries `965b419`, so every command succeeds and the
diff quietly compares against the wrong repository. Reading the URL is what
catches it.

## Version numbers do not line up, and never will

Both projects independently reached `0.6.0` with **completely different code**.
This fork jumped to `0.7.0` to get clear of the collision. Now at `0.8.0` after
porting upstream v0.7.0. Never assume a shared version number means shared code —
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

### Divergences from upstream v0.7.0

**Caller-chosen effort is retained; upstream's fixed `xhigh` pins are NOT adopted.** Upstream has long defaulted every lane (sol, terra, luna, reviewer) to a hardcoded `xhigh` — at the *previous* sync point (`965b419`), upstream's `codex-implementer-sol.md:3` already read "at xhigh effort", so v0.7.0 did not convert anything; those diff rows are context-only. Caller-chosen per-dispatch effort has only ever existed in this fork — it is fork-only, not a capability upstream removed. Upstream's agents also still let an explicitly requested effort override the `xhigh` pin, so upstream's `xhigh` is a strong *default*, not a fixed effort; "adopting the pins would delete a capability" would therefore have overstated the difference. This fork keeps per-lane defaults that a dispatch can override because the user explicitly asked for effort to stay a per-job decision, and because the fork's `lib/review-with-effort.mjs` driver exists specifically to make effort a per-dispatch decision on the review path.

**Upstream's lane-pin test block was not ported.** Upstream's suite asserts that sol/terra/luna/reviewer dispatch at a fixed `xhigh` regardless of the caller's request. This fork deliberately does not have that behavior (see above), so porting the test block would assert something the fork intentionally does not do; it stays unported until the pin decision itself changes.

**Lane defaults lowered to `medium`.** `codex-implementer-sol` and `codex-reviewer` previously defaulted to `high`; both now default to `medium`. `terra` stays `medium`, `luna` stays `low`. The sensitivity override is unchanged: auth/credentials, Terraform or CI work still uses `xhigh` regardless of lane default.

**Astra was ported into the fork's idiom, not copied verbatim.** Upstream's `agents/codex-implementer-astra.md` documents exit code **4** for SUPERSEDED and prefixes every command with `cd <sandbox root> && `. This fork uses exit code **5** for SUPERSEDED and the "run from the directory you launched from; `crew-codex` probes sibling state directories on a miss" idiom. Copying upstream's file verbatim would have shipped a wrong exit code.

## Fork-only features (upstream has none of these)

Do not expect a port to touch them, and do not let one regress them:

- `adversarial-review --effort` and `lib/review-with-effort.mjs`
- the deterministic sensitivity gate (`lib/review-with-effort.mjs`,
  `SENSITIVE_PATH_RULES` / `SENSITIVE_CONTENT_RULES` / `resolveEffectiveEffort`):
  classifies the changed files of an `adversarial-review --effort` dispatch
  (Terraform, Bicep/ARM, CloudFormation, Kubernetes RBAC/NetworkPolicy, CI/CD,
  secret material, auth-ish source paths) and RAISES the effort to `xhigh` on a
  match — never lowers, always announces the match on stderr.
  `CREW_CODEX_SENSITIVITY_OVERRIDE="<reason>"` opts out for one dispatch and
  requires a non-empty value (only emptiness is checked — see Known gaps).
  Upstream has nothing like it.
  ⚠️ **SCOPE LIMIT**: only `adversarial-review` invoked *with* `--effort` goes
  through this gate. The `task` path is not covered, and `adversarial-review`
  with no `--effort` routes to the vendor review path ungated (see Known gaps).
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
- `adversarial-review` invoked with **no `--effort`** bypasses the sensitivity
  gate and the effort driver entirely — it runs through the vendor review path
  at whatever `model_reasoning_effort` the codex config carries, even on a
  Terraform/CI/auth-touching diff. The gate only ever sees a dispatch that
  already passed `--effort`.
- `CREW_CODEX_SENSITIVITY_OVERRIDE` enforces only that its value is **non-empty**,
  not that it is reason-shaped (`lib/review-with-effort.mjs`, the
  `override !== ""` check). `CREW_CODEX_SENSITIVITY_OVERRIDE=1` therefore
  satisfies the "written reason" requirement and bypasses the gate, recording
  `stated reason: 1`. That is exactly the flip-it-once-in-a-shell-profile switch
  the surrounding comment says the reason string exists to prevent. The
  override's loud stderr block still fires, so the bypass is never silent — but
  the reason it prints can be meaningless. Wants a minimum-length or
  multi-word check.

## Open questions

- **UNVERIFIED**: upstream claims `gpt-5.4-mini` was retired 2026-08-31.
  `codex-crew/README.md` and `codex-crew/skills/crew-runtime/SKILL.md` still
  offer it (the `mini` → `gpt-5.4-mini` alias). This claim has not been checked
  against the actual model registry or a live dispatch, and the `mini`
  references are deliberately left in place — removing them on an unverified
  retirement claim risks breaking a lane that still works. Verify against a
  live Codex CLI/API call before acting on this.
