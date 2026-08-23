#!/usr/bin/env bash
# Resolver tests for bin/crew-codex. Uses a throwaway CLAUDE_CONFIG_DIR;
# never touches the real ~/.claude.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREW="$HERE/../bin/crew-codex"
REPO="$(cd "$HERE/.." && pwd)"
TMP="$(mktemp -d)"
# chmod before rm: several cases create mode-000 fixtures to prove that
# "unreadable" never reads as "absent", and rm -rf cannot descend into one.
trap 'chmod -R u+rwX "$TMP" 2>/dev/null || true; rm -rf "$TMP"' EXIT

# ⚠️ SHARED-STATE SAFETY. This machine runs several Claude Code sessions at
# once, and every one of them keeps job registries under
# ~/.claude/plugins/data/codex-openai-codex/state. If any of these variables
# leaked in from the invoking shell, a reap case below would sweep, chmod or
# DELETE another live session's state. Every case sets what it needs against a
# fixture under $TMP; nothing may be inherited.
unset CLAUDE_PLUGIN_DATA CREW_CODEX_ARCHIVE_DIR CREW_CODEX_BROKER_PATTERN \
      CREW_CODEX_SOCKET_GLOB CREW_CODEX_REAP_LOG_AGE CREW_CODEX_POLL_SECS \
      CREW_CODEX_HUNG_SECS CREW_CODEX_HUNG_POLL_SECS CREW_CODEX_RETRY_DELAYS \
      CLAUDE_CONFIG_DIR
# Default CODEX_HOME to an empty fixture too: the dispatch stamp reads
# config.toml from it, and reading the developer's real codex config would make
# effortConfig assertions depend on the machine.
mkdir -p "$TMP/no-codex-home"
export CODEX_HOME="$TMP/no-codex-home"

# ⚠️ EVERY `reap --brokers` case must pin CREW_CODEX_BROKER_PATTERN. The default
# is the real `app-server-broker` pattern, so an unpinned case would pgrep the
# live brokers of every other Claude Code session on this machine and print
# them as candidates. $NOMATCH is for the cases that only exercise the registry
# survey and want zero process discovery.
NOMATCH="crewtest-nomatch-$$"

pass=0
fail=0
skipped=0

# A skip is NOT a pass. Cases that cannot run (root defeats chmod 000, say)
# print SKIP and increment nothing but the skip counter, so a suite that
# silently stopped testing something cannot report a full green.
skip() {
  echo "SKIP: $1 ($2)"
  skipped=$((skipped + 1))
}

check() {
  local name="$1" expected_exit="$2" grep_for="$3" actual_exit="$4" output="$5"
  if [[ "$actual_exit" == "$expected_exit" ]] && grep -q "$grep_for" <<<"$output"; then
    echo "PASS: $name"
    pass=$((pass + 1))
  else
    echo "FAIL: $name (exit=$actual_exit, want=$expected_exit; output: $output)"
    fail=$((fail + 1))
  fi
}

# Asserts the fake companion recorded NO invocation — the whole point of the
# usage guards is that a help/--effort request never becomes a dispatch at all.
check_no_dispatch() {
  local name="$1" record="$2"
  # A MISSING record is not an empty one: it means the fake companion was never
  # wired up (or the case forgot to truncate it), so "nothing was dispatched"
  # would be asserted by a file that never existed. Fail instead of passing on
  # the absence — the same absent-vs-unreadable confusion this release exists
  # to remove from the reap paths.
  if [[ ! -f "$record" ]]; then
    echo "FAIL: $name (no invocation record at $record — this assertion proved nothing)"
    fail=$((fail + 1))
  elif [[ ! -s "$record" ]]; then
    echo "PASS: $name"
    pass=$((pass + 1))
  else
    echo "FAIL: $name (companion was invoked with: $(cat "$record"))"
    fail=$((fail + 1))
  fi
}

# Case 1: missing installed_plugins.json -> loud error, exit 1
out="$(CLAUDE_CONFIG_DIR="$TMP/empty" bash "$CREW" --resolve 2>&1)" && rc=0 || rc=$?
check "missing installed_plugins.json" 1 "install the official Codex plugin" "$rc" "$out"

# Case 2: codex plugin absent from installed_plugins.json -> loud error, exit 1
mkdir -p "$TMP/no-codex/plugins"
echo '{"version":2,"plugins":{"other@mp":[{"installPath":"/nowhere"}]}}' > "$TMP/no-codex/plugins/installed_plugins.json"
out="$(CLAUDE_CONFIG_DIR="$TMP/no-codex" bash "$CREW" --resolve 2>&1)" && rc=0 || rc=$?
check "codex plugin not installed" 1 "is not installed" "$rc" "$out"

# Case 3: entry present but companion script missing -> loud layout error, exit 1
mkdir -p "$TMP/stale/plugins" "$TMP/stale/fake-install"
echo "{\"version\":2,\"plugins\":{\"codex@openai-codex\":[{\"installPath\":\"$TMP/stale/fake-install\"}]}}" > "$TMP/stale/plugins/installed_plugins.json"
out="$(CLAUDE_CONFIG_DIR="$TMP/stale" bash "$CREW" --resolve 2>&1)" && rc=0 || rc=$?
check "companion script missing" 1 "layout changed" "$rc" "$out"

# Case 4: happy path with a fake companion -> resolves path, exit 0
mkdir -p "$TMP/happy/plugins" "$TMP/happy/install/scripts"
touch "$TMP/happy/install/scripts/codex-companion.mjs"
echo "{\"version\":2,\"plugins\":{\"codex@openai-codex\":[{\"installPath\":\"$TMP/happy/install\"}]}}" > "$TMP/happy/plugins/installed_plugins.json"
out="$(CLAUDE_CONFIG_DIR="$TMP/happy" bash "$CREW" --resolve 2>&1)" && rc=0 || rc=$?
check "happy path resolve" 0 "$TMP/happy/install/scripts/codex-companion.mjs" "$rc" "$out"

# Case 5: happy path forwards argv to the companion (exec node <companion> <args>)
cat > "$TMP/happy/install/scripts/codex-companion.mjs" <<'EOF'
console.log("ARGS:" + process.argv.slice(2).join(","));
console.log("DATA:" + (process.env.CLAUDE_PLUGIN_DATA || "unset"));
EOF
out="$(CLAUDE_CONFIG_DIR="$TMP/happy" env -u CLAUDE_PLUGIN_DATA bash "$CREW" status --json 2>&1)" && rc=0 || rc=$?
check "argv forwarding" 0 "ARGS:status,--json" "$rc" "$out"
check "CLAUDE_PLUGIN_DATA default" 0 "DATA:$TMP/happy/plugins/data/codex-openai-codex" "$rc" "$out"

# --- Capacity-retry cases: fake companion whose behavior depends on attempt count ---
mkdir -p "$TMP/retry/plugins" "$TMP/retry/install/scripts"
echo "{\"version\":2,\"plugins\":{\"codex@openai-codex\":[{\"installPath\":\"$TMP/retry/install\"}]}}" > "$TMP/retry/plugins/installed_plugins.json"
cat > "$TMP/retry/install/scripts/codex-companion.mjs" <<'EOF'
import fs from "node:fs";
const counter = process.env.CREW_TEST_COUNTER;
const failuresBeforeSuccess = Number(process.env.CREW_TEST_FAILURES ?? 0);
const failureMessage = process.env.CREW_TEST_FAILURE_MSG ?? "Selected model is at capacity";
let n = 0;
try { n = Number(fs.readFileSync(counter, "utf8")); } catch {}
n += 1;
fs.writeFileSync(counter, String(n));
if (n <= failuresBeforeSuccess) {
  console.error(`[codex] Turn failed: ${failureMessage}`);
  process.exit(1);
}
console.log("TASK-RESULT-OK");
EOF

run_retry() {
  CLAUDE_CONFIG_DIR="$TMP/retry" CREW_CODEX_RETRY_DELAYS="0 0" \
  CREW_TEST_COUNTER="$1" CREW_TEST_FAILURES="$2" CREW_TEST_FAILURE_MSG="${3:-Selected model is at capacity}" \
    bash "$CREW" task "test prompt" 2>&1
}

# Case 7: capacity failure twice, then success -> retried to success, exit 0
c="$TMP/retry/c7"; out="$(run_retry "$c" 2)" && rc=0 || rc=$?
attempts="$(cat "$c")"
check "capacity retry then success" 0 "TASK-RESULT-OK" "$rc" "$out"
check "capacity retry attempt count" 0 "^3$" "$rc" "$attempts"

# Case 8: capacity failure exhausts all attempts -> loud give-up, nonzero exit
c="$TMP/retry/c8"; out="$(run_retry "$c" 99)" && rc=0 || rc=$?
attempts="$(cat "$c")"
check "capacity exhausted gives up" 1 "still at capacity after 3 attempts" "$rc" "$out"
check "capacity exhausted attempt count" 1 "^3$" "$rc" "$attempts"

# Case 9: non-capacity failure -> NO retry, error and exit code pass through
c="$TMP/retry/c9"; out="$(run_retry "$c" 99 "authentication expired")" && rc=0 || rc=$?
attempts="$(cat "$c")"
check "non-capacity failure not retried" 1 "authentication expired" "$rc" "$out"
check "non-capacity single attempt" 1 "^1$" "$rc" "$attempts"

# Case 10: real (1s) delay exercises the sleep + jitter arithmetic path
c="$TMP/retry/c10"
start=$(date +%s)
out="$(CLAUDE_CONFIG_DIR="$TMP/retry" CREW_CODEX_RETRY_DELAYS="1" \
  CREW_TEST_COUNTER="$c" CREW_TEST_FAILURES=1 bash "$CREW" task "test prompt" 2>&1)" && rc=0 || rc=$?
elapsed=$(( $(date +%s) - start ))
check "real-delay retry succeeds" 0 "TASK-RESULT-OK" "$rc" "$out"
if [[ "$elapsed" -ge 1 ]]; then
  echo "PASS: real-delay retry actually slept (${elapsed}s)"
  pass=$((pass + 1))
else
  echo "FAIL: real-delay retry did not sleep (${elapsed}s)"
  fail=$((fail + 1))
fi

# --- await cases: fake companion serving status/result for a synthetic job ---
mkdir -p "$TMP/await/plugins" "$TMP/await/install/scripts"
echo "{\"version\":2,\"plugins\":{\"codex@openai-codex\":[{\"installPath\":\"$TMP/await/install\"}]}}" > "$TMP/await/plugins/installed_plugins.json"
cat > "$TMP/await/install/scripts/codex-companion.mjs" <<'EOF'
import fs from "node:fs";
const [cmd, jobId, flag] = process.argv.slice(2);
if (jobId === "task-missing") { console.log("{}"); process.exit(0); }
if (cmd === "result") {
  if (flag === "--json") console.log(JSON.stringify({ storedJob: { id: jobId, result: { rawOutput: "FINAL-RESULT" } } }));
  else console.log("FINAL-RESULT");
  process.exit(0);
}
// status: report `running` for CREW_TEST_RUNNING_POLLS polls, then terminal.
const counter = process.env.CREW_TEST_COUNTER;
const runningPolls = Number(process.env.CREW_TEST_RUNNING_POLLS ?? 0);
const terminal = process.env.CREW_TEST_TERMINAL ?? "completed";
let n = 0;
try { n = Number(fs.readFileSync(counter, "utf8")); } catch {}
n += 1;
fs.writeFileSync(counter, String(n));
const status = n <= runningPolls ? "running" : terminal;
console.log(JSON.stringify({
  job: { id: jobId, status, elapsed: `${n * 5}s`, logFile: "-", progressPreview: ["Turn started.", `poll ${n}`] }
}));
EOF

# Case 11: job already terminal -> DONE completed, exit 0, result archived
c="$TMP/await/c11"; arc="$TMP/await/archive11"
out="$(CLAUDE_CONFIG_DIR="$TMP/await" CREW_CODEX_ARCHIVE_DIR="$arc" CREW_CODEX_POLL_SECS=0 \
  CREW_TEST_COUNTER="$c" CREW_TEST_RUNNING_POLLS=0 bash "$CREW" await task-x --for 5 2>&1)" && rc=0 || rc=$?
check "await terminal completed" 0 "DONE completed" "$rc" "$out"
check "await archived result" 0 "FINAL-RESULT" "$rc" "$(cat "$arc/task-x.result.txt" 2>/dev/null)"

