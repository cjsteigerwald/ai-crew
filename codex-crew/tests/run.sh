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
if ! grep -q "GPT-5.6 family" <<<"$out"; then
  echo "PASS: low on a 5.6 model warns about nothing"; pass=$((pass + 1))
else
  echo "FAIL: low on a 5.6 model warned spuriously"; fail=$((fail + 1))
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
# directory, must still hold the --brokers kill gate shut. The gate used to
# `continue` past such a workspace before reading state.json, bypassing the
# union in exactly the split-brain case it exists for.
mkdir -p "$TMP/state-only/state/ghost"
echo '{"jobs":[{"id":"ghost-1","status":"running","workspaceRoot":"/nonexistent-ghost"}]}' \
  > "$TMP/state-only/state/ghost/state.json"
out="$(CLAUDE_CONFIG_DIR="$TMP/await" CLAUDE_PLUGIN_DATA="$TMP/state-only" \
  bash "$CREW" reap --brokers --dry-run 2>&1)" && rc=0 || rc=$?
if [[ "$rc" != "0" ]] && grep -q "ghost-1" <<<"$out"; then
  echo "PASS: state.json-only live job blocks the broker sweep"; pass=$((pass + 1))
else
  echo "FAIL: state-only live job did not block the sweep (exit=$rc; output: $out)"; fail=$((fail + 1))
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
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
