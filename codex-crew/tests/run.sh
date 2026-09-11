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
# The broker stubs go first: they are real listening processes, and `kill` on an
# already-dead pid returns non-zero, which under `set -e` would abort this
# handler BEFORE the temp tree is removed — so every signal here is best-effort.
# Stub processes the ported cases start. fake_broker runs inside a command
# substitution, so its own assignment would land in a subshell and never reach
# here — those pids go through $TMP/stub_pids instead. This variable carries the
# ones started directly.
STUB_PIDS=""

cleanup_suite() {
  local status=$?
  local pf p
  for pf in "$TMP"/crewb-*/broker.pid; do
    [[ -f "$pf" ]] || continue
    p="$(cat "$pf" 2>/dev/null || true)"
    [[ "$p" =~ ^[0-9]+$ ]] && kill -9 "$p" 2>/dev/null || true
  done
  for p in $STUB_PIDS $(cat "$TMP/stub_pids" 2>/dev/null || true); do
    kill -9 "$p" 2>/dev/null || true
  done
  chmod -R u+rwX "$TMP" 2>/dev/null || true
  rm -rf "$TMP"
  exit "$status"
}
trap cleanup_suite EXIT

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

# ---- portability shims: the suite runs on GNU/Linux AND on stock macOS ------
# `touch -d '<N> <unit> ago'` is GNU-only; BSD touch aborted the whole suite
# under `set -e`. touch_ago backdates a file by "<N> minutes|hours ago" with
# GNU touch when it works, else via an absolute `touch -t` stamp.
touch_ago() { # $1 = "<N> minutes|hours ago", $2 = file
  touch -d "$1" "$2" 2>/dev/null && return 0
  local n unit secs
  read -r n unit _ <<<"$1"
  case "$unit" in
    minute|minutes) secs=$(( n * 60 )) ;;
    hour|hours)     secs=$(( n * 3600 )) ;;
    *) echo "touch_ago: unsupported offset '$1'" >&2; return 1 ;;
  esac
  touch -t "$(date -r $(( $(date +%s) - secs )) +%Y%m%d%H%M.%S)" "$2"
}
# `timeout` is GNU coreutils; stock macOS has none. Prefer gtimeout, else
# portable_timeout. ⚠️ NOT `perl -e 'alarm shift; exec @ARGV'`: that exits 142
# (SIGALRM), so every `rc == 124` hang check below silently never fired, and it
# signals only the direct child, so a grandchild holding a captured stdout pipe
# kept `$(...)` blocked past the deadline. portable_timeout matches GNU: CMD
# runs in its own process group; on expiry the WHOLE group gets TERM, then KILL
# after a short grace, and the result is 124. Otherwise CMD's own status, or
# 128+signal if CMD died by a signal.
portable_timeout() { # $1 = seconds, rest = command
  perl -e '
    use strict; use Time::HiRes ();
    my $secs = shift @ARGV; my $grace = 2;
    my $pid = fork; die "portable_timeout: fork: $!\n" unless defined $pid;
    if ($pid == 0) { setpgrp(0, 0); exec { $ARGV[0] } @ARGV; exit 127; }
    setpgrp($pid, $pid);  # also from the parent, so the group exists before any kill
    for my $sig (qw(TERM INT HUP)) { $SIG{$sig} = sub { kill $sig, -$pid; }; }
    # ⚠️ Escalation is driven by the ALARM, never by the leader exiting: a
    # leader that ignores TERM never returns from waitpid, so grace/KILL code
    # placed after waitpid was unreachable and the timeout waited forever.
    # First ALRM: TERM the group and re-arm for the grace. Second: KILL it.
    my $timed_out = 0;
    $SIG{ALRM} = sub {
      if (!$timed_out) { $timed_out = 1; kill "TERM", -$pid; Time::HiRes::alarm($grace); }
      else             { $timed_out = 2; kill "KILL", -$pid; }
    };
    Time::HiRes::alarm($secs);
    1 while waitpid($pid, 0) == -1 && $!{EINTR};
    my $status = $?;
    if ($timed_out) {
      # The leader is gone but TERM-ignoring members may remain: keep the
      # grace the armed alarm promised, then KILL whatever is left.
      Time::HiRes::sleep(0.1) while $timed_out == 1 && kill(0, -$pid);
      Time::HiRes::alarm(0);
      kill "KILL", -$pid;
      exit 124;
    }
    Time::HiRes::alarm(0);
    exit(($status & 127) ? 128 + ($status & 127) : $status >> 8);
  ' "$@"
}
if ! command -v timeout >/dev/null 2>&1; then
  if command -v gtimeout >/dev/null 2>&1; then
    timeout() { gtimeout "$@"; }
  else
    timeout() { portable_timeout "$@"; }
  fi
fi

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

# The ported doc-assertion cases read the shipped agent prompts and the runtime
# skill, so the whole surface stays consistent with the binary's behaviour.
AGENT_DIR="$HERE/../agents"
SKILL_FILE="$HERE/../skills/crew-runtime/SKILL.md"

# Brokers the ported upstream cases spawn land under $TMP, so the suite's own
# cleanup reaches them instead of leaving app-servers behind in the real tmpdir.
export CREW_CODEX_BROKER_TMPDIR="$TMP"

# A broker stub shaped like the real thing: it opens the unix socket and writes
# the pid file, so crew_spawn_job_broker actually succeeds. Without this every
# per-job-broker path silently no-ops and the tests cannot see it.
write_broker_stub() { # $1 = scripts dir
  cat > "$1/app-server-broker.mjs" <<'BROKEREOF'
import net from "node:net";
import fs from "node:fs";
const a = process.argv.slice(2);
const endpoint = a[a.indexOf("--endpoint") + 1] || "";
const pidFile = a[a.indexOf("--pid-file") + 1] || "";
const sockPath = endpoint.replace(/^unix:/, "");
if (pidFile) fs.writeFileSync(pidFile, String(process.pid));
net.createServer(() => {}).listen(sockPath);
setInterval(() => {}, 1 << 30);
BROKEREOF
}

check_contains() { # assert a shipped doc/prompt carries a phrase
  local name="$1" file="$2" phrase="$3"
  if grep -qF -- "$phrase" "$file"; then
    echo "PASS: $name"
    pass=$((pass + 1))
  else
    echo "FAIL: $name (missing '$phrase' in $(basename "$file"))"
    fail=$((fail + 1))
  fi
}

