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

# Asserts the fake companion recorded NO invocation — the whole point of the
# usage guards is that a help/--effort request never becomes a dispatch at all.
check_no_dispatch() {
  local name="$1" record="$2"
  if [[ ! -s "$record" ]]; then
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
out="$(run_guard review --base main help)" && rc=0 || rc=$?
check "bare 'help' among review args exits 0" 0 "NO --effort flag" "$rc" "$out"
check_no_dispatch "review help did not dispatch" "$INVOKED"

# Case 25: --effort on the review path is refused loudly, exit 2, no dispatch
out="$(run_guard adversarial-review --effort high)" && rc=0 || rc=$?
check "review --effort refused" 2 "does not accept --effort" "$rc" "$out"
check "review --effort names the working alternative" 2 "crew-codex task --effort" "$rc" "$out"
check_no_dispatch "review --effort did not dispatch" "$INVOKED"

out="$(run_guard adversarial-review --effort=xhigh "focus")" && rc=0 || rc=$?
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
check "state dry-run refuses a dir with a non-terminal job" 0 "state kept: busy-ws .* non-terminal" "$rc" "$out"
check "state dry-run summary counts" 0 "reap state summary: 1 would prune, 1 kept (cwd alive), 1 kept (non-terminal jobs), 1 unresolved" "$rc" "$out"
if [[ -d "$SWEEP/dead-ws" ]]; then
  echo "PASS: state dry-run deleted nothing"; pass=$((pass + 1))
else
  echo "FAIL: state dry-run deleted a state dir"; fail=$((fail + 1))
fi

# Case 35: --brokers is REFUSED outright while any job is non-terminal
out="$(CLAUDE_CONFIG_DIR="$TMP/await" CLAUDE_PLUGIN_DATA="$TMP/sweep-data" \
  bash "$CREW" reap --brokers --dry-run 2>&1)" && rc=0 || rc=$?
check "brokers sweep refused under a live job" 3 "REFUSED" "$rc" "$out"
check "brokers refusal names the offending job" 3 "busy-ws/task-busy-1(running)" "$rc" "$out"

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

# Case 37: --brokers --dry-run classifies by cwd liveness and kills NOTHING
out="$(CLAUDE_CONFIG_DIR="$TMP/await" CLAUDE_PLUGIN_DATA="$TMP/sweep-clean" \
  CREW_CODEX_BROKER_PATTERN="$BROKER_PAT" CREW_CODEX_SOCKET_GLOB="$TMP/sockets/cxc-*" \
  bash "$CREW" reap --brokers --dry-run 2>&1)" && rc=0 || rc=$?
check "broker with a dead cwd is flagged" 0 "would reap broker: pid $DEADCWD_PID" "$rc" "$out"
check "broker with a live cwd is kept" 0 "broker kept: pid $LIVECWD_PID" "$rc" "$out"
check "non-serve process is skipped" 0 "broker skipped: pid $NOTBROKER_PID" "$rc" "$out"
check "broker summary counts" 0 "reap brokers summary: 1 flagged, 1 kept (cwd alive), 1 skipped" "$rc" "$out"
check "held socket dir kept" 0 "socket kept: $TMP/sockets/cxc-held" "$rc" "$out"
check "idle socket dir flagged" 0 "would remove socket dir: $TMP/sockets/cxc-idle" "$rc" "$out"
if kill -0 "$DEADCWD_PID" 2>/dev/null && kill -0 "$LIVECWD_PID" 2>/dev/null \
   && kill -0 "$NOTBROKER_PID" 2>/dev/null && [[ -d "$TMP/sockets/cxc-idle" ]]; then
  echo "PASS: brokers dry-run killed nothing and removed nothing"; pass=$((pass + 1))
else
  echo "FAIL: brokers dry-run had side effects"; fail=$((fail + 1))
fi
kill "$DEADCWD_PID" "$LIVECWD_PID" "$NOTBROKER_PID" 2>/dev/null || true
wait "$DEADCWD_PID" "$LIVECWD_PID" "$NOTBROKER_PID" 2>/dev/null || true

# Case 38: a real --state sweep removes exactly the dead-cwd dir
out="$(CLAUDE_CONFIG_DIR="$TMP/await" CLAUDE_PLUGIN_DATA="$TMP/sweep-clean" \
  bash "$CREW" reap --state 2>&1)" && rc=0 || rc=$?
check "real state sweep prunes the dead dir" 0 "pruned state dir: $CLEAN/dead-ws" "$rc" "$out"
if [[ ! -d "$CLEAN/dead-ws" && -d "$CLEAN/live-ws" && -d "$CLEAN/unresolved-ws" ]]; then
  echo "PASS: state sweep removed exactly the dead-cwd dir"; pass=$((pass + 1))
else
  echo "FAIL: state sweep removed the wrong dirs"; fail=$((fail + 1))
fi

# Case 40: the pre-kill re-validation fails SAFE. This runs the real (non-dry)
# broker sweep, but with a pgrep regex that the fixed-string re-check cannot
# match — exactly what a recycled pid looks like — so the process must survive.
# It is the only non-dry-run broker case, and it is designed to kill nothing.
printf '#!/usr/bin/env bash\nsleep 60\n' > "$TMP/crewtest-broker2-$$.sh"
bash "$TMP/crewtest-broker2-$$.sh" serve --endpoint "unix:$TMP/none.sock" --cwd "$GONE_WS" & SURVIVOR_PID=$!
sleep 0.5
out="$(CLAUDE_CONFIG_DIR="$TMP/await" CLAUDE_PLUGIN_DATA="$TMP/sweep-clean" \
  CREW_CODEX_BROKER_PATTERN="crewtest-brok.r2-$$" CREW_CODEX_SOCKET_GLOB="$TMP/sockets/cxc-*" \
  bash "$CREW" reap --brokers 2>&1)" && rc=0 || rc=$?
check "pid recycle re-check blocks the kill" 0 "broker skipped: pid $SURVIVOR_PID (exited or pid recycled" "$rc" "$out"
if kill -0 "$SURVIVOR_PID" 2>/dev/null; then
  echo "PASS: re-validation failure left the process alive"; pass=$((pass + 1))
else
  echo "FAIL: re-validation failure still killed the process"; fail=$((fail + 1))
fi
# Same run exercised the REAL socket sweep against the throwaway glob.
if [[ ! -d "$TMP/sockets/cxc-idle" && -d "$TMP/sockets/cxc-held" ]]; then
  echo "PASS: socket sweep removed only the unheld dir"; pass=$((pass + 1))
else
  echo "FAIL: socket sweep removed the wrong dirs"; fail=$((fail + 1))
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

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