# Case 12: job running past the deadline -> RUNNING line, exit 10, no archive
c="$TMP/await/c12"; arc="$TMP/await/archive12"
out="$(CLAUDE_CONFIG_DIR="$TMP/await" CREW_CODEX_ARCHIVE_DIR="$arc" CREW_CODEX_POLL_SECS=0 \
  CREW_TEST_COUNTER="$c" CREW_TEST_RUNNING_POLLS=9999 bash "$CREW" await task-x --for 1 2>&1)" && rc=0 || rc=$?
check "await still running exits 10" 10 "RUNNING" "$rc" "$out"
check "await surfaces last progress" 10 "last: poll" "$rc" "$out"

# Case 13: job running then completing -> polls through, then DONE, exit 0
c="$TMP/await/c13"; arc="$TMP/await/archive13"
out="$(CLAUDE_CONFIG_DIR="$TMP/await" CREW_CODEX_ARCHIVE_DIR="$arc" CREW_CODEX_POLL_SECS=0 \
  CREW_TEST_COUNTER="$c" CREW_TEST_RUNNING_POLLS=3 bash "$CREW" await task-x --for 30 2>&1)" && rc=0 || rc=$?
check "await polls then completes" 0 "DONE completed" "$rc" "$out"
check "await polled 4 times" 0 "^4$" "$rc" "$(cat "$c")"

# Case 14: terminal failure -> DONE failed, exit 1
c="$TMP/await/c14"; arc="$TMP/await/archive14"
out="$(CLAUDE_CONFIG_DIR="$TMP/await" CREW_CODEX_ARCHIVE_DIR="$arc" CREW_CODEX_POLL_SECS=0 \
  CREW_TEST_COUNTER="$c" CREW_TEST_RUNNING_POLLS=0 CREW_TEST_TERMINAL=failed bash "$CREW" await task-x --for 5 2>&1)" && rc=0 || rc=$?
check "await failed job exits 1" 1 "DONE failed" "$rc" "$out"

# Case 15: unknown job -> exit 2 after tolerating transient misses
c="$TMP/await/c15"
out="$(CLAUDE_CONFIG_DIR="$TMP/await" CREW_CODEX_POLL_SECS=0 \
  CREW_TEST_COUNTER="$c" bash "$CREW" await task-missing --for 30 2>&1)" && rc=0 || rc=$?
check "await unknown job exits 2" 2 "not found in codex state" "$rc" "$out"

# --- pid-aware await: blocks on the job process, detects silent death --------
cat > "$TMP/await/install/scripts/pid-companion.mjs" <<'EOF'
import fs from "node:fs";
const [cmd, jobId, flag] = process.argv.slice(2);
if (cmd === "result") { console.log("FINAL-RESULT"); process.exit(0); }
const counter = process.env.CREW_TEST_COUNTER;
const pid = process.env.CREW_TEST_PID ?? "-";
const runningPolls = Number(process.env.CREW_TEST_RUNNING_POLLS ?? 0);
let n = 0;
try { n = Number(fs.readFileSync(counter, "utf8")); } catch {}
n += 1;
fs.writeFileSync(counter, String(n));
const status = n <= runningPolls ? "running" : "completed";
console.log(JSON.stringify({
  job: { id: jobId, status, elapsed: `${n}s`, logFile: "-", pid: Number(pid), progressPreview: [`poll ${n}`] }
}));
EOF
cp "$TMP/await/install/scripts/pid-companion.mjs" "$TMP/await/install/scripts/codex-companion.mjs"

# Case 17: live pid -> await blocks on the process, returns when it exits
sleep 2 & LIVE_PID=$!
c="$TMP/await/c17"; arc="$TMP/await/archive17"
start=$(date +%s)
out="$(CLAUDE_CONFIG_DIR="$TMP/await" CREW_CODEX_ARCHIVE_DIR="$arc" \
  CREW_TEST_COUNTER="$c" CREW_TEST_PID="$LIVE_PID" CREW_TEST_RUNNING_POLLS=1 \
  bash "$CREW" await task-x --for 30 2>&1)" && rc=0 || rc=$?
elapsed=$(( $(date +%s) - start ))
wait "$LIVE_PID" 2>/dev/null || true
check "pid-block completes on process exit" 0 "DONE completed" "$rc" "$out"
if [[ "$elapsed" -ge 2 && "$elapsed" -le 8 ]]; then
  echo "PASS: pid-block woke on exit, not on poll timer (${elapsed}s)"
  pass=$((pass + 1))
else
  echo "FAIL: pid-block timing off (${elapsed}s, expected 2-8s)"
  fail=$((fail + 1))
fi

# Case 18: dead pid + status stuck running -> STALE, exit 3 (silent-death signal)
DEAD_PID=$(bash -c 'echo $$')
c="$TMP/await/c18"
out="$(CLAUDE_CONFIG_DIR="$TMP/await" CREW_CODEX_POLL_SECS=0 \
  CREW_TEST_COUNTER="$c" CREW_TEST_PID="$DEAD_PID" CREW_TEST_RUNNING_POLLS=9999 \
  bash "$CREW" await task-x --for 30 2>&1)" && rc=0 || rc=$?
check "stale job detected" 3 "died without reporting" "$rc" "$out"

# restore the plain fake for any later cases
cat > "$TMP/await/install/scripts/codex-companion.mjs" <<'EOF'
import fs from "node:fs";
const [cmd, jobId, flag] = process.argv.slice(2);
if (jobId === "task-missing") { console.log("{}"); process.exit(0); }
if (cmd === "result") { console.log("FINAL-RESULT"); process.exit(0); }
console.log(JSON.stringify({ job: { id: jobId, status: "completed", elapsed: "1s", logFile: "-", pid: null, progressPreview: ["done"] } }));
EOF

# Case 16: await requires a job id
out="$(CLAUDE_CONFIG_DIR="$TMP/await" bash "$CREW" await --for 5 2>&1)" && rc=0 || rc=$?
check "await without job id" 2 "needs a job id" "$rc" "$out"

# --- hung-turn await: pid alive but the job log stopped moving ---------------
cat > "$TMP/await/install/scripts/codex-companion.mjs" <<'EOF'
import fs from "node:fs";
const [cmd, jobId, flag] = process.argv.slice(2);
if (cmd === "result") { console.log("FINAL-RESULT"); process.exit(0); }
console.log(JSON.stringify({
  job: { id: jobId, status: "running", elapsed: "99s",
         logFile: process.env.CREW_TEST_LOG ?? "-",
         pid: Number(process.env.CREW_TEST_PID ?? "-"),
         progressPreview: ["Turn started."] }
}));
EOF

# Case 19: live pid + frozen log -> HUNG, exit 4
sleep 30 & HUNG_PID=$!
frozen="$TMP/await/frozen.log"; echo x > "$frozen"; touch -d '10 minutes ago' "$frozen"
out="$(CLAUDE_CONFIG_DIR="$TMP/await" CREW_CODEX_HUNG_SECS=2 CREW_CODEX_HUNG_POLL_SECS=1 \
  CREW_TEST_PID="$HUNG_PID" CREW_TEST_LOG="$frozen" \
  bash "$CREW" await task-x --for 30 2>&1)" && rc=0 || rc=$?
check "hung turn detected (frozen log, live pid)" 4 "HUNG task-x" "$rc" "$out"

# Case 20: live pid + fresh log -> not hung, plain RUNNING at deadline, exit 10
fresh="$TMP/await/fresh.log"; echo x > "$fresh"
out="$(CLAUDE_CONFIG_DIR="$TMP/await" CREW_CODEX_HUNG_POLL_SECS=1 \
  CREW_TEST_PID="$HUNG_PID" CREW_TEST_LOG="$fresh" \
  bash "$CREW" await task-x --for 2 2>&1)" && rc=0 || rc=$?
check "fresh log does not false-fire hung" 10 "RUNNING" "$rc" "$out"
kill "$HUNG_PID" 2>/dev/null || true

# --- reap: sweep stuck registry entries --------------------------------------
# repo-a: dead-pid job alone (reapable, has state.json to mirror into)
# repo-b: live job + frozen job + done job (frozen must be SKIPPED — live ws)
# repo-c: frozen no-pid job alone (reapable via log age)
REAP_DATA="$TMP/reap-data"
mkdir -p "$REAP_DATA/state/repo-a/jobs" "$REAP_DATA/state/repo-b/jobs" "$REAP_DATA/state/repo-c/jobs"
DEAD_PID2=$(bash -c 'echo $$')
oldlog="$REAP_DATA/state/repo-a/jobs/dead.log"; echo x > "$oldlog"; touch -d '2 hours ago' "$oldlog"
cat > "$REAP_DATA/state/repo-a/jobs/dead.json" <<EOF
{"id":"job-dead","status":"running","pid":$DEAD_PID2,"logFile":"$oldlog","createdAt":"2026-07-01T00:00:00Z"}
EOF
cat > "$REAP_DATA/state/repo-a/state.json" <<EOF
[{"id":"job-dead","status":"running","pid":$DEAD_PID2},{"id":"job-other","status":"completed"}]
EOF
frozenlog="$REAP_DATA/state/repo-b/jobs/frozen.log"; echo x > "$frozenlog"; touch -d '2 hours ago' "$frozenlog"
cat > "$REAP_DATA/state/repo-b/jobs/frozen.json" <<EOF
{"id":"job-frozen","status":"running","logFile":"$frozenlog","createdAt":"2026-07-01T00:00:00Z"}
EOF
livelog="$REAP_DATA/state/repo-b/jobs/live.log"; echo x > "$livelog"
cat > "$REAP_DATA/state/repo-b/jobs/live.json" <<EOF
{"id":"job-live","status":"running","pid":$$,"logFile":"$livelog","createdAt":"2026-08-06T00:00:00Z"}
EOF
cat > "$REAP_DATA/state/repo-b/jobs/done.json" <<EOF
{"id":"job-done","status":"completed"}
EOF
frozenlog2="$REAP_DATA/state/repo-c/jobs/frozen2.log"; echo x > "$frozenlog2"; touch -d '2 hours ago' "$frozenlog2"
cat > "$REAP_DATA/state/repo-c/jobs/frozen2.json" <<EOF
{"id":"job-frozen2","status":"running","logFile":"$frozenlog2","createdAt":"2026-07-01T00:00:00Z"}
EOF

# Case 21: dry-run reports but mutates nothing
out="$(CLAUDE_CONFIG_DIR="$TMP/await" CLAUDE_PLUGIN_DATA="$REAP_DATA" \
  bash "$CREW" reap --dry-run 2>&1)" && rc=0 || rc=$?
check "reap dry-run flags dead job" 0 "would reap: repo-a/job-dead" "$rc" "$out"
check "reap dry-run skips live workspace" 0 "skipped: repo-b/job-frozen" "$rc" "$out"
check "reap dry-run summary" 0 "2 flagged, 1 kept, 1 skipped" "$rc" "$out"
if grep -q '"status":"running"' "$REAP_DATA/state/repo-a/jobs/dead.json"; then
  echo "PASS: dry-run left state untouched"; pass=$((pass + 1))
else
  echo "FAIL: dry-run mutated state"; fail=$((fail + 1))
fi

# Case 22: real reap marks dead+frozen failed, keeps live, mirrors state.json
out="$(CLAUDE_CONFIG_DIR="$TMP/await" CLAUDE_PLUGIN_DATA="$REAP_DATA" \
  bash "$CREW" reap 2>&1)" && rc=0 || rc=$?
check "reap marks stuck jobs failed" 0 "2 reaped, 1 kept, 1 skipped" "$rc" "$out"
if grep -q '"status": "failed"' "$REAP_DATA/state/repo-a/jobs/dead.json" \
   && grep -q '"status": "failed"' "$REAP_DATA/state/repo-c/jobs/frozen2.json" \
   && grep -q '"status":"running"' "$REAP_DATA/state/repo-b/jobs/live.json" \
   && grep -q '"status":"running"' "$REAP_DATA/state/repo-b/jobs/frozen.json"; then
  echo "PASS: reap mutated exactly the stuck jobs"; pass=$((pass + 1))
else
  echo "FAIL: reap touched the wrong jobs"; fail=$((fail + 1))
fi
if python3 -c "
import json,sys
s=json.load(open('$REAP_DATA/state/repo-a/state.json'))
d={e['id']:e for e in s}
assert d['job-dead']['status']=='failed' and d['job-dead']['pid'] is None, d
assert d['job-other']['status']=='completed', d
"; then
  echo "PASS: state.json mirrored (failed + pid cleared, others untouched)"; pass=$((pass + 1))
else
  echo "FAIL: state.json not mirrored correctly"; fail=$((fail + 1))
fi