check_absent() { # assert a phrase is NOT present; the inverse of check_contains
  local name="$1" haystack="$2" phrase="$3"
  if grep -qF -- "$phrase" <<<"$haystack"; then
    echo "FAIL: $name (unexpectedly found '$phrase')"
    fail=$((fail + 1))
  else
    echo "PASS: $name"
    pass=$((pass + 1))
  fi
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

# Case T1: portable_timeout is exercised DIRECTLY on every machine, whether or
# not GNU timeout exists — the old perl fallback was never run here because this
# suite's machines all had GNU timeout, which is how its 142 exit code survived.
# (a) expiry returns 124 and does not wait on a grandchild holding the pipe.
t0=$(date +%s)
out="$(portable_timeout 1 bash -c 'sleep 30 & wait')" && rc=0 || rc=$?
elapsed=$(( $(date +%s) - t0 ))
if [[ "$rc" == 124 && "$elapsed" -lt 5 ]]; then
  echo "PASS: portable_timeout expiry returns 124 and kills the process group"; pass=$((pass + 1))
else
  echo "FAIL: portable_timeout expiry (exit=$rc, want=124; elapsed=${elapsed}s, want <5s)"; fail=$((fail + 1))
fi
# (a2) a group LEADER that ignores TERM (and whose grandchild does too) must
# still be killed: escalation to KILL used to wait on the leader exiting, which
# a TERM-ignoring leader never does, so the "timeout" blocked forever.
T1_GC="$TMP/t1-grandchild.pid"
t0=$(date +%s)
out="$(portable_timeout 1 perl -e '$SIG{TERM}="IGNORE"; if (!fork) { open my $f, ">", $ARGV[0]; print $f $$; close $f; sleep 30; exit } sleep 60' "$T1_GC")" && rc=0 || rc=$?
elapsed=$(( $(date +%s) - t0 ))
t1_gc="$(cat "$T1_GC" 2>/dev/null || true)"
for _ in 1 2 3 4 5 6 7 8 9 10; do   # the orphaned grandchild may take a moment to be reaped
  [[ -n "$t1_gc" ]] && kill -0 "$t1_gc" 2>/dev/null || break
  sleep 0.1
done
if [[ "$rc" == 124 && "$elapsed" -lt 6 && -n "$t1_gc" ]] && ! kill -0 "$t1_gc" 2>/dev/null; then
  echo "PASS: portable_timeout kills a TERM-ignoring leader and its grandchild"; pass=$((pass + 1))
else
  echo "FAIL: portable_timeout TERM-ignoring leader (exit=$rc, want=124; elapsed=${elapsed}s, want <6s; grandchild=${t1_gc:-none} $(kill -0 "${t1_gc:-0}" 2>/dev/null && echo ALIVE || echo gone))"; fail=$((fail + 1))
  [[ -n "$t1_gc" ]] && kill -9 "$t1_gc" 2>/dev/null || true
fi
# (b) a command that finishes in time keeps its own exit status.
out="$(portable_timeout 5 bash -c 'exit 3')" && rc=0 || rc=$?
check "portable_timeout passes through the command's exit status" 3 "" "$rc" "$out"

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
frozen="$TMP/await/frozen.log"; echo x > "$frozen"; touch_ago '10 minutes ago' "$frozen"
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

# --- archive sanitization: the .meta.json must not carry prompt text ---------
# `result --json` returns storedJob verbatim, and storedJob carries the REQUEST:
# a background task keeps its prompt there, a background effort review keeps its
# focus text there, and a task's summary is the first 96 chars of the prompt.
# That file was written straight into an archive that deliberately outlives the
# vendor's session cleanup, right next to a carefully redacted .dispatch.json.
# The fake companion below embeds a distinctive secret everywhere the real one
# can, INCLUDING under a key the current vendor does not use — a shape change
# must not reopen this silently.
SECRET="AKIAZZTESTSECRET42"
mkdir -p "$TMP/meta/plugins" "$TMP/meta/install/scripts"
echo "{\"version\":2,\"plugins\":{\"codex@openai-codex\":[{\"installPath\":\"$TMP/meta/install\"}]}}" > "$TMP/meta/plugins/installed_plugins.json"
cat > "$TMP/meta/install/scripts/codex-companion.mjs" <<'EOF'
const [cmd, jobId, flag] = process.argv.slice(2);
const secret = process.env.CREW_TEST_SECRET;
const summaryOf = (id) =>
  id.startsWith("task-") ? "Investigate " + secret : "Review found 2 issues";
if (cmd === "result") {
  if (flag !== "--json") {
    // The vendor's FINAL fallback render, verbatim in shape: it fires whenever
    // a job stored no output at all, and it prints Summary: <job.summary>.
    if (process.env.CREW_TEST_FALLBACK_RENDER === "1") {
      console.log("# Codex Task\n\nJob: " + jobId + "\nStatus: completed\n"
        + "Codex session ID: th-keepme\nSummary: " + summaryOf(jobId)
        + "\n\nNo captured result payload was stored for this job.");
      process.exit(0);
    }
    // A model answer that merely CONTAINS a Summary: line. Not the fallback
    // skeleton, so the skeleton rule must leave every word of it alone.
    if (process.env.CREW_TEST_PROSE_RESULT === "1") {
      console.log("Here is what I found.\n\nSummary: three call sites need the guard.\n");
      process.exit(0);
    }
    console.log("FINAL-RESULT-KEEP");
    process.exit(0);
  }
  if (process.env.CREW_TEST_BAD_JSON === "1") {
    console.log("this is not JSON at all, and it mentions " + secret);
    process.exit(0);
  }
  // A prompt the USER controls that merely LOOKS like a marker this script
  // writes. Treating it as already-sanitized archives it verbatim.
  if (process.env.CREW_TEST_MARKER_PROMPT === "1") {
    console.log(JSON.stringify({
      job: { id: jobId, status: "completed", summary: "<redacted and yet " + secret },
      storedJob: {
        id: jobId, status: "completed",
        request: { cwd: "/w", model: "gpt-5.6-sol",
                   prompt: "<redacted: but this still says " + secret,
                   focusText: "<redacted> " + secret }
      }
    }));
    process.exit(0);
  }
  if (process.env.CREW_TEST_SCALAR_REQUEST === "1") {
    console.log(JSON.stringify({
      job: { id: jobId, status: "completed", elapsed: "3s", pid: null },
      storedJob: { id: jobId, status: "completed", request: "raw request line " + secret }
    }));
    process.exit(0);
  }
  // The REQUEST is reproduced under BOTH job and storedJob, exactly as a real
  // archived payload carries it, and it holds four ways of naming free text:
  // the two the denylist knows, two the vendor could rename to tomorrow
  // (userInput, reviewFocus) and a free-text LIST. Only the allowlist catches
  // the last three; a denylist passes them through in silence.
  const request = {
    cwd: "/w", base: "main", model: "gpt-5.6-sol", effort: "high",
    // Allowlisted NAMES that hold unconstrained strings. The vendor sends both.
    scope: "scope field carrying " + secret,
    title: "title field carrying " + secret,
    prompt: "Investigate " + secret,
    focusText: "focus on " + secret,
    userInput: "renamed free text carrying " + secret,
    reviewFocus: "another renamed field carrying " + secret,
    attachments: ["pasted log line with " + secret]
  };
  console.log(JSON.stringify({
    job: {
      id: jobId, status: "completed", elapsed: "3s", pid: null,
      summary: summaryOf(jobId),
      request: request,
      // Free text relocated OUTSIDE any request, under a name no rule knows.
      // Long, the way a pasted incident log or a prompt is long.
      notes: "pasted incident log ".repeat(30) + secret
    },
    storedJob: {
      id: jobId, status: "completed", threadId: "th-keepme",
      createdAt: "2026-08-23T00:00:00Z", completedAt: "2026-08-23T00:01:00Z",
      request: request,
      result: {
        rawOutput: "FINAL-RESULT-KEEP",
        // Model OUTPUT is arbitrarily long and is the reason the archive
        // exists. The length guard must not fire inside it.
        transcript: "the model wrote a great deal about this ".repeat(40)
      }
    }
  }));
  process.exit(0);
}
console.log(JSON.stringify({
  job: { id: jobId, status: "completed", elapsed: "3s", logFile: "-", pid: null,
         progressPreview: ["done"] }
}));
EOF

# Case 20b: a background TASK. Its prompt, its focus text, a relocated prompt
# under an unknown key and the prompt-derived job summary must all be gone from
# the .meta.json, while result/thread/status/routing survive — and await's exit
# code and its single stdout line must be untouched by any of it.
metaerr="$TMP/meta/err.txt"
arc="$TMP/meta/arc-task"
out="$(CLAUDE_CONFIG_DIR="$TMP/meta" CREW_CODEX_ARCHIVE_DIR="$arc" CREW_CODEX_POLL_SECS=0 \
  CREW_TEST_SECRET="$SECRET" bash "$CREW" await task-secret1 --for 5 2>"$metaerr")" && rc=0 || rc=$?
check "await over a sanitized archive still exits 0" 0 "DONE completed" "$rc" "$out"
check "await stdout contract unchanged" 0 "archived: $arc/task-secret1.result.txt" "$rc" "$out"
if [[ $(( $(wc -l <<<"$out") )) -eq 1 && ! -s "$metaerr" ]]; then
  echo "PASS: await still prints exactly one stdout line and nothing on stderr"; pass=$((pass + 1))
else
  echo "FAIL: await stdout/stderr contract changed (stdout: $out; stderr: $(cat "$metaerr"))"; fail=$((fail + 1))
fi
if [[ -f "$arc/task-secret1.meta.json" ]] && ! grep -rq "$SECRET" "$arc"; then
  echo "PASS: no archived file carries the prompt secret"; pass=$((pass + 1))
elif [[ ! -f "$arc/task-secret1.meta.json" ]]; then
  # Not an acceptable pass: an absent meta means the sanitizer was never
  # exercised and this assertion would prove nothing.
  echo "FAIL: no .meta.json written — sanitization was not exercised"; fail=$((fail + 1))
else
  echo "FAIL: the archive still carries the secret: $(grep -rl "$SECRET" "$arc")"; fail=$((fail + 1))
fi
if python3 -c "
import json
d = json.load(open('$arc/task-secret1.meta.json'))
sj = d['storedJob']
assert sj['result']['rawOutput'] == 'FINAL-RESULT-KEEP', sj
assert sj['threadId'] == 'th-keepme', sj
assert sj['status'] == 'completed' and d['job']['status'] == 'completed', d
assert sj['createdAt'] == '2026-08-23T00:00:00Z', sj
assert d['job']['summary'].startswith('<redacted:'), d
# Routing survives inside the request boundary, or the archive stops being
# worth keeping.
for holder in ('job', 'storedJob'):
    r = d[holder]['request']
    assert r['model'] == 'gpt-5.6-sol' and r['effort'] == 'high', r
    assert r['base'] == 'main' and r['cwd'] == '/w', r
    # Both boundaries, not just storedJob: a real payload carries the request
    # twice and a path rule anchored on one leaves the other readable.
    assert r['prompt'].startswith('<redacted:'), r
    assert r['focusText'].startswith('<redacted:'), r
    # The three the DENYLIST cannot see. These are the assertions that fail if
    # anyone reverts the allowlist to key-shape matching.
    assert r['userInput'].startswith('<redacted:'), r
    assert r['reviewFocus'].startswith('<redacted:'), r
    assert r['attachments'].startswith('<redacted:'), r
    # scope and title are unconstrained strings the vendor really sends. They
    # were allowlisted by name; a name is not a guarantee about content.
    assert r['scope'].startswith('<redacted:'), r
    assert r['title'].startswith('<redacted:'), r
# Free text relocated OUTSIDE any request, under a name no rule knows. The
# request allowlist cannot see this one at all — only the length guard can.
assert d['job']['notes'].startswith('<redacted:'), d['job']['notes'][:80]
# ...and the guard must NOT fire inside a model-output subtree, or the archive
# loses the very thing it is kept for.
assert d['storedJob']['result']['transcript'].startswith('the model wrote'), d['storedJob']['result']
assert d['storedJob']['result']['rawOutput'] == 'FINAL-RESULT-KEEP', d['storedJob']['result']
"; then
  echo "PASS: meta kept result/thread/status/routing and marked every prompt field"; pass=$((pass + 1))
else
  echo "FAIL: meta sanitization dropped or kept the wrong fields: $(cat "$arc/task-secret1.meta.json")"; fail=$((fail + 1))
fi

# Case 20c: a REVIEW job. Its focus text goes, but its summary is the model's
# finding summary — output, not input — and must survive, or the archive stops
# being worth keeping.
arc="$TMP/meta/arc-review"
out="$(CLAUDE_CONFIG_DIR="$TMP/meta" CREW_CODEX_ARCHIVE_DIR="$arc" CREW_CODEX_POLL_SECS=0 \
  CREW_TEST_SECRET="$SECRET" bash "$CREW" await review-secret2 --for 5 2>/dev/null)" && rc=0 || rc=$?
if [[ -f "$arc/review-secret2.meta.json" ]] && ! grep -q "$SECRET" "$arc/review-secret2.meta.json" \
   && python3 -c "
import json
d = json.load(open('$arc/review-secret2.meta.json'))
assert d['job']['summary'] == 'Review found 2 issues', d
assert d['storedJob']['request']['focusText'].startswith('<redacted:'), d
"; then
  echo "PASS: review meta redacted the focus text and kept the finding summary"; pass=$((pass + 1))
else
  echo "FAIL: review meta wrong (exit=$rc): $(cat "$arc/review-secret2.meta.json" 2>/dev/null)"; fail=$((fail + 1))
fi

# Case 20d: an unparseable payload is WITHHELD, never archived raw. "We could
# not sanitize it" must not become "so we wrote it out intact".
arc="$TMP/meta/arc-bad"
out="$(CLAUDE_CONFIG_DIR="$TMP/meta" CREW_CODEX_ARCHIVE_DIR="$arc" CREW_CODEX_POLL_SECS=0 \
  CREW_TEST_SECRET="$SECRET" CREW_TEST_BAD_JSON=1 \
  bash "$CREW" await task-secret3 --for 5 2>/dev/null)" && rc=0 || rc=$?
if [[ "$rc" == "0" ]] && [[ -f "$arc/task-secret3.meta.json" ]] \
   && grep -q "withheld" "$arc/task-secret3.meta.json" \
   && ! grep -q "$SECRET" "$arc/task-secret3.meta.json"; then
  echo "PASS: unparseable payload withheld, not archived raw"; pass=$((pass + 1))
else
  echo "FAIL: unparseable payload mishandled (exit=$rc): $(cat "$arc/task-secret3.meta.json" 2>/dev/null)"; fail=$((fail + 1))
fi

# Case 20e: a request that is not a mapping. The allowlist can only reason
# about keys, so an unexpected SHAPE goes whole rather than through.
arc="$TMP/meta/arc-scalar"
out="$(CLAUDE_CONFIG_DIR="$TMP/meta" CREW_CODEX_ARCHIVE_DIR="$arc" CREW_CODEX_POLL_SECS=0 \
  CREW_TEST_SECRET="$SECRET" CREW_TEST_SCALAR_REQUEST=1 \
  bash "$CREW" await task-secret4 --for 5 2>/dev/null)" && rc=0 || rc=$?
if [[ -f "$arc/task-secret4.meta.json" ]] && ! grep -rq "$SECRET" "$arc" \
   && grep -q '"request": "<redacted:' "$arc/task-secret4.meta.json"; then
  echo "PASS: a non-mapping request is redacted whole"; pass=$((pass + 1))
else
  echo "FAIL: scalar request mishandled (exit=$rc): $(cat "$arc/task-secret4.meta.json" 2>/dev/null)"; fail=$((fail + 1))
fi

# Case 20f: THE .result.txt LEAK. The vendor fallback render prints
# "Summary: <job.summary>", and a task summary is the first 96 chars of the
# prompt — so the archive carried in plain text exactly what .meta.json was
# being scrubbed of, one filename apart.
arc="$TMP/meta/arc-fallback-task"
out="$(CLAUDE_CONFIG_DIR="$TMP/meta" CREW_CODEX_ARCHIVE_DIR="$arc" CREW_CODEX_POLL_SECS=0 \
  CREW_TEST_SECRET="$SECRET" CREW_TEST_FALLBACK_RENDER=1 \
  bash "$CREW" await task-secret5 --for 5 2>"$metaerr")" && rc=0 || rc=$?
if [[ "$rc" == 0 ]] && [[ -f "$arc/task-secret5.result.txt" ]] \
   && ! grep -rq "$SECRET" "$arc" \
   && grep -q "<redacted:" "$arc/task-secret5.result.txt" \
   && grep -q "Job: task-secret5" "$arc/task-secret5.result.txt"; then
  echo "PASS: task .result.txt redacted the prompt-derived summary, kept the rest"; pass=$((pass + 1))
else
  echo "FAIL: .result.txt leaked the prompt summary (exit=$rc): $(cat "$arc/task-secret5.result.txt" 2>/dev/null)"; fail=$((fail + 1))
fi
if [[ -z "$(find "$arc" -name '*.result.raw' 2>/dev/null)" ]]; then
  echo "PASS: the unsanitized staging file is not left behind"; pass=$((pass + 1))
else
  echo "FAIL: staging file survived: $(find "$arc" -name '*.result.raw')"; fail=$((fail + 1))
fi

# Case 20g: a REVIEW summary is the model finding summary — output, not input.
# Over-redacting it would make the archive useless for the case it exists for.
arc="$TMP/meta/arc-fallback-review"
out="$(CLAUDE_CONFIG_DIR="$TMP/meta" CREW_CODEX_ARCHIVE_DIR="$arc" CREW_CODEX_POLL_SECS=0 \
  CREW_TEST_SECRET="$SECRET" CREW_TEST_FALLBACK_RENDER=1 \
  bash "$CREW" await review-secret6 --for 5 2>/dev/null)" && rc=0 || rc=$?
if grep -q "Summary: Review found 2 issues" "$arc/review-secret6.result.txt" 2>/dev/null; then
  echo "PASS: review .result.txt kept its finding summary"; pass=$((pass + 1))
else
  echo "FAIL: review summary was over-redacted (exit=$rc): $(cat "$arc/review-secret6.result.txt" 2>/dev/null)"; fail=$((fail + 1))
fi

# Case 20h: a model answer that merely contains a "Summary:" line is NOT the
# fallback skeleton, and the skeleton rule must not touch it. This is the
# over-redaction guard: without the skeleton scoping, every task answer with a
# Summary line would come back mutilated.
arc="$TMP/meta/arc-prose"
out="$(CLAUDE_CONFIG_DIR="$TMP/meta" CREW_CODEX_ARCHIVE_DIR="$arc" CREW_CODEX_POLL_SECS=0 \
  CREW_TEST_SECRET="$SECRET" CREW_TEST_PROSE_RESULT=1 \
  bash "$CREW" await task-secret7 --for 5 2>/dev/null)" && rc=0 || rc=$?
if grep -q "Summary: three call sites need the guard." "$arc/task-secret7.result.txt" 2>/dev/null; then
  echo "PASS: a model answer containing a Summary line is left intact"; pass=$((pass + 1))
else
  echo "FAIL: skeleton rule over-redacted model output (exit=$rc): $(cat "$arc/task-secret7.result.txt" 2>/dev/null)"; fail=$((fail + 1))
fi

# Case 20j: A MARKER-SHAPED PROMPT. marker() short-circuits on values it
# believes an earlier pass wrote, so that test has to be anchored to the exact
# canonical forms. A prefix test is a redaction bypass: prompt and focus text
# are user-controlled, so "<redacted and yet <SECRET>" would be mistaken for
# an already-sanitized value and archived verbatim.
arc="$TMP/meta/arc-marker"
out="$(CLAUDE_CONFIG_DIR="$TMP/meta" CREW_CODEX_ARCHIVE_DIR="$arc" CREW_CODEX_POLL_SECS=0 \
  CREW_TEST_SECRET="$SECRET" CREW_TEST_MARKER_PROMPT=1 \
  bash "$CREW" await task-secret8 --for 5 2>/dev/null)" && rc=0 || rc=$?
if [[ -f "$arc/task-secret8.meta.json" ]] && ! grep -rq "$SECRET" "$arc"; then
  echo "PASS: a marker-shaped prompt is redacted, not mistaken for a marker"; pass=$((pass + 1))
else
  echo "FAIL: marker-prefix bypass leaked the prompt (exit=$rc): $(cat "$arc/task-secret8.meta.json" 2>/dev/null)"; fail=$((fail + 1))
fi

# Case 20k: the archive holds ONLY the artifacts it is supposed to. The
# unsanitized render used to be staged as a dotfile INSIDE this directory,
# where a SIGTERM before the sanitizer ran left prompt text permanently in the
# one place built to outlive the vendor cleanup. `.sanitized` is the fourth
# legitimate artifact: a content digest of the result, carrying no payload.
arc="$TMP/meta/arc-fallback-task"
stray="$(find "$arc" -type f ! -name '*.meta.json' ! -name '*.result.txt' ! -name '*.log' ! -name '*.sanitized' 2>/dev/null)"
if [[ -z "$stray" ]]; then
  echo "PASS: the archive holds no artifact beyond meta/result/log/sanitized"; pass=$((pass + 1))
else
  echo "FAIL: unexpected artifact in the archive: $stray"; fail=$((fail + 1))
fi

# ...and the sentinel is a DIGEST, not a copy. If it ever carried the bytes it
# vouches for, it would be a second unredacted archive of the same text.
if [[ -f "$arc/task-secret5.sanitized" ]] \
   && ! grep -q "$SECRET" "$arc/task-secret5.sanitized" \
   && grep -q '"sha256"' "$arc/task-secret5.sanitized"; then
  echo "PASS: the provenance sentinel records a digest and no content"; pass=$((pass + 1))
else
  echo "FAIL: sentinel missing or carrying content: $(cat "$arc/task-secret5.sanitized" 2>/dev/null)"; fail=$((fail + 1))
fi

# Case 20l: a stale UNSANITIZED result from an earlier crew-codex must be
# replaced, not left in place because a file happens to already exist.
arc="$TMP/meta/arc-stale"
mkdir -p "$arc"
printf 'legacy unsanitized render mentioning %s\n' "$SECRET" > "$arc/task-secret9.result.txt"
out="$(CLAUDE_CONFIG_DIR="$TMP/meta" CREW_CODEX_ARCHIVE_DIR="$arc" CREW_CODEX_POLL_SECS=0 \
  CREW_TEST_SECRET="$SECRET" bash "$CREW" await task-secret9 --for 5 2>/dev/null)" && rc=0 || rc=$?
if ! grep -rq "$SECRET" "$arc"; then
  echo "PASS: a pre-existing unsanitized result is overwritten, not preserved"; pass=$((pass + 1))
else
  echo "FAIL: stale leaked result survived (exit=$rc): $(cat "$arc/task-secret9.result.txt")"; fail=$((fail + 1))
fi

# Case 20i: sanitize-archive — the fix above only helps jobs archived from now
# on. Everything an earlier crew-codex wrote is still on disk with its focus
# text in the clear, in the archive that deliberately outlives the vendor's
# cleanup. The sweep must clean those, be a no-op on an already-clean file, and
# write nothing at all under --dry-run.
legacy="$TMP/legacy-archive"
mkdir -p "$legacy"
cat > "$legacy/task-old1.meta.json" <<EOF
{"job":{"id":"task-old1","status":"completed","summary":"Investigate $SECRET"},
 "storedJob":{"id":"task-old1","status":"completed","threadId":"th-keepme",
 "request":{"cwd":"/w","model":"gpt-5.6-sol","effort":"high",
 "focusText":"focus on $SECRET","userInput":"renamed carrying $SECRET"}}}
EOF
printf '# Codex Task\n\nJob: task-old1\nStatus: completed\nSummary: Investigate %s\n\nNo captured result payload was stored for this job.\n' \
  "$SECRET" > "$legacy/task-old1.result.txt"
cp "$legacy/task-old1.meta.json" "$TMP/legacy-meta-before.json"
cp "$legacy/task-old1.result.txt" "$TMP/legacy-result-before.txt"

out="$(bash "$CREW" sanitize-archive --dir "$legacy" --dry-run 2>&1)" && rc=0 || rc=$?
if [[ "$rc" == 0 ]] && grep -q "would sanitize: task-old1" <<<"$out" \
   && cmp -s "$legacy/task-old1.meta.json" "$TMP/legacy-meta-before.json" \
   && cmp -s "$legacy/task-old1.result.txt" "$TMP/legacy-result-before.txt"; then
  echo "PASS: sanitize-archive --dry-run reported the leak and wrote nothing"; pass=$((pass + 1))
else
  echo "FAIL: --dry-run wrote something or missed the file (exit=$rc; output: $out)"; fail=$((fail + 1))
fi

out="$(bash "$CREW" sanitize-archive --dir "$legacy" 2>&1)" && rc=0 || rc=$?
if [[ "$rc" == 0 ]] && ! grep -rq "$SECRET" "$legacy" \
   && grep -q '"focusText": "<redacted:' "$legacy/task-old1.meta.json" \
   && grep -q '"userInput": "<redacted:' "$legacy/task-old1.meta.json" \
   && grep -q "<redacted:" "$legacy/task-old1.result.txt" \
   && grep -q "Job: task-old1" "$legacy/task-old1.result.txt"; then
  echo "PASS: sanitize-archive cleaned a legacy meta and its result render"; pass=$((pass + 1))
else
  echo "FAIL: legacy archive still leaks (exit=$rc; output: $out)"; fail=$((fail + 1))
fi

# Idempotence is load-bearing: the sweep is safe to re-run only if a second
# pass is a genuine no-op. Re-markering would rewrite each recorded length to
# the length of the marker itself, quietly corrupting the shape record.
# ⚠️ This is ALSO the only caller entitled to trust a marker — sanitize-archive
# re-reads its own prior output, so it sets CREW_TRUST_MARKERS. The live await
# path must not, and case 20j plus the structural cases below hold that line.
cp "$legacy/task-old1.meta.json" "$TMP/legacy-meta-clean.json"
cp "$legacy/task-old1.result.txt" "$TMP/legacy-result-clean.txt"
out="$(bash "$CREW" sanitize-archive --dir "$legacy" 2>&1)" && rc=0 || rc=$?
if [[ "$rc" == 0 ]] && grep -q "0 rewritten" <<<"$out" \
   && cmp -s "$legacy/task-old1.meta.json" "$TMP/legacy-meta-clean.json" \
   && cmp -s "$legacy/task-old1.result.txt" "$TMP/legacy-result-clean.txt"; then
  echo "PASS: a second sanitize-archive pass is byte-for-byte a no-op"; pass=$((pass + 1))
else
  echo "FAIL: sanitize-archive is not idempotent (exit=$rc; output: $out)"; fail=$((fail + 1))
fi

# ...and byte-identity is not enough on its own: assert the RECORDED LENGTHS
# still describe the original text. A re-marker that happened to be stable
# would pass cmp on the third pass while having already corrupted the second.
if python3 -c "
import json
d = json.load(open('$legacy/task-old1.meta.json'))
# 'focus on AKIAZZTESTSECRET42' is 27 chars; a re-marker would record 20 (the
# length of '<redacted: 24 chars>' itself).
assert d['storedJob']['request']['focusText'] == '<redacted: 27 chars>', d
assert d['job']['summary'] == '<redacted: 30 chars>', d
"; then
  echo "PASS: repeated sweeps preserve the recorded shape, not the marker's own length"; pass=$((pass + 1))
else
  echo "FAIL: re-markering corrupted the shape record: $(cat "$legacy/task-old1.meta.json")"; fail=$((fail + 1))
fi

# Case 20m: an ORPHANED result — a .result.txt with no .meta.json beside it.
# await wrote the render before running the best-effort meta sanitizer, so an
# interruption in that window leaves exactly this. A meta-driven sweep never
# enumerates it, never counts it, and exits 0 calling the archive clean.
orphan="$TMP/orphan-archive"
mkdir -p "$orphan"
printf '# Codex Task\n\nJob: task-orphan\nStatus: completed\nSummary: Investigate %s\n\nNo captured result payload was stored for this job.\n' \
  "$SECRET" > "$orphan/task-orphan.result.txt"
out="$(bash "$CREW" sanitize-archive --dir "$orphan" 2>&1)" && rc=0 || rc=$?
if [[ "$rc" == 0 ]] && ! grep -rq "$SECRET" "$orphan" \
   && grep -q "1 archived job(s) inspected" <<<"$out"; then
  echo "PASS: sanitize-archive cleans a result with no meta beside it"; pass=$((pass + 1))
else
  echo "FAIL: orphaned result was skipped (exit=$rc; output: $out; file: $(cat "$orphan/task-orphan.result.txt"))"; fail=$((fail + 1))
fi

# Case 20n: a stale unsanitized STAGING file from the old in-archive design is
# pure prompt text that nothing else will ever read. The sweep removes it.
printf 'raw render mentioning %s\n' "$SECRET" > "$orphan/.task-ghost.result.raw"
out="$(bash "$CREW" sanitize-archive --dir "$orphan" 2>&1)" && rc=0 || rc=$?
if ! grep -rq "$SECRET" "$orphan" && grep -q "stale unsanitized staging file" <<<"$out"; then
  echo "PASS: sanitize-archive removes a stale unsanitized staging file"; pass=$((pass + 1))
else
  echo "FAIL: stale staging file survived (exit=$rc; output: $out)"; fail=$((fail + 1))
fi

# Case 20o: a symlinked archive entry. cp/mv through one writes wherever it
# points, so --dir at a crafted directory could rewrite files outside the
# archive entirely. Refuse rather than follow.
linkarc="$TMP/link-archive"
mkdir -p "$linkarc"
printf 'victim contents\n' > "$TMP/victim.txt"
ln -s "$TMP/victim.txt" "$linkarc/task-link.result.txt"
echo '{"job":{"id":"task-link","summary":"x"},"storedJob":{"id":"task-link"}}' \
  > "$linkarc/task-link.meta.json"
out="$(bash "$CREW" sanitize-archive --dir "$linkarc" 2>&1)" && rc=0 || rc=$?
if [[ "$rc" == 1 ]] && grep -q "symlinked archive entry" <<<"$out" \
   && [[ "$(cat "$TMP/victim.txt")" == "victim contents" ]] \
   && [[ -L "$linkarc/task-link.result.txt" ]]; then
  echo "PASS: sanitize-archive refuses to write through a symlink"; pass=$((pass + 1))
else
  echo "FAIL: symlink was followed or not reported (exit=$rc; output: $out; victim: $(cat "$TMP/victim.txt"))"; fail=$((fail + 1))
fi

# --- structural allowlist: unknown is redacted, at every level ---------------
# The predecessor decided by NAME: a *prompt/*focusText denylist, an output
# allowlist matched at ANY depth, and a 512-char length guard as the catch-all.
# All three failed the same way — they let something through because of what it
# was CALLED or how LONG it was. These cases pin the replacement: a key is
# recognized by WHERE it sits, and everything else is markered.
mkdir -p "$TMP/struct/plugins" "$TMP/struct/install/scripts"
echo "{\"version\":2,\"plugins\":{\"codex@openai-codex\":[{\"installPath\":\"$TMP/struct/install\"}]}}" \
  > "$TMP/struct/plugins/installed_plugins.json"
# A companion whose result --json payload the CASE supplies verbatim, so each
# case below pins one exact shape instead of adding another env branch to a
# fixture five cases already share.
cat > "$TMP/struct/install/scripts/codex-companion.mjs" <<'EOF'
const [cmd, jobId, flag] = process.argv.slice(2);
if (cmd === "result") {
  if (flag !== "--json") { console.log("FINAL-RESULT-KEEP"); process.exit(0); }
  console.log(process.env.CREW_TEST_PAYLOAD || "{}");
  process.exit(0);
}
console.log(JSON.stringify({
  job: { id: jobId, status: "completed", elapsed: "1s", logFile: "-", pid: null }
}));
EOF

struct_await() {  # $1 = job id, $2 = archive dir, $3 = payload JSON
  CLAUDE_CONFIG_DIR="$TMP/struct" CREW_CODEX_ARCHIVE_DIR="$2" CREW_CODEX_POLL_SECS=0 \
    CREW_TEST_PAYLOAD="$3" bash "$CREW" await "$1" --for 5 >/dev/null 2>&1
}

# Case 20p: a SHORT secret under an unknown metadata key. The length guard was
# the only thing standing between an unrecognized field and the archive, and a
# bearer token, an API key or an internal hostname is nowhere near 512 chars —
# every one of them walked straight through.
arc="$TMP/struct/arc-short"
struct_await task-short "$arc" '{"job":{"id":"task-short","status":"completed","apiToken":"sk-ab12"},"storedJob":{"id":"task-short","status":"completed"}}' || true
if [[ -f "$arc/task-short.meta.json" ]] && ! grep -q "sk-ab12" "$arc/task-short.meta.json" \
   && grep -q '"apiToken": "<redacted: 7 chars>"' "$arc/task-short.meta.json"; then
  echo "PASS: a short secret under an unknown key is redacted, not size-tested"; pass=$((pass + 1))
else
  echo "FAIL: short unknown field survived: $(cat "$arc/task-short.meta.json" 2>/dev/null)"; fail=$((fail + 1))
fi

# Case 20q: THE OUTPUT-NAME BYPASS. `result`/`rendered`/`stdout`/`output` used
# to be matched by name at ANY depth, and once matched they disabled every
# bound BELOW them. So a field called `stdout` sitting where no output belongs
# was an unbounded hole: name it right and anything fits through.
arc="$TMP/struct/arc-bypass"
struct_await task-bypass "$arc" '{"job":{"id":"task-bypass","status":"completed","stdout":{"leak":"PROMPTLEAK-'"$(printf 'x%.0s' {1..600})"'"}},"storedJob":{"id":"task-bypass","status":"completed"}}' || true
if [[ -f "$arc/task-bypass.meta.json" ]] && ! grep -q "PROMPTLEAK-" "$arc/task-bypass.meta.json" \
   && grep -q '"stdout": "<redacted: 1 key(s)>"' "$arc/task-bypass.meta.json"; then
  echo "PASS: an output-NAMED key outside the output path gets no privileges"; pass=$((pass + 1))
else
  echo "FAIL: the output-name bypass is still open: $(cat "$arc/task-bypass.meta.json" 2>/dev/null)"; fail=$((fail + 1))
fi

# Case 20r: the flip side, and the reason the archive exists at all. Genuine
# storedJob.result and storedJob.rendered are model OUTPUT — verbatim, however
# long. An allowlist that over-redacts here is not safer, it is useless.
arc="$TMP/struct/arc-output"
LONGOUT="$(printf 'the model wrote a great deal %.0s' {1..60})"
struct_await review-output "$arc" '{"job":{"id":"review-output","status":"completed"},"storedJob":{"id":"review-output","status":"completed","result":{"rawOutput":"'"$LONGOUT"'"},"rendered":"'"$LONGOUT"'"}}' || true
if python3 -c "
import json
d = json.load(open('$arc/review-output.meta.json'))
sj = d['storedJob']
assert sj['result']['rawOutput'] == '''$LONGOUT''', sj['result']
assert sj['rendered'] == '''$LONGOUT''', sj['rendered']
" 2>/dev/null; then
  echo "PASS: storedJob.result and storedJob.rendered survive verbatim and unbounded"; pass=$((pass + 1))
else
  echo "FAIL: the output subtrees were redacted: $(cat "$arc/review-output.meta.json" 2>/dev/null)"; fail=$((fail + 1))
fi

# Case 20s: an EXACTLY CANONICAL marker arriving from the companion. Case 20j
# covers the near-miss; this is the one that a fullmatch alone cannot stop,
# because the string genuinely IS a marker — it is just not OURS. The live
# await path reads user-controlled data and must therefore trust no marker at
# all, so the value is re-markered to the length of the string it received.
arc="$TMP/struct/arc-canon"
struct_await task-canon "$arc" '{"job":{"id":"task-canon","status":"completed"},"storedJob":{"id":"task-canon","status":"completed","request":{"cwd":"/w","prompt":"<redacted: 42 chars>"}}}' || true
if python3 -c "
import json
d = json.load(open('$arc/task-canon.meta.json'))
r = d['storedJob']['request']
# '<redacted: 42 chars>' is 20 characters. Passing it through would record 42 —
# a length this archive never measured, attesting to text it never saw.
assert r['prompt'] == '<redacted: 20 chars>', r
" 2>/dev/null; then
  echo "PASS: await trusts no marker — a canonical one from the companion is re-markered"; pass=$((pass + 1))
else
  echo "FAIL: await trusted a companion-supplied marker: $(cat "$arc/task-canon.meta.json" 2>/dev/null)"; fail=$((fail + 1))
fi

# Case 20t: a UNICODE-digit marker. `\d` without re.ASCII matches Devanagari
# digits, so "<redacted: ६ chars>" satisfied the old pattern. Under marker
# trust that is a bypass; the ASCII flag closes it. Asserted through the sweep,
# which is the caller that trusts markers.
canon="$TMP/canon-archive"
mkdir -p "$canon"
printf '{"job":{"id":"task-uni","status":"completed","summary":"<redacted: \xe0\xa5\xac chars>"},"storedJob":{"id":"task-uni","status":"completed"}}\n' \
  > "$canon/task-uni.meta.json"
out="$(bash "$CREW" sanitize-archive --dir "$canon" 2>&1)" && rc=0 || rc=$?
if [[ "$rc" == 0 ]] && grep -q '"summary": "<redacted: 19 chars>"' "$canon/task-uni.meta.json"; then
  echo "PASS: a unicode-digit marker is not mistaken for a canonical one"; pass=$((pass + 1))
else
  echo "FAIL: unicode-digit marker trusted (exit=$rc): $(cat "$canon/task-uni.meta.json")"; fail=$((fail + 1))
fi

# Case 20u: a TRANSIENT sanitizer failure must not destroy a result an earlier
# pass already sanitized. The old code stubbed unconditionally, so one node
# crash or one closed pipe replaced an unrepeatable model answer with an
# apology. The trap below is a DIRECTORY at the meta's atomic-write path: the
# sanitizer raises before it reaches the result, exactly like a transient fault.
arc="$TMP/struct/arc-sentinel"
struct_await task-sent "$arc" '{"job":{"id":"task-sent","status":"completed"},"storedJob":{"id":"task-sent","status":"completed","result":{"rawOutput":"KEEP-THIS-ANSWER"}}}' || true
cp "$arc/task-sent.result.txt" "$TMP/sent-before.txt"
# The trap is a DIRECTORY at the meta's own path: write_atomic stages through
# mkstemp now, so the old "$path.tmp" trap no longer fires — but os.replace onto
# a directory still raises, which is what a transient fault looks like here.
rm -f "$arc/task-sent.meta.json"
mkdir "$arc/task-sent.meta.json"
struct_await task-sent "$arc" '{"job":{"id":"task-sent","status":"completed"}}' || true
if cmp -s "$arc/task-sent.result.txt" "$TMP/sent-before.txt" \
   && grep -q "FINAL-RESULT-KEEP" "$arc/task-sent.result.txt"; then
  echo "PASS: a sentinel-verified result survives a transient sanitizer failure"; pass=$((pass + 1))
else
  echo "FAIL: a transient failure destroyed a verified result: $(cat "$arc/task-sent.result.txt" 2>/dev/null)"; fail=$((fail + 1))
fi

# ...and the sentinel must not become a licence to keep ANY file that happens
# to be there. A legacy result with no sentinel is still replaced, which is the
# stale-leak contract case 20l pins.
printf 'legacy unsanitized render mentioning %s\n' "$SECRET" > "$arc/task-sent.result.txt"
rm -f "$arc/task-sent.sanitized"
struct_await task-sent "$arc" '{"job":{"id":"task-sent","status":"completed"}}' || true
if ! grep -q "$SECRET" "$arc/task-sent.result.txt" \
   && grep -q "result withheld" "$arc/task-sent.result.txt"; then
  echo "PASS: an unverified legacy result is still replaced on sanitizer failure"; pass=$((pass + 1))
else
  echo "FAIL: unverified legacy result survived: $(cat "$arc/task-sent.result.txt")"; fail=$((fail + 1))
fi
# ...and a sentinel whose digest no longer matches the file is not a sentinel.
printf 'sanitized-looking but tampered\n' > "$arc/task-sent.result.txt"
printf '{"jobId":"task-sent","sha256":"%s","bytes":1}\n' "$(printf 'd%.0s' {1..64})" \
  > "$arc/task-sent.sanitized"
struct_await task-sent "$arc" '{"job":{"id":"task-sent","status":"completed"}}' || true
if grep -q "result withheld" "$arc/task-sent.result.txt" \
   && [[ ! -f "$arc/task-sent.sanitized" ]]; then
  echo "PASS: a stale sentinel does not vouch for the file beside it"; pass=$((pass + 1))
else
  echo "FAIL: a mismatched sentinel was trusted: $(cat "$arc/task-sent.result.txt")"; fail=$((fail + 1))
fi
rmdir "$arc/task-sent.meta.json" 2>/dev/null || true

# Case 20v: the staging path must be UNPREDICTABLE. "$dst.satmp.$$" is derived
# from a pid, so in a group- or world-writable archive an attacker precreates a
# symlink at the name the sweep is about to use and the write lands wherever
# they point — defeating the destination symlink check the sweep performs one
# line earlier. mktemp creates O_EXCL under an unguessable name. Asserted by
# recording the templates mktemp is actually asked for: the old code never
# called it for staging at all.
mkdir -p "$TMP/mkshim"
REAL_MKTEMP="$(command -v mktemp)"
cat > "$TMP/mkshim/mktemp" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$MKTEMP_LOG"
exec "$REAL_MKTEMP" "\$@"
EOF
chmod +x "$TMP/mkshim/mktemp"
stagearc="$TMP/stage-archive"
mkdir -p "$stagearc"
cat > "$stagearc/task-stage.meta.json" <<EOF
{"job":{"id":"task-stage","status":"completed","summary":"Investigate $SECRET"},
 "storedJob":{"id":"task-stage","status":"completed"}}
EOF
export MKTEMP_LOG="$TMP/mktemp-calls.txt"
: > "$MKTEMP_LOG"
out="$(PATH="$TMP/mkshim:$PATH" bash "$CREW" sanitize-archive --dir "$stagearc" 2>&1)" && rc=0 || rc=$?
unset MKTEMP_LOG
if [[ "$rc" == 0 ]] && ! grep -rq "$SECRET" "$stagearc" \
   && grep -q "$stagearc/\.crew-sa\.XXXXXX" "$TMP/mktemp-calls.txt"; then
  echo "PASS: sanitize-archive stages through mktemp in the destination directory"; pass=$((pass + 1))
else
  echo "FAIL: staging path is predictable or the sweep failed (exit=$rc; calls: $(cat "$TMP/mktemp-calls.txt"); output: $out)"; fail=$((fail + 1))
fi
if [[ -z "$(find "$stagearc" -name '*.satmp.*' -o -name '.crew-sa.*' 2>/dev/null)" ]]; then
  echo "PASS: no staging residue is left in the archive"; pass=$((pass + 1))
else
  echo "FAIL: staging residue survived: $(find "$stagearc" -name '*.satmp.*' -o -name '.crew-sa.*')"; fail=$((fail + 1))
fi

# Case 20w: a filename containing a NEWLINE. The sweep used to join every id
# into one newline-delimited string and `sort -u` it, which split this single
# real file into two ids that do not exist. Both were then "inspected" and
# found absent, the sweep exited 0 calling the archive clean, and the actual
# prompt-bearing file was never opened.
nlarc="$TMP/nl-archive"
mkdir -p "$nlarc"
nlname=$'task-nl\nghost'
printf '# Codex Task\n\nJob: %s\nStatus: completed\nSummary: Investigate %s\n\nNo captured result payload was stored for this job.\n' \
  "task-nl" "$SECRET" > "$nlarc/$nlname.result.txt"
out="$(bash "$CREW" sanitize-archive --dir "$nlarc" 2>&1)" && rc=0 || rc=$?
if ! grep -rq "$SECRET" "$nlarc"; then
  echo "PASS: a newline in a filename does not hide the file from the sweep"; pass=$((pass + 1))
else
  echo "FAIL: newline-named file was skipped (exit=$rc; output: $out; file: $(cat "$nlarc/$nlname.result.txt"))"; fail=$((fail + 1))
fi

# --- round-3 review findings -------------------------------------------------

# Case 20x: fv-2. `summary` used to be dropped only for a `task-` prefix, so
# every OTHER job kind kept it verbatim and unbounded. That is fail-OPEN: a
# future vendor job kind whose summary is prompt-derived leaks silently, which
# is the exact failure mode the structural rewrite exists to remove. The test is
# inverted with it — only a known output prefix keeps a summary.
arc="$TMP/struct/arc-prefix"
struct_await job-newkind "$arc" '{"job":{"id":"job-newkind","status":"completed","summary":"Investigate NEWKINDSECRET"},"storedJob":{"id":"job-newkind","status":"completed"}}' || true
if [[ -f "$arc/job-newkind.meta.json" ]] && ! grep -q "NEWKINDSECRET" "$arc/job-newkind.meta.json"; then
  echo "PASS: an unknown job-id prefix does not keep its summary"; pass=$((pass + 1))
else
  echo "FAIL: summary failed open for an unknown prefix: $(cat "$arc/job-newkind.meta.json" 2>/dev/null)"; fail=$((fail + 1))
fi
# ...while a review summary still survives, or the archive stops being useful.
arc="$TMP/struct/arc-prefix-review"
struct_await review-keep "$arc" '{"job":{"id":"review-keep","status":"completed","summary":"Review found 2 issues"},"storedJob":{"id":"review-keep","status":"completed"}}' || true
if grep -q '"summary": "Review found 2 issues"' "$arc/review-keep.meta.json" 2>/dev/null; then
  echo "PASS: a review finding summary is still kept"; pass=$((pass + 1))
else
  echo "FAIL: review summary was over-redacted: $(cat "$arc/review-keep.meta.json" 2>/dev/null)"; fail=$((fail + 1))
fi

# Case 20y: fv-3. The withheld-record keys exist so the SWEEP can re-read its
# own output idempotently. Honoring them on the live await path — where the
# payload is companion output — preserved a top-level `reason` for no benefit.
arc="$TMP/struct/arc-toplevel"
struct_await task-top "$arc" '{"reason":"top-level TOPLEVELSECRET","job":{"id":"task-top","status":"completed"}}' || true
if [[ -f "$arc/task-top.meta.json" ]] && ! grep -q "TOPLEVELSECRET" "$arc/task-top.meta.json"; then
  echo "PASS: top-level scalar recognition is a sweep privilege, not a live-path one"; pass=$((pass + 1))
else
  echo "FAIL: live path preserved a top-level scalar: $(cat "$arc/task-top.meta.json" 2>/dev/null)"; fail=$((fail + 1))
fi

# Case 20z: the output boundary is compared EXACTLY. Everywhere else norm() can
# only tighten the rule; here it hands out unbounded verbatim preservation, so
# an aliased spelling would alias straight into it.
arc="$TMP/struct/arc-alias"
struct_await task-alias "$arc" '{"job":{"id":"task-alias","status":"completed","R_e_s_u_l_t":{"leak":"ALIASSECRET"}},"storedJob":{"id":"task-alias","status":"completed"}}' || true
if [[ -f "$arc/task-alias.meta.json" ]] && ! grep -q "ALIASSECRET" "$arc/task-alias.meta.json"; then
  echo "PASS: an aliased output key does not reach the verbatim branch"; pass=$((pass + 1))
else
  echo "FAIL: norm() aliased into the output boundary: $(cat "$arc/task-alias.meta.json" 2>/dev/null)"; fail=$((fail + 1))
fi

# Case 20aa: fv-1. A prompt-derived summary embedded in a PRESERVED output
# string. The .result.txt path already strips it; keeping it in the meta beside
# that file would mean redacting a prompt in the file a human reads and
# archiving it one filename away.
arc="$TMP/struct/arc-rendered"
struct_await task-rend "$arc" '{"job":{"id":"task-rend","status":"completed","summary":"Implemented the fix"},"storedJob":{"id":"task-rend","status":"completed","summary":"Investigate RENDSECRET thoroughly","rendered":"# Codex Task\n\nSummary: Investigate RENDSECRET thoroughly\n\nmodel output continues here"}}' || true
if [[ -f "$arc/task-rend.meta.json" ]] && ! grep -q "RENDSECRET" "$arc/task-rend.meta.json" \
   && grep -q "model output continues here" "$arc/task-rend.meta.json"; then
  echo "PASS: a prompt-derived summary is stripped from preserved output, the rest kept"; pass=$((pass + 1))
else
  echo "FAIL: rendered output kept the prompt summary or lost its content: $(cat "$arc/task-rend.meta.json" 2>/dev/null)"; fail=$((fail + 1))
fi

# Case 20ab: fv-4. write_atomic staged at the fully predictable "$path.tmp" and
# opened it with a plain open(..., "w"), which follows a symlink. The archive
# directory is the one place this matters, and the sweep's commit helper was
# hardened against exactly this in the same commit — await was not.
arc="$TMP/struct/arc-symlink"
mkdir -p "$arc"
printf 'victim contents\n' > "$TMP/victim-await.txt"
ln -s "$TMP/victim-await.txt" "$arc/task-sym.meta.json.tmp"
struct_await task-sym "$arc" '{"job":{"id":"task-sym","status":"completed"},"storedJob":{"id":"task-sym","status":"completed"}}' || true
if [[ "$(cat "$TMP/victim-await.txt")" == "victim contents" ]] \
   && [[ -f "$arc/task-sym.meta.json" ]] && grep -q '"id": "task-sym"' "$arc/task-sym.meta.json"; then
  echo "PASS: await does not stage through a predictable, symlinked temp path"; pass=$((pass + 1))
else
  echo "FAIL: await wrote through the planted symlink (victim: $(cat "$TMP/victim-await.txt"))"; fail=$((fail + 1))
fi

# Case 20ac: the alias defect at EVERY boundary, not just the output one.
# Fixing only the verbatim-output comparison leaves the rest fail-open: an
# aliased TOP-LEVEL key normalizes to `job`, after which the exactly-spelled
# nested `result` under it is preserved verbatim anyway.
arc="$TMP/struct/arc-alias-top"
struct_await task-atop "$arc" '{"j-o-b":{"result":{"prompt":"TOPALIASSECRET"}},"storedJob":{"id":"task-atop","status":"completed"}}' || true
if [[ -f "$arc/task-atop.meta.json" ]] && ! grep -q "TOPALIASSECRET" "$arc/task-atop.meta.json"; then
  echo "PASS: an aliased top-level key does not become a job container"; pass=$((pass + 1))
else
  echo "FAIL: top-level alias reached the job branch: $(cat "$arc/task-atop.meta.json" 2>/dev/null)"; fail=$((fail + 1))
fi

# ...and the same for the metadata and request allowlists, where the value is
# capped but a SHORT secret fits inside the cap with room to spare.
arc="$TMP/struct/arc-alias-meta"
struct_await task-ameta "$arc" '{"job":{"id":"task-ameta","status":"completed","t-h-r-e-a-d-I-d":"sk-meta-1"},"storedJob":{"id":"task-ameta","status":"completed","request":{"cwd":"/w","m-o-d-e-l":"sk-req-1"}}}' || true
if [[ -f "$arc/task-ameta.meta.json" ]] \
   && ! grep -q "sk-meta-1" "$arc/task-ameta.meta.json" \
   && ! grep -q "sk-req-1" "$arc/task-ameta.meta.json" \
   && grep -q '"cwd": "/w"' "$arc/task-ameta.meta.json"; then
  echo "PASS: aliased metadata and request keys are redacted, real ones still kept"; pass=$((pass + 1))
else
  echo "FAIL: an aliased key reached an allowlist: $(cat "$arc/task-ameta.meta.json" 2>/dev/null)"; fail=$((fail + 1))
fi

# --- round-4 review findings -------------------------------------------------

# Case 20ad: a COMPLETED task's two summaries have OPPOSITE provenance, and the
# fix for the previous round got this exactly backwards. Verified against codex
# 1.0.6: storedJob.summary is the dispatch record's shorten(prompt) — input, the
# needle. job.summary is execution.summary = firstMeaningfulLine(rawOutput) —
# MODEL OUTPUT, and by construction a line that also appears inside result. Using
# it as a substring needle deletes the first line of the answer out of the
# preserved subtree of every completed task.
arc="$TMP/struct/arc-summary-provenance"
struct_await task-prov "$arc" '{"job":{"id":"task-prov","status":"completed","summary":"Implemented the fix"},"storedJob":{"id":"task-prov","status":"completed","summary":"investigate PROVSECRET thoroughly","result":{"rawOutput":"Implemented the fix\nTests pass"}}}' || true
if [[ -f "$arc/task-prov.meta.json" ]] \
   && ! grep -q "PROVSECRET" "$arc/task-prov.meta.json" \
   && python3 -c "
import json
d = json.load(open('$arc/task-prov.meta.json'))
out = d['storedJob']['result']['rawOutput']
assert out == 'Implemented the fix\nTests pass', repr(out)
"; then
  echo "PASS: the prompt-derived summary is the needle; model output survives intact"; pass=$((pass + 1))
else
  echo "FAIL: output-derived summary was used as a needle: $(cat "$arc/task-prov.meta.json" 2>/dev/null)"; fail=$((fail + 1))
fi

# Case 20af: sanitize-archive sets marker trust for EVERY file it sweeps —
# including the legacy unsanitized ones it exists to migrate. Recognizing
# top-level scalars under that trust meant the migration command preserved a
# legacy top-level secret verbatim. The withheld record is now REGENERATED, not
# copied, so nothing read off disk is trusted.
legacytop="$TMP/legacy-toplevel"
mkdir -p "$legacytop"
printf '{"reason":"LEGACYTOPSECRET","crewArchive":"withheld","jobId":"task-lt"}\n' \
  > "$legacytop/task-lt.meta.json"
out="$(bash "$CREW" sanitize-archive --dir "$legacytop" 2>&1)" && rc=0 || rc=$?
if [[ "$rc" == 0 ]] && ! grep -q "LEGACYTOPSECRET" "$legacytop/task-lt.meta.json"; then
  echo "PASS: the sweep does not trust top-level scalars in the files it migrates"; pass=$((pass + 1))
else
  echo "FAIL: sanitize-archive preserved a legacy top-level secret (exit=$rc): $(cat "$legacytop/task-lt.meta.json")"; fail=$((fail + 1))
fi
# ...and re-sanitizing a withheld record it wrote itself is still a no-op.
cp "$legacytop/task-lt.meta.json" "$TMP/legacy-lt-clean.json"
out="$(bash "$CREW" sanitize-archive --dir "$legacytop" 2>&1)" && rc=0 || rc=$?
if [[ "$rc" == 0 ]] && grep -q "0 rewritten" <<<"$out" \
   && cmp -s "$legacytop/task-lt.meta.json" "$TMP/legacy-lt-clean.json"; then
  echo "PASS: a regenerated withheld record round-trips byte-identically"; pass=$((pass + 1))
else
  echo "FAIL: withheld-record idempotence broke (exit=$rc; output: $out)"; fail=$((fail + 1))
fi

# Case 20ag: marker-shaped summaries must never become needles. A second sweep
# would otherwise use pass 1's "<redacted: N chars>" as a search string and
# rewrite matching markers inside preserved output — falsifying a recorded
# length (22 -> 20) and breaking byte-idempotence on an already-clean archive.
markarc="$TMP/marker-needle-archive"
mkdir -p "$markarc"
cat > "$markarc/task-mn.meta.json" <<'EOF'
{"job":{"id":"task-mn","status":"completed"},
 "storedJob":{"id":"task-mn","status":"completed","summary":"<redacted: 22 chars>",
 "rendered":"Summary: <redacted: 22 chars>\nand the answer continues"}}
EOF
# ⚠️ Assert on the FIRST sweep. Comparing pass 2 against pass 1 would miss the
# defect entirely: pass 1 does the 22 -> 20 rewrite and pass 2 is then stable,
# so a "second pass is a no-op" test passes while the archive is already
# corrupted. The invariant is that the recorded length still describes the text
# that was removed.
out="$(bash "$CREW" sanitize-archive --dir "$markarc" 2>&1)" && rc=0 || rc=$?
if [[ "$rc" == 0 ]] && grep -q '"rendered": "Summary: <redacted: 22 chars>' "$markarc/task-mn.meta.json"; then
  echo "PASS: a marker is never used as a replacement needle"; pass=$((pass + 1))
else
  echo "FAIL: marker-as-needle rewrote preserved output on the first pass (exit=$rc; file: $(cat "$markarc/task-mn.meta.json"))"; fail=$((fail + 1))
fi
cp "$markarc/task-mn.meta.json" "$TMP/marker-needle-clean.json"
out="$(bash "$CREW" sanitize-archive --dir "$markarc" 2>&1)" && rc=0 || rc=$?
if [[ "$rc" == 0 ]] && grep -q "0 rewritten" <<<"$out" \
   && cmp -s "$markarc/task-mn.meta.json" "$TMP/marker-needle-clean.json"; then
  echo "PASS: and the sweep over that archive stays a byte-for-byte no-op"; pass=$((pass + 1))
else
  echo "FAIL: marker-needle archive is not idempotent (exit=$rc; output: $out)"; fail=$((fail + 1))
fi

# --- round-5 review findings -------------------------------------------------

# Case 20ah: a SHORT prompt secret echoed into preserved output. The previous
# round exempted summaries under 12 characters from redaction, because the
# replacement was a bare substring sweep and a two-character summary shredded
# the answer. That exemption traded confidentiality for fidelity: `PIN=123456`
# is ten characters and stayed in the archive in full. Anchoring the replacement
# removes the trade — length stops mattering in either direction.
arc="$TMP/struct/arc-short-secret"
struct_await task-pin "$arc" '{"job":{"id":"task-pin","status":"completed"},"storedJob":{"id":"task-pin","status":"completed","summary":"PIN=123456","result":{"rawOutput":"PIN=123456"}}}' || true
if [[ -f "$arc/task-pin.meta.json" ]] && ! grep -q "PIN=123456" "$arc/task-pin.meta.json"; then
  echo "PASS: a short prompt secret in preserved output is still redacted"; pass=$((pass + 1))
else
  echo "FAIL: short summary exempted from redaction: $(cat "$arc/task-pin.meta.json" 2>/dev/null)"; fail=$((fail + 1))
fi

# ...and the anchoring is what makes that safe: a two-character summary must
# still not rewrite every occurrence of those two characters in the answer.
arc="$TMP/struct/arc-anchor"
struct_await task-anch "$arc" '{"job":{"id":"task-anch","status":"completed"},"storedJob":{"id":"task-anch","status":"completed","summary":"ls","result":{"rawOutput":"false positives also contain ls inside words"}}}' || true
if python3 -c "
import json
d = json.load(open('$arc/task-anch.meta.json'))
assert d['storedJob']['result']['rawOutput'] == 'false positives also contain ls inside words', d['storedJob']['result']
" 2>/dev/null; then
  echo "PASS: an anchored replacement does not shred output containing the summary"; pass=$((pass + 1))
else
  echo "FAIL: substring replacement corrupted model output: $(cat "$arc/task-anch.meta.json" 2>/dev/null)"; fail=$((fail + 1))
fi

# --- reap: sweep stuck registry entries --------------------------------------
# repo-a: dead-pid job alone (reapable, has state.json to mirror into)
# repo-b: live job + frozen job + done job (frozen must be SKIPPED — live ws)
# repo-c: frozen no-pid job alone (reapable via log age)
REAP_DATA="$TMP/reap-data"
mkdir -p "$REAP_DATA/state/repo-a/jobs" "$REAP_DATA/state/repo-b/jobs" "$REAP_DATA/state/repo-c/jobs"
DEAD_PID2=$(bash -c 'echo $$')
oldlog="$REAP_DATA/state/repo-a/jobs/dead.log"; echo x > "$oldlog"; touch_ago '2 hours ago' "$oldlog"
cat > "$REAP_DATA/state/repo-a/jobs/dead.json" <<EOF
{"id":"job-dead","status":"running","pid":$DEAD_PID2,"logFile":"$oldlog","createdAt":"2026-07-01T00:00:00Z"}
EOF
cat > "$REAP_DATA/state/repo-a/state.json" <<EOF
[{"id":"job-dead","status":"running","pid":$DEAD_PID2},{"id":"job-other","status":"completed"}]
EOF
frozenlog="$REAP_DATA/state/repo-b/jobs/frozen.log"; echo x > "$frozenlog"; touch_ago '2 hours ago' "$frozenlog"
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
frozenlog2="$REAP_DATA/state/repo-c/jobs/frozen2.log"; echo x > "$frozenlog2"; touch_ago '2 hours ago' "$frozenlog2"
cat > "$REAP_DATA/state/repo-c/jobs/frozen2.json" <<EOF
{"id":"job-frozen2","status":"running","logFile":"$frozenlog2","createdAt":"2026-07-01T00:00:00Z"}
EOF

# Case 21: dry-run reports but mutates nothing.
# ⚠️ Exit 3, not 0: repo-b's frozen job is SKIPPED because that workspace holds a
# live job, and a sweep that walked past an entry is not a complete sweep. The
# clean-sweep counterpart (exit 0) is case 39 — the two together are what make
# this exit code mean anything.
out="$(CLAUDE_CONFIG_DIR="$TMP/await" CLAUDE_PLUGIN_DATA="$REAP_DATA" \
  bash "$CREW" reap --dry-run 2>&1)" && rc=0 || rc=$?
check "reap dry-run flags dead job" 3 "would reap: repo-a/job-dead" "$rc" "$out"
check "reap dry-run skips live workspace" 3 "skipped: repo-b/job-frozen" "$rc" "$out"
check "reap dry-run summary" 3 "2 flagged, 1 kept, 1 skipped" "$rc" "$out"
if grep -q '"status":"running"' "$REAP_DATA/state/repo-a/jobs/dead.json"; then
  echo "PASS: dry-run left state untouched"; pass=$((pass + 1))
else
  echo "FAIL: dry-run mutated state"; fail=$((fail + 1))
fi

# Case 22: real reap marks dead+frozen failed, keeps live, mirrors state.json
out="$(CLAUDE_CONFIG_DIR="$TMP/await" CLAUDE_PLUGIN_DATA="$REAP_DATA" \
  bash "$CREW" reap 2>&1)" && rc=0 || rc=$?
check "reap marks stuck jobs failed" 3 "2 reaped, 1 kept, 1 skipped" "$rc" "$out"
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

# On `review`: since 0.9.0 every adversarial-review runs on the effort driver,
# which this companion-only fixture cannot host. The guard logic is shared by
# both subcommands; the driver side is asserted in the effort cases (Case 53b).
out="$(run_guard review improve the help wording)" && rc=0 || rc=$?
check "unquoted focus prose containing 'help' still dispatches" 0 "COMPANION-RAN:review|improve|the|help|wording" "$rc" "$out"

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
# On `review` for the same reason as above; Case 53b covers adversarial-review.
out="$(run_guard review --base main "does the help text render")" && rc=0 || rc=$?
check "focus text containing 'help' forwards" 0 "COMPANION-RAN:review" "$rc" "$out"
check "focus text reaches the companion intact" 0 "does the help text render" "$rc" "$out"

out="$(run_guard review --effortless --helpful "focus")" && rc=0 || rc=$?
check "non-intercepted --flags forward untouched" 0 "COMPANION-RAN:review|--effortless|--helpful|focus" "$rc" "$out"

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

# Case 29: a NATIVE review dispatch stamps effort from the codex config. (An
# adversarial-review no longer can: it runs on the driver, at --effort or medium
# — Case 48 asserts that stamp.)
arc="$TMP/stamp/arc29"
out="$(run_stamp "$arc" "Review started in the background as review-msi4zm8e-cpisj8. Check /codex:status" \
  review --model gpt-5.6-sol --base main "focus")" && rc=0 || rc=$?
check "stamped dispatch passes output through" 0 "started in the background" "$rc" "$out"
if python3 -c "
import json
d = json.load(open('$arc/review-msi4zm8e-cpisj8.dispatch.json'))
assert d['jobId'] == 'review-msi4zm8e-cpisj8', d
assert d['subcommand'] == 'review', d
assert d['model'] == 'gpt-5.6-sol', d
assert d['effortRequested'] is None, d
assert d['effortEffective'] == 'xhigh', d
assert d['effortSource'] == 'config', d
assert d['argv'][:3] == ['review', '--model', 'gpt-5.6-sol'], d
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
out="$(run_stamp "$arc" "Review finished inline; no job was created." review "focus")" && rc=0 || rc=$?
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
  bash "$CREW" review "focus" 2>&1)" && rc=0 || rc=$?
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

