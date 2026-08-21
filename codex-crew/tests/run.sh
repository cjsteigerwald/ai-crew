#!/usr/bin/env bash
# Resolver tests for bin/crew-codex. Uses a throwaway CLAUDE_CONFIG_DIR;
# never touches the real ~/.claude.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREW="$HERE/../bin/crew-codex"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

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

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