# --- usage guards: a help/--effort request must never become a dispatch ------
# The fake companion records every invocation, so "did not dispatch" is an
# assertion about the file being empty rather than about the output text.
mkdir -p "$TMP/guard/plugins" "$TMP/guard/install/scripts"
echo "{\"version\":2,\"plugins\":{\"codex@openai-codex\":[{\"installPath\":\"$TMP/guard/install\"}]}}" > "$TMP/guard/plugins/installed_plugins.json"
cat > "$TMP/guard/install/scripts/codex-companion.mjs" <<'EOF'
import fs from "node:fs";
fs.appendFileSync(process.env.CREW_TEST_INVOKED, process.argv.slice(2).join("|") + "\n");
console.log("COMPANION-RAN:" + process.argv.slice(2).join("|"));
EOF

INVOKED="$TMP/guard/invoked.log"
run_guard() {
  : > "$INVOKED"
  CLAUDE_CONFIG_DIR="$TMP/guard" CREW_TEST_INVOKED="$INVOKED" bash "$CREW" "$@" 2>&1
}

# Case 23: adversarial-review --help prints usage, exits 0, dispatches nothing
out="$(run_guard adversarial-review --help)" && rc=0 || rc=$?
check "adversarial-review --help exits 0" 0 "crew-codex adversarial-review \[flags\]" "$rc" "$out"
check "adversarial-review --help names the effort source" 0 "model_reasoning_effort" "$rc" "$out"
check_no_dispatch "adversarial-review --help did not dispatch" "$INVOKED"

# Case 24: review -h and review help take the same path
out="$(run_guard review -h)" && rc=0 || rc=$?
check "review -h exits 0" 0 "crew-codex review \[flags\]" "$rc" "$out"
check_no_dispatch "review -h did not dispatch" "$INVOKED"
out="$(run_guard review help)" && rc=0 || rc=$?
check "bare 'help' as the FIRST arg exits 0" 0 "NO --effort flag" "$rc" "$out"
check_no_dispatch "review help did not dispatch" "$INVOKED"

# ...but a bare `help` anywhere LATER is focus text, not a help request, and
# must still dispatch. Focus prose arrives as unquoted positionals that the
# companion joins, so intercepting `help` at every position would silently
# swallow a real review and exit 0 — telling the caller it succeeded while
# reviewing nothing. Refusing to review is worse than printing usage late.
out="$(run_guard review --base main help)" && rc=0 || rc=$?
check "bare 'help' in a later position still forwards" 0 "COMPANION-RAN:review|--base|main|help" "$rc" "$out"

out="$(run_guard adversarial-review improve the help wording)" && rc=0 || rc=$?
check "unquoted focus prose containing 'help' still dispatches" 0 "COMPANION-RAN:adversarial-review|improve|the|help|wording" "$rc" "$out"

out="$(run_guard adversarial-review -h)" && rc=0 || rc=$?
check "-h as the FIRST arg exits 0" 0 "crew-codex adversarial-review \\[flags\\]" "$rc" "$out"
check_no_dispatch "-h first-arg did not dispatch" "$INVOKED"

# Case 25: --effort on the NATIVE review path is still refused loudly, exit 2,
# no dispatch. `review` maps to the companion's runAppServerReview path, which
# crew-codex's effort driver does not model — so unlike adversarial-review it
# cannot be honored, and pretending otherwise would be the silent-wrongness bug
# this guard exists to prevent. (adversarial-review --effort now ROUTES instead
# of refusing; that is covered by the effort-driver cases further down.)
out="$(run_guard review --effort high)" && rc=0 || rc=$?
check "review --effort refused" 2 "does not accept --effort" "$rc" "$out"
check "review --effort names the working alternative" 2 "adversarial-review --effort" "$rc" "$out"
check_no_dispatch "review --effort did not dispatch" "$INVOKED"

out="$(run_guard review --effort=xhigh "focus")" && rc=0 || rc=$?
check "review --effort=<v> refused" 2 "does not accept --effort" "$rc" "$out"
check_no_dispatch "review --effort=<v> did not dispatch" "$INVOKED"

# Case 26: interception is EXACT — legitimate focus text still forwards
out="$(run_guard adversarial-review --base main "does the help text render")" && rc=0 || rc=$?
check "focus text containing 'help' forwards" 0 "COMPANION-RAN:adversarial-review" "$rc" "$out"
check "focus text reaches the companion intact" 0 "does the help text render" "$rc" "$out"

out="$(run_guard adversarial-review --effortless --helpful "focus")" && rc=0 || rc=$?
check "non-intercepted --flags forward untouched" 0 "COMPANION-RAN:adversarial-review|--effortless|--helpful|focus" "$rc" "$out"

# Case 27: task --help is intercepted too — the companion has no help handler
# for `task` either, so forwarding it dispatches a real job whose PROMPT is the
# literal string "--help". Cheaper than an accidental review, still wasted.
out="$(run_guard task --help)" && rc=0 || rc=$?
check "task --help exits 0" 0 "crew-codex task \[flags\]" "$rc" "$out"
check "task usage advertises --effort" 0 "task DOES accept --effort" "$rc" "$out"
check_no_dispatch "task --help did not dispatch" "$INVOKED"

out="$(run_guard task -h)" && rc=0 || rc=$?
check "task -h exits 0" 0 "crew-codex task \[flags\]" "$rc" "$out"
check_no_dispatch "task -h did not dispatch" "$INVOKED"

# ...but a BARE `help` is NOT intercepted for task: a task prompt is a
# positional, so `task help` is a plausible (terse) real prompt, unlike
# `review help`. Over-intercepting here would break a legitimate dispatch.
out="$(run_guard task help)" && rc=0 || rc=$?
check "bare 'help' still forwards as a task prompt" 0 "COMPANION-RAN:task|help" "$rc" "$out"

# --effort remains legal on task — it is the one path that really supports it.
out="$(run_guard task --effort high "do the thing")" && rc=0 || rc=$?
check "task --effort forwards untouched" 0 "COMPANION-RAN:task|--effort|high|do the thing" "$rc" "$out"

# Case 28: bare crew-codex and top-level help print usage, forward nothing
out="$(run_guard)" && rc=0 || rc=$?
check "bare crew-codex exits 0" 0 "Subcommands crew-codex handles itself" "$rc" "$out"
check_no_dispatch "bare crew-codex did not dispatch" "$INVOKED"
for helpflag in --help -h help; do
  out="$(run_guard "$helpflag")" && rc=0 || rc=$?
  check "crew-codex $helpflag exits 0" 0 "forwarded verbatim to the codex plugin" "$rc" "$out"
  check_no_dispatch "crew-codex $helpflag did not dispatch" "$INVOKED"
done

# --- dispatch stamping: model + effort audit trail next to the archive -------
mkdir -p "$TMP/stamp/plugins" "$TMP/stamp/install/scripts" "$TMP/stamp/codex-home"
echo "{\"version\":2,\"plugins\":{\"codex@openai-codex\":[{\"installPath\":\"$TMP/stamp/install\"}]}}" > "$TMP/stamp/plugins/installed_plugins.json"
printf 'model_reasoning_effort = "xhigh"\n\n[profiles.cheap]\nmodel_reasoning_effort = "low"\n' > "$TMP/stamp/codex-home/config.toml"
cat > "$TMP/stamp/install/scripts/codex-companion.mjs" <<'EOF'
const line = process.env.CREW_TEST_LAUNCH_LINE ?? "";
if (line) console.log(line);
process.exit(Number(process.env.CREW_TEST_EXIT ?? 0));
EOF

run_stamp() {
  local archive="$1" launch="$2"; shift 2
  CLAUDE_CONFIG_DIR="$TMP/stamp" CREW_CODEX_ARCHIVE_DIR="$archive" \
  CODEX_HOME="$TMP/stamp/codex-home" CREW_TEST_LAUNCH_LINE="$launch" \
  CREW_CODEX_RETRY_DELAYS="0" bash "$CREW" "$@" 2>&1
}

# Case 29: a review dispatch stamps effort from the codex config
arc="$TMP/stamp/arc29"
out="$(run_stamp "$arc" "Adversarial Review started in the background as review-msi4zm8e-cpisj8. Check /codex:status" \
  adversarial-review --model gpt-5.6-sol --base main "focus")" && rc=0 || rc=$?
check "stamped dispatch passes output through" 0 "started in the background" "$rc" "$out"
if python3 -c "
import json
d = json.load(open('$arc/review-msi4zm8e-cpisj8.dispatch.json'))
assert d['jobId'] == 'review-msi4zm8e-cpisj8', d
assert d['subcommand'] == 'adversarial-review', d
assert d['model'] == 'gpt-5.6-sol', d
assert d['effortRequested'] is None, d
assert d['effortEffective'] == 'xhigh', d
assert d['effortSource'] == 'config', d
assert d['argv'][:3] == ['adversarial-review', '--model', 'gpt-5.6-sol'], d
"; then
  echo "PASS: review dispatch stamped model + config effort"; pass=$((pass + 1))
else
  echo "FAIL: review dispatch stamp malformed"; fail=$((fail + 1))
fi

# Case 30: a task dispatch records the flag effort AND the config value it beat
arc="$TMP/stamp/arc30"
out="$(run_stamp "$arc" "Codex Task started in the background as task-mrw7xw66-j3p2k0." \
  task --model gpt-5.6-luna --effort low "do a thing")" && rc=0 || rc=$?
if python3 -c "
import json
d = json.load(open('$arc/task-mrw7xw66-j3p2k0.dispatch.json'))
assert d['effortRequested'] == 'low', d
assert d['effortEffective'] == 'low', d
assert d['effortConfig'] == 'xhigh', d
assert d['effortSource'] == 'flag', d
assert d['model'] == 'gpt-5.6-luna', d
"; then
  echo "PASS: task dispatch stamped flag effort over config"; pass=$((pass + 1))
else
  echo "FAIL: task dispatch stamp malformed"; fail=$((fail + 1))
fi

# Case 31: no job id in the output -> nothing written, nothing broken
arc="$TMP/stamp/arc31"
out="$(run_stamp "$arc" "Review finished inline; no job was created." adversarial-review "focus")" && rc=0 || rc=$?
if [[ "$rc" == 0 ]] && [[ -z "$(ls -A "$arc" 2>/dev/null || true)" ]]; then
  echo "PASS: no job id stamps nothing and still exits 0"; pass=$((pass + 1))
else
  echo "FAIL: stamped without a job id (rc=$rc, dir: $(ls -A "$arc" 2>/dev/null))"; fail=$((fail + 1))
fi

# Case 32: a stamping failure changes neither exit code nor stdout. The archive
# path is a regular FILE, so mkdir -p fails and the whole block is swallowed.
blocked="$TMP/stamp/not-a-dir"; : > "$blocked"
out="$(CLAUDE_CONFIG_DIR="$TMP/stamp" CREW_CODEX_ARCHIVE_DIR="$blocked" \
  CODEX_HOME="$TMP/stamp/codex-home" CREW_CODEX_RETRY_DELAYS="0" \
  CREW_TEST_LAUNCH_LINE="started in the background as review-aaa1-bbb2." \
  bash "$CREW" adversarial-review "focus" 2>&1)" && rc=0 || rc=$?
if [[ "$rc" == 0 && "$out" == "started in the background as review-aaa1-bbb2." ]]; then
  echo "PASS: unwritable archive left exit code and stdout untouched"; pass=$((pass + 1))
else
  echo "FAIL: stamping failure leaked (rc=$rc, out: $out)"; fail=$((fail + 1))
fi

# Case 33: a failing dispatch keeps its own exit code through the stamp
arc="$TMP/stamp/arc33"
out="$(CLAUDE_CONFIG_DIR="$TMP/stamp" CREW_CODEX_ARCHIVE_DIR="$arc" \
  CODEX_HOME="$TMP/stamp/codex-home" CREW_CODEX_RETRY_DELAYS="0" \
  CREW_TEST_LAUNCH_LINE="started in the background as task-ccc3-ddd4." CREW_TEST_EXIT=7 \
  bash "$CREW" task "prompt" 2>&1)" && rc=0 || rc=$?
check "failing dispatch keeps its exit code" 7 "task-ccc3-ddd4" "$rc" "$out"
if [[ -f "$arc/task-ccc3-ddd4.dispatch.json" ]]; then
  echo "PASS: failing dispatch is still stamped"; pass=$((pass + 1))
else
  echo "FAIL: failing dispatch was not stamped"; fail=$((fail + 1))
fi

# --- reap --brokers / --state: dead-cwd sweeps, all against throwaway data ----
# NOTHING here runs a destructive sweep against the real machine: every case
# points CLAUDE_PLUGIN_DATA, the broker pgrep pattern and the socket glob at
# fixtures under $TMP, and every kill path is exercised in --dry-run only.
GONE_WS="$TMP/gone-workspace"   # deliberately never created