# Case 34: --state classifies all four dirs and deletes nothing. --dry-run is
# accepted and redundant (the sweep never deletes), and the fixture carries a
# blocked and an unresolved dir, so the sweep is INCOMPLETE -> exit 3.
out="$(CLAUDE_CONFIG_DIR="$TMP/await" CLAUDE_PLUGIN_DATA="$TMP/sweep-data" \
  bash "$CREW" reap --state --dry-run 2>&1)" && rc=0 || rc=$?
check "state sweep reports the dead-cwd dir" 3 "state candidate: dead-ws" "$rc" "$out"
check "state sweep accepts a redundant --dry-run" 3 "dry-run is redundant with --state" "$rc" "$out"
check "state sweep keeps the live-cwd dir" 3 "state kept: live-ws" "$rc" "$out"
check "state sweep reports the unresolvable dir" 3 "state unresolved: unresolved-ws" "$rc" "$out"
check "state sweep refuses a dir with a non-terminal job" 3 "state blocked: busy-ws .* non-terminal" "$rc" "$out"
check "state summary counts" 3 "reap state summary: 1 reported (nothing deleted), 1 kept (cwd alive), 1 blocked (non-terminal, live pid or unreadable), 1 unresolved" "$rc" "$out"
if [[ -d "$SWEEP/dead-ws" ]]; then
  echo "PASS: state sweep deleted nothing"; pass=$((pass + 1))
else
  echo "FAIL: state sweep deleted a state dir"; fail=$((fail + 1))
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
# The script's basename must be exactly app-server-broker.mjs — the sweep only
# classifies that script — so the unique pattern lives in its directory.
BROKER_PAT="crewtest-broker-$$"
mkdir -p "$TMP/$BROKER_PAT"
# They run under REAL node, in the vendor's exact argv shape
# (`node <script> serve …`), because the sweep classifies nothing else.
BSCRIPT="$TMP/$BROKER_PAT/app-server-broker.mjs"
echo 'setTimeout(() => {}, 60000);' > "$BSCRIPT"
node "$BSCRIPT" serve --endpoint "unix:$TMP/none.sock" --cwd "$GONE_WS" & DEADCWD_PID=$!
node "$BSCRIPT" serve --endpoint "unix:$TMP/none.sock" --cwd "$TMP" & LIVECWD_PID=$!
node "$BSCRIPT" notserve --cwd "$GONE_WS" & NOTBROKER_PID=$!
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

# Case 37a: a process that matches the pgrep pattern, has the `serve` verb and
# a --cwd that is provably gone, but is NOT the broker script, is skipped — it
# used to be reported as a candidate with a paste-ready kill command. The
# decoy's name deliberately contains `app-server-broker` too.
DECOY_PAT="crewtest-decoy-$$"
mkdir -p "$TMP/$DECOY_PAT"
printf '#!/usr/bin/env bash\nsleep 60\n' > "$TMP/$DECOY_PAT/app-server-broker-decoy.sh"
bash "$TMP/$DECOY_PAT/app-server-broker-decoy.sh" serve --cwd "$GONE_WS" & DECOY_PID=$!
STUB_PIDS="$STUB_PIDS $DECOY_PID"   # the suite's EXIT trap kills it if anything aborts
sleep 0.5
out="$(CLAUDE_CONFIG_DIR="$TMP/await" CLAUDE_PLUGIN_DATA="$TMP/sweep-clean" \
  CREW_CODEX_BROKER_PATTERN="$DECOY_PAT" \
  bash "$CREW" reap --brokers 2>&1)" && rc=0 || rc=$?
kill "$DECOY_PID" 2>/dev/null || true
wait "$DECOY_PID" 2>/dev/null || true
STUB_PIDS="${STUB_PIDS% $DECOY_PID}"   # reaped: never kill -9 a recycled pid at exit
check "non-broker script matching the pattern is skipped" 0 "broker skipped: pid $DECOY_PID (not the codex broker script)" "$rc" "$out"
if ! grep -q "broker candidate: pid $DECOY_PID" <<<"$out"; then
  echo "PASS: non-broker script was never offered as a kill candidate"; pass=$((pass + 1))
else
  echo "FAIL: non-broker script offered as a candidate (output: $out)"; fail=$((fail + 1))
fi

# Case 37e: the adversarial reviewer's PoC. A NON-node process carrying the
# exact script basename and `serve` as plain positional arguments, with a cwd
# that is provably gone, satisfied the old "some argv element is the script"
# test and was reported REAP with a paste-ready kill command.
POC_PAT="crewtest-poc-$$"
python3 -c 'import time; time.sleep(60)' "$TMP/$POC_PAT/app-server-broker.mjs" serve --cwd "$GONE_WS" & POC_PID=$!
STUB_PIDS="$STUB_PIDS $POC_PID"
sleep 0.5
out="$(CLAUDE_CONFIG_DIR="$TMP/await" CLAUDE_PLUGIN_DATA="$TMP/sweep-clean" \
  CREW_CODEX_BROKER_PATTERN="$POC_PAT" \
  bash "$CREW" reap --brokers 2>&1)" && rc=0 || rc=$?
kill "$POC_PID" 2>/dev/null || true
wait "$POC_PID" 2>/dev/null || true
STUB_PIDS="${STUB_PIDS% $POC_PID}"
check "python3 carrying the broker script as an argument is skipped" 0 "broker skipped: pid $POC_PID (not the codex broker script)" "$rc" "$out"
check "python3 PoC summary has no candidate" 0 "reap brokers summary: 0 reported (nothing killed), 0 live (cwd exists), 0 unknown (cwd unreadable), 1 skipped" "$rc" "$out"
if ! grep -q "broker candidate: pid $POC_PID" <<<"$out"; then
  echo "PASS: python3 PoC was never offered as a kill candidate"; pass=$((pass + 1))
else
  echo "FAIL: python3 PoC offered as a candidate (output: $out)"; fail=$((fail + 1))
fi

# Case 37f: an EMPTY argv element. cmdline() used to drop every empty element,
# so argv ["node", "", <script>, "serve", "--cwd", /gone] normalized into the
# accepted shape and was reported REAP. `cat` fails on "" and then blocks
# opening the FIFO for read, which keeps that argv alive on darwin and Linux.
# POSIXLY_CORRECT: GNU cat otherwise permutes and rejects `--cwd` as its own
# option; `--` would change the argv shape under test. BSD cat ignores it.
EMPTY_PAT="crewtest-emptyarg-$$"
EMPTY_GONE="/nonexistent-$EMPTY_PAT"
mkdir -p "$TMP/$EMPTY_PAT"
mkfifo "$TMP/$EMPTY_PAT/app-server-broker.mjs"
bash -c 'export POSIXLY_CORRECT=1; exec -a node cat "" "$1" serve --cwd "$2"' _ "$TMP/$EMPTY_PAT/app-server-broker.mjs" "$EMPTY_GONE" 2>/dev/null & EMPTY_PID=$!
STUB_PIDS="$STUB_PIDS $EMPTY_PID"
sleep 0.5
empty_args="$(ps -o args= -p "$EMPTY_PID" 2>/dev/null)" || empty_args=""
if [[ "$empty_args" == "node "*"$EMPTY_PAT/app-server-broker.mjs serve --cwd $EMPTY_GONE" ]]; then
  echo "PASS: empty-argv decoy is alive with the expected argv"; pass=$((pass + 1))
else
  echo "FAIL: empty-argv decoy fixture did not start as expected (ps: $empty_args)"; fail=$((fail + 1))
fi
out="$(CLAUDE_CONFIG_DIR="$TMP/await" CLAUDE_PLUGIN_DATA="$TMP/sweep-clean" \
  CREW_CODEX_BROKER_PATTERN="$EMPTY_PAT" \
  bash "$CREW" reap --brokers 2>&1)" && rc=0 || rc=$?
kill "$EMPTY_PID" 2>/dev/null || true
wait "$EMPTY_PID" 2>/dev/null || true
STUB_PIDS="${STUB_PIDS% $EMPTY_PID}"
rm -f "$TMP/$EMPTY_PAT/app-server-broker.mjs"
check "empty argv element before the script is skipped" 0 "broker skipped: pid $EMPTY_PID (not the codex broker script)" "$rc" "$out"
if ! grep -q "broker candidate: pid $EMPTY_PID" <<<"$out"; then
  echo "PASS: empty-argv decoy was never offered as a kill candidate"; pass=$((pass + 1))
else
  echo "FAIL: empty-argv decoy offered as a candidate (output: $out)"; fail=$((fail + 1))
fi

# Case 37b: a cwd that cannot be PROVEN absent is UNKNOWN, never a candidate.
# os.path.isdir returns False for permission-denied, which is what reported a
# workspace we merely cannot see as one that is gone.
BROKER_PAT_U="crewtest-unknown-$$"
mkdir -p "$TMP/$BROKER_PAT_U"
echo 'setTimeout(() => {}, 60000);' > "$TMP/$BROKER_PAT_U/app-server-broker.mjs"
mkdir -p "$TMP/unreadable-parent/ws"
chmod 000 "$TMP/unreadable-parent" 2>/dev/null || true
node "$TMP/$BROKER_PAT_U/app-server-broker.mjs" serve --endpoint "unix:$TMP/none.sock" --cwd "$TMP/unreadable-parent/ws" & UNKNOWN_PID=$!
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

# Case 38: THE assertion the report-only --state design rests on. This is the
# real, non-dry sweep against the fixture the old code DELETED: a state dir whose
# cwd is provably gone, every record parsed, every job terminal, no live pid. It
# must survive, and the run must print a command for a human instead.
out="$(CLAUDE_CONFIG_DIR="$TMP/await" CLAUDE_PLUGIN_DATA="$TMP/sweep-clean" \
  bash "$CREW" reap --state 2>&1)" && rc=0 || rc=$?
check "real state sweep reports the dead dir" 3 "state candidate: dead-ws" "$rc" "$out"
check "state candidate carries a paste-ready rm command" 3 "rm -rf $CLEAN/dead-ws" "$rc" "$out"
check "state candidate warns the registry may be another session's" 3 "SHARED by every Claude Code session" "$rc" "$out"
check "state sweep announces report-only" 3 "REPORT ONLY" "$rc" "$out"
if [[ -d "$CLEAN/dead-ws" && -f "$CLEAN/dead-ws/state.json" \
      && -d "$CLEAN/live-ws" && -d "$CLEAN/unresolved-ws" ]]; then
  echo "PASS: real state sweep deleted NOTHING (dead-cwd dir still on disk)"; pass=$((pass + 1))
else
  echo "FAIL: real state sweep deleted a state dir"; fail=$((fail + 1))
fi
if ! grep -qE "pruned state dir|would prune" <<<"$out"; then
  echo "PASS: no prune verb remains in the state output"; pass=$((pass + 1))
else
  echo "FAIL: state output still claims to prune (output: $out)"; fail=$((fail + 1))
fi

# Case 38b: a GENUINELY CLEAN --state sweep exits 0 — and the candidate it
# reports is still on disk afterwards. This is the other half of the exit code:
# without an exit-0 case, "always return 3" would pass every blocked-entry
# assertion in this file. The fixture holds exactly one dir, whose cwd is
# provably gone and whose every record parses terminal, so nothing is blocked or
# unresolved. This is a REAL sweep: no --dry-run anywhere near it.
REPORT="$TMP/state-report/state"
mkdir -p "$REPORT/dead-ws/jobs"
cat > "$REPORT/dead-ws/state.json" <<EOF
{"version":1,"jobs":[{"id":"task-gone-1","status":"completed","workspaceRoot":"$GONE_WS"}]}
EOF
cat > "$REPORT/dead-ws/jobs/task-gone-1.json" <<EOF
{"id":"task-gone-1","status":"completed","workspaceRoot":"$GONE_WS"}
EOF
out="$(CLAUDE_CONFIG_DIR="$TMP/await" CLAUDE_PLUGIN_DATA="$TMP/state-report" \
  bash "$CREW" reap --state 2>&1)" && rc=0 || rc=$?
