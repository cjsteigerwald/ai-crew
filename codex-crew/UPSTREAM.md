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
| Synced to | **v0.6.1**, commit `965b419` (`test(codex-crew): make the suite leave nothing behind`) |
| Synced on | 2026-08-28 |
| This plugin's version | **0.7.0** |

Upstream is a git remote here, so the next port is a diff and not an
investigation:

```bash
git remote add upstream https://github.com/sidkik/claude-plugins.git   # once
git fetch upstream --tags
git diff 965b419 upstream/main -- codex-crew/
```

## Version numbers do not line up, and never will

Both projects independently reached `0.6.0` with **completely different code**.
This fork jumped to `0.7.0` to get clear of the collision. Never assume a shared
version number means shared code — compare against the commit in the table
above, never against a tag name.

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

## Fork-only features (upstream has none of these)

Do not expect a port to touch them, and do not let one regress them:

- `adversarial-review --effort` and `lib/review-with-effort.mjs`
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