# sweep-data: dead cwd + live cwd + unresolvable + a dir held by a live job
SWEEP="$TMP/sweep-data/state"
mkdir -p "$SWEEP/dead-ws/jobs" "$SWEEP/live-ws/jobs" "$SWEEP/unresolved-ws" "$SWEEP/busy-ws/jobs"
cat > "$SWEEP/dead-ws/state.json" <<EOF
{"version":1,"jobs":[{"id":"task-dead-1","status":"completed","workspaceRoot":"$GONE_WS"}]}
EOF
cat > "$SWEEP/dead-ws/jobs/task-dead-1.json" <<EOF
{"id":"task-dead-1","status":"completed","workspaceRoot":"$GONE_WS"}
EOF
cat > "$SWEEP/live-ws/state.json" <<EOF
{"version":1,"jobs":[{"id":"task-live-1","status":"completed","workspaceRoot":"$TMP"}]}
EOF
echo '{"version":1,"jobs":[]}' > "$SWEEP/unresolved-ws/state.json"
cat > "$SWEEP/busy-ws/state.json" <<EOF
{"version":1,"jobs":[{"id":"task-busy-1","status":"running","workspaceRoot":"$GONE_WS"}]}
EOF
cat > "$SWEEP/busy-ws/jobs/task-busy-1.json" <<EOF
{"id":"task-busy-1","status":"running","pid":$$,"workspaceRoot":"$GONE_WS","createdAt":"2026-08-23T00:00:00Z"}
EOF

# Case 34: --state --dry-run classifies all four dirs and deletes nothing
out="$(CLAUDE_CONFIG_DIR="$TMP/await" CLAUDE_PLUGIN_DATA="$TMP/sweep-data" \
  bash "$CREW" reap --state --dry-run 2>&1)" && rc=0 || rc=$?
check "state dry-run flags the dead-cwd dir" 0 "would prune state dir: $SWEEP/dead-ws" "$rc" "$out"
check "state dry-run keeps the live-cwd dir" 0 "state kept: live-ws" "$rc" "$out"
check "state dry-run reports the unresolvable dir" 0 "state unresolved: unresolved-ws" "$rc" "$out"
check "state dry-run refuses a dir with a non-terminal job" 0 "state blocked: busy-ws .* non-terminal" "$rc" "$out"
check "state dry-run summary counts" 0 "reap state summary: 1 would prune, 1 kept (cwd alive), 1 blocked (non-terminal, live pid or unreadable), 1 unresolved" "$rc" "$out"
if [[ -d "$SWEEP/dead-ws" ]]; then
  echo "PASS: state dry-run deleted nothing"; pass=$((pass + 1))
else
  echo "FAIL: state dry-run deleted a state dir"; fail=$((fail + 1))
fi

# Case 35: --brokers is REPORT-ONLY. It no longer refuses (there is no kill to
# refuse) and it no longer opens a gate — it prints an advisory survey that
# names every non-terminal record, so a human deciding whether to kill a pid
# sees that another session may own it.
out="$(CLAUDE_CONFIG_DIR="$TMP/await" CLAUDE_PLUGIN_DATA="$TMP/sweep-data" \
  CREW_CODEX_BROKER_PATTERN="$NOMATCH" \
  bash "$CREW" reap --brokers --dry-run 2>&1)" && rc=0 || rc=$?
check "brokers sweep announces report-only" 0 "REPORT ONLY" "$rc" "$out"
check "brokers survey names the non-terminal job" 0 "busy-ws/task-busy-1(running)" "$rc" "$out"
check "brokers accepts a redundant --dry-run" 0 "dry-run is redundant with --brokers" "$rc" "$out"
if ! grep -qi "REFUSED" <<<"$out"; then
  echo "PASS: brokers no longer refuses on a live job"; pass=$((pass + 1))
else
  echo "FAIL: brokers still refuses (output: $out)"; fail=$((fail + 1))
fi

# Case 36: unknown reap flags are rejected, not silently treated as a real run
out="$(CLAUDE_CONFIG_DIR="$TMP/await" CLAUDE_PLUGIN_DATA="$TMP/sweep-data" \
  bash "$CREW" reap --dryrun 2>&1)" && rc=0 || rc=$?
check "reap rejects an unknown flag" 2 "unknown flag" "$rc" "$out"

# sweep-clean: same fixtures minus the live job, so the broker gate opens
CLEAN="$TMP/sweep-clean/state"
mkdir -p "$CLEAN"
cp -r "$SWEEP/dead-ws" "$SWEEP/live-ws" "$SWEEP/unresolved-ws" "$CLEAN/"

# Three fake "brokers": dead cwd (reapable), live cwd (kept), no serve verb
# (skipped). The pattern is unique to this run so pgrep cannot reach a real one.
BROKER_PAT="crewtest-broker-$$"
BSCRIPT="$TMP/$BROKER_PAT.sh"
printf '#!/usr/bin/env bash\nsleep 60\n' > "$BSCRIPT"
bash "$BSCRIPT" serve --endpoint "unix:$TMP/none.sock" --cwd "$GONE_WS" & DEADCWD_PID=$!
bash "$BSCRIPT" serve --endpoint "unix:$TMP/none.sock" --cwd "$TMP" & LIVECWD_PID=$!
bash "$BSCRIPT" notserve --cwd "$GONE_WS" & NOTBROKER_PID=$!
sleep 0.5

# Socket dirs: one held by a live pid via broker.pid, one idle.
mkdir -p "$TMP/sockets/cxc-held" "$TMP/sockets/cxc-idle"
echo "$$" > "$TMP/sockets/cxc-held/broker.pid"
echo 99999999 > "$TMP/sockets/cxc-idle/broker.pid"

# Case 37: --brokers classifies by cwd liveness, prints a paste-ready command
# for the human, and touches NOTHING — no kill, no socket removal. This is the
# real (non-dry) sweep; the whole point is that it is safe to run.
out="$(CLAUDE_CONFIG_DIR="$TMP/await" CLAUDE_PLUGIN_DATA="$TMP/sweep-clean" \
  CREW_CODEX_BROKER_PATTERN="$BROKER_PAT" CREW_CODEX_SOCKET_GLOB="$TMP/sockets/cxc-*" \
  bash "$CREW" reap --brokers 2>&1)" && rc=0 || rc=$?
check "broker with a dead cwd is a candidate" 0 "broker candidate: pid $DEADCWD_PID" "$rc" "$out"
check "candidate carries a paste-ready kill command" 0 "pkill -P $DEADCWD_PID; kill -TERM $DEADCWD_PID" "$rc" "$out"
check "candidate warns it may be another session's" 0 "may belong to ANOTHER Claude Code session" "$rc" "$out"
check "broker with a live cwd is not a candidate" 0 "broker live: pid $LIVECWD_PID" "$rc" "$out"
check "non-serve process is skipped" 0 "broker skipped: pid $NOTBROKER_PID" "$rc" "$out"
check "broker summary counts" 0 "reap brokers summary: 1 reported (nothing killed), 1 live (cwd exists), 0 unknown (cwd unreadable), 1 skipped" "$rc" "$out"
check "brokers survey reports a clean registry honestly" 0 "registry survey: every job record read cleanly and is terminal" "$rc" "$out"
if kill -0 "$DEADCWD_PID" 2>/dev/null && kill -0 "$LIVECWD_PID" 2>/dev/null \
   && kill -0 "$NOTBROKER_PID" 2>/dev/null; then
  echo "PASS: real brokers sweep killed nothing"; pass=$((pass + 1))
else
  echo "FAIL: real brokers sweep killed a process"; fail=$((fail + 1))
fi
# Socket dirs are in a namespace shared with every other session, so the sweep
# must leave BOTH of them alone — including the one nothing is holding.
if [[ -d "$TMP/sockets/cxc-idle" && -d "$TMP/sockets/cxc-held" ]]; then
  echo "PASS: brokers sweep removed no socket dir"; pass=$((pass + 1))
else
  echo "FAIL: brokers sweep removed a socket dir"; fail=$((fail + 1))
fi
if ! grep -qE "socket (kept|removed)|would remove socket" <<<"$out"; then
  echo "PASS: socket sweep is gone from the output entirely"; pass=$((pass + 1))
else
  echo "FAIL: socket sweep output still present"; fail=$((fail + 1))
fi
kill "$DEADCWD_PID" "$LIVECWD_PID" "$NOTBROKER_PID" 2>/dev/null || true
wait "$DEADCWD_PID" "$LIVECWD_PID" "$NOTBROKER_PID" 2>/dev/null || true

# Case 37b: a cwd that cannot be PROVEN absent is UNKNOWN, never a candidate.
# os.path.isdir returns False for permission-denied, which is what reported a
# workspace we merely cannot see as one that is gone.
BROKER_PAT_U="crewtest-unknown-$$"
printf '#!/usr/bin/env bash\nsleep 60\n' > "$TMP/$BROKER_PAT_U.sh"
mkdir -p "$TMP/unreadable-parent/ws"
chmod 000 "$TMP/unreadable-parent" 2>/dev/null || true
bash "$TMP/$BROKER_PAT_U.sh" serve --cwd "$TMP/unreadable-parent/ws" & UNKNOWN_PID=$!
sleep 0.5
out="$(CLAUDE_CONFIG_DIR="$TMP/await" CLAUDE_PLUGIN_DATA="$TMP/sweep-clean" \
  CREW_CODEX_BROKER_PATTERN="$BROKER_PAT_U" \
  bash "$CREW" reap --brokers 2>&1)" && rc=0 || rc=$?
chmod 755 "$TMP/unreadable-parent" 2>/dev/null || true
if [[ "$(id -u)" == "0" ]]; then
  skip "unreadable cwd classified UNKNOWN" "running as root, chmod 000 is not enforced"
else
  check "unreadable cwd is UNKNOWN, not a candidate" 0 "broker unknown: pid $UNKNOWN_PID" "$rc" "$out"
  if ! grep -q "broker candidate: pid $UNKNOWN_PID" <<<"$out"; then
    echo "PASS: unreadable cwd was never offered as a kill candidate"; pass=$((pass + 1))
  else
    echo "FAIL: unreadable cwd offered as a candidate (output: $out)"; fail=$((fail + 1))
  fi
fi
kill "$UNKNOWN_PID" 2>/dev/null || true
wait "$UNKNOWN_PID" 2>/dev/null || true

# Case 38: a real --state sweep removes exactly the dead-cwd dir
out="$(CLAUDE_CONFIG_DIR="$TMP/await" CLAUDE_PLUGIN_DATA="$TMP/sweep-clean" \
  bash "$CREW" reap --state 2>&1)" && rc=0 || rc=$?
check "real state sweep prunes the dead dir" 0 "pruned state dir: $CLEAN/dead-ws" "$rc" "$out"
if [[ ! -d "$CLEAN/dead-ws" && -d "$CLEAN/live-ws" && -d "$CLEAN/unresolved-ws" ]]; then
  echo "PASS: state sweep removed exactly the dead-cwd dir"; pass=$((pass + 1))
else
  echo "FAIL: state sweep removed the wrong dirs"; fail=$((fail + 1))
fi

# Case 40: THE assertion the report-only design rests on — a REAL (non-dry)
# --brokers sweep against a process that is a textbook reap candidate (broker
# pattern, `serve` verb, --cwd that does not exist) leaves it ALIVE. The old
# code killed exactly this process. A candidate may be another session's broker,
# so the only correct action is to print the command and stop.
printf '#!/usr/bin/env bash\nsleep 60\n' > "$TMP/crewtest-broker2-$$.sh"
bash "$TMP/crewtest-broker2-$$.sh" serve --endpoint "unix:$TMP/none.sock" --cwd "$GONE_WS" & SURVIVOR_PID=$!
sleep 0.5
out="$(CLAUDE_CONFIG_DIR="$TMP/await" CLAUDE_PLUGIN_DATA="$TMP/sweep-clean" \
  CREW_CODEX_BROKER_PATTERN="crewtest-broker2-$$" \
  bash "$CREW" reap --brokers 2>&1)" && rc=0 || rc=$?
check "real sweep reports the candidate" 0 "broker candidate: pid $SURVIVOR_PID" "$rc" "$out"
sleep 1   # a TERM+KILL tree kill would have finished well inside this
if kill -0 "$SURVIVOR_PID" 2>/dev/null; then
  echo "PASS: real --brokers sweep left the candidate process ALIVE"; pass=$((pass + 1))
else
  echo "FAIL: real --brokers sweep killed the candidate process"; fail=$((fail + 1))
fi
if ! grep -qE "reaped broker|would reap broker" <<<"$out"; then
  echo "PASS: no reap verb remains in the broker output"; pass=$((pass + 1))