check "clean state sweep exits 0" 0 "state candidate: dead-ws" "$rc" "$out"
check "clean state sweep summary" 0 "reap state summary: 1 reported (nothing deleted), 0 kept (cwd alive), 0 blocked (non-terminal, live pid or unreadable), 0 unresolved" "$rc" "$out"
check "clean state sweep prints the rm command" 0 "rm -rf $REPORT/dead-ws" "$rc" "$out"
if [[ -d "$REPORT/dead-ws" ]] && python3 -c "
import json
d = json.load(open('$REPORT/dead-ws/state.json'))
assert d['jobs'][0]['id'] == 'task-gone-1', d
"; then
  echo "PASS: reported candidate survived a real state sweep, registry intact"; pass=$((pass + 1))
else
  echo "FAIL: real state sweep destroyed the reported candidate"; fail=$((fail + 1))
fi
if [[ -f "$REPORT/dead-ws/jobs/task-gone-1.json" ]]; then
  echo "PASS: the candidate's job history survived too"; pass=$((pass + 1))
else
  echo "FAIL: the candidate's job history was deleted"; fail=$((fail + 1))
fi

# Case 38c: every blocking classification is NAMED and makes the sweep exit
# non-zero. Four kinds in one fixture — unparseable record, unrecognized
# registry schema, terminal record with a LIVE pid, unreadable jobs dir — each
# one an entry a human still has to decide about. Exit 0 here told automation
# the sweep was complete when it had skipped exactly those.
BLK="$TMP/state-blocked/state"
mkdir -p "$BLK/ws-unparseable/jobs" "$BLK/ws-schema" "$BLK/ws-livepid/jobs" "$BLK/ws-unreadable/jobs"
echo '{"jobs":[{"id":"u1","status":"completed","workspaceRoot":"/nonexistent-u"}]}' \
  > "$BLK/ws-unparseable/state.json"
printf '{"id":"u1", TRUNCATED' > "$BLK/ws-unparseable/jobs/u1.json"
echo '{"workspaceRoot":"/nonexistent-s","jobs":{"id":"s1","status":"running"}}' \
  > "$BLK/ws-schema/state.json"
echo '{"jobs":[{"id":"p1","status":"completed","workspaceRoot":"/nonexistent-p"}]}' \
  > "$BLK/ws-livepid/state.json"
cat > "$BLK/ws-livepid/jobs/p1.json" <<EOF
{"id":"p1","status":"completed","pid":$$,"workspaceRoot":"/nonexistent-p"}
EOF
echo '{"jobs":[{"id":"r1","status":"completed","workspaceRoot":"/nonexistent-r"}]}' \
  > "$BLK/ws-unreadable/state.json"
echo '{"id":"r1","status":"completed"}' > "$BLK/ws-unreadable/jobs/r1.json"
chmod 000 "$BLK/ws-unreadable/jobs" 2>/dev/null || true
out="$(CLAUDE_CONFIG_DIR="$TMP/await" CLAUDE_PLUGIN_DATA="$TMP/state-blocked" \
  bash "$CREW" reap --state 2>&1)" && rc=0 || rc=$?
# Restored immediately: a mode-000 dir left behind defeats this suite's cleanup.
chmod 755 "$BLK/ws-unreadable/jobs" 2>/dev/null || true
check "blocked state sweep exits non-zero" 3 "reap state summary" "$rc" "$out"
check "blocked sweep names the unparseable record" 3 "state blocked: ws-unparseable .*unparseable JSON" "$rc" "$out"
check "blocked sweep names the unrecognized schema" 3 "state blocked: ws-schema .*unrecognized schema" "$rc" "$out"
check "blocked sweep names the live-pid workspace" 3 "state blocked: ws-livepid .*pid $$ alive" "$rc" "$out"
if [[ "$(id -u)" == "0" ]]; then
  skip "blocked sweep names the unreadable jobs dir" "running as root, chmod 000 is not enforced"
else
  check "blocked sweep names the unreadable jobs dir" 3 "state blocked: ws-unreadable .*PermissionError" "$rc" "$out"
fi
if [[ -d "$BLK/ws-unparseable" && -d "$BLK/ws-schema" && -d "$BLK/ws-livepid" && -d "$BLK/ws-unreadable" ]]; then
  echo "PASS: blocked state sweep left every workspace on disk"; pass=$((pass + 1))
else
  echo "FAIL: blocked state sweep deleted a workspace"; fail=$((fail + 1))
fi

# Case 40: THE assertion the report-only design rests on — a REAL (non-dry)
# --brokers sweep against a process that is a textbook reap candidate (broker
# pattern, `serve` verb, --cwd that does not exist) leaves it ALIVE. The old
# code killed exactly this process. A candidate may be another session's broker,
# so the only correct action is to print the command and stop.
mkdir -p "$TMP/crewtest-broker2-$$"
echo 'setTimeout(() => {}, 60000);' > "$TMP/crewtest-broker2-$$/app-server-broker.mjs"
node "$TMP/crewtest-broker2-$$/app-server-broker.mjs" serve --endpoint "unix:$TMP/none.sock" --cwd "$GONE_WS" & SURVIVOR_PID=$!
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