else
  echo "FAIL: broker output still claims to reap (output: $out)"; fail=$((fail + 1))
fi
kill "$SURVIVOR_PID" 2>/dev/null || true
wait "$SURVIVOR_PID" 2>/dev/null || true

# Case 39: plain reap output is unchanged when no new flag is passed
out="$(CLAUDE_CONFIG_DIR="$TMP/await" CLAUDE_PLUGIN_DATA="$TMP/sweep-data" \
  bash "$CREW" reap --dry-run 2>&1)" && rc=0 || rc=$?
check "plain reap still reports only job records" 0 "reap summary: " "$rc" "$out"
if ! grep -qE "broker|socket|state summary" <<<"$out"; then
  echo "PASS: plain reap emitted no broker/socket/state output"; pass=$((pass + 1))
else
  echo "FAIL: plain reap leaked the opt-in sweeps"; fail=$((fail + 1))
fi

# --- effort driver: adversarial-review --effort runs on crew-codex's own -----
# driver, which composes the codex plugin's EXPORTED modules instead of
# patching them. The whole tree below is a STUB vendor plugin: no test here may
# dispatch a real Codex job, so the stubbed runAppServerTurn records the options
# object it was handed and returns a canned result. "effort actually reached
# runAppServerTurn" is the assertion the entire feature rests on.
mkdir -p "$TMP/effort/plugins" "$TMP/effort/install/scripts/lib" \
         "$TMP/effort/install/prompts" "$TMP/effort/install/schemas" \
         "$TMP/effort/install/.claude-plugin" "$TMP/effort/codex-home"
echo "{\"version\":2,\"plugins\":{\"codex@openai-codex\":[{\"installPath\":\"$TMP/effort/install\"}]}}" > "$TMP/effort/plugins/installed_plugins.json"
printf 'model_reasoning_effort = "medium"\n' > "$TMP/effort/codex-home/config.toml"
echo '{"name":"codex","version":"9.9.9-stub"}' > "$TMP/effort/install/.claude-plugin/plugin.json"
printf 'KIND={{REVIEW_KIND}} TARGET={{TARGET_LABEL}} FOCUS={{USER_FOCUS}} GUIDE={{REVIEW_COLLECTION_GUIDANCE}} INPUT={{REVIEW_INPUT}}\n' \
  > "$TMP/effort/install/prompts/adversarial-review.md"
echo '{"title":"stub-review-schema","type":"object"}' > "$TMP/effort/install/schemas/review-output.schema.json"

# The companion stub records every invocation, so "routed to the driver, NOT to
# the vendor" is an assertion about this file staying empty.
cat > "$TMP/effort/install/scripts/codex-companion.mjs" <<'EOF'
import fs from "node:fs";
fs.appendFileSync(process.env.CREW_TEST_INVOKED, process.argv.slice(2).join("|") + "\n");
console.log("COMPANION-RAN:" + process.argv.slice(2).join("|"));
EOF

cat > "$TMP/effort/install/scripts/lib/git.mjs" <<'EOF'
export function resolveReviewTarget(cwd, options = {}) {
  const base = options.base ?? "main";
  return { mode: "branch", label: `branch diff against ${base}`, baseRef: base, explicit: true };
}
export function collectReviewContext(cwd, target) {
  return {
    cwd, repoRoot: cwd, branch: "stub-branch", target, fileCount: 1, diffBytes: 42,
    inputMode: "inline-diff", collectionGuidance: "STUB-GUIDANCE",
    content: "STUB-DIFF", summary: "STUB-SUMMARY", changedFiles: ["stub.txt"]
  };
}
EOF

cat > "$TMP/effort/install/scripts/lib/prompts.mjs" <<'EOF'
import fs from "node:fs";
import path from "node:path";
export function loadPromptTemplate(rootDir, name) {
  return fs.readFileSync(path.join(rootDir, "prompts", `${name}.md`), "utf8");
}
export function interpolateTemplate(template, variables) {
  return template.replace(/\{\{([A-Z_]+)\}\}/g, (_, key) =>
    Object.prototype.hasOwnProperty.call(variables, key) ? variables[key] : "");
}
EOF

cat > "$TMP/effort/install/scripts/lib/codex.mjs" <<'EOF'
import fs from "node:fs";
export async function runAppServerTurn(cwd, options = {}) {
  fs.writeFileSync(process.env.CREW_TEST_TURN_RECORD, JSON.stringify({
    cwd,
    prompt: options.prompt ?? null,
    model: options.model ?? null,
    sandbox: options.sandbox ?? null,
    effort: options.effort ?? null,
    outputSchemaNull: options.outputSchema == null,
    outputSchemaTitle: (options.outputSchema && options.outputSchema.title) || null,
    hasOnProgress: typeof options.onProgress === "function"
  }, null, 2));
  options.onProgress?.({ message: "stub turn running" });
  return {
    status: 0, threadId: "th-stub", turnId: "tu-stub",
    finalMessage: JSON.stringify({ summary: "stub review summary", findings: [] }),
    reasoningSummary: null, stderr: "", error: null
  };
}
export function readOutputSchema(schemaPath) {
  return JSON.parse(fs.readFileSync(schemaPath, "utf8"));
}
export function parseStructuredOutput(rawOutput, fallback = {}) {
  try { return { parsed: JSON.parse(rawOutput), parseError: null, rawOutput, ...fallback }; }
  catch (error) { return { parsed: null, parseError: error.message, rawOutput, ...fallback }; }
}
EOF

cat > "$TMP/effort/install/scripts/lib/render.mjs" <<'EOF'
export function renderReviewResult(parsedResult, meta) {
  return `RENDERED ${meta.reviewLabel} :: ${meta.targetLabel} :: ${parsedResult.parsed?.summary ?? parsedResult.parseError}\n`;
}
EOF

cat > "$TMP/effort/install/scripts/lib/workspace.mjs" <<'EOF'
export function resolveWorkspaceRoot(cwd) { return cwd; }
EOF

cat > "$TMP/effort/install/scripts/lib/state.mjs" <<'EOF'
import fs from "node:fs";
import path from "node:path";
const dir = process.env.CREW_TEST_STATE_DIR;
fs.mkdirSync(dir, { recursive: true });
export function generateJobId(prefix = "job") {
  return `${prefix}-stub-${process.env.CREW_TEST_JOB_SUFFIX ?? "default"}`;
}
export function upsertJob(cwd, jobPatch) {
  fs.appendFileSync(path.join(dir, "upserts.jsonl"), JSON.stringify(jobPatch) + "\n");
}
export function writeJobFile(cwd, jobId, payload) {
  const jobFile = path.join(dir, `${jobId}.json`);
  fs.writeFileSync(jobFile, JSON.stringify(payload, null, 2));
  return jobFile;
}
EOF

cat > "$TMP/effort/install/scripts/lib/tracked-jobs.mjs" <<'EOF'
import fs from "node:fs";
import path from "node:path";
import { upsertJob, writeJobFile } from "./state.mjs";
export function appendLogLine(logFile, message) {
  if (!logFile || !String(message ?? "").trim()) return;
  fs.appendFileSync(logFile, `${String(message).trim()}\n`);
}
export function createJobLogFile(workspaceRoot, jobId, title) {
  const dir = process.env.CREW_TEST_STATE_DIR;
  fs.mkdirSync(dir, { recursive: true });
  const logFile = path.join(dir, `${jobId}.log`);
  fs.writeFileSync(logFile, "");
  if (title) appendLogLine(logFile, `Starting ${title}.`);
  return logFile;
}
export function createJobRecord(base) {
  return { ...base, createdAt: new Date().toISOString() };
}
export function createJobProgressUpdater() { return () => {}; }
export function createProgressReporter({ logFile = null, onEvent = null } = {}) {
  return (event) => {
    appendLogLine(logFile, typeof event === "string" ? event : event?.message);
    onEvent?.(event);
  };
}
export async function runTrackedJob(job, runner, options = {}) {
  const running = { ...job, status: "running", pid: process.pid, logFile: options.logFile ?? job.logFile ?? null };
  writeJobFile(job.workspaceRoot, job.id, running);
  upsertJob(job.workspaceRoot, running);
  try {
    const execution = await runner();
    writeJobFile(job.workspaceRoot, job.id, {
      ...running,
      status: execution.exitStatus === 0 ? "completed" : "failed",
      threadId: execution.threadId ?? null,
      result: execution.payload,
      rendered: execution.rendered
    });
    return execution;
  } catch (error) {
    writeJobFile(job.workspaceRoot, job.id, {
      ...running, status: "failed", errorMessage: error?.message ?? String(error)
    });
    throw error;
  }
}
EOF

INVOKED_E="$TMP/effort/invoked.log"
STATE_E="$TMP/effort/state"
ARC_E="$TMP/effort/archive"
mkdir -p "$STATE_E" "$ARC_E"

run_effort() {
  : > "$INVOKED_E"
  rm -f "$TMP/effort/turn.json"
  CLAUDE_CONFIG_DIR="$TMP/effort" CREW_TEST_INVOKED="$INVOKED_E" \
  CREW_TEST_TURN_RECORD="$TMP/effort/turn.json" CREW_TEST_STATE_DIR="$STATE_E" \
  CREW_CODEX_ARCHIVE_DIR="$ARC_E" CODEX_HOME="$TMP/effort/codex-home" \
  CREW_CODEX_RETRY_DELAYS="0" bash "$CREW" "$@" 2>&1
}

# Case 41: THE assertion — --effort reaches runAppServerTurn, alongside the
# model, a read-only sandbox and a non-null output schema. Without this the
# feature is unproven: the flag could be parsed, stamped and still dropped.
out="$(run_effort adversarial-review --effort xhigh --model gpt-5.6-sol "focus words")" && rc=0 || rc=$?
check "effort dispatch renders the review" 0 "RENDERED Adversarial Review" "$rc" "$out"
check_no_dispatch "effort dispatch bypassed the vendor companion" "$INVOKED_E"
if python3 -c "
import json
t = json.load(open('$TMP/effort/turn.json'))
assert t['effort'] == 'xhigh', t
assert t['model'] == 'gpt-5.6-sol', t
assert t['sandbox'] == 'read-only', t
assert t['outputSchemaNull'] is False, t
assert t['outputSchemaTitle'] == 'stub-review-schema', t
assert t['hasOnProgress'] is True, t
"; then
  echo "PASS: effort/model/sandbox/schema all reached runAppServerTurn"; pass=$((pass + 1))
else
  echo "FAIL: runAppServerTurn options wrong ($(cat "$TMP/effort/turn.json" 2>/dev/null))"; fail=$((fail + 1))
fi

# Case 42: the prompt is the vendor's template with all five variables bound —
# same target resolution, same collection guidance, same diff, same focus text.
if python3 -c "
import json
p = json.load(open('$TMP/effort/turn.json'))['prompt']
assert 'KIND=Adversarial Review' in p, p
assert 'TARGET=branch diff against main' in p, p
assert 'FOCUS=focus words' in p, p
assert 'GUIDE=STUB-GUIDANCE' in p, p
assert 'INPUT=STUB-DIFF' in p, p
"; then
  echo "PASS: prompt bound all five vendor template variables"; pass=$((pass + 1))
else
  echo "FAIL: prompt interpolation diverged from the vendor"; fail=$((fail + 1))
fi

# Case 43: the job record carries the effort and model. Vendor review records
# carry neither, so this record is the only audit trail of what a review ran at.
if python3 -c "
import json
j = json.load(open('$STATE_E/review-stub-default.json'))
assert j['effort'] == 'xhigh', j
assert j['model'] == 'gpt-5.6-sol', j
assert j['kind'] == 'adversarial-review', j
assert j['kindLabel'] == 'adversarial-review', j
assert j['jobClass'] == 'review', j
assert j['title'] == 'Codex Adversarial Review', j
assert j['id'].startswith('review-'), j
assert j['codexPluginVersion'] == '9.9.9-stub', j
assert j['status'] == 'completed', j
assert j['result']['dispatch']['effort'] == 'xhigh', j
"; then
  echo "PASS: job record stamps effort, model and the vendor job shape"; pass=$((pass + 1))
else
  echo "FAIL: job record missing effort/model or vendor shape"; fail=$((fail + 1))
fi

# Case 44: the dispatch.json sidecar still lands, and now attributes the effort
# to the FLAG rather than to the codex config.
if python3 -c "
import json
d = json.load(open('$ARC_E/review-stub-default.dispatch.json'))
assert d['subcommand'] == 'adversarial-review', d
assert d['effortRequested'] == 'xhigh', d
assert d['effortEffective'] == 'xhigh', d
assert d['effortConfig'] == 'medium', d
assert d['effortSource'] == 'flag', d
assert d['model'] == 'gpt-5.6-sol', d
"; then
  echo "PASS: sidecar records flag-sourced review effort"; pass=$((pass + 1))
else
  echo "FAIL: sidecar wrong for an --effort review"; fail=$((fail + 1))
fi

# Case 45: every valid effort is accepted and threaded through verbatim.
for e in none minimal low medium high xhigh; do
  out="$(run_effort adversarial-review --effort "$e" --model gpt-5.4-legacy "focus")" && rc=0 || rc=$?
  got="$(python3 -c "import json; print(json.load(open('$TMP/effort/turn.json'))['effort'])" 2>/dev/null || echo MISSING)"
  check "effort $e threaded to the turn" 0 "^$e\$" "$rc" "$got"
done

# Case 46: an invalid effort is refused before anything runs — including the
# registry's max/ultra tiers, which the vendor validator would also refuse but
# this driver bypasses.
for bad in max ultra bogus; do
  out="$(run_effort adversarial-review --effort "$bad" "focus")" && rc=0 || rc=$?
  check "effort $bad refused" 2 "invalid --effort" "$rc" "$out"
  check_no_dispatch "effort $bad did not reach the companion" "$INVOKED_E"
  if [[ ! -f "$TMP/effort/turn.json" ]]; then
    echo "PASS: effort $bad started no turn"; pass=$((pass + 1))
  else
    echo "FAIL: effort $bad started a turn"; fail=$((fail + 1))
  fi
done
out="$(run_effort adversarial-review --effort)" && rc=0 || rc=$?
check "bare --effort with no value refused" 2 "without a value" "$rc" "$out"
check_no_dispatch "valueless --effort did not dispatch" "$INVOKED_E"

# Case 47: none/minimal are ACCEPTED (the runtime takes them) but warned about
# on gpt-5.6 models, which 400 on reasoning.effort for those two values. The
# warning must not block: other model families may accept them.
out="$(run_effort adversarial-review --effort minimal --model gpt-5.6-terra "focus")" && rc=0 || rc=$?
check "minimal on a 5.6 model warns" 0 "rejected by the GPT-5.6 family" "$rc" "$out"
check "minimal on a 5.6 model still dispatches" 0 "RENDERED Adversarial Review" "$rc" "$out"
out="$(run_effort adversarial-review --effort none "focus")" && rc=0 || rc=$?
check "none with no --model warns (config default is 5.6)" 0 "no --model given" "$rc" "$out"
out="$(run_effort adversarial-review --effort low --model gpt-5.6-sol "focus")" && rc=0 || rc=$?
# The positive half matters: an absence check alone passes when the dispatch
# failed outright and printed nothing at all.
if grep -q "RENDERED Adversarial Review" <<<"$out" && ! grep -q "GPT-5.6 family" <<<"$out"; then
  echo "PASS: low on a 5.6 model dispatches and warns about nothing"; pass=$((pass + 1))
else
  echo "FAIL: low on a 5.6 model warned spuriously or did not dispatch (out: $out)"; fail=$((fail + 1))
fi

# Case 48: WITHOUT --effort the dispatch is an unchanged vendor passthrough.
# This is the blast-radius assertion: the default path must not move at all.
out="$(run_effort adversarial-review --base main "focus words")" && rc=0 || rc=$?
check "no --effort still goes to the companion" 0 "COMPANION-RAN:adversarial-review|--base|main|focus words" "$rc" "$out"
if [[ ! -f "$TMP/effort/turn.json" ]]; then
  echo "PASS: no --effort never touched the driver"; pass=$((pass + 1))
else
  echo "FAIL: no --effort was routed to the driver"; fail=$((fail + 1))
fi

# Case 49: a vendor rename is LOUD and never falls through to the vendor path.
# Silently falling back would run a review at the config's effort while the
# caller believed it ran at theirs — the exact failure this driver prevents.
cp -r "$TMP/effort/install" "$TMP/effort/broken-install"
cat > "$TMP/effort/broken-install/scripts/lib/render.mjs" <<'EOF'
export function renderSomethingElse() { return "renamed upstream"; }
EOF
mkdir -p "$TMP/broken/plugins"
echo "{\"version\":2,\"plugins\":{\"codex@openai-codex\":[{\"installPath\":\"$TMP/effort/broken-install\"}]}}" > "$TMP/broken/plugins/installed_plugins.json"
: > "$INVOKED_E"
rm -f "$TMP/effort/turn.json"
out="$(CLAUDE_CONFIG_DIR="$TMP/broken" CREW_TEST_INVOKED="$INVOKED_E" \
  CREW_TEST_TURN_RECORD="$TMP/effort/turn.json" CREW_TEST_STATE_DIR="$STATE_E" \
  CREW_CODEX_ARCHIVE_DIR="$ARC_E" CODEX_HOME="$TMP/effort/codex-home" \
  CREW_CODEX_RETRY_DELAYS="0" bash "$CREW" adversarial-review --effort high "focus" 2>&1)" && rc=0 || rc=$?
check "missing export fails nonzero" 3 "does not export .renderReviewResult." "$rc" "$out"
check "missing export names the plugin version" 3 "codex@openai-codex 9.9.9-stub" "$rc" "$out"
check "missing export names the module" 3 "scripts/lib/render.mjs" "$rc" "$out"
check "missing export tells the caller how to proceed" 3 "re-run WITHOUT --effort" "$rc" "$out"
check "missing export refuses to fall back" 3 "refusing to fall back automatically" "$rc" "$out"
check_no_dispatch "missing export did not fall through to the vendor" "$INVOKED_E"
if [[ ! -f "$TMP/effort/turn.json" ]]; then
  echo "PASS: missing export started no turn"; pass=$((pass + 1))
else
  echo "FAIL: missing export still started a turn"; fail=$((fail + 1))
fi

# Case 51: a vendor field rename that keeps the SYMBOL but drops the DATA is
# refused before any turn starts. This is the nastiest failure mode the driver
# has: every import succeeds, so the presence check passes, REVIEW_INPUT
# interpolates to "", and the model is asked to adversarially review nothing.
# It would answer "no findings" — rendering as a CLEAN PASS. A review gate that
# silently approves on breakage is worse than one that errors.
cp -r "$TMP/effort/install" "$TMP/effort/hollow-install"
cat > "$TMP/effort/hollow-install/scripts/lib/git.mjs" <<'EOF'
export function resolveReviewTarget(cwd, options = {}) {
  const base = options.base ?? "main";
  return { mode: "branch", label: `branch diff against ${base}`, baseRef: base, explicit: true };
}
// Symbol intact, shape changed: `content` renamed upstream to `reviewBody`.
export function collectReviewContext(cwd, target) {
  return {
    cwd, repoRoot: cwd, branch: "stub-branch", target, fileCount: 1, diffBytes: 42,
    inputMode: "inline-diff", collectionGuidance: "STUB-GUIDANCE",
    reviewBody: "STUB-DIFF", summary: "STUB-SUMMARY", changedFiles: []
  };
}
EOF
mkdir -p "$TMP/hollow/plugins"
echo "{\"version\":2,\"plugins\":{\"codex@openai-codex\":[{\"installPath\":\"$TMP/effort/hollow-install\"}]}}" > "$TMP/hollow/plugins/installed_plugins.json"
: > "$INVOKED_E"
rm -f "$TMP/effort/turn.json"
out="$(CLAUDE_CONFIG_DIR="$TMP/hollow" CREW_TEST_INVOKED="$INVOKED_E" \
  CREW_TEST_TURN_RECORD="$TMP/effort/turn.json" CREW_TEST_STATE_DIR="$STATE_E" \
  CREW_TEST_JOB_SUFFIX="hollow" CREW_CODEX_ARCHIVE_DIR="$ARC_E" \
  CODEX_HOME="$TMP/effort/codex-home" CREW_CODEX_RETRY_DELAYS="0" \
  bash "$CREW" adversarial-review --effort xhigh "focus" 2>&1)" && rc=0 || rc=$?
if [[ "$rc" != "0" ]] && grep -q 'no usable "content"' <<<"$out"; then
  echo "PASS: hollow context refused, naming the missing field"; pass=$((pass + 1))
else
  echo "FAIL: hollow context not refused (exit=$rc; output: $out)"; fail=$((fail + 1))
fi
# NOT `check ... "$rc" ... "$rc"` — that compares the exit code to itself and
# asserts nothing. The block above already proved rc != 0; this asserts the
# message explains WHY, so a future reader of the failure understands the
# hazard rather than just seeing a refusal.
if grep -q "indistinguishable from a clean review" <<<"$out"; then
  echo "PASS: hollow context explains the clean-review hazard"; pass=$((pass + 1))
else
  echo "FAIL: hollow context did not explain the hazard (output: $out)"; fail=$((fail + 1))
fi
if [[ ! -f "$TMP/effort/turn.json" ]]; then
  echo "PASS: hollow context started no turn"; pass=$((pass + 1))
else
  echo "FAIL: hollow context still started a turn"; fail=$((fail + 1))
fi
check_no_dispatch "hollow context did not fall through to the vendor" "$INVOKED_E"

# Case 52: a ZERO-CHANGED-FILE context is refused. The vendor renders an empty
# section as the literal "(none)" (lib/git.mjs:194), so `content` stays
# non-empty for a clean tree — a string check alone would dispatch a review of
# nothing, and "no findings" is indistinguishable from a clean review.
cp -r "$TMP/effort/install" "$TMP/effort/empty-install"
cat > "$TMP/effort/empty-install/scripts/lib/git.mjs" <<'EOF'
export function resolveReviewTarget(cwd, options = {}) {
  const base = options.base ?? "main";
  return { mode: "branch", label: `branch diff against ${base}`, baseRef: base, explicit: true };
}
export function collectReviewContext(cwd, target) {
  return {
    cwd, repoRoot: cwd, branch: "stub-branch", target, fileCount: 0, diffBytes: 0,
    inputMode: "inline-diff", collectionGuidance: "## Files\n\n(none)\n",
    content: "## Diff\n\n(none)\n", summary: "", changedFiles: []
  };
}
EOF
mkdir -p "$TMP/empty/plugins"
echo "{\"version\":2,\"plugins\":{\"codex@openai-codex\":[{\"installPath\":\"$TMP/effort/empty-install\"}]}}" > "$TMP/empty/plugins/installed_plugins.json"
: > "$INVOKED_E"; rm -f "$TMP/effort/turn.json"
out="$(CLAUDE_CONFIG_DIR="$TMP/empty" CREW_TEST_INVOKED="$INVOKED_E" \
  CREW_TEST_TURN_RECORD="$TMP/effort/turn.json" CREW_TEST_STATE_DIR="$STATE_E" \
  CREW_TEST_JOB_SUFFIX="empty" CREW_CODEX_ARCHIVE_DIR="$ARC_E" \
  CODEX_HOME="$TMP/effort/codex-home" CREW_CODEX_RETRY_DELAYS="0" \
  bash "$CREW" adversarial-review --effort xhigh "focus" 2>&1)" && rc=0 || rc=$?
if [[ "$rc" != "0" ]] && grep -q "no changed files" <<<"$out"; then
  echo "PASS: zero-diff context refused despite non-empty (none) content"; pass=$((pass + 1))
else
  echo "FAIL: zero-diff context not refused (exit=$rc; output: $out)"; fail=$((fail + 1))
fi
if [[ ! -f "$TMP/effort/turn.json" ]]; then
  echo "PASS: zero-diff context started no turn"; pass=$((pass + 1))
else
  echo "FAIL: zero-diff context still started a turn"; fail=$((fail + 1))
fi

# Case 53: the `--` sentinel. The vendor treats everything after it as focus
# text, so `-- --effort high` is a NO-EFFORT vendor dispatch whose literal focus
# is "--effort high". Diverting it to the driver would break the
# byte-identical-passthrough guarantee and then fail for lack of a parsed effort.
: > "$INVOKED_E"; rm -f "$TMP/effort/turn.json"
out="$(CLAUDE_CONFIG_DIR="$TMP/effort" CREW_TEST_INVOKED="$INVOKED_E" \
  CREW_TEST_TURN_RECORD="$TMP/effort/turn.json" CREW_TEST_STATE_DIR="$STATE_E" \
  CREW_CODEX_ARCHIVE_DIR="$ARC_E" CODEX_HOME="$TMP/effort/codex-home" \
  CREW_CODEX_RETRY_DELAYS="0" bash "$CREW" adversarial-review -- --effort high 2>&1)" && rc=0 || rc=$?