# The changed-file list and the diff body are parameterised so the sensitivity
# cases below can hand the driver a Terraform change, a Bicep change or an RBAC
# manifest without a git repository. Defaults reproduce the original fixture
# exactly, so every case written before the gate existed is untouched.
cat > "$TMP/effort/install/scripts/lib/git.mjs" <<'EOF'
export function resolveReviewTarget(cwd, options = {}) {
  const base = options.base ?? "main";
  return { mode: "branch", label: `branch diff against ${base}`, baseRef: base, explicit: true };
}
export function collectReviewContext(cwd, target, options = {}) {
  const changedFiles = (process.env.CREW_TEST_CHANGED_FILES ?? "stub.txt")
    .split(",").map((f) => f.trim()).filter(Boolean);
  // Overridable independently of the list: a context reporting files it cannot
  // name is exactly the shape the gate has to fail CLOSED on.
  const fileCount = process.env.CREW_TEST_FILECOUNT
    ? Number(process.env.CREW_TEST_FILECOUNT)
    : changedFiles.length;
  // The collector THROWS. "gate" throws only for the caller that forces the
  // diff body, which is what an oversized diff really does (ENOBUFS out of
  // spawnSync's 1 MiB default), leaving the unforced summary collection to
  // succeed; "all" throws for everyone.
  const throwMode = process.env.CREW_TEST_COLLECT_THROW ?? "";
  if (throwMode === "all" || (throwMode === "gate" && options.includeDiff === true)) {
    const err = new Error("spawnSync git ENOBUFS");
    err.code = "ENOBUFS";
    throw err;
  }
  // The vendor's REAL default: above 2 files or 256 KB it withholds the diff
  // body and returns a summary (lib/git.mjs:332). A classifier handed this has
  // no diff to match content rules against.
  const selfCollect = process.env.CREW_TEST_SELF_COLLECT === "1" && options.includeDiff !== true;
  const context = {
    cwd, repoRoot: cwd, branch: "stub-branch", target, fileCount, diffBytes: 42,
    inputMode: selfCollect ? "self-collect" : "inline-diff",
    collectionGuidance: "STUB-GUIDANCE",
    content: selfCollect
      ? ["## Commit Log", "", "abc1234 change things", "", "## Diff Stat", "",
         " " + changedFiles.join(" | 2 +-\n ") + " | 2 +-", "", "## Changed Files", "",
         changedFiles.join("\n"), ""].join("\n")
      : process.env.CREW_TEST_DIFF_CONTENT ?? "STUB-DIFF",
    summary: "STUB-SUMMARY", changedFiles
  };
  if (process.env.CREW_TEST_DROP_CHANGED_FILES === "1") {
    delete context.changedFiles;
  }
  return context;
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

# Case 48: WITHOUT --effort an adversarial review still runs on the driver, at
# MEDIUM sent explicitly — never at the codex config's model_reasoning_effort.
# User decision 2026-09-10: "If NO effort is passed in then default to medium."
# The config here says xhigh, so inheriting it cannot pass for the default.
mkdir -p "$TMP/effort/codex-home-xhigh"
printf 'model_reasoning_effort = "xhigh"\n' > "$TMP/effort/codex-home-xhigh/config.toml"
: > "$INVOKED_E"; rm -f "$TMP/effort/turn.json" "$ARC_E/review-stub-default.dispatch.json"
out="$(CLAUDE_CONFIG_DIR="$TMP/effort" CREW_TEST_INVOKED="$INVOKED_E" \
  CREW_TEST_TURN_RECORD="$TMP/effort/turn.json" CREW_TEST_STATE_DIR="$STATE_E" \
  CREW_CODEX_ARCHIVE_DIR="$ARC_E" CODEX_HOME="$TMP/effort/codex-home-xhigh" \
  CREW_CODEX_RETRY_DELAYS="0" bash "$CREW" adversarial-review --base main "focus words" 2>&1)" && rc=0 || rc=$?
check "no --effort still runs the review, on the driver" 0 "RENDERED Adversarial Review" "$rc" "$out"
check_no_dispatch "no --effort never reached the vendor companion" "$INVOKED_E"
check "no --effort runs the turn at medium, not the config's xhigh" 0 "^medium\$" "$rc" \
  "$(python3 -c "import json; print(json.load(open('$TMP/effort/turn.json'))['effort'])" 2>/dev/null || echo MISSING)"
if python3 -c "
import json
d = json.load(open('$ARC_E/review-stub-default.dispatch.json'))
assert d['effortRequested'] is None, d
assert d['effortEffective'] == 'medium', d
assert d['effortConfig'] == 'xhigh', d
assert d['effortSource'] == 'default', d
j = json.load(open('$STATE_E/review-stub-default.json'))
assert j['effort'] == 'medium', j
assert j['effortRequested'] is None, j
assert j['effortEffective'] == 'medium', j
"; then
  echo "PASS: no --effort is stamped and recorded as the medium default"; pass=$((pass + 1))
else
  echo "FAIL: no --effort stamp/record wrong ($(cat "$ARC_E/review-stub-default.dispatch.json" 2>/dev/null))"; fail=$((fail + 1))
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
check "missing export tells the caller how to proceed" 3 "Update codex-crew" "$rc" "$out"
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

# Case 53: the `--` sentinel. Everything after it is focus text, so
# `-- --effort high` is a NO-effort dispatch — the driver's medium default —
# whose literal focus is "--effort high". Reading the token as an effort would
# both run the wrong effort and eat part of the caller's focus.
: > "$INVOKED_E"; rm -f "$TMP/effort/turn.json"
out="$(CLAUDE_CONFIG_DIR="$TMP/effort" CREW_TEST_INVOKED="$INVOKED_E" \
  CREW_TEST_TURN_RECORD="$TMP/effort/turn.json" CREW_TEST_STATE_DIR="$STATE_E" \
  CREW_CODEX_ARCHIVE_DIR="$ARC_E" CODEX_HOME="$TMP/effort/codex-home" \
  CREW_CODEX_RETRY_DELAYS="0" bash "$CREW" adversarial-review -- --effort high 2>&1)" && rc=0 || rc=$?
check "post-sentinel --effort still runs the review" 0 "RENDERED Adversarial Review" "$rc" "$out"
check_no_dispatch "post-sentinel --effort never reached the vendor companion" "$INVOKED_E"
if python3 -c "
import json
t = json.load(open('$TMP/effort/turn.json'))
assert t['effort'] == 'medium', t
assert 'FOCUS=--effort high' in t['prompt'], t['prompt']
"; then
  echo "PASS: post-sentinel --effort is focus text and the turn runs at medium"; pass=$((pass + 1))
else
  echo "FAIL: post-sentinel --effort was read as an effort ($(cat "$TMP/effort/turn.json" 2>/dev/null))"; fail=$((fail + 1))
fi

# Case 53b: the guard's focus-text rules hold on the driver path too — the
# half of Cases 24/26 that moved here when adversarial-review left the vendor.
out="$(run_effort adversarial-review improve the help wording)" && rc=0 || rc=$?
check "focus prose containing 'help' runs a review on the driver" 0 "RENDERED Adversarial Review" "$rc" "$out"
check "focus prose containing 'help' reaches the prompt intact" 0 "FOCUS=improve the help wording" "$rc" \
  "$(python3 -c "import json; print(json.load(open('$TMP/effort/turn.json'))['prompt'])" 2>/dev/null || echo MISSING)"
out="$(run_effort adversarial-review --effortless --helpful "focus")" && rc=0 || rc=$?
check "unrecognized --flags become focus text on the driver" 0 "FOCUS=--effortless --helpful focus" "$rc" \
  "$(python3 -c "import json; print(json.load(open('$TMP/effort/turn.json'))['prompt'])" 2>/dev/null || echo MISSING)"

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


# --- Case 58: the sensitivity classifier -------------------------------------
# User decision 2026-09-10: "the orchestrator should have ability to call effort
# required. If NO effort is passed in then default to medium." The classifier
# used to RAISE a sensitive diff to xhigh; it is now an informational label.
# These cases assert both halves on the same fixtures: every rule still FIRES
# (named on stderr), and the effort that reaches runAppServerTurn is exactly the
# one requested — no floor, no raise, no override.
run_gate() { # $1 = comma-separated changed files, $2 = diff content, rest = argv
  local files="$1" content="$2"; shift 2
  : > "$INVOKED_E"
  rm -f "$TMP/effort/turn.json"
  CLAUDE_CONFIG_DIR="$TMP/effort" CREW_TEST_INVOKED="$INVOKED_E" \
  CREW_TEST_TURN_RECORD="$TMP/effort/turn.json" CREW_TEST_STATE_DIR="$STATE_E" \
  CREW_CODEX_ARCHIVE_DIR="$ARC_E" CODEX_HOME="$TMP/effort/codex-home" \
  CREW_CODEX_RETRY_DELAYS="0" CREW_TEST_CHANGED_FILES="$files" \
  CREW_TEST_DIFF_CONTENT="$content" bash "$CREW" "$@" 2>&1
}

# The effort the TURN ran at, not the one the flag asked for. Every assertion
# below reads this rather than trusting the stderr line: a gate that announces
# an escalation it never applied is the failure mode worth catching.
gate_turn_effort() {
  python3 -c "import json; print(json.load(open('$TMP/effort/turn.json'))['effort'])" 2>/dev/null || echo MISSING
}

# 58a: a Terraform-only change is labelled and runs at exactly the requested medium.
out="$(run_gate "infra/edp/main.tf,infra/edp/prod.tfvars" "STUB-DIFF" \
  adversarial-review --effort medium --model gpt-5.6-sol "focus")" && rc=0 || rc=$?
check "terraform change keeps --effort medium" 0 "^medium\$" "$rc" "$(gate_turn_effort)"
check "terraform label is announced" 0 "sensitivity classifier: this diff matches sensitive rules" "$rc" "$out"
check_absent "terraform label raises nothing" "$out" "raising --effort"
check "terraform label names the triggering path" 0 "infra/edp/main.tf" "$rc" "$out"
check "terraform label names the rule" 0 "terraform:" "$rc" "$out"
check "terraform label still dispatches the review" 0 "RENDERED Adversarial Review" "$rc" "$out"
check "label says it is informational" 0 "Informational only" "$rc" "$out"
check_absent "label no longer advertises the retired override" "$out" "CREW_CODEX_SENSITIVITY_OVERRIDE"

# The audit trail has to agree with the turn: a sensitive diff is stamped as
# flag-sourced at exactly the requested effort, and the job record carries the
# classifier's label.
if python3 -c "
import json
d = json.load(open('$ARC_E/review-stub-default.dispatch.json'))
assert d['effortRequested'] == 'medium', d
assert d['effortEffective'] == 'medium', d
assert d['effortSource'] == 'flag', d
"; then
  echo "PASS: sidecar records the requested effort for a sensitive diff"; pass=$((pass + 1))
else
  echo "FAIL: sidecar wrong for a sensitive review ($(cat "$ARC_E/review-stub-default.dispatch.json" 2>/dev/null))"; fail=$((fail + 1))
fi
if python3 -c "
import json
j = json.load(open('$STATE_E/review-stub-default.json'))
assert j['effort'] == 'medium', j
assert j['effortRequested'] == 'medium', j
assert j['effortEffective'] == 'medium', j
assert j['sensitivityRules'] == ['terraform'], j
"; then
  echo "PASS: job record keeps the requested effort and the sensitivity label"; pass=$((pass + 1))
else
  echo "FAIL: job record lost the effort pair or the label ($(cat "$STATE_E/review-stub-default.json" 2>/dev/null))"; fail=$((fail + 1))
fi

# 58b: Bicep — the review that prompted this work called the old prose list too
# narrow, and Azure's IaC dialect was one of the things it did not mention.
out="$(run_gate "infra/deploy.bicep" "STUB-DIFF" \
  adversarial-review --effort low --model gpt-5.6-sol "focus")" && rc=0 || rc=$?
check "bicep change keeps --effort low" 0 "^low\$" "$rc" "$(gate_turn_effort)"
check "bicep escalation names the path" 0 "infra/deploy.bicep" "$rc" "$out"

# 58c: a Kubernetes RBAC manifest under a name that gives nothing away. Only the
# CONTENT says ClusterRoleBinding, so this is the case a filename-only
# classifier fails, and the stderr line must still name the file.
K8S_DIFF='### deploy/manifest.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ci-admin'
out="$(run_gate "deploy/manifest.yaml" "$K8S_DIFF" \
  adversarial-review --effort medium --model gpt-5.6-sol "focus")" && rc=0 || rc=$?
check "kubernetes RBAC manifest keeps --effort medium" 0 "^medium\$" "$rc" "$(gate_turn_effort)"
check "kubernetes RBAC hit is attributed to its file" 0 "kubernetes-rbac: deploy/manifest.yaml" "$rc" "$out"

# 58d: CI/CD — a workflow change runs with the fleet's credentials.
out="$(run_gate ".github/workflows/deploy.yml" "STUB-DIFF" \
  adversarial-review --effort medium --model gpt-5.6-sol "focus")" && rc=0 || rc=$?
check "workflow change keeps --effort medium" 0 "^medium\$" "$rc" "$(gate_turn_effort)"
check "workflow escalation names the path" 0 ".github/workflows/deploy.yml" "$rc" "$out"

# 58e: the negative case, and the one that keeps the control usable. A plain
# source/docs diff must run at EXACTLY the requested effort with no gate output
# at all — a gate that fires on everything is a gate that gets switched off.
out="$(run_gate "src/app.ts,docs/notes.md" "STUB-DIFF" \
  adversarial-review --effort medium --model gpt-5.6-sol "focus")" && rc=0 || rc=$?
check "plain source change keeps the requested effort" 0 "^medium\$" "$rc" "$(gate_turn_effort)"
check_absent "plain source change says nothing about the gate" "$out" "sensitivity gate"
check_absent "plain source change was not escalated" "$out" "xhigh"

# 58f: an explicit xhigh on a sensitive diff runs at xhigh — the orchestrator's
# choice — and is labelled, never described as changed.
out="$(run_gate "infra/edp/main.tf" "STUB-DIFF" \
  adversarial-review --effort xhigh --model gpt-5.6-sol "focus")" && rc=0 || rc=$?
check "explicit xhigh survives the gate" 0 "^xhigh\$" "$rc" "$(gate_turn_effort)"
check "explicit xhigh on a sensitive diff is still labelled" 0 "terraform: infra/edp/main.tf" "$rc" "$out"
check_absent "explicit xhigh is never described as raised" "$out" "raising --effort"

# 58g: FAIL CLOSED. A context that reports changed files it cannot name leaves
# the diff unclassified, and that has to be SAID — otherwise a vendor rename
# turns the labels off silently while the diff reads as clean.
export CREW_TEST_FILECOUNT=3
out="$(run_gate "" "STUB-DIFF" adversarial-review --effort low --model gpt-5.6-sol "focus")" && rc=0 || rc=$?
unset CREW_TEST_FILECOUNT
check "unclassifiable diff keeps --effort low" 0 "^low\$" "$rc" "$(gate_turn_effort)"
check "unclassifiable diff says why it escalated" 0 "unclassifiable-diff" "$rc" "$out"

# 58h: the retired override. CREW_CODEX_SENSITIVITY_OVERRIDE overrode a floor
# that no longer exists; a value left in a shell profile is reported as dead
# and changes nothing — the review runs at the requested effort either way.
export CREW_CODEX_SENSITIVITY_OVERRIDE="re-run of an already-reviewed diff"
out="$(run_gate "infra/edp/main.tf" "STUB-DIFF" \
  adversarial-review --effort low --model gpt-5.6-sol "focus")" && rc=0 || rc=$?
unset CREW_CODEX_SENSITIVITY_OVERRIDE
check "retired override keeps the requested effort" 0 "^low\$" "$rc" "$(gate_turn_effort)"
check "retired override is reported as ignored" 0 "no longer does anything" "$rc" "$out"
check_absent "retired override prints no override banner" "$out" "SENSITIVITY GATE OVERRIDDEN"

# 58i: THE BLIND-CLASSIFIER CASE. The vendor withholds the diff body above 2
# files or 256 KB (lib/git.mjs:332) and returns Commit Log + Diff Stat +
# Changed Files instead — i.e. on essentially every real PR. Collecting without
# `{ includeDiff: true }` therefore ran every content rule against a summary
# with no diff in it, and an RBAC manifest under an innocent filename sailed
# through at medium. The stub here reproduces that vendor behaviour exactly: it
# returns the summary UNLESS the caller forces the body. Revert the force and
# this case fails — the escalation reason stops being the RBAC rule.
export CREW_TEST_SELF_COLLECT=1
out="$(run_gate "deploy/manifest.yaml,src/a.ts,src/b.ts" "$K8S_DIFF" \
  adversarial-review --effort medium --model gpt-5.6-sol "focus")" && rc=0 || rc=$?
unset CREW_TEST_SELF_COLLECT
check "self-collect-sized diff still keeps --effort medium" 0 "^medium\$" "$rc" "$(gate_turn_effort)"
check "self-collect-sized diff is caught by the CONTENT rule" 0 "kubernetes-rbac: deploy/manifest.yaml" "$rc" "$out"
check_absent "the forced body means nothing was left unread" "$out" "unreadable-diff-body"

# 58j: the diff body cannot be read at all — the ENOBUFS a diff larger than
# spawnSync's 1 MiB buffer really produces. Path rules still run off the
# fallback collection (these paths match none of them), and the diff is
# labelled anyway: an unread body has not been shown to be insensitive.
export CREW_TEST_COLLECT_THROW=gate
out="$(run_gate "src/app.ts,docs/notes.md" "STUB-DIFF" \
  adversarial-review --effort medium --model gpt-5.6-sol "focus")" && rc=0 || rc=$?
unset CREW_TEST_COLLECT_THROW
check "unreadable diff body keeps --effort medium" 0 "^medium\$" "$rc" "$(gate_turn_effort)"
check "unreadable diff body says why" 0 "unreadable-diff-body" "$rc" "$out"
check "unreadable diff body still dispatches the review" 0 "RENDERED Adversarial Review" "$rc" "$out"

# 58k: the collector fails outright, both attempts. There is no changed-file
# list and no body, so the gate has nothing to acquit the diff with. The run
# itself then fails on the same collector — the assertion is on the gate's
# stderr, which is emitted before the dispatch.
export CREW_TEST_COLLECT_THROW=all
out="$(run_gate "infra/edp/main.tf" "STUB-DIFF" \
  adversarial-review --effort low --model gpt-5.6-sol "focus")" && rc=0 || rc=$?
unset CREW_TEST_COLLECT_THROW
# Not `check ... 0 ...`: the run's OWN collection fails on the same collector,
# so a zero exit here would mean the driver reviewed a diff it could not read.
if [[ "$rc" != "0" ]] && grep -q "sensitivity classifier: this diff matches" <<<"$out"; then
  echo "PASS: a failed collection is labelled before the run gives up"; pass=$((pass + 1))
else
  echo "FAIL: a failed collection was not labelled (exit=$rc; out: $out)"; fail=$((fail + 1))
fi
if grep -q "unclassifiable-diff" <<<"$out"; then
  echo "PASS: a failed collection says the diff is unclassifiable"; pass=$((pass + 1))
else
  echo "FAIL: a failed collection did not name the reason (out: $out)"; fail=$((fail + 1))
fi

# 58l: a context with NO changedFiles key at all — the shape an upstream rename
# produces, where every import still succeeds. `Array.isArray(undefined)` is
# false, so this must fail closed exactly like an empty list does.
export CREW_TEST_DROP_CHANGED_FILES=1
out="$(run_gate "src/app.ts" "STUB-DIFF" \
  adversarial-review --effort low --model gpt-5.6-sol "focus")" && rc=0 || rc=$?
unset CREW_TEST_DROP_CHANGED_FILES
check "a context without changedFiles is labelled" 0 "sensitivity classifier: this diff matches" "$rc" "$out"
check "a context without changedFiles says why" 0 "unclassifiable-diff" "$rc" "$out"

# 58m: NON-ASCII PATHS. core.quotePath is on by default, so `git diff
# --name-only` hands back the literal `"infra/prod\303\274.tf"` — quotes and
# octal escapes included. Every path rule is anchored, so the raw string matches
# nothing and a Terraform-only branch used to run unescalated. The string below
# is byte-for-byte what git emits for infra/prod<u-umlaut>.tf.
out="$(run_gate '"infra/prod\303\274.tf"' "STUB-DIFF" \
  adversarial-review --effort medium --model gpt-5.6-sol "focus")" && rc=0 || rc=$?
check "C-quoted terraform path keeps --effort medium" 0 "^medium\$" "$rc" "$(gate_turn_effort)"
check "C-quoted path is reported decoded, not escaped" 0 "terraform: infra/prod.*\.tf" "$rc" "$out"
check_absent "the escaped form is not what the operator is shown" "$out" '303\\274'

# 58n: `### ` is the collector's untracked-file heading AND an ordinary YAML
# comment. Attributing this segment to the "file" RBAC made it fail the k8s
# rule's .yaml/.json filter, so the ClusterRoleBinding below it went UNCHECKED —
# misattribution NARROWED the check. A heading that names no changed file is
# now attributed to nothing, which widens it back.
COMMENT_DIFF='### RBAC
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ci-admin'
out="$(run_gate "deploy/manifest.yaml" "$COMMENT_DIFF" \
  adversarial-review --effort medium --model gpt-5.6-sol "focus")" && rc=0 || rc=$?
check "a ### YAML comment does not hide an RBAC object" 0 "^medium\$" "$rc" "$(gate_turn_effort)"
check "the unattributable hit is labelled as such" 0 "unattributed diff content" "$rc" "$out"

# 58o: `--effort none` on a sensitive diff is NOT raised any more, so the
# strict-model warning about the effort actually sent must still fire.
out="$(run_gate "infra/edp/main.tf" "STUB-DIFF" \
  adversarial-review --effort none --model gpt-6-astra "focus")" && rc=0 || rc=$?
check "none on a sensitive diff runs at none" 0 "^none\$" "$rc" "$(gate_turn_effort)"
check "none on a sensitive diff still warns about the API" 0 "rejected by gpt-6-astra" "$rc" "$out"
out="$(run_gate "src/app.ts" "STUB-DIFF" \
  adversarial-review --effort none --model gpt-6-astra "focus")" && rc=0 || rc=$?
check "an unlabelled none still warns about the API" 0 "rejected by gpt-6-astra" "$rc" "$out"

# --- Case 58p: sensitive DIRECTORY segments, not just the final basename -----
# The secret rule matched secret-SHAPED basenames, so `secrets/prod/config.yaml`
# — a whole directory of them — was classified by its innocent leaf name and ran
# unescalated. A `secrets/`, `credentials/` or `creds/` segment ANYWHERE in the
# path is the thing that carries the hazard; the leaf name is incidental.
for p in secrets/prod/config.yaml credentials/prod/config.json ops/creds/aws.json; do
  out="$(run_gate "$p" "STUB-DIFF" \
    adversarial-review --effort medium --model gpt-5.6-sol "focus")" && rc=0 || rc=$?
  check "$p keeps --effort medium" 0 "^medium\$" "$rc" "$(gate_turn_effort)"
  check "$p is named as the trigger" 0 "secret-material: $p" "$rc" "$out"
done

# 58q: the full words. `auth-source` knew only the abbreviated stems, so a tree
# named `authentication/` — what real code is actually called — read as ordinary
# source. `identity` was not in the vocabulary at all.
for p in internal/authentication/provider.ts services/authorization/policy.go src/Identity/provider.ts; do
  out="$(run_gate "$p" "STUB-DIFF" \
    adversarial-review --effort medium --model gpt-5.6-sol "focus")" && rc=0 || rc=$?
  check "$p keeps --effort medium" 0 "^medium\$" "$rc" "$(gate_turn_effort)"
  check "$p is named as the trigger" 0 "auth-source: $p" "$rc" "$out"
done

# 58r: CamelCase source names. Segment anchoring alone requires the term to end
# at a `/`, `.`, `_` or `-`, so `AuthService.ts` — the ordinary way a TypeScript
# or C# auth entry point is named — ran at the lane default. The boundary that
# makes this safe is the UPPERCASE letter after the term; see 58s.
for p in src/AuthService.ts src/IdentityProvider.ts src/authService.ts lib/TokenStore/index.ts; do
  out="$(run_gate "$p" "STUB-DIFF" \
    adversarial-review --effort medium --model gpt-5.6-sol "focus")" && rc=0 || rc=$?
  check "$p keeps --effort medium" 0 "^medium\$" "$rc" "$(gate_turn_effort)"
  check "$p is named as the trigger" 0 "auth-source: $p" "$rc" "$out"
done

# 58s: THE ANTI-FALSE-POSITIVE PROPERTY, and the reason this widening is safe to
# ship. A control that fires on everything gets switched off, so each of these
# must still run at EXACTLY the requested effort with no gate output at all.
#
#   author.js / authoring/ — `auth` followed by a lowercase letter is a word,
#     not a term. Both the segment and the CamelCase anchoring require a
#     separator or a capital after the term.
#   authority.ts — same shape, and the new `authorization` term must not reach
#     it either: `authority` is not a prefix-with-separator of anything.
#   tokenizer.py — the guard the original rule was written around; unchanged.
#   docs/environment.md — the dotenv rule needs a LEADING dot (`.env`).
#   AUTHORS — the file at the root of half of GitHub, and the case that decides
#     how case-insensitive the CamelCase rule may be: a per-letter /i term plus
#     an uppercase boundary matches `AUTH` + `O`. Only the term's FIRST letter
#     is case-flexible, so this stays clean.
#   identityserver-docs/README.md — a judgment call, deliberately NOT matched.
#     It is documentation named after a product, and the existing segment
#     anchoring already excludes it; a real `IdentityServer/` implementation
#     directory still trips the CamelCase rule on its capital S.
for p in src/author.js authoring/guide.md src/authority.ts tokenizer.py docs/environment.md AUTHORS identityserver-docs/README.md; do
  out="$(run_gate "$p" "STUB-DIFF" \
    adversarial-review --effort medium --model gpt-5.6-sol "focus")" && rc=0 || rc=$?
  check "$p keeps the requested effort" 0 "^medium\$" "$rc" "$(gate_turn_effort)"
  check_absent "$p says nothing about the gate" "$out" "sensitivity gate"
done

# 58t: RENAMES. `git diff --name-only` — the vendor's only source for
# changedFiles (lib/git.mjs:266) — reports a rename as its DESTINATION alone, so
# renaming `infra/main.tf` to `archive/main.txt` handed the classifier one path
# matching no rule and a Terraform change went unclassified. Git's rename
# detection is on by default, so the pre-rename name is in the diff BODY, in the
# extended header the fixture below reproduces verbatim from real `git diff`
# output. BOTH sides must be classified.
RENAME_DIFF='diff --git a/infra/main.tf b/archive/main.txt
similarity index 100%
rename from infra/main.tf
rename to archive/main.txt'
out="$(run_gate "archive/main.txt" "$RENAME_DIFF" \
  adversarial-review --effort medium --model gpt-5.6-sol "focus")" && rc=0 || rc=$?
check "a renamed terraform file keeps --effort medium" 0 "^medium\$" "$rc" "$(gate_turn_effort)"
check "the pre-rename path is what is reported" 0 "terraform: infra/main.tf (pre-rename path)" "$rc" "$out"

# ...and the destination is not mislabelled as a pre-rename path. `rename to`
# names a file that IS in changedFiles, so it must be reported plainly or the
# operator is told a path that still exists no longer does.
RENAME_SENSITIVE_DEST='diff --git a/docs/notes.md b/secrets/notes.md
similarity index 100%
rename from docs/notes.md
rename to secrets/notes.md'
out="$(run_gate "secrets/notes.md" "$RENAME_SENSITIVE_DEST" \
  adversarial-review --effort medium --model gpt-5.6-sol "focus")" && rc=0 || rc=$?
check "a rename INTO a secrets tree keeps --effort medium" 0 "^medium\$" "$rc" "$(gate_turn_effort)"
check "the destination is reported plainly" 0 "secret-material: secrets/notes.md" "$rc" "$out"
check_absent "the destination is not called a pre-rename path" "$out" "secrets/notes.md (pre-rename path)"

# ...and a rename that touches nothing sensitive on EITHER side still says
# nothing. The old-path lookup must not become a second way to fire on
# everything.
BENIGN_RENAME='diff --git a/src/a.ts b/src/b.ts
similarity index 100%
rename from src/a.ts
rename to src/b.ts'
out="$(run_gate "src/b.ts" "$BENIGN_RENAME" \
  adversarial-review --effort medium --model gpt-5.6-sol "focus")" && rc=0 || rc=$?
check "a benign rename keeps the requested effort" 0 "^medium\$" "$rc" "$(gate_turn_effort)"
check_absent "a benign rename says nothing about the gate" "$out" "sensitivity gate"


# --- Case 58u: effort is the caller's, on every sensitive fixture ------------
# The user's decision, verbatim (2026-09-10): "the orchestrator should have
# ability to call effort required. If NO effort is passed in then default to
# medium." Over every sensitive fixture in this file — Terraform, IaC, CI, RBAC,
# secrets, auth, mixed, unreadable — at every explicit effort, the turn runs at
# EXACTLY the requested effort and the label still fires; with no --effort it
# runs at medium. A fixture is "files|content-var|env" (env: one CREW_TEST_*
# assignment, or empty). The collector-throws-for-everyone shape is absent: its
# run fails before a turn exists (58k asserts its label instead).
CRED_DIFF='### config/app.txt
-----BEGIN RSA PRIVATE KEY-----'
HELM_DIFF='### charts/app/values.yaml
+  dbPassword: hunter2'
CFN_DIFF='### deploy/stack.yaml
AWSTemplateFormatVersion: "2010-09-09"'
effort_fixtures=(
  "infra/edp/main.tf,infra/edp/prod.tfvars|STUB|"
  "infra/deploy.bicep|STUB|"
  "deploy/manifest.yaml|K8S_DIFF|"
  ".github/workflows/deploy.yml|STUB|"
  "|STUB|CREW_TEST_FILECOUNT=3"
  "deploy/manifest.yaml,src/a.ts,src/b.ts|K8S_DIFF|CREW_TEST_SELF_COLLECT=1"
  "src/app.ts,docs/notes.md|STUB|CREW_TEST_COLLECT_THROW=gate"
  "src/app.ts|STUB|CREW_TEST_DROP_CHANGED_FILES=1"
  '"infra/prod\303\274.tf"|STUB|'
  "deploy/manifest.yaml|COMMENT_DIFF|"
  "secrets/prod/config.yaml|STUB|"
  "ops/creds/aws.json|STUB|"
  "internal/authentication/provider.ts|STUB|"
  "src/AuthService.ts|STUB|"
  "src/auth/session.ts|STUB|"
  "archive/main.txt|RENAME_DIFF|"
  "secrets/notes.md|RENAME_SENSITIVE_DEST|"
  "config/app.txt|CRED_DIFF|"
  "charts/app/values.yaml|HELM_DIFF|"
  "deploy/stack.yaml|CFN_DIFF|"
  "infra/edp/main.tf,src/auth/session.ts|STUB|"
)
effort_bad=""
effort_runs=0
for fx in "${effort_fixtures[@]}"; do
  IFS='|' read -r fx_files fx_var fx_env <<<"$fx"
  if [[ "$fx_var" == "STUB" ]]; then fx_content="STUB-DIFF"; else fx_content="${!fx_var}"; fi
  for e in low medium high xhigh omitted; do
    if [[ -n "$fx_env" ]]; then export "${fx_env?}"; fi
    if [[ "$e" == "omitted" ]]; then
      want=medium
      out="$(run_gate "$fx_files" "$fx_content" \
        adversarial-review --model gpt-5.4-legacy "focus")" && rc=0 || rc=$?
    else
      want="$e"
      out="$(run_gate "$fx_files" "$fx_content" \
        adversarial-review --effort "$e" --model gpt-5.4-legacy "focus")" && rc=0 || rc=$?
    fi
    if [[ -n "$fx_env" ]]; then unset "${fx_env%%=*}"; fi
    got="$(gate_turn_effort)"
    effort_runs=$((effort_runs + 1))
    if [[ "$got" != "$want" ]]; then
      effort_bad+=" [$fx_files@$e ran at $got, want $want]"
    fi
    # Positive half: without it this loop passes on a classifier that stopped
    # firing altogether.
    if ! grep -q "sensitivity classifier: this diff matches sensitive rules" <<<"$out"; then
      effort_bad+=" [$fx_files@$e not labelled]"
    fi
    if grep -q -- "raising --effort" <<<"$out"; then
      effort_bad+=" [$fx_files@$e announced a raise]"
    fi
  done
done
if [[ -z "$effort_bad" && "$effort_runs" -eq $(( ${#effort_fixtures[@]} * 5 )) ]]; then
  echo "PASS: effort == request (medium when omitted) and labelled, across $effort_runs sensitive dispatches"; pass=$((pass + 1))
else
  echo "FAIL: a sensitive dispatch ran at an unrequested effort or went unlabelled:$effort_bad"; fail=$((fail + 1))
fi

# The omitted-effort label says the default applied; a plain diff with no
# --effort runs at medium and is not labelled at all.
out="$(run_gate "src/auth/session.ts" "STUB-DIFF" \
  adversarial-review --model gpt-5.6-sol "focus")" && rc=0 || rc=$?
check "omitted effort on an auth diff runs at medium" 0 "^medium\$" "$rc" "$(gate_turn_effort)"
check "omitted effort is named as the default in the label" 0 "the default; no --effort was given" "$rc" "$out"
out="$(run_gate "src/app.ts" "STUB-DIFF" \
  adversarial-review --model gpt-5.6-sol "focus")" && rc=0 || rc=$?
check "omitted effort on a plain diff runs at medium" 0 "^medium\$" "$rc" "$(gate_turn_effort)"
check_absent "a plain diff is not labelled" "$out" "sensitivity classifier"

# A mixed Terraform + auth diff at low stays low, and the job record and job log
# carry BOTH labels.
out="$(run_gate "infra/edp/main.tf,src/auth/session.ts" "STUB-DIFF" \
  adversarial-review --effort low --model gpt-5.6-sol "focus")" && rc=0 || rc=$?
check "mixed terraform+auth diff at low stays low" 0 "^low\$" "$rc" "$(gate_turn_effort)"
if python3 -c "
import json
j = json.load(open('$STATE_E/review-stub-default.json'))
assert sorted(j['sensitivityRules']) == ['auth-source', 'terraform'], j
assert j['effort'] == 'low', j
" && grep -q "Sensitivity labels (informational; the review runs at effort low as chosen): the diff matched terraform, auth-source" "$STATE_E/review-stub-default.log"; then
  echo "PASS: mixed diff's labels reach the job record and the job log"; pass=$((pass + 1))
else
  echo "FAIL: mixed diff's labels missing from the record/log ($(cat "$STATE_E/review-stub-default.log" 2>/dev/null))"; fail=$((fail + 1))
fi

# --- Case 59: the none/minimal guard covers the Astra lane ------------------
# gpt-6-astra rejects `none` and `minimal` at the API exactly as the 5.6 family
# does. Before this, the local guard was pinned to /^gpt-5\.6/i, so an Astra
# dispatch passed local validation and only failed minutes later at the API.
for e in none minimal; do
  out="$(run_effort adversarial-review --effort "$e" --model gpt-6-astra "focus")" && rc=0 || rc=$?
  check "$e on gpt-6-astra warns locally" 0 "rejected by gpt-6-astra" "$rc" "$out"
  check "$e on gpt-6-astra names the usable ladder" 0 "ladder on gpt-6-astra is low|medium|high|xhigh" "$rc" "$out"
  # Warn, never block: the wrapper mirrors the RUNTIME's contract, not one
  # family's, so the dispatch still goes out.
  check "$e on gpt-6-astra still dispatches" 0 "RENDERED Adversarial Review" "$rc" "$out"
done

# A usable effort on Astra must warn about nothing. The positive half matters:
# an absence check alone passes when the dispatch failed and printed nothing.
out="$(run_effort adversarial-review --effort medium --model gpt-6-astra "focus")" && rc=0 || rc=$?
if grep -q "RENDERED Adversarial Review" <<<"$out" && ! grep -q "rejected by" <<<"$out"; then
  echo "PASS: medium on gpt-6-astra dispatches and warns about nothing"; pass=$((pass + 1))
else
  echo "FAIL: medium on gpt-6-astra warned spuriously or did not dispatch (out: $out)"; fail=$((fail + 1))
fi

# Regression guard: widening the predicate must not have moved the 5.6 family's
# behaviour, including the wording the 5.6 cases above assert.
out="$(run_effort adversarial-review --effort minimal --model gpt-5.6-sol "focus")" && rc=0 || rc=$?
check "minimal on gpt-5.6-sol still names the 5.6 family" 0 "rejected by the GPT-5.6 family" "$rc" "$out"
check_absent "the 5.6 warning does not mention astra" "$out" "astra"
out="$(run_effort adversarial-review --effort high --model gpt-5.6-terra "focus")" && rc=0 || rc=$?
check_absent "high on gpt-5.6-terra warns about nothing" "$out" "rejected by"

# Case 54z: reap must MERGE into a fresh read of state.json, never write back
# the snapshot it classified from. This is the difference between "another
# session's job survives the sweep" and "it silently disappears from the
# registry that await and status are served from".
#
# The ordering here is deterministic, not a sleep race. The reaped job's
# logFile is a FIFO, and reap appends to it between rewriting jobs/*.json and
# mirroring into state.json. Opening a FIFO for write BLOCKS until a reader
# opens it — and the reader below opens it only AFTER injecting a new job into
# state.json. So the injection is guaranteed to land after reap took its
# snapshot and before reap mirrors. A snapshot writeback deletes job-injected;
# a merge keeps it.
MERGE_DATA="$TMP/merge-data"
mkdir -p "$MERGE_DATA/state/repo-m/jobs"
MERGE_FIFO="$MERGE_DATA/state/repo-m/jobs/dead.fifo"
mkfifo "$MERGE_FIFO"
# Frozen log age, not just a dead pid: reapability must not depend on whether
# this machine has recycled the throwaway pid, because if the job is NOT
# reaped then reap never writes to the FIFO and the reader below would block
# forever. Every wait in this case is bounded for the same reason.
touch_ago '2 hours ago' "$MERGE_FIFO"
DEAD_PID3=$(bash -c 'echo $$')
cat > "$MERGE_DATA/state/repo-m/jobs/dead.json" <<EOF
{"id":"job-m-dead","status":"running","pid":$DEAD_PID3,"logFile":"$MERGE_FIFO","createdAt":"2026-07-01T00:00:00Z"}
EOF
cat > "$MERGE_DATA/state/repo-m/state.json" <<EOF
[{"id":"job-m-dead","status":"running","pid":$DEAD_PID3}]
EOF
(
  # Wait for reap to rewrite jobs/dead.json. That write happens AFTER reap has
  # taken its state.json snapshot and BEFORE the log append, so seeing it
  # proves the snapshot is already in hand — injecting before this point just
  # puts the new job INTO the snapshot and tests nothing. No sleep race: reap
  # is blocked opening the FIFO below and cannot reach the mirror until this
  # subshell opens it for reading.
  # ⚠️ The deadline is not a formality. If it expires and this subshell injects
  # anyway, the injection may land BEFORE reap took its snapshot — in which
  # case a snapshot writeback preserves job-injected too and the case passes
  # while testing nothing. Record whether the transition was actually observed
  # and let the assertion below fail on a blind run.
  for _ in $(seq 1 600); do
    if grep -q 'reaped' "$MERGE_DATA/state/repo-m/jobs/dead.json" 2>/dev/null; then
      : > "$MERGE_DATA/observed"
      break
    fi
    sleep 0.05
  done
  if [[ ! -f "$MERGE_DATA/observed" ]]; then
    timeout 60 cat "$MERGE_FIFO" >/dev/null 2>&1 || true
    exit 0
  fi
  python3 - "$MERGE_DATA/state/repo-m/state.json" <<'INJECT' || true
import json, sys
p = sys.argv[1]
entries = json.load(open(p))
entries.append({"id": "job-injected", "status": "running", "pid": 1})
json.dump(entries, open(p, "w"), indent=2)
INJECT
  timeout 60 cat "$MERGE_FIFO" >/dev/null 2>&1 || true
) &
MERGE_READER=$!
out="$(timeout 90 env CLAUDE_CONFIG_DIR="$TMP/await" CLAUDE_PLUGIN_DATA="$MERGE_DATA" \
  bash "$CREW" reap 2>&1)" && rc=0 || rc=$?
wait "$MERGE_READER" 2>/dev/null || true
if [[ "$rc" == 124 ]]; then
  echo "FAIL: reap hung against a FIFO logFile"; fail=$((fail + 1))
elif [[ ! -f "$MERGE_DATA/observed" ]]; then
  # Not a pass and not a skip: the ordering this case depends on never
  # happened, so whatever the registry says now proves nothing either way.
  echo "FAIL: 54z never observed the reaped transition — the injection window was not established"; fail=$((fail + 1))
elif grep -q '"id": "job-injected"' "$MERGE_DATA/state/repo-m/state.json" \
   && grep -q '"status": "failed"' "$MERGE_DATA/state/repo-m/state.json"; then
  echo "PASS: reap merged into a fresh read and kept a concurrently added job"; pass=$((pass + 1))
else
  echo "FAIL: reap clobbered a concurrent registry write (exit=$rc; output: $out; state: $(cat "$MERGE_DATA/state/repo-m/state.json"))"; fail=$((fail + 1))
fi

# --- reap two-phase: validate before mutating, roll back on a late conflict ---
# The registry read is the ONLY place these cases can be raced deterministically
# from outside, so state.json is a FIFO: reap's successive opens block until the
# feeder hands over the next payload, which makes "what the sweep saw on read N"
# something the test dictates rather than something it hopes for. Read order in
# a workspace that gets reaped is exactly three: the baseline, the phase-(a)
# pre-check, and the mirror.
reap_fifo_fixture() {  # $1 = fixture root, $2 = workspace name, $3 = dead pid
  mkdir -p "$1/state/$2/jobs"
  printf 'log line\n' > "$1/state/$2/jobs/dead.log"
  touch_ago '2 hours ago' "$1/state/$2/jobs/dead.log"
  cat > "$1/state/$2/jobs/dead.json" <<EOF
{"id":"job-fifo","status":"running","pid":$3,"logFile":"$1/state/$2/jobs/dead.log","createdAt":"2026-07-01T00:00:00Z"}
EOF
  mkfifo "$1/state/$2/state.json"
}

DEAD_PID_F=$(bash -c 'echo $$')

# Case 56: PHASE (a). A conflict discovered before the first write must leave
# the workspace byte-identical. The old order wrote every jobs/*.json first and
# only then looked, so an abort left per-job records saying "failed" beside a
# registry the companion still served as running — a split brain it had no way
# to undo, and the reason this rewrite exists.
PRE_DATA="$TMP/reap-pre"
reap_fifo_fixture "$PRE_DATA" repo-p "$DEAD_PID_F"
cp "$PRE_DATA/state/repo-p/jobs/dead.json" "$TMP/reap-pre-before.json"
(
  # read 1 — the baseline the classification runs on
  timeout 30 bash -c "printf '%s' '[{\"id\":\"job-fifo\",\"status\":\"running\",\"pid\":$DEAD_PID_F}]' > '$PRE_DATA/state/repo-p/state.json'" || true
  # read 2 — phase (a). Another session resumed the job: pid moved, status did
  # NOT. A status-only comparison calls this "nothing happened".
  timeout 30 bash -c "printf '%s' '[{\"id\":\"job-fifo\",\"status\":\"running\",\"pid\":999999}]' > '$PRE_DATA/state/repo-p/state.json'" || true
) &
PRE_FEEDER=$!
out="$(timeout 90 env CLAUDE_CONFIG_DIR="$TMP/await" CLAUDE_PLUGIN_DATA="$PRE_DATA" \
  bash "$CREW" reap 2>&1)" && rc=0 || rc=$?
wait "$PRE_FEEDER" 2>/dev/null || true
if [[ "$rc" == 124 ]]; then
  echo "FAIL: reap hung against a FIFO state.json (phase-a case)"; fail=$((fail + 1))
elif [[ "$rc" == 3 ]] && grep -q "not touching this workspace" <<<"$out" \
   && ! grep -q "^reaped: " <<<"$out" \
   && cmp -s "$PRE_DATA/state/repo-p/jobs/dead.json" "$TMP/reap-pre-before.json"; then
  echo "PASS: reap aborts before any mutation when the registry moved under it"; pass=$((pass + 1))
else
  echo "FAIL: phase-(a) abort mutated the workspace (exit=$rc; output: $out; job: $(cat "$PRE_DATA/state/repo-p/jobs/dead.json"))"; fail=$((fail + 1))
fi

# Case 57: PHASE (b). The conflict appears only in the window the per-job
# rewrite itself opens — phase (a) saw nothing wrong. The identity test is the
# FULL tuple, so a resume that moves `pid` while `status` stays "running" is a
# conflict; status-only equality read that as quiet and marked another
# session's live job failed. The rollback is what makes aborting there safe.
POST_DATA="$TMP/reap-post"
reap_fifo_fixture "$POST_DATA" repo-q "$DEAD_PID_F"
cp "$POST_DATA/state/repo-q/jobs/dead.json" "$TMP/reap-post-before.json"
(
  for _payload in \
    "[{\"id\":\"job-fifo\",\"status\":\"running\",\"pid\":$DEAD_PID_F}]" \
    "[{\"id\":\"job-fifo\",\"status\":\"running\",\"pid\":$DEAD_PID_F}]" \
    "[{\"id\":\"job-fifo\",\"status\":\"running\",\"pid\":999999}]"; do
    timeout 30 bash -c "printf '%s' '$_payload' > '$POST_DATA/state/repo-q/state.json'" || true
  done
) &
POST_FEEDER=$!
out="$(timeout 90 env CLAUDE_CONFIG_DIR="$TMP/await" CLAUDE_PLUGIN_DATA="$POST_DATA" \
  bash "$CREW" reap 2>&1)" && rc=0 || rc=$?
wait "$POST_FEEDER" 2>/dev/null || true
if [[ "$rc" == 124 ]]; then
  echo "FAIL: reap hung against a FIFO state.json (phase-b case)"; fail=$((fail + 1))
elif [[ "$rc" == 3 ]] && grep -q "changed status while this sweep ran" <<<"$out" \
   && grep -q "^rolled back: " <<<"$out" \
   && cmp -s "$POST_DATA/state/repo-q/jobs/dead.json" "$TMP/reap-post-before.json"; then
  echo "PASS: a pid-only concurrent change is a conflict, and the jobs/*.json writes roll back"; pass=$((pass + 1))
else
  echo "FAIL: late conflict left a split brain (exit=$rc; output: $out; job: $(cat "$POST_DATA/state/repo-q/jobs/dead.json"))"; fail=$((fail + 1))
fi
if grep -q "0 reaped" <<<"$out"; then
  echo "PASS: a rolled-back reap is not counted as a reap"; pass=$((pass + 1))
else
  echo "FAIL: the summary still claims the rolled-back job was reaped: $out"; fail=$((fail + 1))
fi

# Case 58: rollback-ability is a PRECONDITION, not a best effort. When a record
# this sweep is about to mutate cannot be captured as a pre-image, the sweep used
# to overwrite it anyway and then silently skip it during the rollback while
# still claiming the workspace was restored — a false claim over exactly the
# split brain the two-phase design exists to prevent.
#
# ⚠️ The pre-image read is NOT the first read of the file — the classification
# loop already read it — so a statically unreadable fixture is caught by the
# earlier unreadable-record guard and never reaches this path. The gap only
# opens mid-sweep, so the FIFO state.json is used to hold the sweep still while
# the record is removed: reap blocks on the phase-(a) open, the feeder deletes
# jobs/dead.json, and only then hands over a non-conflicting payload.
GONE_DATA="$TMP/reap-gone"
reap_fifo_fixture "$GONE_DATA" repo-g "$DEAD_PID_F"
(
  timeout 30 bash -c "printf '%s' '[{\"id\":\"job-fifo\",\"status\":\"running\",\"pid\":$DEAD_PID_F}]' > '$GONE_DATA/state/repo-g/state.json'" || true
  # reap is now blocked opening state.json for phase (a). The record it has
  # classified but not yet captured goes away underneath it.
  rm -f "$GONE_DATA/state/repo-g/jobs/dead.json"
  timeout 30 bash -c "printf '%s' '[{\"id\":\"job-fifo\",\"status\":\"running\",\"pid\":$DEAD_PID_F}]' > '$GONE_DATA/state/repo-g/state.json'" || true
  # ⚠️ Swap the FIFO for a regular file once the rendezvous is spent. Without
  # this, a regression that performs a THIRD read blocks for the full timeout
  # and reports "reap hung" — which names the wrong defect and short-circuits
  # the assertions that would name the right one. With it, extra reads succeed
  # and the case fails on what it actually tests.
  rm -f "$GONE_DATA/state/repo-g/state.json"
  printf '%s' "[{\"id\":\"job-fifo\",\"status\":\"running\",\"pid\":$DEAD_PID_F}]" \
    > "$GONE_DATA/state/repo-g/state.json"
) &
GONE_FEEDER=$!
out="$(timeout 90 env CLAUDE_CONFIG_DIR="$TMP/await" CLAUDE_PLUGIN_DATA="$GONE_DATA" \
  bash "$CREW" reap 2>&1)" && rc=0 || rc=$?
wait "$GONE_FEEDER" 2>/dev/null || true
if [[ "$rc" == 124 ]]; then
  echo "FAIL: reap hung against a FIFO state.json (pre-image case)"; fail=$((fail + 1))
elif [[ "$rc" == 3 ]] && grep -q "changed between capture and write\|could not be read for rollback\|no captured pre-image" <<<"$out" \
   && ! grep -q "^reaped: " <<<"$out" \
   && [[ ! -e "$GONE_DATA/state/repo-g/jobs/dead.json" ]]; then
  echo "PASS: reap refuses to mutate a record it could not capture for rollback"; pass=$((pass + 1))
else
  echo "FAIL: mutated or recreated an unrollbackable record (exit=$rc; output: $out)"; fail=$((fail + 1))
fi

# Case 59: fv-6. The rollback fires precisely BECAUSE another session is active,
# so that session may have rewritten the same record in the meantime. Writing
# our pre-image back over it destroys their fresher write — the very harm the
# rollback was added to prevent. Same FIFO rendezvous as case 57, with the
# feeder also rewriting jobs/dead.json in the window our write opens.
CLOB_DATA="$TMP/reap-clobber"
reap_fifo_fixture "$CLOB_DATA" repo-c "$DEAD_PID_F"
(
  timeout 30 bash -c "printf '%s' '[{\"id\":\"job-fifo\",\"status\":\"running\",\"pid\":$DEAD_PID_F}]' > '$CLOB_DATA/state/repo-c/state.json'" || true
  timeout 30 bash -c "printf '%s' '[{\"id\":\"job-fifo\",\"status\":\"running\",\"pid\":$DEAD_PID_F}]' > '$CLOB_DATA/state/repo-c/state.json'" || true
  # reap has now passed phase (a) and is about to write jobs/dead.json. Wait for
  # that write, then stand in for the other session and rewrite it ourselves.
  for _ in $(seq 1 600); do
    if grep -q 'reaped' "$CLOB_DATA/state/repo-c/jobs/dead.json" 2>/dev/null; then
      : > "$CLOB_DATA/observed"
      break
    fi
    sleep 0.05
  done
  if [[ -f "$CLOB_DATA/observed" ]]; then
    printf '%s' '{"id":"job-fifo","status":"running","pid":424242,"note":"OTHER-SESSION-WROTE-THIS"}' \
      > "$CLOB_DATA/state/repo-c/jobs/dead.json"
  fi
  # ...and only now hand over the conflicting registry read that triggers the
  # rollback, so the ordering is a rendezvous rather than a race.
  timeout 30 bash -c "printf '%s' '[{\"id\":\"job-fifo\",\"status\":\"running\",\"pid\":999999}]' > '$CLOB_DATA/state/repo-c/state.json'" || true
) &
CLOB_FEEDER=$!
out="$(timeout 90 env CLAUDE_CONFIG_DIR="$TMP/await" CLAUDE_PLUGIN_DATA="$CLOB_DATA" \
  bash "$CREW" reap 2>&1)" && rc=0 || rc=$?
wait "$CLOB_FEEDER" 2>/dev/null || true
if [[ "$rc" == 124 ]]; then
  echo "FAIL: reap hung against a FIFO state.json (clobber case)"; fail=$((fail + 1))
elif [[ ! -f "$CLOB_DATA/observed" ]]; then
  echo "FAIL: case 59 never observed the reaped transition — the clobber window was not established"; fail=$((fail + 1))
elif grep -q "OTHER-SESSION-WROTE-THIS" "$CLOB_DATA/state/repo-c/jobs/dead.json" \
   && grep -q "NOT restored" <<<"$out"; then
  echo "PASS: the rollback leaves a record another session rewrote after us"; pass=$((pass + 1))
else
  echo "FAIL: rollback clobbered a concurrent writer (exit=$rc; output: $out; job: $(cat "$CLOB_DATA/state/repo-c/jobs/dead.json"))"; fail=$((fail + 1))
fi

# Case 60: a forward write that FAILS. The writes used to sit outside every try
# block, so a raising write exited the sweep with earlier records already marked
# failed — no mirror, no rollback, no summary.
#
# ⚠️ The failure is injected at the DIRECTORY, not the file. Records are now
# written through a same-directory temp and renamed over, and rename(2) does not
# need write permission on its target — so the old read-only-file fixture stops
# injecting anything, which is itself the point of that change: a write that
# fails can no longer truncate the record it failed on.
PART_DATA="$TMP/reap-partial"
mkdir -p "$PART_DATA/state/repo-w/jobs"
for n in a b; do
  printf 'log line\n' > "$PART_DATA/state/repo-w/jobs/$n.log"
  touch_ago '2 hours ago' "$PART_DATA/state/repo-w/jobs/$n.log"
  cat > "$PART_DATA/state/repo-w/jobs/$n.json" <<EOF
{"id":"job-$n","status":"running","pid":$DEAD_PID_F,"logFile":"$PART_DATA/state/repo-w/jobs/$n.log","createdAt":"2026-07-01T00:00:00Z"}
EOF
done
cat > "$PART_DATA/state/repo-w/state.json" <<EOF
[{"id":"job-a","status":"running","pid":$DEAD_PID_F},{"id":"job-b","status":"running","pid":$DEAD_PID_F}]
EOF
cp "$PART_DATA/state/repo-w/jobs/a.json" "$TMP/reap-part-a-before.json"
cp "$PART_DATA/state/repo-w/jobs/b.json" "$TMP/reap-part-b-before.json"
chmod 500 "$PART_DATA/state/repo-w/jobs"
if [[ -w "$PART_DATA/state/repo-w/jobs" ]]; then
  skip "reap rolls back when a forward write fails" "running as root defeats chmod 500"
else
  out="$(timeout 60 env CLAUDE_CONFIG_DIR="$TMP/await" CLAUDE_PLUGIN_DATA="$PART_DATA" \
    bash "$CREW" reap 2>&1)" && rc=0 || rc=$?
  chmod 700 "$PART_DATA/state/repo-w/jobs"
  if [[ "$rc" == 3 ]] && grep -q "write failed" <<<"$out" \
     && grep -q "reap summary: 0 reaped" <<<"$out" \
     && ! grep -q "^reaped: " <<<"$out" \
     && ! grep -q "NOT restored" <<<"$out" \
     && cmp -s "$PART_DATA/state/repo-w/jobs/a.json" "$TMP/reap-part-a-before.json" \
     && cmp -s "$PART_DATA/state/repo-w/jobs/b.json" "$TMP/reap-part-b-before.json"; then
    echo "PASS: a failed forward write rolls back, claims nothing, and reports no false inconsistency"; pass=$((pass + 1))
  else
    echo "FAIL: failed write left a split brain or a false claim (exit=$rc; output: $out)"; fail=$((fail + 1))
  fi
fi

# Case 61: two jobs/*.json carrying the SAME id. One registry entry cannot
# describe two records, so the per-file accounting and the id-keyed mirror
# disagree by construction. Corrupt input; touch nothing.
DUP_DATA="$TMP/reap-dup"
mkdir -p "$DUP_DATA/state/repo-d/jobs"
for n in one two; do
  printf 'log line\n' > "$DUP_DATA/state/repo-d/jobs/$n.log"
  touch_ago '2 hours ago' "$DUP_DATA/state/repo-d/jobs/$n.log"
  cat > "$DUP_DATA/state/repo-d/jobs/$n.json" <<EOF
{"id":"job-dup","status":"running","pid":$DEAD_PID_F,"logFile":"$DUP_DATA/state/repo-d/jobs/$n.log","createdAt":"2026-07-01T00:00:00Z"}
EOF
done
cat > "$DUP_DATA/state/repo-d/state.json" <<EOF
[{"id":"job-dup","status":"running","pid":$DEAD_PID_F}]
EOF
cp "$DUP_DATA/state/repo-d/jobs/one.json" "$TMP/reap-dup-before.json"
out="$(timeout 60 env CLAUDE_CONFIG_DIR="$TMP/await" CLAUDE_PLUGIN_DATA="$DUP_DATA" \
  bash "$CREW" reap 2>&1)" && rc=0 || rc=$?
if [[ "$rc" == 3 ]] && grep -q "more than one jobs/\*\?.json record\|more than one" <<<"$out" \
   && cmp -s "$DUP_DATA/state/repo-d/jobs/one.json" "$TMP/reap-dup-before.json"; then
  echo "PASS: duplicate job ids abort the workspace instead of miscounting it"; pass=$((pass + 1))
else
  echo "FAIL: duplicate ids were swept (exit=$rc; output: $out)"; fail=$((fail + 1))
fi

# Case 62: duplicate ids where only ONE record looks stuck. Counting duplicates
# across the reap SUBSET missed exactly the case that splits the brain: the
# stuck record and the single registry entry get marked failed while its twin
# is still running, and no duplicate was ever detected.
DUP2_DATA="$TMP/reap-dup-partial"
mkdir -p "$DUP2_DATA/state/repo-e/jobs"
printf 'log line\n' > "$DUP2_DATA/state/repo-e/jobs/stuck.log"
touch_ago '2 hours ago' "$DUP2_DATA/state/repo-e/jobs/stuck.log"
cat > "$DUP2_DATA/state/repo-e/jobs/stuck.json" <<EOF
{"id":"job-twin","status":"running","pid":$DEAD_PID_F,"logFile":"$DUP2_DATA/state/repo-e/jobs/stuck.log","createdAt":"2026-07-01T00:00:00Z"}
EOF
# The twin: same id, no stuck signal (fresh log, no dead pid).
printf 'log line\n' > "$DUP2_DATA/state/repo-e/jobs/live.log"
cat > "$DUP2_DATA/state/repo-e/jobs/live.json" <<EOF
{"id":"job-twin","status":"running","pid":null,"logFile":"$DUP2_DATA/state/repo-e/jobs/live.log","createdAt":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
EOF
cat > "$DUP2_DATA/state/repo-e/state.json" <<EOF
[{"id":"job-twin","status":"running","pid":$DEAD_PID_F}]
EOF
cp "$DUP2_DATA/state/repo-e/jobs/stuck.json" "$TMP/reap-dup2-before.json"
out="$(timeout 60 env CLAUDE_CONFIG_DIR="$TMP/await" CLAUDE_PLUGIN_DATA="$DUP2_DATA" \
  bash "$CREW" reap 2>&1)" && rc=0 || rc=$?
if [[ "$rc" == 3 ]] && grep -q "more than one" <<<"$out" \
   && ! grep -q "^reaped: " <<<"$out" \
   && cmp -s "$DUP2_DATA/state/repo-e/jobs/stuck.json" "$TMP/reap-dup2-before.json"; then
  echo "PASS: a duplicate id is caught even when only one of the twins looks stuck"; pass=$((pass + 1))
else
  echo "FAIL: partial-duplicate split brain (exit=$rc; output: $out)"; fail=$((fail + 1))
fi

# Case 63: a record that changes between the pre-image capture and the write.
# The rollback can only tell "ours" from "theirs" for a writer that lands AFTER
# our write; one that landed before it is invisible, and we would overwrite it
# and then "restore" a pre-image two writes stale. Detect and abort instead.
MOVED_DATA="$TMP/reap-moved"
reap_fifo_fixture "$MOVED_DATA" repo-v "$DEAD_PID_F"
(
  timeout 30 bash -c "printf '%s' '[{\"id\":\"job-fifo\",\"status\":\"running\",\"pid\":$DEAD_PID_F}]' > '$MOVED_DATA/state/repo-v/state.json'" || true
  # reap is blocked on the phase-(a) open, after classification and before the
  # pre-image capture. Another session updates the record right here.
  printf '%s' '{"id":"job-fifo","status":"running","pid":777777,"note":"MOVED-BEFORE-CAPTURE"}' \
    > "$MOVED_DATA/state/repo-v/jobs/dead.json"
  timeout 30 bash -c "printf '%s' '[{\"id\":\"job-fifo\",\"status\":\"running\",\"pid\":$DEAD_PID_F}]' > '$MOVED_DATA/state/repo-v/state.json'" || true
  rm -f "$MOVED_DATA/state/repo-v/state.json"
  printf '%s' "[{\"id\":\"job-fifo\",\"status\":\"running\",\"pid\":$DEAD_PID_F}]" \
    > "$MOVED_DATA/state/repo-v/state.json"
) &
MOVED_FEEDER=$!
out="$(timeout 90 env CLAUDE_CONFIG_DIR="$TMP/await" CLAUDE_PLUGIN_DATA="$MOVED_DATA" \
  bash "$CREW" reap 2>&1)" && rc=0 || rc=$?
wait "$MOVED_FEEDER" 2>/dev/null || true
if [[ "$rc" == 124 ]]; then
  echo "FAIL: reap hung against a FIFO state.json (moved-record case)"; fail=$((fail + 1))
elif [[ "$rc" == 3 ]] && grep -q "MOVED-BEFORE-CAPTURE" "$MOVED_DATA/state/repo-v/jobs/dead.json" \
   && grep -q "changed between capture and write" <<<"$out" \
   && ! grep -q "^reaped: " <<<"$out" \
   && grep -q "reap summary: 0 reaped" <<<"$out"; then
  echo "PASS: a record moved before capture is left alone and claims no reap"; pass=$((pass + 1))
else
  echo "FAIL: overwrote a record that moved before capture (exit=$rc; output: $out; job: $(cat "$MOVED_DATA/state/repo-v/jobs/dead.json"))"; fail=$((fail + 1))
fi

# Case 64: a reaped id with NO matching state.json entry. `state_conflicts` only
# inspects entries that exist, so an absent one produced no conflict, updated
# nothing, and still set the mirror flag — the sweep claimed a reap while the
# registry the companion actually serves had no failed entry for it. That is the
# split brain the two-record commit exists to prevent.
NOENT_DATA="$TMP/reap-no-entry"
mkdir -p "$NOENT_DATA/state/repo-n/jobs"
printf 'log line\n' > "$NOENT_DATA/state/repo-n/jobs/dead.log"
touch_ago '2 hours ago' "$NOENT_DATA/state/repo-n/jobs/dead.log"
cat > "$NOENT_DATA/state/repo-n/jobs/dead.json" <<EOF
{"id":"job-orphan","status":"running","pid":$DEAD_PID_F,"logFile":"$NOENT_DATA/state/repo-n/jobs/dead.log","createdAt":"2026-07-01T00:00:00Z"}
EOF
printf '%s' '[]' > "$NOENT_DATA/state/repo-n/state.json"
cp "$NOENT_DATA/state/repo-n/jobs/dead.json" "$TMP/reap-noent-before.json"
out="$(timeout 60 env CLAUDE_CONFIG_DIR="$TMP/await" CLAUDE_PLUGIN_DATA="$NOENT_DATA" \
  bash "$CREW" reap 2>&1)" && rc=0 || rc=$?
if [[ "$rc" == 3 ]] && ! grep -q "^reaped: " <<<"$out" \
   && grep -q "reap summary: 0 reaped" <<<"$out" \
   && cmp -s "$NOENT_DATA/state/repo-n/jobs/dead.json" "$TMP/reap-noent-before.json"; then
  echo "PASS: a reap with no registry entry to mirror into is rolled back, not claimed"; pass=$((pass + 1))
else
  echo "FAIL: claimed a reap the registry never recorded (exit=$rc; output: $out; job: $(cat "$NOENT_DATA/state/repo-n/jobs/dead.json"))"; fail=$((fail + 1))
fi

# Case 65: sanitize-archive must REPORT a staging file, never delete it. Age is
# not an ownership test — a suspended await can own a `.crew-w.*` for any length
# of time, and deleting it makes that await's atomic replace fail, which in the
# result-publication window replaces a good archived result with a withheld
# stub. Same rule `reap --brokers` arrived at: no ownership, no destruction.
stagearc2="$TMP/staging-report"
mkdir -p "$stagearc2"
printf 'half-written meta\n' > "$stagearc2/.crew-w.abc123"
touch_ago '3 hours ago' "$stagearc2/.crew-w.abc123"
echo '{"job":{"id":"task-keep","status":"completed"},"storedJob":{"id":"task-keep","status":"completed"}}' \
  > "$stagearc2/task-keep.meta.json"
out="$(bash "$CREW" sanitize-archive --dir "$stagearc2" 2>&1)" && rc=0 || rc=$?
if [[ -f "$stagearc2/.crew-w.abc123" ]] && grep -q "NOT removed" <<<"$out"; then
  echo "PASS: a stranded staging file is reported, not deleted on an mtime guess"; pass=$((pass + 1))
else
  echo "FAIL: staging file deleted or unreported (exit=$rc; output: $out)"; fail=$((fail + 1))
fi

# Case 66: the status printed in a `reaped:` line must be the one that made the
# job reapable, not the one this sweep just wrote. The claim is printed after
# the commit and the record is mutated in between, so it reported every real
# reap as "(failed, ...)" — a terminal status, which is by definition never
# stuck — while --dry-run reported the same record as "(running, ...)". Two
# modes disagreeing about one record is how a reader stops trusting either.
STATUS_DATA="$TMP/reap-status"
mkdir -p "$STATUS_DATA/state/repo-s/jobs"
printf 'log line\n' > "$STATUS_DATA/state/repo-s/jobs/dead.log"
touch_ago '2 hours ago' "$STATUS_DATA/state/repo-s/jobs/dead.log"
cat > "$STATUS_DATA/state/repo-s/jobs/dead.json" <<EOF
{"id":"job-status","status":"running","pid":$DEAD_PID_F,"logFile":"$STATUS_DATA/state/repo-s/jobs/dead.log","createdAt":"2026-07-01T00:00:00Z"}
EOF
cat > "$STATUS_DATA/state/repo-s/state.json" <<EOF
[{"id":"job-status","status":"running","pid":$DEAD_PID_F}]
EOF
dry_out="$(timeout 60 env CLAUDE_CONFIG_DIR="$TMP/await" CLAUDE_PLUGIN_DATA="$STATUS_DATA" \
  bash "$CREW" reap --dry-run 2>&1)" || true
real_out="$(timeout 60 env CLAUDE_CONFIG_DIR="$TMP/await" CLAUDE_PLUGIN_DATA="$STATUS_DATA" \
  bash "$CREW" reap 2>&1)" || true
if grep -q "would reap: repo-s/job-status (running," <<<"$dry_out" \
   && grep -q "reaped: repo-s/job-status (running," <<<"$real_out"; then
  echo "PASS: dry-run and real reap report the same pre-mutation status"; pass=$((pass + 1))
else
  echo "FAIL: reaped: line reports a post-mutation status (dry: $dry_out; real: $real_out)"; fail=$((fail + 1))
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
if [[ "$rc" == 3 ]] && grep -q "state blocked: ghost" <<<"$out" && grep -q "ghost-1" <<<"$out" \
   && [[ -f "$TMP/state-only/state/ghost/state.json" ]]; then
  echo "PASS: state.json-only live job blocks the prune"; pass=$((pass + 1))
else
  echo "FAIL: state-only live job did not block the prune (exit=$rc; output: $out)"; fail=$((fail + 1))
fi
# The same workspace is surfaced by the --brokers advisory survey, which now
# reports rather than gates. Exit 3, NOT 0: every reap invocation runs the
# default sweep first, and that sweep now refuses to classify this workspace
# (Case 55b) instead of walking past it. 3 is the honest answer — "the sweep
# ran and left something for a human" — and this assertion wanted 0 only
# because the default sweep used to skip the workspace silently.
out="$(CLAUDE_CONFIG_DIR="$TMP/await" CLAUDE_PLUGIN_DATA="$TMP/state-only" \
  CREW_CODEX_BROKER_PATTERN="$NOMATCH" \
  bash "$CREW" reap --brokers 2>&1)" && rc=0 || rc=$?
check "brokers survey surfaces a state.json-only live job" 3 "ghost/ghost-1(running)" "$rc" "$out"

# Case 55b: the DEFAULT sweep (no flags) has the same blind spot and it is the
# dangerous one — the default sweep MUTATES job records. It used to `continue`
# on a missing jobs/ dir, so it never opened state.json, never saw the running
# job, reported "0 skipped" and exited 0. A caller reading that exit code was
# told the workspace had been classified when the sweep had not looked at it.
# Now: no jobs/ dir is not a reason to skip reading the authoritative registry.
out="$(CLAUDE_CONFIG_DIR="$TMP/await" CLAUDE_PLUGIN_DATA="$TMP/state-only" \
  bash "$CREW" reap 2>&1)" && rc=0 || rc=$?
if [[ "$rc" == 3 ]] && grep -q "ghost/ghost-1(running)" <<<"$out" \
   && grep -q "not touching this workspace" <<<"$out" \
   && [[ -f "$TMP/state-only/state/ghost/state.json" ]]; then
  echo "PASS: default sweep reads state.json in a workspace with no jobs/ dir"; pass=$((pass + 1))
else
  echo "FAIL: default sweep walked past a state.json-only running job (exit=$rc; output: $out)"; fail=$((fail + 1))
fi

# Case 55c: fail closed on a status the sweep has never heard of. The test is
# NOT-TERMINAL, not `in ("running","queued")` — a vendor that adds "paused" or
# "resuming" must not silently become a status this sweep treats as done.
mkdir -p "$TMP/state-unknown/state/odd"
echo '{"jobs":[{"id":"odd-1","status":"resuming","workspaceRoot":"/nonexistent-odd"}]}' \
  > "$TMP/state-unknown/state/odd/state.json"
out="$(CLAUDE_CONFIG_DIR="$TMP/await" CLAUDE_PLUGIN_DATA="$TMP/state-unknown" \
  bash "$CREW" reap 2>&1)" && rc=0 || rc=$?
if [[ "$rc" == 3 ]] && grep -q "odd/odd-1(resuming)" <<<"$out"; then
  echo "PASS: default sweep fails closed on an unrecognized job status"; pass=$((pass + 1))
else
  echo "FAIL: unrecognized status was treated as terminal (exit=$rc; output: $out)"; fail=$((fail + 1))
fi

# Case 55d: the union must not fire on a workspace whose registry is entirely
# TERMINAL — otherwise every settled workspace on the machine reports as
# unreconciled and exit 3 stops meaning anything.
mkdir -p "$TMP/state-done/state/settled/jobs"
echo '{"jobs":[{"id":"done-1","status":"completed","workspaceRoot":"/nonexistent-done"}]}' \
  > "$TMP/state-done/state/settled/state.json"
out="$(CLAUDE_CONFIG_DIR="$TMP/await" CLAUDE_PLUGIN_DATA="$TMP/state-done" \
  bash "$CREW" reap 2>&1)" && rc=0 || rc=$?
# Match the per-entry skip LINE, not the word "unreconciled" — that also appears
# in the summary's legend, where it is present on every run and proves nothing.
if [[ "$rc" == 0 ]] && ! grep -q "^skipped: " <<<"$out" \
   && grep -q "0 skipped" <<<"$out"; then
  echo "PASS: a fully terminal registry is not reported as unreconciled"; pass=$((pass + 1))
else
  echo "FAIL: terminal registry wrongly blocked the sweep (exit=$rc; output: $out)"; fail=$((fail + 1))
fi

# Case 56: the --state prune must fail CLOSED on registries it cannot parse or
# read. os.path.isdir/isfile/exists return False for permission-denied too, so
# "unreadable" used to be indistinguishable from "absent" — and absent is the
# answer that lets an rmtree proceed. Every fixture here lives under $TMP; none
# of them touches the real, session-shared plugin data dir.
state_blocks() {
  # name, fixture root, grep pattern -> asserts blocked, exit 3, AND still on disk.
  # Exit 3 is load-bearing: a blocked entry is work a human still has to do, and
  # the old exit 0 told automation the sweep had finished it.
  local name="$1" root="$2" want="$3" ws="$4" o r
  o="$(CLAUDE_CONFIG_DIR="$TMP/await" CLAUDE_PLUGIN_DATA="$root" \
    bash "$CREW" reap --state 2>&1)" && r=0 || r=$?
  if [[ "$r" == 3 ]] && grep -q "state blocked" <<<"$o" && grep -q "$want" <<<"$o" && [[ -d "$ws" ]]; then
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

# Case 57c: OVER-COUNT. The changed-path cross-check does not save the parser
# when the colliding text names a REAL changed file: the collector inlines
# untracked files raw inside a fence, so a reviewed doc that quotes the
# collector's own output ("### notes.md" / "(skipped: ...)") produced a marker
# for a path that IS in changedFiles. With fileCount 1 that reached the refusal
# threshold and a perfectly reviewable diff was refused. Markers inside a fenced
# region are file CONTENT and must not count.
cp -r "$TMP/effort/install" "$TMP/effort/fence-install"
cat > "$TMP/effort/fence-install/scripts/lib/git.mjs" <<'EOF'
export function resolveReviewTarget(cwd, options = {}) {
  const base = options.base ?? "main";
  return { mode: "branch", label: `branch diff against ${base}`, baseRef: base, explicit: true };
}
export function collectReviewContext(cwd, target) {
  const content = [
    "## Untracked Files",
    "",
    "### notes.md",
    "```",
    "Documenting how the collector renders an unusable file:",
    "### notes.md",
    "(skipped: this line is FILE CONTENT, not a collector marker)",
    "```",
    ""
  ].join("\n");
  return {
    cwd, repoRoot: cwd, branch: "stub", target, fileCount: 1, diffBytes: 0,
    inputMode: "inline-diff", collectionGuidance: "STUB-GUIDANCE",
    content, summary: "s", changedFiles: ["notes.md"]
  };
}
EOF
mkdir -p "$TMP/fence/plugins"
echo "{\"version\":2,\"plugins\":{\"codex@openai-codex\":[{\"installPath\":\"$TMP/effort/fence-install\"}]}}" > "$TMP/fence/plugins/installed_plugins.json"
: > "$INVOKED_E"; rm -f "$TMP/effort/turn.json"
out="$(CLAUDE_CONFIG_DIR="$TMP/fence" CREW_TEST_INVOKED="$INVOKED_E" \
  CREW_TEST_TURN_RECORD="$TMP/effort/turn.json" CREW_TEST_STATE_DIR="$STATE_E" \
  CREW_TEST_JOB_SUFFIX="fence" CREW_CODEX_ARCHIVE_DIR="$ARC_E" \
  CODEX_HOME="$TMP/effort/codex-home" CREW_CODEX_RETRY_DELAYS="0" \
  bash "$CREW" adversarial-review --effort high "focus" 2>&1)" && rc=0 || rc=$?
check "fenced marker naming a real changed file does not refuse" 0 "RENDERED Adversarial Review" "$rc" "$out"
if [[ -f "$TMP/effort/turn.json" ]] && ! grep -q "every changed file" <<<"$out" \
   && ! grep -q "were NOT inlined by the collector" <<<"$out"; then
  echo "PASS: fenced marker counted zero skips and the turn ran"; pass=$((pass + 1))
else
  echo "FAIL: fenced marker still counted as a collector skip (exit=$rc; out: $out)"; fail=$((fail + 1))
fi

# Case 57d: UNDER-COUNT. The heading capture used to trim trailing whitespace
# before the changedFiles membership test, so a changed path that really ends in
# spaces never matched its own heading. The marker went uncounted, the
# all-skipped guard never fired, and the driver dispatched a BLIND review of
# content with nothing reviewable in it. The path is compared exactly.
cp -r "$TMP/effort/install" "$TMP/effort/wspace-install"
cat > "$TMP/effort/wspace-install/scripts/lib/git.mjs" <<'EOF'
export function resolveReviewTarget(cwd, options = {}) {
  const base = options.base ?? "main";
  return { mode: "branch", label: `branch diff against ${base}`, baseRef: base, explicit: true };
}
export function collectReviewContext(cwd, target) {
  const padded = "pad.txt  ";
  const content = ["### " + padded, "(skipped: binary file)", ""].join("\n");
  return {
    cwd, repoRoot: cwd, branch: "stub", target, fileCount: 1, diffBytes: 0,
    inputMode: "inline-diff", collectionGuidance: "STUB-GUIDANCE",
    content, summary: "s", changedFiles: [padded]
  };
}
EOF
mkdir -p "$TMP/wspace/plugins"
echo "{\"version\":2,\"plugins\":{\"codex@openai-codex\":[{\"installPath\":\"$TMP/effort/wspace-install\"}]}}" > "$TMP/wspace/plugins/installed_plugins.json"
: > "$INVOKED_E"; rm -f "$TMP/effort/turn.json"
out="$(CLAUDE_CONFIG_DIR="$TMP/wspace" CREW_TEST_INVOKED="$INVOKED_E" \
  CREW_TEST_TURN_RECORD="$TMP/effort/turn.json" CREW_TEST_STATE_DIR="$STATE_E" \
  CREW_TEST_JOB_SUFFIX="wspace" CREW_CODEX_ARCHIVE_DIR="$ARC_E" \
  CODEX_HOME="$TMP/effort/codex-home" CREW_CODEX_RETRY_DELAYS="0" \
  bash "$CREW" adversarial-review --effort high "focus" 2>&1)" && rc=0 || rc=$?
if [[ "$rc" != "0" ]] && grep -q "every changed file" <<<"$out"; then
  echo "PASS: trailing-whitespace path matched its heading and refused"; pass=$((pass + 1))
else
  echo "FAIL: trailing-whitespace path was not matched (exit=$rc; out: $out)"; fail=$((fail + 1))
fi
if [[ ! -f "$TMP/effort/turn.json" ]]; then
  echo "PASS: no blind review was dispatched for the all-skipped context"; pass=$((pass + 1))
else
  echo "FAIL: a blind review was dispatched (turn: $(cat "$TMP/effort/turn.json"))"; fail=$((fail + 1))
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
out="$(run_stamp "$arc" "Review started in the background as review-sec33-sec44." \
  review --prompt-file /internal/INC-999 --base main)" && rc=0 || rc=$?
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


# ============================================================================
# Ported from upstream sidkik/claude-plugins v0.4.3..v0.6.1 (commit 965b419).
# Fixtures are self-contained under $TMP; assertions are upstream's except
# where this fork deliberately diverges, and every such change is commented.
# ============================================================================
# --- redirect: interrupt a running job and resume its thread on new text ----
mkdir -p "$TMP/redir/plugins" "$TMP/redir/install/scripts" "$TMP/redir/data/state/lab-1/jobs"
echo "{\"version\":2,\"plugins\":{\"codex@openai-codex\":[{\"installPath\":\"$TMP/redir/install\"}]}}" > "$TMP/redir/plugins/installed_plugins.json"
# Fake companion: records argv, and answers `task` with a new job id.
cat > "$TMP/redir/install/scripts/codex-companion.mjs" <<'EOF'
import fs from "node:fs";
const argv = process.argv.slice(2);
fs.appendFileSync(process.env.CREW_TEST_ARGV_LOG,
  argv.join(" ") + " @endpoint=" + (process.env.CODEX_COMPANION_APP_SERVER_ENDPOINT || "none") + "\n");
if (argv[0] === "task") { console.log("Codex Resume started in the background as task-new1-aaa1."); }
else if (argv[0] === "cancel") { console.log("Cancelled " + argv[1] + "."); }
process.exit(0);
EOF

write_job() { # dir id status thread createdAt model effort write
  # A real job record always carries a pid. Fixtures without one hid a field
  # gluing bug for a whole release: crew_job_meta's last field was empty, bash
  # stripped the trailing tab, and the corruption only appeared against live
  # data. Keep every field populated the way production populates it.
  printf '{"id":"%s","status":"%s","threadId":"%s","createdAt":"%s","turnId":"turn-%s","pid":424242,"request":{"cwd":"%s","model":"%s","effort":"%s","write":%s}}\n' \
    "$2" "$3" "$4" "$5" "$2" "$PWD" "$6" "$7" "$8" > "$1/$2.json"
}
JOBS="$TMP/redir/data/state/lab-1/jobs"
write_broker_stub "$TMP/redir/install/scripts"
write_job "$JOBS" task-old1-bbb1 running thread-A 2026-01-01T00:00:00.000Z gpt-5.6-terra xhigh true

run_redirect() {
  CLAUDE_CONFIG_DIR="$TMP/redir" CLAUDE_PLUGIN_DATA="$TMP/redir/data" \
  CREW_TEST_ARGV_LOG="$1" bash "$CREW" redirect "${@:2}" 2>&1
}

# Case 23: redirect without a job id
out="$(CLAUDE_CONFIG_DIR="$TMP/redir" bash "$CREW" redirect 2>&1)" && rc=0 || rc=$?
check "redirect without job id" 2 "needs a job id" "$rc" "$out"

# Case 24: redirect without instruction text
out="$(CLAUDE_CONFIG_DIR="$TMP/redir" CLAUDE_PLUGIN_DATA="$TMP/redir/data" bash "$CREW" redirect task-old1-bbb1 2>&1)" && rc=0 || rc=$?
check "redirect without instruction" 2 "needs the new instruction text" "$rc" "$out"

# Case 25: happy path -> cancels, resumes the thread, reports old -> new
log="$TMP/redir/argv1"; : > "$log"
out="$(run_redirect "$log" task-old1-bbb1 "Change of plan: stop and write NOTES.md")" && rc=0 || rc=$?
check "redirect interrupts the running job" 0 "interrupted task-old1-bbb1" "$rc" "$out"
check "redirect reports the successor" 0 "REDIRECTED task-old1-bbb1 -> task-new1-aaa1" "$rc" "$out"
check "redirect cancelled first" 0 "^cancel task-old1-bbb1 " "$rc" "$(cat "$log")"
check "redirect resumed the same thread" 0 "task --background --resume-last" "$rc" "$(cat "$log")"
check "redirect carries the write posture" 0 "resume-last --write" "$rc" "$(cat "$log")"
check "redirect carries model and effort" 0 "\-\-model gpt-5.6-terra --effort xhigh" "$rc" "$(cat "$log")"
check "redirect passes the instruction" 0 "Change of plan: stop and write NOTES.md" "$rc" "$(cat "$log")"

# Case 26: explicit --model/--effort override the job's own pins
log="$TMP/redir/argv2"; : > "$log"
out="$(run_redirect "$log" task-old1-bbb1 --model gpt-5.6-sol --effort high "escalate this")" && rc=0 || rc=$?
check "redirect honours model override" 0 "\-\-model gpt-5.6-sol --effort high" "$rc" "$(cat "$log")"

# Case 27: refuse when the target is not the newest task job for this cwd
write_job "$JOBS" task-new2-ccc2 running thread-B 2026-06-01T00:00:00.000Z gpt-5.6-terra xhigh true
log="$TMP/redir/argv3"; : > "$log"
out="$(run_redirect "$log" task-old1-bbb1 "too late")" && rc=0 || rc=$?
check "redirect refuses a non-newest job" 2 "is not the newest task job for this cwd" "$rc" "$out"

# Case 28: unknown job id -> not found, with the cwd hint machinery intact
log="$TMP/redir/argv4"; : > "$log"
out="$(run_redirect "$log" task-zzz9-zzz9 "nothing to redirect")" && rc=0 || rc=$?
check "redirect on unknown job" 2 "not found in codex state" "$rc" "$out"

# --- await exit 4: a cancelled job whose thread was picked up by a successor -
mkdir -p "$TMP/sup/plugins" "$TMP/sup/install/scripts" "$TMP/sup/data/state/lab-1/jobs"
echo "{\"version\":2,\"plugins\":{\"codex@openai-codex\":[{\"installPath\":\"$TMP/sup/install\"}]}}" > "$TMP/sup/plugins/installed_plugins.json"
cat > "$TMP/sup/install/scripts/codex-companion.mjs" <<'EOF'
const [cmd, jobId] = process.argv.slice(2);
if (cmd === "result") { console.log("FINAL-RESULT"); process.exit(0); }
console.log(JSON.stringify({ job: { id: jobId, status: "cancelled", elapsed: "9s", logFile: "-", pid: null, progressPreview: ["stopped"] } }));
EOF
SJOBS="$TMP/sup/data/state/lab-1/jobs"
printf '{"id":"task-old2-ddd2","status":"cancelled","threadId":"thread-Z","createdAt":"2026-01-01T00:00:00.000Z"}\n' > "$SJOBS/task-old2-ddd2.json"
printf '{"id":"task-new3-eee3","status":"running","threadId":"thread-Z","createdAt":"2026-01-02T00:00:00.000Z"}\n' > "$SJOBS/task-new3-eee3.json"

# Case 29: cancelled + later job on the same thread -> SUPERSEDED, exit 4
out="$(CLAUDE_CONFIG_DIR="$TMP/sup" CLAUDE_PLUGIN_DATA="$TMP/sup/data" CREW_CODEX_ARCHIVE_DIR="$TMP/sup/arc" \
  CREW_CODEX_POLL_SECS=0 bash "$CREW" await task-old2-ddd2 --for 5 2>&1)" && rc=0 || rc=$?
check "cancelled job names its successor" 5 "SUPERSEDED task-old2-ddd2 -> task-new3-eee3" "$rc" "$out"
# ^ 5, not upstream's 4: exit 4 has meant HUNG in this fork since v0.4.2.

# Case 30: cancelled with NO successor -> ordinary DONE cancelled, exit 1
printf '{"id":"task-lone1-fff1","status":"cancelled","threadId":"thread-Y","createdAt":"2026-01-01T00:00:00.000Z"}\n' > "$SJOBS/task-lone1-fff1.json"
out="$(CLAUDE_CONFIG_DIR="$TMP/sup" CLAUDE_PLUGIN_DATA="$TMP/sup/data" CREW_CODEX_ARCHIVE_DIR="$TMP/sup/arc" \
  CREW_CODEX_POLL_SECS=0 bash "$CREW" await task-lone1-fff1 --for 5 2>&1)" && rc=0 || rc=$?
check "lone cancelled job stays a failure" 1 "DONE cancelled" "$rc" "$out"

# Case 31: the prompts tell agents how to handle a redirect
for f in "$AGENT_DIR"/*.md "$SKILL_FILE"; do
  check_contains "$(basename "$f") handles the SUPERSEDED exit" "$f" "SUPERSEDED"
done
check_contains "SKILL.md documents redirect" "$SKILL_FILE" "crew-codex redirect <job-id>"
check_contains "SKILL.md warns against cancel-and-restart" "$SKILL_FILE" "cancel\` plus a fresh dispatch is worse"

# --- patch: applying the codex-plugin fix to whatever version is installed ---
# The fixture is reconstructed FROM the shipped patch's own pre-image, so these
# cases exercise the real patch file and never touch the real codex install.
PATCH_FILE="$HERE/../patches/codex-plugin-queue-passthrough.patch"

build_fixture() { # $1 = destination plugin root
  python3 - "$PATCH_FILE" "$1" <<'PYEOF'
import sys, os
patch, out = sys.argv[1], sys.argv[2]
cur, files, order = None, {}, []
for line in open(patch):
    if line.startswith("--- a/"):
        cur = line[6:].strip()
        if cur not in files:
            files[cur] = []; order.append(cur)
    elif line.startswith("+++") or cur is None:
        continue
    elif line.startswith("@@"):
        files[cur].append("// ---- unrelated code between hunks ----")
    elif line.startswith(" ") or line.startswith("-"):
        files[cur].append(line[1:].rstrip("\n"))
for f in order:
    p = os.path.join(out, f)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, "w").write("\n".join(files[f]) + "\n")
PYEOF
}

mkdir -p "$TMP/patch/plugins" "$TMP/patch/install/scripts"
touch "$TMP/patch/install/scripts/codex-companion.mjs"
echo "{\"version\":2,\"plugins\":{\"codex@openai-codex\":[{\"installPath\":\"$TMP/patch/install\"}]}}" > "$TMP/patch/plugins/installed_plugins.json"
build_fixture "$TMP/patch/install"

crew_patch() { CLAUDE_CONFIG_DIR="$TMP/patch" bash "$CREW" patch "$@" 2>&1; }

# Case 32: an unpatched install reports appliable, exit 10
out="$(crew_patch --status)" && rc=0 || rc=$?
check "patch status on unpatched install" 10 "UNPATCHED" "$rc" "$out"

# Case 33: apply succeeds and verifies
out="$(crew_patch --apply)" && rc=0 || rc=$?
check "patch applies" 0 "PATCHED" "$rc" "$out"
check "patch flips experimentalApi" 0 "experimentalApi: true" "$rc" "$(cat "$TMP/patch/install/scripts/lib/app-server.mjs")"
check "patch forwards the queue method" 0 "thread/queue/add" "$rc" "$(cat "$TMP/patch/install/scripts/app-server-broker.mjs")"
check "patch keeps interrupt forwarded" 0 "turn/interrupt" "$rc" "$(cat "$TMP/patch/install/scripts/app-server-broker.mjs")"
check "patch leaves a backup" 0 "experimentalApi: false" "$rc" "$(cat "$TMP/patch/install/scripts/lib/app-server.mjs.crew-orig" 2>/dev/null)"

# Case 34: status now reports patched, and a second apply is a no-op
out="$(crew_patch --status)" && rc=0 || rc=$?
check "patch status on patched install" 0 "PATCHED" "$rc" "$out"
out="$(crew_patch --apply)" && rc=0 || rc=$?
check "patch apply is idempotent" 0 "already patched" "$rc" "$out"

# Case 35: revert restores the original, and a second revert is a no-op
out="$(crew_patch --revert)" && rc=0 || rc=$?
check "patch reverts" 0 "UNPATCHED" "$rc" "$out"
check "revert restores experimentalApi" 0 "experimentalApi: false" "$rc" "$(cat "$TMP/patch/install/scripts/lib/app-server.mjs")"
out="$(crew_patch --revert)" && rc=0 || rc=$?
check "patch revert is idempotent" 0 "nothing to revert" "$rc" "$out"

# Case 36: a DIFFERENT plugin version (line drift) still takes the patch
mkdir -p "$TMP/patchdrift/plugins" "$TMP/patchdrift/install/scripts"
touch "$TMP/patchdrift/install/scripts/codex-companion.mjs"
echo "{\"version\":2,\"plugins\":{\"codex@openai-codex\":[{\"installPath\":\"$TMP/patchdrift/install\"}]}}" > "$TMP/patchdrift/plugins/installed_plugins.json"
build_fixture "$TMP/patchdrift/install"
python3 - "$TMP/patchdrift/install" <<'PYEOF'
import sys, os
root = sys.argv[1]
for rel in ["scripts/lib/app-server.mjs", "scripts/app-server-broker.mjs"]:
    p = os.path.join(root, rel)
    lines = open(p).read().split("\n")
    lines = ["// a later release added this above" for _ in range(37)] + lines
    open(p, "w").write("\n".join(lines))
PYEOF
out="$(CLAUDE_CONFIG_DIR="$TMP/patchdrift" bash "$CREW" patch --apply 2>&1)" && rc=0 || rc=$?
check "patch survives version line drift" 0 "PATCHED" "$rc" "$out"
check "drifted install got the queue method" 0 "thread/queue/add" "$rc" "$(cat "$TMP/patchdrift/install/scripts/app-server-broker.mjs")"

# Case 37: a version that moved the code out from under the patch -> refuse
mkdir -p "$TMP/patchgone/plugins" "$TMP/patchgone/install/scripts/lib"
touch "$TMP/patchgone/install/scripts/codex-companion.mjs"
echo "{\"version\":2,\"plugins\":{\"codex@openai-codex\":[{\"installPath\":\"$TMP/patchgone/install\"}]}}" > "$TMP/patchgone/plugins/installed_plugins.json"
echo "// upstream rewrote this file entirely" > "$TMP/patchgone/install/scripts/lib/app-server.mjs"
echo "// upstream rewrote this file entirely" > "$TMP/patchgone/install/scripts/app-server-broker.mjs"
out="$(CLAUDE_CONFIG_DIR="$TMP/patchgone" bash "$CREW" patch --apply 2>&1)" && rc=0 || rc=$?
check "patch refuses to half-apply" 1 "refusing to half-apply" "$rc" "$out"
check "refused install is untouched" 1 "upstream rewrote this file entirely" "$rc" "$(cat "$TMP/patchgone/install/scripts/app-server-broker.mjs")"

# Case 37d: patched-state detection is right under EVERY patch(1) on this
# machine, not just whichever is first on PATH. Apple's patch auto-answers
# "Ignore -R? [y]" on an unpatched tree, so the old reverse-first probe read an
# UNPATCHED install as PATCHED and the SessionStart --apply silently did
# nothing. Each available implementation is pinned in turn via a PATH shim.
patch_impls=()
for cand in /usr/bin/patch "$(command -v gpatch 2>/dev/null || true)" "$(command -v patch 2>/dev/null || true)"; do
  [[ -n "$cand" && -x "$cand" ]] || continue
  real="$(cd "$(dirname "$cand")" && pwd -P)/$(basename "$cand")"
  dup=0; for seen in "${patch_impls[@]+"${patch_impls[@]}"}"; do [[ "$seen" == "$real" ]] && dup=1; done
  [[ $dup -eq 0 ]] && patch_impls+=("$real")
done
for impl in "${patch_impls[@]}"; do
  tag="$(basename "$impl")"; [[ "$impl" == /usr/bin/patch ]] && tag="usr-bin-patch"
  shim="$TMP/patchimpl-$tag/bin"; root="$TMP/patchimpl-$tag"
  mkdir -p "$shim" "$root/plugins" "$root/install/scripts"
  ln -sf "$impl" "$shim/patch"
  touch "$root/install/scripts/codex-companion.mjs"
  echo "{\"version\":2,\"plugins\":{\"codex@openai-codex\":[{\"installPath\":\"$root/install\"}]}}" > "$root/plugins/installed_plugins.json"
  build_fixture "$root/install"
  pp() { PATH="$shim:$PATH" CLAUDE_CONFIG_DIR="$root" bash "$CREW" patch "$@" 2>&1; }
  out="$(pp --status)" && rc=0 || rc=$?
  check "[$tag] unpatched install is not reported PATCHED" 10 "UNPATCHED" "$rc" "$out"
  out="$(pp --apply)" && rc=0 || rc=$?
  check "[$tag] SessionStart --apply really applies an unpatched install" 0 "PATCHED | codex plugin install | backups" "$rc" "$out"
  check "[$tag] applied tree carries the change" 0 "experimentalApi: true" "$rc" "$(cat "$root/install/scripts/lib/app-server.mjs")"
  out="$(pp --status)" && rc=0 || rc=$?
  check "[$tag] patched install reports PATCHED" 0 "PATCHED | codex plugin" "$rc" "$out"
  out="$(pp --revert)" && rc=0 || rc=$?
  check "[$tag] revert restores the original" 0 "experimentalApi: false" "$rc" "$(cat "$root/install/scripts/lib/app-server.mjs")"

  # Case 37c: a HALF-applied install (one target patched, one restored from
  # its backup) is stale. --revert must refuse with exit 1 and change nothing —
  # it used to print "nothing to revert" and exit 0 over the patched hunks.
  out="$(pp --apply)" && rc=0 || rc=$?
  check "[$tag] re-apply before the half-applied case" 0 "PATCHED" "$rc" "$out"
  cp "$root/install/scripts/lib/app-server.mjs.crew-orig" "$root/install/scripts/lib/app-server.mjs"
  sums_before="$(cksum "$root/install/scripts/lib/app-server.mjs" "$root/install/scripts/app-server-broker.mjs")"
  out="$(pp --revert)" && rc=0 || rc=$?
  check "[$tag] revert refuses a half-applied install" 1 "in state 'stale'.*nothing was changed.*crew-orig" "$rc" "$out"
  if ! grep -q "nothing to revert" <<<"$out"; then
    echo "PASS: [$tag] half-applied install is not reported clean"; pass=$((pass + 1))
  else
    echo "FAIL: [$tag] half-applied install reported as nothing to revert (output: $out)"; fail=$((fail + 1))
  fi
  sums_after="$(cksum "$root/install/scripts/lib/app-server.mjs" "$root/install/scripts/app-server-broker.mjs")"
  if [[ "$sums_before" == "$sums_after" ]]; then
    echo "PASS: [$tag] refused revert left both targets byte-identical"; pass=$((pass + 1))
  else
    echo "FAIL: [$tag] refused revert modified a target"; fail=$((fail + 1))
  fi
  out="$(pp --apply)" && rc=0 || rc=$?
  check "[$tag] apply still refuses a half-applied install" 1 "refusing to half-apply" "$rc" "$out"
done

# --- queue: say something to a running job without stopping it ---------------
# Stubs the codex plugin's app-server client, so the real lib/appserver-cli.mjs
# and the real queue/await paths run against a scripted server.
mkdir -p "$TMP/q/plugins" "$TMP/q/install/scripts/lib" "$TMP/q/data/state/lab-1/jobs" "$TMP/q/arc"
echo "{\"version\":2,\"plugins\":{\"codex@openai-codex\":[{\"installPath\":\"$TMP/q/install\"}]}}" > "$TMP/q/plugins/installed_plugins.json"
cat > "$TMP/q/install/scripts/codex-companion.mjs" <<'EOF'
const [cmd, jobId] = process.argv.slice(2);
if (cmd === "cancel" && process.env.CREW_TEST_CANCEL_FAIL) {
  console.error("cancel failed: " + process.env.CREW_TEST_CANCEL_FAIL);
  process.exit(1);
}
if (cmd === "result") { console.log("FIRST-TURN-RESULT"); process.exit(0); }
console.log(JSON.stringify({ job: { id: jobId, status: "completed", elapsed: "4s", logFile: "-", pid: null, progressPreview: ["done"] } }));
EOF
cat > "$TMP/q/install/scripts/lib/app-server.mjs" <<'EOF'
import fs from "node:fs";
export class CodexAppServerClient {
  static async connect() { return new CodexAppServerClient(); }
  async request(method, params) {
    fs.appendFileSync(process.env.CREW_TEST_RPC_LOG, method + " " + JSON.stringify(params) + "\n");
    if (process.env.CREW_TEST_DUMP_ENDPOINT) {
      fs.appendFileSync(process.env.CREW_TEST_RPC_LOG,
        "endpoint=" + (process.env.CODEX_COMPANION_APP_SERVER_ENDPOINT || "<none>") + "\n");
    }
    if (method === "thread/queue/add") {
      if (process.env.CREW_TEST_QUEUE_FAIL) throw new Error(process.env.CREW_TEST_QUEUE_FAIL);
      return { queuedSubmission: { id: "sub-1", clientUserMessageId: params.clientUserMessageId } };
    }
    if (method === "turn/steer") {
      if (process.env.CREW_TEST_STEER_FAIL) throw new Error(process.env.CREW_TEST_STEER_FAIL);
      return { turnId: params.expectedTurnId };
    }
    if (method === "thread/turns/list") {
      if (process.env.CREW_TEST_NO_TURN) return { data: [] };
      // Mirror a real turn: chatter lands first, the final answer only once the
      // turn actually finishes. CREW_TEST_CHATTER_POLLS controls how many reads
      // see chatter alone, which is the race that made an early capture return
      // a preamble instead of the answer.
      let n = 0;
      const counter = process.env.CREW_TEST_TURN_COUNTER;
      if (counter) {
        try { n = Number(fs.readFileSync(counter, "utf8")); } catch {}
        n += 1;
        fs.writeFileSync(counter, String(n));
      }
      const chatterOnly = n <= Number(process.env.CREW_TEST_CHATTER_POLLS ?? 0);
      const items = [
        { type: "userMessage", id: "i1", clientId: process.env.CREW_TEST_CLIENT_ID, content: [] },
        { type: "agentMessage", id: "i2", text: "preamble, about to start", phase: "chatter" }
      ];
      if (!chatterOnly) {
        items.push({ type: "agentMessage", id: "i3", text: "QUEUED-TURN-ANSWER", phase: "final_answer" });
      }
      return { data: [{ id: "turn-2", items }] };
    }
    return {};
  }
  async close() {}
}
EOF
write_broker_stub "$TMP/q/install/scripts"
QJOBS="$TMP/q/data/state/lab-1/jobs"
qjob() { # id status thread
  printf '{"id":"%s","status":"%s","threadId":"%s","createdAt":"2026-02-01T00:00:00.000Z","pid":424242,"request":{"cwd":"%s","model":"gpt-5.6-terra","effort":"xhigh","write":true}}\n' \
    "$1" "$2" "$3" "$PWD" > "$QJOBS/$1.json"
}
qjob task-run1-aaa1 running thread-Q

crew_queue() {
  CLAUDE_CONFIG_DIR="$TMP/q" CLAUDE_PLUGIN_DATA="$TMP/q/data" CREW_CODEX_ARCHIVE_DIR="$TMP/q/arc" \
  CREW_TEST_RPC_LOG="${CREW_TEST_RPC_LOG:-$TMP/q/rpc.log}" bash "$CREW" queue "$@" 2>&1
}

# Case 38: usage errors
out="$(CLAUDE_CONFIG_DIR="$TMP/q" bash "$CREW" queue 2>&1)" && rc=0 || rc=$?
check "queue without job id" 2 "needs a job id" "$rc" "$out"
out="$(crew_queue task-run1-aaa1)" && rc=0 || rc=$?
check "queue without message" 2 "needs the message text" "$rc" "$out"

# Case 39: happy path -> queues, records the marker, never cancels
: > "$TMP/q/rpc.log"
out="$(CREW_TEST_RPC_LOG="$TMP/q/rpc.log" crew_queue task-run1-aaa1 "finish then write NOTES.md")" && rc=0 || rc=$?
check "queue reports success" 0 "QUEUED task-run1-aaa1" "$rc" "$out"
check "queue names the client id" 0 "crew-task-run1-aaa1-1" "$rc" "$out"
check "queue used thread/queue/add" 0 "^thread/queue/add" "$rc" "$(cat "$TMP/q/rpc.log")"
check "queue sent the message text" 0 "finish then write NOTES.md" "$rc" "$(cat "$TMP/q/rpc.log")"
check_absent "queue never interrupts the turn" "$(cat "$TMP/q/rpc.log")" "turn/interrupt"
check_absent "queue never cancels the job" "$(cat "$TMP/q/rpc.log")" "cancel"
check "queue records the marker" 0 "crew-task-run1-aaa1-1" "$rc" "$(cat "$TMP/q/arc/task-run1-aaa1.queued.txt")"

# Case 40: a second queued message increments the client id
out="$(CREW_TEST_RPC_LOG="$TMP/q/rpc.log" crew_queue task-run1-aaa1 "and update the README")" && rc=0 || rc=$?
check "second queue increments the id" 0 "crew-task-run1-aaa1-2" "$rc" "$out"

# Case 41: refuse to queue onto a job that will never read it
qjob task-done1-bbb1 completed thread-R
out="$(crew_queue task-done1-bbb1 "too late")" && rc=0 || rc=$?
check "queue refuses a finished job" 2 "would never be read" "$rc" "$out"

# Case 42: unknown job id
out="$(crew_queue task-zzz9-zzz9 "nobody home")" && rc=0 || rc=$?
check "queue on unknown job" 2 "not found in codex state" "$rc" "$out"

# Case 43: an unpatched plugin refusing the method points at the patch
out="$(CREW_TEST_QUEUE_FAIL="Shared Codex broker is busy." CREW_TEST_RPC_LOG="$TMP/q/rpc.log" \
  crew_queue task-run1-aaa1 "will be refused")" && rc=0 || rc=$?
check "queue failure explains the patch" 1 "crew-codex patch --apply" "$rc" "$out"

# Case 44: await captures the queued turn's FINAL answer into the archive
: > "$TMP/q/arc/task-run1-aaa1.queued.txt"
printf 'crew-task-run1-aaa1-1\tfinish then write NOTES.md\n' > "$TMP/q/arc/task-run1-aaa1.queued.txt"
out="$(CLAUDE_CONFIG_DIR="$TMP/q" CLAUDE_PLUGIN_DATA="$TMP/q/data" CREW_CODEX_ARCHIVE_DIR="$TMP/q/arc" \
  CREW_CODEX_POLL_SECS=0 CREW_TEST_RPC_LOG="$TMP/q/rpc.log" CREW_TEST_CLIENT_ID="crew-task-run1-aaa1-1" \
  CREW_TEST_TURN_COUNTER="$TMP/q/turnc" CREW_TEST_CHATTER_POLLS=2 \
  bash "$CREW" await task-run1-aaa1 --for 5 2>&1)" && rc=0 || rc=$?
check "await reports captured replies" 0 "QUEUED-REPLIES 1/1 captured" "$rc" "$out"
check "await appends the follow-up" 0 "QUEUED-TURN-ANSWER" "$rc" "$(cat "$TMP/q/arc/task-run1-aaa1.result.txt")"
check "await keeps the first turn's result" 0 "FIRST-TURN-RESULT" "$rc" "$(cat "$TMP/q/arc/task-run1-aaa1.result.txt")"
check_absent "await captures the answer, not the preamble" \
  "$(cat "$TMP/q/arc/task-run1-aaa1.result.txt")" "preamble, about to start"

# Case 45: a queued turn that never runs is reported, not silently dropped
printf 'crew-task-run2-ccc2\tnever read\n' > "$TMP/q/arc/task-run2-ccc2.queued.txt"
qjob task-run2-ccc2 running thread-S
out="$(CLAUDE_CONFIG_DIR="$TMP/q" CLAUDE_PLUGIN_DATA="$TMP/q/data" CREW_CODEX_ARCHIVE_DIR="$TMP/q/arc" \
  CREW_CODEX_POLL_SECS=0 CREW_CODEX_QUEUE_GRACE_SECS=0 CREW_TEST_RPC_LOG="$TMP/q/rpc.log" \
  CREW_TEST_NO_TURN=1 bash "$CREW" await task-run2-ccc2 --for 5 2>&1)" && rc=0 || rc=$?
check "unread queued message is reported" 0 "QUEUED-REPLIES 0/1" "$rc" "$out"

# --- steer: interject into the turn that is running right now ----------------
qjob task-steer1-ddd1 running thread-T
python3 - "$QJOBS/task-steer1-ddd1.json" <<'PYEOF'
import json, sys
p = sys.argv[1]
j = json.load(open(p))
j["turnId"] = "turn-live-1"
json.dump(j, open(p, "w"))
PYEOF

crew_steer() {
  CLAUDE_CONFIG_DIR="$TMP/q" CLAUDE_PLUGIN_DATA="$TMP/q/data" CREW_CODEX_ARCHIVE_DIR="$TMP/q/arc" \
  CREW_TEST_RPC_LOG="$TMP/q/rpc.log" bash "$CREW" steer "$@" 2>&1
}

# Case 46: usage errors
out="$(CLAUDE_CONFIG_DIR="$TMP/q" bash "$CREW" steer 2>&1)" && rc=0 || rc=$?
check "steer without job id" 2 "needs a job id" "$rc" "$out"
out="$(crew_steer task-steer1-ddd1)" && rc=0 || rc=$?
check "steer without message" 2 "needs the message text" "$rc" "$out"

# Case 47: happy path -> turn/steer with the live turn id, nothing destroyed
: > "$TMP/q/rpc.log"
out="$(crew_steer task-steer1-ddd1 "stop adding files and fix the test")" && rc=0 || rc=$?
check "steer reports success" 0 "STEERED task-steer1-ddd1" "$rc" "$out"
check "steer used turn/steer" 0 "^turn/steer" "$rc" "$(cat "$TMP/q/rpc.log")"
check "steer sends expectedTurnId" 0 '"expectedTurnId":"turn-live-1"' "$rc" "$(cat "$TMP/q/rpc.log")"
# The turn id must go out CLEAN. A short `read` glues later meta fields onto it,
# which the server rejects as an expected-turn mismatch.
check_absent "steered turn id carries no glued-on field" \
  "$(grep '^turn/steer' "$TMP/q/rpc.log")" '"expectedTurnId":"turn-live-1\t'
check "steer sends the message" 0 "stop adding files and fix the test" "$rc" "$(cat "$TMP/q/rpc.log")"
check_absent "steer never interrupts" "$(cat "$TMP/q/rpc.log")" "turn/interrupt"
check_absent "steer never queues instead" "$(cat "$TMP/q/rpc.log")" "thread/queue/add"
check_absent "steer leaves no follow-up marker to collect" \
  "$(ls "$TMP/q/arc")" "task-steer1-ddd1.queued.txt"

# Case 48: a job with no live turn cannot be steered, and says what to use
qjob task-steer2-eee2 completed thread-U
out="$(crew_steer task-steer2-eee2 "too late")" && rc=0 || rc=$?
check "steer refuses a finished job" 2 "no live turn to steer" "$rc" "$out"
check "steer points at queue instead" 2 "crew-codex queue" "$rc" "$out"

# Case 49: turn ended between read and send -> explain, do not fall back blindly
out="$(CREW_TEST_STEER_FAIL="no active turn to steer" crew_steer task-steer1-ddd1 "just missed it")" && rc=0 || rc=$?
check "steer explains a turn that moved on" 1 "use crew-codex queue" "$rc" "$out"

# Case 50: an unpatched plugin refusing to steer points at the patch
out="$(CREW_TEST_STEER_FAIL="Shared Codex broker is busy." crew_steer task-steer1-ddd1 "refused")" && rc=0 || rc=$?
check "steer failure explains the patch" 1 "crew-codex patch --apply" "$rc" "$out"

# Case 51: the patch must forward steer, not just queue
check_contains "patch forwards turn/steer" "$PATCH_FILE" "turn/steer"
check_contains "patch still forwards interrupt" "$PATCH_FILE" "turn/interrupt"

# --- per-job brokers and reaping --------------------------------------------
# A broker holds a codex app-server, so a leaked one is expensive. Stand-in
# "brokers" are real sleep processes, which is all crew_kill_broker needs.
fake_broker() { # $1 = job id -> writes sidecar, echoes the pid
  local job="$1" dir pid
  dir="$(mktemp -d "$TMP/q/fakebroker-XXXXXX")"
  sleep 300 >/dev/null 2>&1 & pid=$!
  disown "$pid" 2>/dev/null || true
  # fake_broker is called through command substitution, so a variable set here
  # dies with the subshell. The pid file is the only channel back to cleanup.
  echo "$pid" >> "$TMP/stub_pids"
  : > "$dir/broker.sock"; echo "$pid" > "$dir/broker.pid"; : > "$dir/broker.log"
  printf 'unix:%s/broker.sock\t%s\t%s\t%s\n' "$dir" "$pid" "$dir" "$PWD" \
    > "$TMP/q/arc/$job.broker"
  echo "$pid"
}
crew_reap() {
  CLAUDE_CONFIG_DIR="$TMP/q" CLAUDE_PLUGIN_DATA="$TMP/q/data" CREW_CODEX_ARCHIVE_DIR="$TMP/q/arc" \
    bash "$CREW" reap 2>&1
}

# Case 52: a terminal job's broker is reaped and its sidecar removed
qjob task-reap1-aaa1 completed thread-R1
bp1="$(fake_broker task-reap1-aaa1)"
out="$(crew_reap)" && rc=0 || rc=$?
# Upstream asserts its "REAPED | n job broker(s)" line here. This fork does not
# print one: `reap`'s default output is a fixed contract (Case 39 asserts it
# gains NO broker/socket/state lines without the opt-in flags), and the
# crew-owned broker retirement is silent housekeeping — the count is reported
# under --brokers instead. The retirement itself is asserted by the two cases
# below, which are the behaviour that actually matters.
check "reap runs" 0 "reap summary: " "$rc" "$out"
if kill -0 "$bp1" 2>/dev/null; then
  echo "FAIL: terminal job's broker survived reap"; fail=$((fail + 1)); kill -9 "$bp1" 2>/dev/null || true
else
  echo "PASS: terminal job's broker is reaped"; pass=$((pass + 1))
fi
check_absent "reaped broker leaves no sidecar" "$(ls "$TMP/q/arc")" "task-reap1-aaa1.broker"

# Case 53: a RUNNING job with a live worker keeps its broker
sleep 300 >/dev/null 2>&1 & live_worker=$!
disown "$live_worker" 2>/dev/null || true
python3 - "$QJOBS/task-reap2-bbb2.json" "$live_worker" <<'PYEOF'
import json, sys
json.dump({"id": "task-reap2-bbb2", "status": "running", "threadId": "thread-R2",
           "createdAt": "2026-02-02T00:00:00.000Z", "pid": int(sys.argv[2]),
           "request": {"cwd": "/nowhere"}}, open(sys.argv[1], "w"))
PYEOF
bp2="$(fake_broker task-reap2-bbb2)"
crew_reap >/dev/null 2>&1 || true
if kill -0 "$bp2" 2>/dev/null; then
  echo "PASS: live job keeps its broker"; pass=$((pass + 1))
else
  echo "FAIL: reap killed a live job's broker"; fail=$((fail + 1))
fi

# Case 54: status says running but the worker is DEAD -> reap anyway.
# This is the session-death path; without it every crashed job leaks a broker.
sleep 300 >/dev/null 2>&1 & dead_worker=$!
kill -9 "$dead_worker" 2>/dev/null || true; wait "$dead_worker" 2>/dev/null || true
python3 - "$QJOBS/task-reap3-ccc3.json" "$dead_worker" <<'PYEOF'
import json, sys
json.dump({"id": "task-reap3-ccc3", "status": "running", "threadId": "thread-R3",
           "createdAt": "2026-02-03T00:00:00.000Z", "pid": int(sys.argv[2]),
           "request": {"cwd": "/nowhere"}}, open(sys.argv[1], "w"))
PYEOF
bp3="$(fake_broker task-reap3-ccc3)"
crew_reap >/dev/null 2>&1 || true
if kill -0 "$bp3" 2>/dev/null; then
  echo "FAIL: orphaned broker of a silently dead job survived"; fail=$((fail + 1)); kill -9 "$bp3" 2>/dev/null || true
else
  echo "PASS: silently dead job's broker is reaped"; pass=$((pass + 1))
fi
check_absent "orphan reap leaves no sidecar" "$(ls "$TMP/q/arc")" "task-reap3-ccc3.broker"
kill -9 "$bp2" 2>/dev/null || true; kill -9 "$live_worker" 2>/dev/null || true

# Case 55: steer/queue route to the job's recorded broker
qjob task-route1-ddd1 running thread-RT
python3 - "$QJOBS/task-route1-ddd1.json" <<'PYEOF'
import json, sys
j = json.load(open(sys.argv[1])); j["turnId"] = "turn-rt-1"; json.dump(j, open(sys.argv[1], "w"))
PYEOF
printf 'unix:/tmp/does-not-matter.sock\t999999\t/tmp/nope\t%s\n' "$PWD" > "$TMP/q/arc/task-route1-ddd1.broker"
out="$(CLAUDE_CONFIG_DIR="$TMP/q" CLAUDE_PLUGIN_DATA="$TMP/q/data" CREW_CODEX_ARCHIVE_DIR="$TMP/q/arc" \
  CREW_TEST_RPC_LOG="$TMP/q/rpc.log" CREW_TEST_DUMP_ENDPOINT=1 \
  bash "$CREW" steer task-route1-ddd1 "routed" 2>&1)" && rc=0 || rc=$?
check "steer routes to the job's own broker" 0 "unix:/tmp/does-not-matter.sock" "$rc" "$(cat "$TMP/q/rpc.log")"
rm -f "$TMP/q/arc/task-route1-ddd1.broker"

# Case 56: no recorded broker -> say so instead of a bare "thread not found"
out="$(CLAUDE_CONFIG_DIR="$TMP/q" CLAUDE_PLUGIN_DATA="$TMP/q/data" CREW_CODEX_ARCHIVE_DIR="$TMP/q/arc" \
  CREW_TEST_RPC_LOG="$TMP/q/rpc.log" bash "$CREW" steer task-route1-ddd1 "unrouted" 2>&1)" && rc=0 || rc=$?
check "steer warns when the job has no broker" 0 "no broker recorded" "$rc" "$out"

# Case 57: prompts and docs put queue ahead of the destructive path
for f in "$AGENT_DIR"/*.md "$SKILL_FILE"; do
  check_contains "$(basename "$f") teaches queue" "$f" "crew-codex queue <job-id>"
done
check_contains "SKILL.md calls redirect destructive" "$SKILL_FILE" "destructive"
check_contains "README documents the patch" "$HERE/../README.md" "crew-codex patch --apply"

# --- metadata encoding: empty columns must not shift later fields -----------
# A review job pins no model or effort, so those columns are empty. Under a tab
# separator bash collapses the run and every later field shifts left, landing
# the turn id in the wrong variable. This is the shape that shipped broken.
cat > "$QJOBS/review-empty1-aaa1.json" <<EOF
{"id":"review-empty1-aaa1","status":"running","threadId":"thread-EMPTY","createdAt":"2026-02-05T00:00:00.000Z","turnId":"turn-empty-1","pid":424242,"request":{"cwd":"$PWD","write":false}}
EOF
: > "$TMP/q/rpc.log"
out="$(CLAUDE_CONFIG_DIR="$TMP/q" CLAUDE_PLUGIN_DATA="$TMP/q/data" CREW_CODEX_ARCHIVE_DIR="$TMP/q/arc" \
  CREW_TEST_RPC_LOG="$TMP/q/rpc.log" bash "$CREW" steer review-empty1-aaa1 "unpinned job" 2>&1)" && rc=0 || rc=$?
check "steer works with empty model/effort columns" 0 "STEERED review-empty1-aaa1" "$rc" "$out"
check "empty columns do not shift the turn id" 0 '"expectedTurnId":"turn-empty-1"' "$rc" "$(cat "$TMP/q/rpc.log")"

# --- reap must not act on an unreadable snapshot ----------------------------
# The companion rewrites job files in place. A half-written file must read as
# UNREADABLE, not as a dead job, or the sweep kills a live job's broker.
qjob task-unread1-bbb1 running thread-UR
bpu="$(fake_broker task-unread1-bbb1)"
printf '{"id":"task-unread1-bbb1","status":"run' > "$QJOBS/task-unread1-bbb1.json"
crew_reap >/dev/null 2>&1 || true
if kill -0 "$bpu" 2>/dev/null; then
  echo "PASS: unreadable snapshot does not reap a live broker"; pass=$((pass + 1))
else
  echo "FAIL: a half-written job file got its broker reaped"; fail=$((fail + 1))
fi
check_contains "unreadable snapshot keeps its sidecar" "$TMP/q/arc/task-unread1-bbb1.broker" "broker.sock"

# ...but it must not skip forever: a file left invalid by a crashed rewrite
# would otherwise hold its broker for the life of the machine. Ageing is by
# wall clock, so back-date the marker rather than sweeping in a loop, which is
# also what stops a burst of concurrent sweeps from racing through it.
printf '%s' "$(( $(date +%s) - 9999 ))" > "$TMP/q/arc/task-unread1-bbb1.broker.unreadable"
crew_reap >/dev/null 2>&1 || true
if kill -0 "$bpu" 2>/dev/null; then
  echo "FAIL: permanently unreadable record held its broker forever"; fail=$((fail + 1)); kill -9 "$bpu" 2>/dev/null || true
else
  echo "PASS: permanently unreadable record eventually releases its broker"; pass=$((pass + 1))
fi
check_absent "aged-out record leaves no sidecar" "$(ls "$TMP/q/arc")" "task-unread1-bbb1.broker"
kill -9 "$bpu" 2>/dev/null || true; rm -f "$TMP/q/arc/task-unread1-bbb1.broker" "$QJOBS/task-unread1-bbb1.json"

# --- a failed cancel must not destroy a live job's broker -------------------
qjob task-cxfail1-ccc1 running thread-CX
bpc="$(fake_broker task-cxfail1-ccc1)"
out="$(CLAUDE_CONFIG_DIR="$TMP/q" CLAUDE_PLUGIN_DATA="$TMP/q/data" CREW_CODEX_ARCHIVE_DIR="$TMP/q/arc" \
  CREW_TEST_CANCEL_FAIL="wrong cwd" bash "$CREW" cancel task-cxfail1-ccc1 2>&1)" && rc=0 || rc=$?
check "failed cancel reports the failure" 1 "cancel failed" "$rc" "$out"
if kill -0 "$bpc" 2>/dev/null; then
  echo "PASS: failed cancel leaves the live broker alone"; pass=$((pass + 1))
else
  echo "FAIL: failed cancel destroyed a live job's broker"; fail=$((fail + 1))
fi
check_contains "failed cancel keeps the sidecar" "$TMP/q/arc/task-cxfail1-ccc1.broker" "broker.sock"
kill -9 "$bpc" 2>/dev/null || true

# --- a successful cancel still retires the broker ---------------------------
out="$(CLAUDE_CONFIG_DIR="$TMP/q" CLAUDE_PLUGIN_DATA="$TMP/q/data" CREW_CODEX_ARCHIVE_DIR="$TMP/q/arc" \
  bash "$CREW" cancel task-cxfail1-ccc1 2>&1)" && rc=0 || rc=$?
check_absent "successful cancel removes the sidecar" "$(ls "$TMP/q/arc")" "task-cxfail1-ccc1.broker"

# --- redirect: broker routing, publication and refusal ----------------------
# The old job's cancel must go to the broker that job runs on, the successor
# must get its own recorded broker, and a broker that cannot be started must
# abort BEFORE the old turn is destroyed.
redir_jobs="$TMP/redir/data/state/lab-1/jobs"
write_job "$redir_jobs" task-rr1-aaa1 running thread-RR 2026-09-01T00:00:00.000Z gpt-5.6-terra xhigh true
mkdir -p "$TMP/redir/arc"
printf 'unix:/tmp/old-broker.sock\t888888\t/tmp/old-broker-dir\t%s\n' "$PWD" > "$TMP/redir/arc/task-rr1-aaa1.broker"
log="$TMP/redir/argv_rr"; : > "$log"
out="$(CLAUDE_CONFIG_DIR="$TMP/redir" CLAUDE_PLUGIN_DATA="$TMP/redir/data" CREW_CODEX_ARCHIVE_DIR="$TMP/redir/arc" \
  CREW_TEST_ARGV_LOG="$log" bash "$CREW" redirect task-rr1-aaa1 "switch approach" 2>&1)" && rc=0 || rc=$?
check "redirect routes the cancel to the old job's broker" 0 \
  "^cancel task-rr1-aaa1 @endpoint=unix:/tmp/old-broker.sock" "$rc" "$(cat "$log")"
check "redirect relaunches on a NEW broker" 0 \
  "resume-last.*@endpoint=unix:$TMP/crewb-" "$rc" "$(grep resume-last "$log")"
check_absent "redirect drops the old job's sidecar" "$(ls "$TMP/redir/arc")" "task-rr1-aaa1.broker"
check_contains "redirect publishes the successor's broker" "$TMP/redir/arc/task-new1-aaa1.broker" "crewb-"

# allocation failure must not destroy the old turn
write_job "$redir_jobs" task-rr2-bbb2 running thread-RR2 2026-09-02T00:00:00.000Z gpt-5.6-terra xhigh true
log="$TMP/redir/argv_rr2"; : > "$log"
out="$(CLAUDE_CONFIG_DIR="$TMP/redir" CLAUDE_PLUGIN_DATA="$TMP/redir/data" CREW_CODEX_ARCHIVE_DIR="$TMP/redir/arc" \
  CREW_CODEX_BROKER_TMPDIR="$TMP/no-such-dir-for-brokers" \
  CREW_TEST_ARGV_LOG="$log" bash "$CREW" redirect task-rr2-bbb2 "should refuse" 2>&1)" && rc=0 || rc=$?
check "redirect refuses when it cannot start a broker" 1 "leaving task-rr2-bbb2 running" "$rc" "$out"
check_absent "refused redirect never cancelled the old job" "$(cat "$log")" "cancel task-rr2-bbb2"

# A burst of sweeps inside the grace period must NOT age a record out: that was
# the concurrency hole in counting sweeps instead of seconds.
qjob task-burst1-ddd1 running thread-BURST
bpb="$(fake_broker task-burst1-ddd1)"
printf '{"id":"task-burst1-ddd1","status":"run' > "$QJOBS/task-burst1-ddd1.json"
crew_reap >/dev/null 2>&1 || true
crew_reap >/dev/null 2>&1 || true
crew_reap >/dev/null 2>&1 || true
crew_reap >/dev/null 2>&1 || true
if kill -0 "$bpb" 2>/dev/null; then
  echo "PASS: a burst of sweeps cannot age out a record early"; pass=$((pass + 1))
else
  echo "FAIL: rapid sweeps reaped a live broker inside the grace period"; fail=$((fail + 1))
fi
kill -9 "$bpb" 2>/dev/null || true
rm -f "$TMP/q/arc/task-burst1-ddd1.broker" "$TMP/q/arc/task-burst1-ddd1.broker.unreadable" "$QJOBS/task-burst1-ddd1.json"

# Identity check: a sidecar naming a pid that has been recycled must not be
# signalled. A live process with a mismatched start time stands in for the
# recycled pid.
qjob task-recycle1-eee1 completed thread-REC
sleep 300 >/dev/null 2>&1 & innocent=$!
disown "$innocent" 2>/dev/null || true
STUB_PIDS="$STUB_PIDS $innocent"
printf 'unix:/tmp/gone.sock\t%s\t/tmp/gone-dir\t%s\t1\n' "$innocent" "$PWD" \
  > "$TMP/q/arc/task-recycle1-eee1.broker"
crew_reap >/dev/null 2>&1 || true
if kill -0 "$innocent" 2>/dev/null; then
  echo "PASS: a recycled pid is not signalled"; pass=$((pass + 1))
else
  echo "FAIL: cleanup killed an unrelated process holding a recycled pid"; fail=$((fail + 1))
fi
kill -9 "$innocent" 2>/dev/null || true

# Case B32: macOS system bash. /bin/bash there is 3.2, which has no
# `declare -A` (sanitize-archive aborted) and mis-parses a here-document inside
# $(…) / <(…) at RUNTIME — `bash -n` passes. The suite may itself run under
# bash 5, so both paths are driven through /bin/bash explicitly and compared
# against the suite's own `bash`.
# ⚠️ Where /bin/bash is not 3.x (every Linux box) this case records an explicit
# SKIP. ai-crew has no CI, so the bash 3.2 gate is the local suite run on a Mac,
# where /bin/bash is 3.2 and B32 always runs. A Linux-only run passing does NOT
# cover bash 3.2. Deferred follow-up: a macOS CI job asserting /bin/bash is 3.x.
if [[ -x /bin/bash ]] && [[ "$(/bin/bash -c 'echo ${BASH_VERSINFO[0]}')" -lt 4 ]]; then
  # sanitize-archive: the pristine legacy fixture from case 20i plus the
  # newline-named file from case 20w, in two identical copies.
  for b32 in ref b32; do
    mkdir -p "$TMP/b32-arc-$b32"
    cp "$TMP/legacy-meta-before.json" "$TMP/b32-arc-$b32/task-old1.meta.json"
    cp "$TMP/legacy-result-before.txt" "$TMP/b32-arc-$b32/task-old1.result.txt"
    printf '# Codex Task\n\nJob: %s\nStatus: completed\nSummary: Investigate %s\n\nNo captured result payload was stored for this job.\n' \
      "task-nl" "$SECRET" > "$TMP/b32-arc-$b32/$nlname.result.txt"
  done
  ref_out="$(bash "$CREW" sanitize-archive --dir "$TMP/b32-arc-ref" 2>&1)" && ref_rc=0 || ref_rc=$?
  out="$(/bin/bash "$CREW" sanitize-archive --dir "$TMP/b32-arc-b32" 2>&1)" && rc=0 || rc=$?
  if [[ "$rc" == 0 && "$ref_rc" == 0 ]] && ! grep -rq "$SECRET" "$TMP/b32-arc-b32" \
     && [[ "${out//b32-arc-b32/X}" == "${ref_out//b32-arc-ref/X}" ]] \
     && diff -r "$TMP/b32-arc-ref" "$TMP/b32-arc-b32" >/dev/null; then
    echo "PASS: /bin/bash 3.2 sanitize-archive matches the suite's bash"; pass=$((pass + 1))
  else
    echo "FAIL: /bin/bash 3.2 sanitize-archive diverged (exit=$rc/$ref_rc; output: $out; ref: $ref_out)"; fail=$((fail + 1))
  fi
  cp -R "$TMP/b32-arc-b32" "$TMP/b32-arc-clean"
  out="$(/bin/bash "$CREW" sanitize-archive --dir "$TMP/b32-arc-b32" 2>&1)" && rc=0 || rc=$?
  if [[ "$rc" == 0 ]] && grep -q "0 rewritten" <<<"$out" \
     && diff -r "$TMP/b32-arc-clean" "$TMP/b32-arc-b32" >/dev/null; then
    echo "PASS: /bin/bash 3.2 sanitize-archive second pass is a no-op"; pass=$((pass + 1))
  else
    echo "FAIL: /bin/bash 3.2 sanitize-archive is not idempotent (exit=$rc; output: $out)"; fail=$((fail + 1))
  fi

  # reap --brokers: case 37's fake broker, under its own unique pattern.
  B32_PAT="crewtest-b32broker-$$"
  mkdir -p "$TMP/$B32_PAT"
  echo 'setTimeout(() => {}, 60000);' > "$TMP/$B32_PAT/app-server-broker.mjs"
  node "$TMP/$B32_PAT/app-server-broker.mjs" serve --endpoint "unix:$TMP/none.sock" --cwd "$GONE_WS" & B32_PID=$!
  STUB_PIDS="$STUB_PIDS $B32_PID"
  sleep 0.5
  out="$(CLAUDE_CONFIG_DIR="$TMP/await" CLAUDE_PLUGIN_DATA="$TMP/sweep-clean" \
    CREW_CODEX_BROKER_PATTERN="$B32_PAT" CREW_CODEX_SOCKET_GLOB="$TMP/sockets/cxc-*" \
    /bin/bash "$CREW" reap --brokers 2>&1)" && rc=0 || rc=$?
  check "/bin/bash 3.2 reap --brokers reports the fake broker" 0 "broker candidate: pid $B32_PID" "$rc" "$out"
  check "/bin/bash 3.2 reap --brokers summary" 0 "reap brokers summary: 1 reported (nothing killed), 0 live (cwd exists), 0 unknown (cwd unreadable), 0 skipped" "$rc" "$out"
  check "/bin/bash 3.2 reap --brokers survey ran" 0 "registry survey: every job record read cleanly and is terminal" "$rc" "$out"
  kill "$B32_PID" 2>/dev/null || true
  wait "$B32_PID" 2>/dev/null || true
  # The clean message above is also what an EMPTY survey program prints, so it
  # cannot tell "ran" from "no-op". Case 56d's fixture holds a running job: the
  # 3.2 run must name it, byte-for-byte as the suite's own bash does.
  ref_out="$(CLAUDE_CONFIG_DIR="$TMP/await" CLAUDE_PLUGIN_DATA="$TMP/gate-ws000" \
    CREW_CODEX_BROKER_PATTERN="$NOMATCH" \
    bash "$CREW" reap --brokers 2>&1)" && ref_rc=0 || ref_rc=$?
  out="$(CLAUDE_CONFIG_DIR="$TMP/await" CLAUDE_PLUGIN_DATA="$TMP/gate-ws000" \
    CREW_CODEX_BROKER_PATTERN="$NOMATCH" \
    /bin/bash "$CREW" reap --brokers 2>&1)" && rc=0 || rc=$?
  check "/bin/bash 3.2 reap --brokers survey names the non-terminal job" 0 "registry survey: non-terminal or unreadable record(s): ws-live/live-000(running)" "$rc" "$out"
  if [[ "$(grep '^registry survey:' <<<"$out")" == "$(grep '^registry survey:' <<<"$ref_out")" && "$rc" == "$ref_rc" ]]; then
    echo "PASS: /bin/bash 3.2 survey line matches the suite's bash"; pass=$((pass + 1))
  else
    echo "FAIL: /bin/bash 3.2 survey diverged (exit=$rc/$ref_rc; output: $out; ref: $ref_out)"; fail=$((fail + 1))
  fi
else
  skip "bash 3.2 sanitize-archive and reap --brokers" "/bin/bash is absent or not bash 3.x"
fi


echo
echo "$pass passed, $fail failed, $skipped skipped"
[[ "$fail" -eq 0 ]]