check "post-sentinel --effort stays a vendor dispatch" 0 "COMPANION-RAN:adversarial-review|--|--effort|high" "$rc" "$out"
if [[ ! -f "$TMP/effort/turn.json" ]]; then
  echo "PASS: post-sentinel --effort never reached the driver"; pass=$((pass + 1))
else
  echo "FAIL: post-sentinel --effort routed to the driver"; fail=$((fail + 1))
fi

# Case 54: the audit sidecar must not archive prompt/focus content. Focus text
# carries pasted incident logs, hostnames and secret-bearing commands, and this
# archive deliberately outlives the vendor's session cleanup.
: > "$INVOKED_E"
rm -f "$ARC_E"/*.dispatch.json 2>/dev/null || true
CLAUDE_CONFIG_DIR="$TMP/effort" CREW_TEST_INVOKED="$INVOKED_E" \
  CREW_TEST_STATE_DIR="$STATE_E" CREW_CODEX_ARCHIVE_DIR="$ARC_E" \
  CODEX_HOME="$TMP/effort/codex-home" CREW_CODEX_RETRY_DELAYS="0" \
  CREW_TEST_TURN_RECORD="$TMP/effort/turn.json" CREW_TEST_JOB_SUFFIX="redact" \
  bash "$CREW" adversarial-review --base main --model gpt-5.6-sol --effort high \
  "AKIAIOSFODNN7EXAMPLE leaked from prod-db-01" >/dev/null 2>&1 || true
# `|| true`: under `set -euo pipefail` a non-matching glob makes ls exit 2 and
# pipefail propagates it out of the command substitution, aborting the suite.
sidecar="$(ls "$ARC_E"/*.dispatch.json 2>/dev/null | head -1 || true)"
if [[ -n "$sidecar" ]] && ! grep -q "AKIAIOSFODNN7EXAMPLE\|prod-db-01" "$sidecar"; then
  echo "PASS: sidecar redacted the focus text"; pass=$((pass + 1))
elif [[ -z "$sidecar" ]]; then
  # Not an acceptable pass: this dispatch carries --effort, so it routes to the
  # driver, which always emits a sidecar. No sidecar means the redaction path
  # was never exercised and this assertion proved nothing.
  echo "FAIL: no sidecar written — redaction was not exercised"; fail=$((fail + 1))
else
  echo "FAIL: sidecar archived focus text: $(cat "$sidecar")"; fail=$((fail + 1))
fi
if [[ -n "$sidecar" ]]; then
  if grep -q -- "--base" "$sidecar" && grep -q "gpt-5.6-sol" "$sidecar"; then
    echo "PASS: sidecar kept routing metadata"; pass=$((pass + 1))
  else
    echo "FAIL: sidecar dropped routing metadata: $(cat "$sidecar")"; fail=$((fail + 1))
  fi
fi

# Case 55: a live job recorded ONLY in state.json, in a workspace with NO jobs/
# directory, must block the IRREVERSIBLE --state prune. The union used to
# `continue` past such a workspace before reading state.json, missing exactly
# the split-brain case it exists for — and the dir it would delete is the
# registry another session's companion serves status/result/cancel from.
mkdir -p "$TMP/state-only/state/ghost"
echo '{"jobs":[{"id":"ghost-1","status":"running","workspaceRoot":"/nonexistent-ghost"}]}' \
  > "$TMP/state-only/state/ghost/state.json"
out="$(CLAUDE_CONFIG_DIR="$TMP/await" CLAUDE_PLUGIN_DATA="$TMP/state-only" \
  bash "$CREW" reap --state 2>&1)" && rc=0 || rc=$?
if grep -q "state blocked: ghost" <<<"$out" && grep -q "ghost-1" <<<"$out" \
   && [[ -f "$TMP/state-only/state/ghost/state.json" ]]; then
  echo "PASS: state.json-only live job blocks the prune"; pass=$((pass + 1))
else
  echo "FAIL: state-only live job did not block the prune (exit=$rc; output: $out)"; fail=$((fail + 1))
fi
# The same workspace is surfaced by the --brokers advisory survey, which now
# reports rather than gates.
out="$(CLAUDE_CONFIG_DIR="$TMP/await" CLAUDE_PLUGIN_DATA="$TMP/state-only" \
  CREW_CODEX_BROKER_PATTERN="$NOMATCH" \
  bash "$CREW" reap --brokers 2>&1)" && rc=0 || rc=$?
check "brokers survey surfaces a state.json-only live job" 0 "ghost/ghost-1(running)" "$rc" "$out"

# Case 56: the --state prune must fail CLOSED on registries it cannot parse or
# read. os.path.isdir/isfile/exists return False for permission-denied too, so
# "unreadable" used to be indistinguishable from "absent" — and absent is the
# answer that lets an rmtree proceed. Every fixture here lives under $TMP; none
# of them touches the real, session-shared plugin data dir.
state_blocks() {
  # name, fixture root, grep pattern -> asserts blocked AND still on disk
  local name="$1" root="$2" want="$3" ws="$4" o r
  o="$(CLAUDE_CONFIG_DIR="$TMP/await" CLAUDE_PLUGIN_DATA="$root" \
    bash "$CREW" reap --state 2>&1)" && r=0 || r=$?
  if [[ "$r" == 0 ]] && grep -q "state blocked" <<<"$o" && grep -q "$want" <<<"$o" && [[ -d "$ws" ]]; then
    echo "PASS: $name"; pass=$((pass + 1))
  else
    echo "FAIL: $name (exit=$r; still on disk: $([[ -d "$ws" ]] && echo yes || echo NO); out: $o)"
    fail=$((fail + 1))
  fi
}

# 56a: a non-list `jobs` value. It used to fall through the isinstance check and
# read as an empty registry — a fail-open in front of an irreversible delete.
mkdir -p "$TMP/gate-malformed/state/ws-a"
echo '{"jobs":{"id":"live","status":"running"},"workspaceRoot":"/nonexistent-a"}' \
  > "$TMP/gate-malformed/state/ws-a/state.json"
state_blocks "unrecognized state.json schema blocks the prune" \
  "$TMP/gate-malformed" "unrecognized schema" "$TMP/gate-malformed/state/ws-a"

# 56b: unparseable JSON. `load()` returned None for this exactly as it did for
# "file absent", and nonterminal_jobs read None as "no jobs".
mkdir -p "$TMP/gate-unparseable/state/ws-c/jobs"
echo '{"jobs":[{"id":"c1","status":"completed","workspaceRoot":"/nonexistent-c"}]}' \
  > "$TMP/gate-unparseable/state/ws-c/state.json"
printf '{"id":"c1", TRUNCATED' > "$TMP/gate-unparseable/state/ws-c/jobs/c1.json"
state_blocks "unparseable job record blocks the prune" \
  "$TMP/gate-unparseable" "unparseable JSON" "$TMP/gate-unparseable/state/ws-c"

# 56c: a mode-000 jobs/ dir. Absent and unreadable must not be the same answer.
mkdir -p "$TMP/gate-denied/state/ws-b/jobs"
echo '{"jobs":[{"id":"x","status":"completed","workspaceRoot":"/nonexistent-b"}]}' \
  > "$TMP/gate-denied/state/ws-b/state.json"
echo '{"id":"x","status":"completed"}' > "$TMP/gate-denied/state/ws-b/jobs/x.json"
chmod 000 "$TMP/gate-denied/state/ws-b/jobs" 2>/dev/null || true
out="$(CLAUDE_CONFIG_DIR="$TMP/await" CLAUDE_PLUGIN_DATA="$TMP/gate-denied" \
  bash "$CREW" reap --state 2>&1)" && rc=0 || rc=$?
# Restored unconditionally and immediately: a mode-000 dir left behind would
# defeat this suite's own cleanup.
chmod 755 "$TMP/gate-denied/state/ws-b/jobs" 2>/dev/null || true
if [[ "$(id -u)" == "0" ]]; then
  skip "unreadable jobs dir blocks the prune" "running as root, chmod 000 is not enforced"
elif grep -q "state blocked" <<<"$out" && grep -q "jobs/(unreadable: PermissionError)" <<<"$out" \
     && [[ -d "$TMP/gate-denied/state/ws-b" ]]; then
  echo "PASS: unreadable jobs dir blocks the prune"; pass=$((pass + 1))
else
  echo "FAIL: unreadable jobs dir did not block (exit=$rc; out: $out)"; fail=$((fail + 1))
fi

# Case 56d: THE reproduction. A mode-000 WORKSPACE dir (one level up from the
# fix that failed) holding a running job. os.path.exists returns False for it,
# which emptied the live list and let the old sweep proceed. --brokers must
# report it as unreadable — never as an empty workspace — and must kill nothing.
mkdir -p "$TMP/gate-ws000/state/ws-live/jobs"
cat > "$TMP/gate-ws000/state/ws-live/state.json" <<EOF
{"jobs":[{"id":"live-000","status":"running","workspaceRoot":"$GONE_WS"}]}
EOF
cat > "$TMP/gate-ws000/state/ws-live/jobs/live-000.json" <<EOF
{"id":"live-000","status":"running","workspaceRoot":"$GONE_WS"}
EOF
BROKER_PAT_W="crewtest-ws000-$$"
printf '#!/usr/bin/env bash\nsleep 60\n' > "$TMP/$BROKER_PAT_W.sh"
bash "$TMP/$BROKER_PAT_W.sh" serve --cwd "$GONE_WS" & WS000_PID=$!
sleep 0.5
chmod 000 "$TMP/gate-ws000/state/ws-live" 2>/dev/null || true
out="$(CLAUDE_CONFIG_DIR="$TMP/await" CLAUDE_PLUGIN_DATA="$TMP/gate-ws000" \
  CREW_CODEX_BROKER_PATTERN="$BROKER_PAT_W" \
  bash "$CREW" reap --brokers 2>&1)" && rc=0 || rc=$?
outstate="$(CLAUDE_CONFIG_DIR="$TMP/await" CLAUDE_PLUGIN_DATA="$TMP/gate-ws000" \
  bash "$CREW" reap --state 2>&1)" && rcs=0 || rcs=$?
chmod 755 "$TMP/gate-ws000/state/ws-live" 2>/dev/null || true
if [[ "$(id -u)" == "0" ]]; then
  skip "mode-000 workspace with a running job" "running as root, chmod 000 is not enforced"
else
  if grep -q "unreadable: PermissionError" <<<"$out" \
     && grep -q "registry survey: non-terminal or unreadable" <<<"$out"; then
    echo "PASS: mode-000 workspace reported unreadable, never as empty"; pass=$((pass + 1))
  else
    echo "FAIL: mode-000 workspace was not reported unreadable (exit=$rc; out: $out)"; fail=$((fail + 1))
  fi
  if grep -q "every job record read cleanly" <<<"$out"; then
    echo "FAIL: mode-000 workspace claimed to be a clean/empty registry"; fail=$((fail + 1))
  else
    echo "PASS: mode-000 workspace never claimed a clean registry"; pass=$((pass + 1))
  fi
  if grep -q "state blocked: ws-live" <<<"$outstate" && [[ -d "$TMP/gate-ws000/state/ws-live" ]]; then
    echo "PASS: mode-000 workspace blocked the --state prune"; pass=$((pass + 1))
  else
    echo "FAIL: mode-000 workspace did not block the prune (exit=$rcs; out: $outstate)"; fail=$((fail + 1))
  fi
fi
if kill -0 "$WS000_PID" 2>/dev/null; then
  echo "PASS: mode-000 sweep left the matching broker process alive"; pass=$((pass + 1))
else
  echo "FAIL: mode-000 sweep killed the broker process"; fail=$((fail + 1))
fi
kill "$WS000_PID" 2>/dev/null || true
wait "$WS000_PID" 2>/dev/null || true

# Case 57: content that is ONLY collector skip markers must refuse. fileCount is
# positive, content is a non-empty string, and there is still nothing to review --
# a review of it answers "no findings", which reads as a clean pass.
cp -r "$TMP/effort/install" "$TMP/effort/skipped-install"
cat > "$TMP/effort/skipped-install/scripts/lib/git.mjs" <<'EOF'
export function resolveReviewTarget(cwd, options = {}) {
  const base = options.base ?? "main";
  return { mode: "branch", label: `branch diff against ${base}`, baseRef: base, explicit: true };
}
export function collectReviewContext(cwd, target) {
  return {
    cwd, repoRoot: cwd, branch: "stub", target, fileCount: 1, diffBytes: 0,
    inputMode: "inline-diff", collectionGuidance: "STUB-GUIDANCE",
    content: "### big.txt\n(skipped: 99999 bytes exceeds 24576 byte limit)\n",
    summary: "s", changedFiles: ["big.txt"]
  };
}
EOF
mkdir -p "$TMP/skipped/plugins"
echo "{\"version\":2,\"plugins\":{\"codex@openai-codex\":[{\"installPath\":\"$TMP/effort/skipped-install\"}]}}" > "$TMP/skipped/plugins/installed_plugins.json"
: > "$INVOKED_E"; rm -f "$TMP/effort/turn.json"
out="$(CLAUDE_CONFIG_DIR="$TMP/skipped" CREW_TEST_INVOKED="$INVOKED_E" \
  CREW_TEST_TURN_RECORD="$TMP/effort/turn.json" CREW_TEST_STATE_DIR="$STATE_E" \
  CREW_TEST_JOB_SUFFIX="skip" CREW_CODEX_ARCHIVE_DIR="$ARC_E" \
  CODEX_HOME="$TMP/effort/codex-home" CREW_CODEX_RETRY_DELAYS="0" \
  bash "$CREW" adversarial-review --effort high "focus" 2>&1)" && rc=0 || rc=$?
if [[ "$rc" != "0" ]] && grep -q "every changed file" <<<"$out"; then
  echo "PASS: all-skipped content refused"; pass=$((pass + 1))
else
  echo "FAIL: all-skipped content not refused (exit=$rc; out: $out)"; fail=$((fail + 1))
fi
# The refusal names the PATH and the counts, never the captured marker text.
# The marker text is rendered from a file the collector read, so echoing it
# copies content fragments into stderr and into job logs.
if grep -q "big.txt" <<<"$out" && ! grep -q "99999 bytes exceeds" <<<"$out"; then
  echo "PASS: refusal names the file, not the marker text"; pass=$((pass + 1))
else
  echo "FAIL: refusal leaked marker text or dropped the path (out: $out)"; fail=$((fail + 1))
fi
if [[ ! -f "$TMP/effort/turn.json" ]]; then
  echo "PASS: all-skipped content started no turn"; pass=$((pass + 1))
else
  echo "FAIL: all-skipped content started a turn"; fail=$((fail + 1))
fi

# Case 57b: SKIP-MARKER COLLISION. The vendor inlines small untracked files RAW
# inside a fence, so a reviewed file whose own content contains a
# `(skipped: ...)` line used to be counted as a collector marker. With
# fileCount 2 and one real marker, the naive whole-blob regex found 2 and
# refused a diff that is perfectly reviewable. A marker counts only directly
# under a `### <changed path>` heading.
cp -r "$TMP/effort/install" "$TMP/effort/collide-install"
cat > "$TMP/effort/collide-install/scripts/lib/git.mjs" <<'EOF'
export function resolveReviewTarget(cwd, options = {}) {
  const base = options.base ?? "main";
  return { mode: "branch", label: `branch diff against ${base}`, baseRef: base, explicit: true };
}
export function collectReviewContext(cwd, target) {
  const content = [
    "## Untracked Files",
    "",
    "### real.txt",
    "(skipped: binary file)",
    "",
    "### doc.md",
    "```",
    "Notes on the collector output format:",
    "### phantom.txt",
    "(skipped: this line is FILE CONTENT, not a collector marker)",
    "```",
    ""
  ].join("\n");
  return {
    cwd, repoRoot: cwd, branch: "stub", target, fileCount: 2, diffBytes: 0,
    inputMode: "inline-diff", collectionGuidance: "STUB-GUIDANCE",
    content, summary: "s", changedFiles: ["real.txt", "doc.md"]
  };
}
EOF
mkdir -p "$TMP/collide/plugins"
echo "{\"version\":2,\"plugins\":{\"codex@openai-codex\":[{\"installPath\":\"$TMP/effort/collide-install\"}]}}" > "$TMP/collide/plugins/installed_plugins.json"
: > "$INVOKED_E"; rm -f "$TMP/effort/turn.json"
out="$(CLAUDE_CONFIG_DIR="$TMP/collide" CREW_TEST_INVOKED="$INVOKED_E" \
  CREW_TEST_TURN_RECORD="$TMP/effort/turn.json" CREW_TEST_STATE_DIR="$STATE_E" \
  CREW_TEST_JOB_SUFFIX="collide" CREW_CODEX_ARCHIVE_DIR="$ARC_E" \
  CODEX_HOME="$TMP/effort/codex-home" CREW_CODEX_RETRY_DELAYS="0" \
  bash "$CREW" adversarial-review --effort high "focus" 2>&1)" && rc=0 || rc=$?
check "content-embedded skip marker does not refuse the review" 0 "RENDERED Adversarial Review" "$rc" "$out"
if python3 -c "
import json
p = json.load(open('$TMP/effort/turn.json'))['prompt']
assert '1 of 2 changed file(s)' in p, p
assert 'real.txt' in p.split('GUIDE=')[1].split('INPUT=')[0], p
assert 'phantom.txt' not in p.split('GUIDE=')[1].split('INPUT=')[0], p
"; then
  echo "PASS: only the structural marker was counted (1 of 2, real.txt)"; pass=$((pass + 1))
else
  echo "FAIL: skip-marker accounting wrong (turn: $(cat "$TMP/effort/turn.json" 2>/dev/null))"; fail=$((fail + 1))
fi

# Case 58: the sidecar must not re-parse post-sentinel focus text as routing
# metadata. `-- --prompt-file /internal/INC-123` is prose, and archiving that path
# into storage that outlives session cleanup is the leak redaction exists to stop.
: > "$INVOKED_E"
rm -f "$ARC_E"/*.dispatch.json 2>/dev/null || true
CLAUDE_CONFIG_DIR="$TMP/effort" CREW_TEST_INVOKED="$INVOKED_E" \
  CREW_TEST_TURN_RECORD="$TMP/effort/turn.json" CREW_TEST_STATE_DIR="$STATE_E" \
  CREW_TEST_JOB_SUFFIX="sentinel" CREW_CODEX_ARCHIVE_DIR="$ARC_E" \
  CODEX_HOME="$TMP/effort/codex-home" CREW_CODEX_RETRY_DELAYS="0" \
  bash "$CREW" adversarial-review --effort high -- --prompt-file /internal/INC-123 --model=leaked \
  >/dev/null 2>&1 || true
sc="$(ls "$ARC_E"/*.dispatch.json 2>/dev/null | head -1 || true)"
if [[ -n "$sc" ]] && ! grep -q "INC-123\|leaked" "$sc"; then
  echo "PASS: sidecar redacted post-sentinel tokens"; pass=$((pass + 1))
else
  echo "FAIL: sidecar leaked post-sentinel tokens: $(cat "$sc" 2>/dev/null)"; fail=$((fail + 1))
fi

# Case 58b: the option table is PER SUBCOMMAND. `--base` is a review flag the
# task parser has never heard of, so `task --base=<secret>` is prompt TEXT —
# but one shared table recognized the prefix and archived the whole token, with
# no `--` sentinel needed, into storage that outlives session cleanup.
arc="$TMP/stamp/arc58b"
out="$(run_stamp "$arc" "Codex Task started in the background as task-sec11-sec22." \
  task --base=AKIAIOSFODNN7SECRETV --model gpt-5.6-luna "do a thing")" && rc=0 || rc=$?
sc="$arc/task-sec11-sec22.dispatch.json"
if [[ -f "$sc" ]] && ! grep -q "AKIAIOSFODNN7SECRETV" "$sc"; then
  echo "PASS: task --base=<secret> is not archived"; pass=$((pass + 1))
else
  echo "FAIL: task --base=<secret> reached the sidecar: $(cat "$sc" 2>/dev/null)"; fail=$((fail + 1))
fi
if [[ -f "$sc" ]] && python3 -c "
import json
d = json.load(open('$sc'))
assert d['argv'] == ['task', '--model', 'gpt-5.6-luna', '<redacted: 2 positional token(s)>'], d
"; then
  echo "PASS: task sidecar kept its own routing flags and shaped the rest"; pass=$((pass + 1))
else
  echo "FAIL: task sidecar argv wrong: $(cat "$sc" 2>/dev/null)"; fail=$((fail + 1))
fi
# ...and the boundary holds in the other direction: --prompt-file is a task
# flag, so on a review it is unrecognized text and must be redacted.
arc="$TMP/stamp/arc58c"
out="$(run_stamp "$arc" "Adversarial Review started in the background as review-sec33-sec44." \
  adversarial-review --prompt-file /internal/INC-999 --base main)" && rc=0 || rc=$?
sc="$arc/review-sec33-sec44.dispatch.json"
if [[ -f "$sc" ]] && ! grep -q "INC-999" "$sc" && grep -q -- "--base" "$sc"; then
  echo "PASS: review sidecar redacts a task-only flag but keeps --base"; pass=$((pass + 1))
else
  echo "FAIL: review sidecar mis-classified --prompt-file: $(cat "$sc" 2>/dev/null)"; fail=$((fail + 1))
fi

# Case 59: agent-definition consistency. Every command governed by the
# launch/await/result loop must carry --background; the adversarial command lost
# it once when --model/--effort were added, silently breaking the lane.
#
# ⚠️ ANCHORED TO $HERE, not to the invoker's cwd. These two greps used to name
# `codex-crew/agents/codex-reviewer.md` relatively: run the suite from anywhere
# but the repo root and the first assertion false-FAILED while the second
# passed VACUOUSLY — `! grep -q` succeeds on grep's exit 2 for a missing file,
# so "the naive probe is gone" was reported by a grep that read no file at all.
REVIEWER_MD="$REPO/agents/codex-reviewer.md"
if [[ -f "$REVIEWER_MD" ]]; then
  echo "PASS: reviewer agent definition is where the suite expects it"; pass=$((pass + 1))
else
  echo "FAIL: reviewer agent definition missing at $REVIEWER_MD"; fail=$((fail + 1))
fi
if grep -q 'adversarial-review --background --model' "$REVIEWER_MD"; then
  echo "PASS: reviewer lane adversarial command is detached"; pass=$((pass + 1))
else
  echo "FAIL: reviewer lane adversarial command lost --background"; fail=$((fail + 1))
fi
# Assert the probe that SHOULD be there, not merely the absence of the old one:
# deleting the probe outright satisfies an absence check.
if grep -qF "grep -q 'review-with-effort' \"\$(command -v crew-codex)\"" "$REVIEWER_MD"; then
  echo "PASS: reviewer lane carries the exact driver-filename probe"; pass=$((pass + 1))
else
  echo "FAIL: reviewer lane lost the driver-filename probe"; fail=$((fail + 1))
fi
if ! grep -q "grep -q -- '--effort'" "$REVIEWER_MD"; then
  echo "PASS: reviewer lane no longer uses the naive --effort probe"; pass=$((pass + 1))
else
  echo "FAIL: reviewer lane still uses the naive --effort probe"; fail=$((fail + 1))
fi

# Case 50: --background detaches. The parent must return a job id immediately
# and exit; the child does the turn. This is why the driver exists at all for
# background dispatches — the vendor's adversarial-review is foreground-only,
# so a Bash call to it dies at the 120s tool timeout and orphans the review.
: > "$INVOKED_E"
rm -f "$TMP/effort/turn.json"
out="$(CLAUDE_CONFIG_DIR="$TMP/effort" CREW_TEST_INVOKED="$INVOKED_E" \
  CREW_TEST_TURN_RECORD="$TMP/effort/turn.json" CREW_TEST_STATE_DIR="$STATE_E" \
  CREW_TEST_JOB_SUFFIX="bg" CREW_CODEX_ARCHIVE_DIR="$ARC_E" \
  CODEX_HOME="$TMP/effort/codex-home" CREW_CODEX_RETRY_DELAYS="0" \
  bash "$CREW" adversarial-review --background --effort high "focus" 2>&1)" && rc=0 || rc=$?
check "background returns a job id" 0 "started in the background as review-stub-bg" "$rc" "$out"
waited=0
while [[ $waited -lt 30 ]]; do
  if [[ -f "$TMP/effort/turn.json" ]]; then break; fi
  sleep 1; waited=$((waited + 1))
done
if python3 -c "
import json
t = json.load(open('$TMP/effort/turn.json'))
assert t['effort'] == 'high', t
j = json.load(open('$STATE_E/review-stub-bg.json'))
assert j['status'] == 'completed', j
assert j['effort'] == 'high', j
" 2>/dev/null; then
  echo "PASS: detached worker ran the turn at the requested effort (${waited}s)"; pass=$((pass + 1))
else
  echo "FAIL: detached worker did not complete (${waited}s; turn: $(cat "$TMP/effort/turn.json" 2>/dev/null))"; fail=$((fail + 1))
fi
check_no_dispatch "background dispatch bypassed the vendor companion" "$INVOKED_E"


echo
echo "$pass passed, $fail failed, $skipped skipped"
[[ "$fail" -eq 0 ]]
