#!/usr/bin/env bash
# Behavioral test for coordinating-partner-sessions/scripts/ledger.sh: the
# ledger path, run lock, init, intents, events (the transition table), outbox,
# slots, done and summary. Runnable standalone. Task 6 extends this file.
#
# Bash 3.2 compatible: no associative arrays, no `mapfile`, no `${var,,}`.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SCRIPTS="$ROOT/skills/coordinating-partner-sessions/scripts"
LSH="$SCRIPTS/ledger.sh"
FRONTIER="$SCRIPTS/frontier.sh"
FFM="$SCRIPTS/ff-merge.sh"

FAIL=0

fail() {
  echo "FAIL: $1" >&2
  FAIL=1
}

[ -f "$LSH" ] || { echo "FAIL: $LSH not found (ledger.sh not found)" >&2; exit 1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

TAB="$(printf '\t')"
H40="1111111111111111111111111111111111111111"
H41="2222222222222222222222222222222222222222"

OUT=""
ERR=""
RC=0
R=""
L=""
# run_raw <args...> — runs ledger.sh in $R; sets OUT, ERR, RC.
run_raw() {
  OUT="$(cd "$R" && "$BASH" "$LSH" "$@" 2>"$T/err")"
  RC=$?
  ERR="$(cat "$T/err")"
}
LASTCMD=""
# assert_outbox_invariant <ledger> — every work entry is of its issue's current gen
# while that issue is resync-requested or rework-*; no CANCEL is older than the
# issue's current gen.
assert_outbox_invariant() {
  jq -e '.issues as $is | all(.outbox[]; ($is[(.n | tostring)]) as $i
         | if (.line | startswith("CANCEL #")) then .gen >= $i.gen
           else .gen == $i.gen and ($i.status == "resync-requested" or ($i.status | startswith("rework-"))) end)' \
    "$1" >/dev/null || fail "outbox invariant violated after '$LASTCMD': $(jq -c .outbox "$1")"
}
# run — run_raw, then the outbox invariant after an rc-0 mutating call.
run() {
  run_raw "$@"
  case "$1" in
    init|intent|event|message|session|reconcile)
      if [ "$RC" -eq 0 ]; then LASTCMD="$*"; assert_outbox_invariant "$2"; fi ;;
  esac
}

g() { git -C "$R" "$@"; }

# mkrepo <name> — fresh repo in $R with the ticket branch `tk` checked out.
mkrepo() {
  R="$T/$1"
  mkdir -p "$R"
  git init -q "$R"
  g config user.name "Test"
  g config user.email "test@example.invalid"
  g checkout -q -b tk
  echo base >"$R/f"
  g add f
  g commit -q -m base
}

# commit_on <branch> <file> — one commit on <branch> (created from tk if new), back to tk.
commit_on() {
  g rev-parse -q --verify "refs/heads/$1" >/dev/null || g branch "$1" tk
  g checkout -q "$1"
  echo "$2" >"$R/$2"
  g add "$2"
  g commit -q -m "$2"
  g checkout -q tk
}

# agents <file> <sid>=<pid>|<sid>=state:<state> ... — a `claude agents --json --all` fixture.
agents() {
  f="$1"; shift
  body=""
  for a in "$@"; do
    sid="${a%%=*}"; v="${a#*=}"
    case "$v" in
      state:*) row="{\"sessionId\":\"$sid\",\"name\":\"$sid\",\"state\":\"${v#state:}\"}" ;;
      *) row="{\"sessionId\":\"$sid\",\"name\":\"$sid\",\"pid\":$v,\"state\":\"working\"}" ;;
    esac
    if [ -z "$body" ]; then body="$row"; else body="$body,$row"; fi
  done
  printf '[%s]\n' "$body" >"$f"
}

# A pid that is certainly dead.
sleep 0 &
DEADPID=$!
wait "$DEADPID"

agents "$T/ag-coord.json" "sid-coord=$$"

# iss <n> [blockers-json] — one issues.json item.
iss() {
  printf '{"n":%s,"blockers":%s,"external":[],"branch":"test-x-%s","testCmd":"true","ac":["AC-1"]}' \
    "$1" "${2:-[]}" "$1"
}
ISS3="[$(iss 1),$(iss 2),$(iss 3)]"

# setup <name> [issues-json] — repo + ledger for key TEST, locked as sid-coord.
setup() {
  mkrepo "$1"
  run path TEST
  L="$OUT"
  run lock "$L" sid-coord "$T/ag-coord.json"
  [ "$RC" -eq 0 ] || fail "setup $1: lock rc $RC ($ERR)"
  PS_OWNER="${OUT#owner=}"
  export PS_OWNER
  printf '%s\n' "${2:-$ISS3}" >"$T/issues.json"
  run init "$L" TEST tk TEST-coord sid-coord "$T/issues.json"
  [ "$RC" -eq 0 ] || fail "setup $1: init rc $RC ($ERR)"
}

# jset <jq-expr> [--arg k v ...] — test-only seeding of the ledger.
jset() {
  expr="$1"; shift
  jq "$@" "$expr" "$L" >"$T/seed.json" && cat "$T/seed.json" >"$L"
}
# seed <n> <status> — set a status; a live seed gets gen >= 1. A seed outside
# resync-requested/rework-* drops that issue's RESYNC/REWORK entries (outbox invariant);
# tests that need the entries to stay must use jset.
seed() {
  jset '.issues[$n].status = $s
        | if (.issues[$n].gen == 0) and ($s != "pending") then .issues[$n].gen = 1 else . end
        | if $s == "resync-requested" or ($s | startswith("rework-")) then .
          else .outbox |= map(select((.n == ($n | tonumber) and ((.line | startswith("CANCEL #")) | not)) | not)) end' \
    --arg n "$1" --arg s "$2"
}
# seed_blocked <n> <m> — `blocked-on #m` with m in .blockers.
seed_blocked() {
  seed "$1" "blocked-on #$2"
  jset '.issues[$n].blockers += [($m | tonumber)]' --arg n "$1" --arg m "$2"
}

st() { jq -r --arg n "$1" '.issues[$n].status' "$L"; }
fld() { jq -r --arg n "$1" ".issues[\$n].$2" "$L"; }
ev() { run event "$L" "$@"; }

expect_rc() { # <name> <want>
  [ "$RC" -eq "$2" ] || fail "$1: expected rc $2, got $RC (out '$OUT', err '$ERR')"
}
expect_st() { # <name> <n> <want>
  got="$(st "$2")"
  [ "$got" = "$3" ] || fail "$1: expected #$2 status '$3', got '$got'"
}
expect_outbox() { # <name> <exact line n<TAB>gen<TAB>text>
  run outbox "$L"
  printf '%s\n' "$OUT" | grep -Fxq "$2" || fail "$1: outbox lacks '$2' (got '$OUT')"
}
# intent_id — from OUT `intent=<id>`.
intent_id() { printf '%s' "${OUT#intent=}"; }
# launch_issue <n> — intent launch + event launch; leaves the issue `launched`.
launch_issue() {
  run intent "$L" launch "$1" "TEST-$1" "$T/wt-$1" "test-x-$1" "$H40"
  [ "$RC" -eq 0 ] || { fail "launch_issue $1: intent rc $RC ($ERR)"; return; }
  ev "$1" launch "$(intent_id)" "sid-$1"
  [ "$RC" -eq 0 ] || fail "launch_issue $1: event rc $RC ($ERR)"
}

# ---------------------------------------------------------------- path_in_git_dir
setup path
COMMON="$(cd "$R" && cd "$(git rev-parse --git-common-dir)" && pwd -P)"
[ "$L" = "$COMMON/partner-sessions/TEST/ledger.json" ] || fail "path_in_git_dir: got '$L', want under '$COMMON'"
[ -d "$COMMON/partner-sessions/TEST" ] || fail "path_in_git_dir: directory not created"
g worktree add -q "$T/path-wt" -b other-wt
R0="$R"; R="$T/path-wt"
run path TEST
R="$R0"
[ "$OUT" = "$L" ] || fail "path_in_git_dir: second worktree printed '$OUT', want '$L'"
[ -z "$(g status --porcelain)" ] || fail "path_in_git_dir: working tree not clean after init"
echo "ok: path_in_git_dir"

# ---------------------------------------------------------------- atomic_write
setup atomic
ev 1 canary-passed
expect_rc "atomic_write event" 0
if ls -a "$(dirname "$L")" | grep -q 'tmp'; then fail "atomic_write: temp file left: $(ls -a "$(dirname "$L")")"; fi
jq -e . "$L" >/dev/null || fail "atomic_write: ledger not valid JSON"
printf '{"key":"TE' >"$L.tmp.99999"
run get "$L"
expect_rc "atomic_write get with stray temp" 0
printf '%s' "$OUT" | jq -e '.canary == "passed"' >/dev/null || fail "atomic_write: previous ledger not readable"
ev 3 drop
expect_rc "atomic_write event with stray temp" 0
jq -e . "$L" >/dev/null || fail "atomic_write: ledger not valid JSON after stray temp"
rm -f "$L.tmp.99999"
echo "ok: atomic_write"

# ---------------------------------------------------------------- lock_contention / lock_own
mkrepo lock1
run path TEST; L="$OUT"
agents "$T/ag-s1.json" "S1=$$"
run lock "$L" S1 "$T/ag-s1.json"
expect_rc "lock_contention S1" 0
case "$OUT" in owner=S1:?*) ;; *) fail "lock_contention: S1 printed '$OUT'" ;; esac
TOK1="$OUT"
run lock "$L" S2 "$T/ag-s1.json"
expect_rc "lock_contention S2" 40
printf '%s\n' "$OUT" | grep -qx 'holder=S1' || fail "lock_contention: expected holder=S1, got '$OUT'"
echo "ok: lock_contention"

run lock "$L" S1 "$T/ag-s1.json"
expect_rc "lock_own second" 0
case "$OUT" in owner=S1:?*) ;; *) fail "lock_own: printed '$OUT'" ;; esac
[ "$OUT" = "$TOK1" ] || fail "lock_own: token changed ('$TOK1' -> '$OUT')"
echo "ok: lock_own"

# A torn holder of our own (no nonce) is taken over, not reported as held.
mkrepo lock-torn
run path TEST; L="$OUT"
mkdir "$(dirname "$L")/lock"
echo S1 >"$(dirname "$L")/lock/holder"
run lock "$L" S1 "$T/ag-s1.json"
expect_rc "lock_own torn holder" 0
case "$OUT" in owner=S1:?*) ;; *) fail "lock_own torn holder: printed '$OUT'" ;; esac
TORN="${OUT#owner=}"
# unlock needs the token, then the lock is free.
PS_OWNER="nobody:0" run unlock "$L"
expect_rc "unlock wrong token" 40
PS_OWNER="$TORN" run unlock "$L"
expect_rc "unlock" 0
[ ! -d "$(dirname "$L")/lock" ] || fail "unlock: lock dir left"
run lock "$L" S2 "$T/ag-s1.json"
expect_rc "lock after unlock" 0
echo "ok: unlock"

# ---------------------------------------------------------------- lock_stale_takeover
agents "$T/ag-s1dead.json" "S1=$DEADPID" "S2=$$"
run lock "$L" S2 "$T/ag-s1dead.json"
expect_rc "lock_stale_takeover" 0
case "$OUT" in owner=S2:?*) ;; *) fail "lock_stale_takeover: printed '$OUT'" ;; esac
grep -q 'lock-takeover' "$(dirname "$L")/ledger.log" || fail "lock_stale_takeover: no lock-takeover in ledger.log"
[ ! -d "$(dirname "$L")/takeover" ] || fail "lock_stale_takeover: takeover dir left behind"
echo "ok: lock_stale_takeover"

# ---------------------------------------------------------------- lock_missing_holder
mkrepo lock2
run path TEST; L="$OUT"
mkdir "$(dirname "$L")/lock"
run lock "$L" S2 "$T/ag-s1dead.json"
expect_rc "lock_missing_holder" 0
case "$OUT" in owner=S2:?*) ;; *) fail "lock_missing_holder: printed '$OUT'" ;; esac
echo "ok: lock_missing_holder"

# ---------------------------------------------------------------- lock_no_pid_fallback
mkrepo lock3
run path TEST; L="$OUT"
run lock "$L" S1 "$T/ag-s1.json"
agents "$T/ag-nopid-working.json" "S1=state:working" "S2=$$"
run lock "$L" S2 "$T/ag-nopid-working.json"
expect_rc "lock_no_pid_fallback working" 40
agents "$T/ag-nopid-stopped.json" "S1=state:stopped" "S2=$$"
run lock "$L" S2 "$T/ag-nopid-stopped.json"
expect_rc "lock_no_pid_fallback stopped" 0
echo "ok: lock_no_pid_fallback"

# ---------------------------------------------------------------- lost_lock_refused
mkrepo lost
run path TEST; L="$OUT"
run lock "$L" S1 "$T/ag-s1.json"
PS_OWNER="${OUT#owner=}"; export PS_OWNER
S1TOK="$PS_OWNER"
printf '%s\n' "$ISS3" >"$T/issues.json"
run init "$L" TEST tk TEST-coord S1 "$T/issues.json"
expect_rc "lost_lock_refused init" 0
run lock "$L" S2 "$T/ag-s1dead.json"
expect_rc "lost_lock_refused takeover" 0
cp "$L" "$T/lost-before.json"
PS_OWNER="$S1TOK" ev 1 canary-passed
expect_rc "lost_lock_refused event" 40
printf '%s\n' "$OUT" | grep -qx 'holder=S2' || fail "lost_lock_refused: expected holder=S2, got '$OUT'"
cmp -s "$L" "$T/lost-before.json" || fail "lost_lock_refused: ledger changed"
PS_OWNER="$S1TOK" run intent "$L" launch 1 TEST-1 "$T/wt" test-x-1 "$H40"
expect_rc "lost_lock_refused intent" 40
cmp -s "$L" "$T/lost-before.json" || fail "lost_lock_refused: ledger changed by intent"
env -u PS_OWNER "$BASH" "$LSH" event "$L" 1 canary-passed >/dev/null 2>&1
[ "$?" -eq 40 ] || fail "lost_lock_refused: missing PS_OWNER not refused with 40"
echo "ok: lost_lock_refused"

# ---------------------------------------------------------------- lock_per_key
mkrepo perkey
agents "$T/ag-s12.json" "S1=$$" "S2=$$"
run path AAA; LA="$OUT"
run path BBB; LB="$OUT"
run lock "$LA" S1 "$T/ag-s12.json"
expect_rc "lock_per_key AAA" 0
run lock "$LB" S2 "$T/ag-s12.json"
expect_rc "lock_per_key BBB" 0
n="$(ls -d "$(dirname "$(dirname "$LA")")"/*/lock | wc -l | tr -d ' ')"
[ "$n" = 2 ] || fail "lock_per_key: expected 2 lock dirs, got $n"
echo "ok: lock_per_key"

# ---------------------------------------------------------------- canary_gate
setup canary
run intent "$L" launch 1 TEST-1 "$T/wt-1" test-x-1 "$H40"
expect_rc "canary_gate first" 0
I1="$(intent_id)"
cp "$L" "$T/canary-before.json"
run intent "$L" launch 2 TEST-2 "$T/wt-2" test-x-2 "$H40"
expect_rc "canary_gate second before pass" 30
cmp -s "$L" "$T/canary-before.json" || fail "canary_gate: refused intent recorded something"
ev 1 launch "$I1" sid-1
expect_rc "canary_gate launch 1" 0
run intent "$L" launch 2 TEST-2 "$T/wt-2" test-x-2 "$H40"
expect_rc "canary_gate second after launch, before pass" 30
ev 1 canary-passed
expect_rc "canary_gate canary-passed" 0
[ "$(jq -r .canary "$L")" = passed ] || fail "canary_gate: .canary not passed"
run intent "$L" launch 2 TEST-2 "$T/wt-2" test-x-2 "$H40"
expect_rc "canary_gate second after pass" 0
echo "ok: canary_gate"

# ---------------------------------------------------------------- launch_blocked
setup blocked "[$(iss 1),$(iss 2 '[1]')]"
ev 1 canary-passed
cp "$L" "$T/blocked-before.json"
run intent "$L" launch 2 TEST-2 "$T/wt-2" test-x-2 "$H40"
expect_rc "launch_blocked" 30
[ "$(jq '.intents | length' "$L")" = 0 ] || fail "launch_blocked: intent recorded"
cmp -s "$L" "$T/blocked-before.json" || fail "launch_blocked: ledger changed"
echo "ok: launch_blocked"

# ---------------------------------------------------------------- launch_closes_intent
setup closes
run intent "$L" launch 1 TEST-1 "$T/wt-1" test-x-1 "$H40"
I1="$(intent_id)"
[ "$(jq -r --arg i "$I1" '.intents[] | select(.id == $i) | .open' "$L")" = true ] || fail "launch_closes_intent: intent not open"
ev 1 launch "$I1" sid-1
expect_rc "launch_closes_intent launch" 0
[ "$OUT" = launched ] || fail "launch_closes_intent: printed '$OUT'"
expect_st "launch_closes_intent" 1 launched
[ "$(jq -r --arg i "$I1" '.intents[] | select(.id == $i) | .open' "$L")" = false ] || fail "launch_closes_intent: intent still open"
[ "$(fld 1 worktree)" = "$T/wt-1" ] || fail "launch_closes_intent: worktree not recorded"
[ "$(fld 1 branch)" = test-x-1 ] || fail "launch_closes_intent: branch not recorded"
[ "$(fld 1 startSha)" = "$H40" ] || fail "launch_closes_intent: startSha not recorded"
[ "$(fld 1 sessionId)" = sid-1 ] || fail "launch_closes_intent: sessionId not recorded"
[ "$(fld 1 sessionName)" = TEST-1 ] || fail "launch_closes_intent: sessionName not recorded"
[ "$(fld 1 gen)" = 1 ] || fail "launch_closes_intent: gen not 1"
ev 1 launch "$I1" sid-1
expect_rc "launch_closes_intent closed intent replay" 10
ev 1 canary-passed
run intent "$L" launch 3 TEST-3 "$T/wt-3" test-x-3 "$H40"
I3="$(intent_id)"
ev 3 launch-failed "$I3"
expect_rc "launch_closes_intent launch-failed" 0
expect_st "launch_closes_intent launch-failed" 3 pending
[ "$(jq -r --arg i "$I3" '.intents[] | select(.id == $i) | .open' "$L")" = false ] || fail "launch_closes_intent: launch-failed left intent open"
[ "$(fld 3 gen)" = 0 ] || fail "launch_closes_intent: launch-failed changed gen"
seed 2 failed
run intent "$L" relaunch 2 TEST-2 "$T/wt-2b" test-x-2-g1 "$H40"
expect_rc "launch_closes_intent relaunch intent" 0
I2="$(intent_id)"
ev 2 launch-failed "$I2"
expect_rc "launch_closes_intent relaunch launch-failed" 0
expect_st "launch_closes_intent relaunch launch-failed" 2 failed
[ "$(jq -r --arg i "$I2" '.intents[] | select(.id == $i) | .open' "$L")" = false ] || fail "launch_closes_intent: relaunch intent left open"
echo "ok: launch_closes_intent"

# ---------------------------------------------------------------- slots_cap
setup slots "[$(iss 1),$(iss 2),$(iss 3),$(iss 4),$(iss 5)]"
ev 1 canary-passed
seed 1 launched; seed 2 started; seed 3 rework-1/3; seed 5 failed
cp "$L" "$T/slots-before.json"
run intent "$L" launch 4 TEST-4 "$T/wt-4" test-x-4 "$H40"
expect_rc "slots_cap launch fourth" 30
run intent "$L" relaunch 5 TEST-5 "$T/wt-5" test-x-5 "$H40"
expect_rc "slots_cap relaunch failed" 30
cmp -s "$L" "$T/slots-before.json" || fail "slots_cap: refused intents recorded something"
run slots "$L"
[ "$OUT" = 3 ] || fail "slots_cap: slots printed '$OUT', want 3"
seed_blocked 1 4; seed 2 merged; seed 3 cancelled
run slots "$L"
[ "$OUT" = 0 ] || fail "slots_cap: non-live statuses counted, slots printed '$OUT'"
run intent "$L" launch 4 TEST-4 "$T/wt-4" test-x-4 "$H40"
expect_rc "slots_cap launch after free" 0
echo "ok: slots_cap"

# ---------------------------------------------------------------- every_row
ISS_ROW="[$(iss 9),$(iss 12),$(iss 13)]"
# launch
setup row-launch "$ISS_ROW"
launch_issue 12
expect_st "every_row launch" 12 launched
# launch-failed (launch)
ev 12 canary-passed
run intent "$L" launch 13 TEST-13 "$T/wt" test-x-13 "$H40"
ev 13 launch-failed "$(intent_id)"
expect_rc "every_row launch-failed" 0
expect_st "every_row launch-failed" 13 pending
# relaunch
seed 12 failed
jset '.issues["12"].rework = 2'
run intent "$L" relaunch 12 TEST-12 "$T/wt2" test-x-12-g1 "$H40"
ev 12 relaunch "$(intent_id)" sid-12b
expect_rc "every_row relaunch" 0
expect_st "every_row relaunch" 12 launched
[ "$(fld 12 gen)" = 2 ] || fail "every_row relaunch: gen not 2"
[ "$(fld 12 rework)" = 0 ] || fail "every_row relaunch: rework not reset"
[ "$(fld 12 sessionId)" = sid-12b ] || fail "every_row relaunch: sessionId not recorded"
[ "$(fld 12 branch)" = test-x-12-g1 ] || fail "every_row relaunch: branch not recorded"
# queue-check stale
seed 12 done-claimed
ev 12 queue-check stale "$H41"
expect_rc "every_row queue-check stale" 0
expect_st "every_row queue-check stale" 12 resync-requested
expect_outbox "every_row queue-check stale" "12${TAB}2${TAB}TEST-12${TAB}RESYNC #12 $H41"
[ "$(fld 12 resyncs)" = 1 ] || fail "every_row queue-check stale: resyncs not 1"
# queue-check ok
seed 12 done-claimed
ev 12 queue-check ok
expect_rc "every_row queue-check ok" 0
expect_st "every_row queue-check ok" 12 verifying
# gate merged
run intent "$L" merge 12 "$H40" "$H41"
expect_rc "every_row intent merge" 0
MI="$(intent_id)"
[ "$(jq -r --arg i "$MI" '.intents[] | select(.id == $i) | .gen' "$L")" = 2 ] || fail "every_row: merge intent gen not recorded"
ev 12 gate merged "$MI" "tests: 3 passed"
expect_rc "every_row gate merged" 0
expect_st "every_row gate merged" 12 merged
[ "$(fld 12 mergeSha)" = "$H40" ] || fail "every_row gate merged: mergeSha not recorded"
# gate resync
seed 13 verifying
ev 13 gate resync "$H41"
expect_rc "every_row gate resync" 0
expect_st "every_row gate resync" 13 resync-requested
expect_outbox "every_row gate resync" "13${TAB}1${TAB}-${TAB}RESYNC #13 $H41"
# gate fail
seed 13 verifying
ev 13 gate fail "unit tests fail"
expect_rc "every_row gate fail" 0
expect_st "every_row gate fail" 13 rework-1/3
expect_outbox "every_row gate fail" "13${TAB}1${TAB}-${TAB}REWORK #13 unit tests fail"
jq -e '.issues["13"].gateResults | map(.text) | index("unit tests fail") != null' "$L" >/dev/null \
  || fail "every_row gate fail: evidence not stored"
# stuck-accept
setup row-stuck "$ISS_ROW"
seed 12 started
ev 12 stuck-accept 9
expect_rc "every_row stuck-accept" 0
expect_st "every_row stuck-accept" 12 "blocked-on #9"
expect_outbox "every_row stuck-accept" "12${TAB}1${TAB}-${TAB}CANCEL #12"
# json failed|stopped|done on blocked-on drops the CANCEL entry
ev 12 json stopped
expect_rc "every_row json stopped on blocked-on" 0
run outbox "$L"
[ -z "$OUT" ] || fail "every_row json stopped: CANCEL entry not dropped ('$OUT')"
expect_st "every_row json stopped on blocked-on" 12 "blocked-on #9"
# edge-remove
ev 12 edge-remove
expect_rc "every_row edge-remove" 0
expect_st "every_row edge-remove" 12 pending
jq -e '.issues["12"].blockers | index(9) == null' "$L" >/dev/null || fail "every_row edge-remove: edge not removed"
# drop
ev 12 drop "not needed"
expect_rc "every_row drop" 0
expect_st "every_row drop" 12 cancelled
[ "$(fld 12 reason)" = "not needed" ] || fail "every_row drop: reason not stored"
# json failed
seed 13 started
ev 13 json failed
expect_rc "every_row json failed" 0
expect_st "every_row json failed" 13 failed
# wake-failed
seed 9 launched
ev 9 wake-failed
expect_rc "every_row wake-failed" 0
expect_st "every_row wake-failed" 9 failed
# user-merged
setup row-user "$ISS_ROW"
commit_on test-x-12 u12
g merge -q --ff-only test-x-12
jset '.issues["12"].status = "failed"'
ev 12 user-merged
expect_rc "every_row user-merged" 0
expect_st "every_row user-merged" 12 merged
# cancel-ticket
seed 9 started
ev 0 cancel-ticket "user stopped"
expect_rc "every_row cancel-ticket" 0
expect_st "every_row cancel-ticket 9" 9 cancelled
expect_st "every_row cancel-ticket 13" 13 cancelled
expect_st "every_row cancel-ticket merged stays" 12 merged
expect_outbox "every_row cancel-ticket" "9${TAB}1${TAB}-${TAB}CANCEL #9"
run outbox "$L"
printf '%s\n' "$OUT" | grep -q 'CANCEL #13' && fail "every_row cancel-ticket: CANCEL for a non-live issue"
# canary-passed
setup row-canary "$ISS_ROW"
ev 9 canary-passed
expect_rc "every_row canary-passed" 0
[ "$(jq -r .canary "$L")" = passed ] || fail "every_row canary-passed: .canary not passed"
ev 9 canary-passed
expect_rc "every_row canary-passed again" 10
echo "ok: every_row"

# ---------------------------------------------------------------- merged_releases_dependents
setup rel-gate "[$(iss 1),$(iss 2)]"
seed_blocked 2 1
seed 1 verifying
run intent "$L" merge 1 "$H40" "$H41"
ev 1 gate merged "$(intent_id)"
expect_rc "merged_releases_dependents gate" 0
expect_st "merged_releases_dependents gate 1" 1 merged
expect_st "merged_releases_dependents gate 2" 2 pending
setup rel-user "[$(iss 1),$(iss 2)]"
commit_on test-x-1 r1
g merge -q --ff-only test-x-1
seed_blocked 2 1
seed 1 failed
ev 1 user-merged
expect_rc "merged_releases_dependents user-merged" 0
expect_st "merged_releases_dependents user 1" 1 merged
expect_st "merged_releases_dependents user 2" 2 pending
echo "ok: merged_releases_dependents"

# ---------------------------------------------------------------- stuck_accept_edge
setup edge "[$(iss 9),$(iss 12)]"
seed 12 started
ev 12 stuck-accept 9
expect_rc "stuck_accept_edge" 0
jq -e '.issues["12"].blockers | index(9) != null' "$L" >/dev/null || fail "stuck_accept_edge: 9 not in blockers"
fr="$("$BASH" "$FRONTIER" "$L" | tr '\n' ' ')"
case " $fr" in *" 12 "*) fail "stuck_accept_edge: frontier lists 12 before 9 merged ($fr)" ;; esac
seed 9 verifying
run intent "$L" merge 9 "$H40" "$H41"
ev 9 gate merged "$(intent_id)"
expect_st "stuck_accept_edge released" 12 pending
fr="$("$BASH" "$FRONTIER" "$L" | tr '\n' ' ')"
case " $fr" in *" 12 "*) ;; *) fail "stuck_accept_edge: frontier does not list 12 after 9 merged ($fr)" ;; esac
# A cycle is refused with exit 30 and the cycle on stdout.
setup edge-cycle "[$(iss 1),$(iss 2 '[1]')]"
seed 1 started
ev 1 stuck-accept 2
expect_rc "stuck_accept_edge cycle" 30
case "$OUT" in *cycle:*) ;; *) fail "stuck_accept_edge cycle: no cycle on stdout ('$OUT')" ;; esac
expect_st "stuck_accept_edge cycle" 1 started
echo "ok: stuck_accept_edge"

# ---------------------------------------------------------------- illegal_refused
setup illegal
seed 1 started
run intent "$L" merge 1 "$H40" "$H41"
expect_rc "illegal_refused intent merge on started" 30
ev 1 gate merged i1
expect_rc "illegal_refused gate merged on started" 30
expect_st "illegal_refused" 1 started
grep -q 'refused' "$(dirname "$L")/ledger.log" || fail "illegal_refused: no 'refused' in ledger.log"
seed 2 done-claimed
ev 2 stuck-accept 3
expect_rc "illegal_refused stuck-accept done-claimed" 30
expect_st "illegal_refused stuck-accept done-claimed" 2 done-claimed
seed 2 verifying
ev 2 stuck-accept 3
expect_rc "illegal_refused stuck-accept verifying" 30
expect_st "illegal_refused stuck-accept verifying" 2 verifying
ev 3 edge-remove
expect_rc "illegal_refused edge-remove on pending" 30
echo "ok: illegal_refused"

# ---------------------------------------------------------------- third_gate_fail
setup third
ev 1 canary-passed
launch_issue 1
for k in 1 2 3; do
  seed 1 done-claimed
  ev 1 queue-check ok
  ev 1 gate fail "fail $k"
  expect_rc "third_gate_fail fail $k" 0
done
expect_st "third_gate_fail" 1 failed
[ "$(fld 1 reason)" = "rework budget" ] || fail "third_gate_fail: reason not 'rework budget'"
run outbox "$L"
printf '%s\n' "$OUT" | grep -q 'REWORK #1 fail 3' && fail "third_gate_fail: REWORK sent on failure"
run intent "$L" relaunch 1 TEST-1 "$T/wt-1b" test-x-1-g1 "$H40"
ev 1 relaunch "$(intent_id)" sid-1b
expect_rc "third_gate_fail relaunch" 0
seed 1 verifying
ev 1 gate fail "again"
expect_st "third_gate_fail after relaunch" 1 rework-1/3
echo "ok: third_gate_fail"

# ---------------------------------------------------------------- json_on_claimed / json_blocked_noop
setup jsonc
seed 1 done-claimed
for o in stopped failed; do
  ev 1 json "$o"
  expect_rc "json_on_claimed $o" 10
  expect_st "json_on_claimed $o" 1 done-claimed
done
seed 1 verifying
ev 1 json failed
expect_rc "json_on_claimed verifying failed" 10
expect_st "json_on_claimed verifying" 1 verifying
echo "ok: json_on_claimed"
for s in launched started; do
  seed 2 "$s"
  ev 2 json blocked
  expect_rc "json_blocked_noop $s" 10
  expect_st "json_blocked_noop $s" 2 "$s"
done
echo "ok: json_blocked_noop"

# ---------------------------------------------------------------- drop_dependents
setup dropdep "[$(iss 1),$(iss 2),$(iss 3)]"
seed_blocked 2 1
ev 1 drop
expect_rc "drop_dependents" 0
printf '%s\n' "$OUT" | grep -qx 'dependents=2' || fail "drop_dependents: expected dependents=2, got '$OUT'"
echo "ok: drop_dependents"

# ---------------------------------------------------------------- user_merged_ancestry
setup ancestry "[$(iss 1),$(iss 2)]"
commit_on test-x-1 a1
g merge -q --ff-only test-x-1
commit_on test-x-2 a2
seed 1 failed; seed 2 failed
ev 1 user-merged
expect_rc "user_merged_ancestry merged" 0
expect_st "user_merged_ancestry merged" 1 merged
ev 2 user-merged
expect_rc "user_merged_ancestry not merged" 30
expect_st "user_merged_ancestry not merged" 2 failed
echo "ok: user_merged_ancestry"

# ---------------------------------------------------------------- all_cancelled / done_not_done
setup allc
ev 0 cancel-ticket
run done "$L"
expect_rc "all_cancelled done" 0
[ "$OUT" = cancel-ticket ] || fail "all_cancelled: done printed '$OUT'"
setup handback
seed 1 merged
ev 0 cancel-ticket
run done "$L"
expect_rc "all_cancelled handback" 0
[ "$OUT" = handback ] || fail "all_cancelled: done printed '$OUT', want handback"
echo "ok: all_cancelled"

setup notdone
seed 1 launched
run done "$L"
expect_rc "done_not_done" 1
echo "ok: done_not_done"

# ---------------------------------------------------------------- summary_table
setup summary
seed 1 verifying
run intent "$L" merge 1 "$H40" "$H41"
ev 1 gate merged "$(intent_id)" "tests: 12 passed | lint clean"
ev 2 drop "out of scope"
ev 0 cancel-ticket "user stopped"
run summary "$L"
expect_rc "summary_table" 0
row1="$(printf '%s\n' "$OUT" | grep '^| #1 |')"
row2="$(printf '%s\n' "$OUT" | grep '^| #2 |')"
row3="$(printf '%s\n' "$OUT" | grep '^| #3 |')"
case "$row1" in *"| merged |"*"test-x-1"*"$H40"*"tests: 12 passed \\| lint clean"*) ;; *) fail "summary_table: row 1 '$row1'" ;; esac
case "$row2" in *"| cancelled |"*"test-x-2"*"out of scope"*) ;; *) fail "summary_table: row 2 '$row2'" ;; esac
case "$row3" in *"| cancelled |"*"user stopped"*) ;; *) fail "summary_table: row 3 '$row3'" ;; esac
printf '%s\n' "$OUT" | head -1 | grep -q '^| Issue |' || fail "summary_table: no header"
echo "ok: summary_table"

# ---------------------------------------------------------------- resync_closes_intent
setup resync "[$(iss 1)]"
commit_on test-x-1 c1
CAND="$(g rev-parse test-x-1)"
PIN="$(g rev-parse tk)"
seed 1 verifying
run intent "$L" merge 1 "$CAND" "$PIN"
MI="$(intent_id)"
echo moved >"$R/moved"; g add moved; g commit -q -m moved
FOUT="$(cd "$R" && "$BASH" "$FFM" tk "$CAND" "$PIN")"
FRC=$?
[ "$FRC" -eq 10 ] || fail "resync_closes_intent: ff-merge rc $FRC, want 10"
HEADNOW="${FOUT#head=}"
ev 1 gate resync "$HEADNOW" "$MI"
expect_rc "resync_closes_intent gate resync" 0
expect_st "resync_closes_intent" 1 resync-requested
[ "$(jq -r --arg i "$MI" '.intents[] | select(.id == $i) | .open' "$L")" = false ] || fail "resync_closes_intent: merge intent still open"
[ "$(jq '[.intents[] | select(.open)] | length' "$L")" = 0 ] || fail "resync_closes_intent: an intent is still open for reconcile to replay"
[ "$(fld 1 resyncs)" = 1 ] || fail "resync_closes_intent: resyncs not 1"
expect_outbox "resync_closes_intent" "1${TAB}1${TAB}-${TAB}RESYNC #1 $HEADNOW"
# reconcile has no open intent to replay: the issue stays resync-requested and the RESYNC is resent.
run reconcile "$L" "$T/ag-coord.json"
expect_rc "resync_closes_intent reconcile" 0
expect_st "resync_closes_intent reconcile" 1 resync-requested
printf '%s\n' "$OUT" | grep -Fxq "resend 1 - RESYNC #1 $HEADNOW" || fail "resync_closes_intent: reconcile printed '$OUT'"
echo "ok: resync_closes_intent"

# ---------------------------------------------------------------- usage
setup usage
ev 1 no-such-event
expect_rc "usage unknown event" 2
ev 99 drop
expect_rc "usage unknown issue" 2
ev 1 queue-check stale not-a-sha
expect_rc "usage bad sha" 2
run init "$L" TEST tk TEST-coord sid-coord "$T/issues.json"
expect_rc "usage init over existing ledger" 2
echo "ok: usage"

# ---------------------------------------------------------------- no_stranded_status
# Seed each non-terminal status on issue 1, apply every event in the table to
# a fresh copy, and require that at least one applies (exit 0). `cancel-ticket`
# applies to every non-terminal status by definition, so it is left out: each
# status must have an exit of its own.
setup stranded "[$(iss 1),$(iss 2)]"
ev 1 canary-passed
commit_on test-x-1 s1
g merge -q --ff-only test-x-1
cp "$L" "$T/stranded-base.json"
# try_event <event args...> — restore the seeded snapshot, then apply.
try_event() {
  cat "$T/stranded-snap.json" >"$L"
  ev 1 "$@"
  [ "$RC" -eq 0 ] && ANY=1
}
for s in pending launched started "blocked-on #2" done-claimed verifying rework-1/3 resync-requested failed; do
  cat "$T/stranded-base.json" >"$L"
  case "$s" in "blocked-on #2") seed_blocked 1 2 ;; *) seed 1 "$s" ;; esac
  cp "$L" "$T/stranded-snap.json"
  ANY=0
  for kind in launch relaunch; do
    cat "$T/stranded-snap.json" >"$L"
    run intent "$L" "$kind" 1 TEST-1 "$T/wt" test-x-1 "$H40"
    if [ "$RC" -eq 0 ]; then
      id="$(intent_id)"; cp "$L" "$T/stranded-intent.json"
      cat "$T/stranded-intent.json" >"$L"; ev 1 "$kind" "$id" sid-x; [ "$RC" -eq 0 ] && ANY=1
      cat "$T/stranded-intent.json" >"$L"; ev 1 launch-failed "$id"; [ "$RC" -eq 0 ] && ANY=1
    fi
  done
  cat "$T/stranded-snap.json" >"$L"
  run intent "$L" merge 1 "$H40" "$H41"
  if [ "$RC" -eq 0 ]; then
    id="$(intent_id)"; cp "$L" "$T/stranded-intent.json"
    ev 1 gate merged "$id"; [ "$RC" -eq 0 ] && ANY=1
  fi
  try_event queue-check ok
  try_event queue-check stale "$H41"
  try_event gate resync "$H41"
  try_event gate fail evidence
  try_event stuck-accept 2
  try_event edge-remove
  try_event drop
  for o in failed stopped blocked done working; do try_event json "$o"; done
  try_event wake-failed
  try_event user-merged
  [ "$ANY" -eq 1 ] || fail "no_stranded_status: no event applies to '$s'"
done
echo "ok: no_stranded_status"

# ================================================================ write lock
# Every mutating call holds an OS lock (lockf/flock) on <dir>/write.lock, on its
# own fd, from before its owner check until it exits (supersedes rulings CX1 and
# T5-M2(a)). No lock-tool process outlives the acquisition.

# start_paused <tag> <args...> — ledger.sh <args> in the background with
# PS_WRITE_TEST_PAUSE=$T/pause-<tag>, waited for until it holds the write lock. Sets
# PW (the background subshell) and WPID (the paused ledger.sh's own $$).
# `touch "$T/pause-<tag>"` releases it; its rc lands in $T/pause-<tag>.rc.
start_paused() {
  tag="$1"; shift
  rm -f "$T/pause-$tag" "$T/pause-$tag.waiting" "$T/pause-$tag.rc"
  ( cd "$R" && PS_WRITE_TEST_PAUSE="$T/pause-$tag" "$BASH" "$LSH" "$@" >"$T/pause-$tag.out" 2>"$T/pause-$tag.err"
    echo $? >"$T/pause-$tag.rc" ) 2>/dev/null &
  PW=$!
  w=0
  while [ ! -s "$T/pause-$tag.waiting" ] && [ "$w" -lt 200 ]; do sleep 0.05; w=$((w + 1)); done
  WPID=""
  [ -s "$T/pause-$tag.waiting" ] && read -r WPID <"$T/pause-$tag.waiting"
  [ -n "$WPID" ] || fail "start_paused $tag: the writer never reached the pause ($(cat "$T/pause-$tag.err"))"
}
# lock_tools_under <pid> — pids of lockf/flock processes whose parent is <pid>.
lock_tools_under() {
  ps -A -o pid= -o ppid= -o comm= | awk -v p="$1" '
    $2 == p { c = $3; sub(/.*\//, "", c); if (c == "lockf" || c == "flock") print $1 }'
}

# ---------------------------------------------------------------- lock_released_on_kill9
setup k9
start_paused k9 event "$L" 1 canary-passed
[ -n "$WPID" ] && kill -9 "$WPID"
wait "$PW" 2>/dev/null
PS_WRITE_WAIT=2 ev 1 canary-passed
expect_rc "lock_released_on_kill9 next write" 0
jq -e 'type == "object"' "$L" >/dev/null || fail "lock_released_on_kill9: ledger not a JSON object"
[ "$(jq -r .canary "$L")" = passed ] || fail "lock_released_on_kill9: the next write did not land"
echo "ok: lock_released_on_kill9"

# ---------------------------------------------------------------- parallel_writers_no_lost_update
I12=""
i=1
while [ "$i" -le 12 ]; do I12="$I12${I12:+,}$(iss "$i")"; i=$((i + 1)); done
setup par "[$I12]"
pids=""
i=1
while [ "$i" -le 12 ]; do
  ( cd "$R" && PS_WRITE_WAIT=60 "$BASH" "$LSH" event "$L" "$i" drop "r$i" >/dev/null 2>"$T/par$i.err"
    echo $? >"$T/par$i.rc" ) &
  pids="$pids $!"
  i=$((i + 1))
done
for p in $pids; do wait "$p"; done
i=1
while [ "$i" -le 12 ]; do
  [ "$(cat "$T/par$i.rc")" = 0 ] || fail "parallel_writers_no_lost_update: #$i rc $(cat "$T/par$i.rc") ($(cat "$T/par$i.err"))"
  expect_st "parallel_writers_no_lost_update" "$i" cancelled
  i=$((i + 1))
done
LASTCMD="parallel drops"; assert_outbox_invariant "$L"
echo "ok: parallel_writers_no_lost_update"

# ---------------------------------------------------------------- busy_timeout_41
setup busy
start_paused busy event "$L" 1 canary-passed
cp "$L" "$T/busy-before.json"
lt="$(lock_tools_under "$WPID")"
[ -z "$lt" ] || fail "busy_timeout_41: a lock-tool process is alive under the writer ($lt)"
PS_WRITE_WAIT=1 ev 2 drop busy
expect_rc "busy_timeout_41" 41
[ "$OUT" = "busy=$(dirname "$L")/write.lock" ] || fail "busy_timeout_41: printed '$OUT'"
cmp -s "$L" "$T/busy-before.json" || fail "busy_timeout_41: the ledger changed"
touch "$T/pause-busy"
wait "$PW"
[ "$(cat "$T/pause-busy.rc")" = 0 ] || fail "busy_timeout_41: the paused writer rc $(cat "$T/pause-busy.rc") ($(cat "$T/pause-busy.err"))"
[ "$(jq -r .canary "$L")" = passed ] || fail "busy_timeout_41: the paused writer's write did not land"
grep -q 'busy event #2 drop' "$(dirname "$L")/ledger.log" || fail "busy_timeout_41: no busy line in ledger.log"
echo "ok: busy_timeout_41"

# ---------------------------------------------------------------- takeover_blocked_by_paused_writer
# A takeover of a dead holder waits for the holder's in-flight write: `lock`
# takes the write lock before it reads lock/holder.
mkrepo tkpw
run path TEST; L="$OUT"
agents "$T/ag-s1live.json" "S1=$$"
run lock "$L" S1 "$T/ag-s1live.json"
expect_rc "takeover_blocked_by_paused_writer S1 lock" 0
PS_OWNER="${OUT#owner=}"; export PS_OWNER
printf '%s\n' "$ISS3" >"$T/issues.json"
run init "$L" TEST tk TEST-coord S1 "$T/issues.json"
expect_rc "takeover_blocked_by_paused_writer init" 0
start_paused tkpw event "$L" 1 canary-passed
hold0="$(cat "$(dirname "$L")/lock/holder")"
agents "$T/ag-tkpw.json" "S1=$DEADPID" "S2=$$"
PS_WRITE_WAIT=1 run lock "$L" S2 "$T/ag-tkpw.json"
expect_rc "takeover_blocked_by_paused_writer blocked" 41
[ "$(cat "$(dirname "$L")/lock/holder")" = "$hold0" ] || fail "takeover_blocked_by_paused_writer: holder changed while the writer was paused"
touch "$T/pause-tkpw"
wait "$PW"
[ "$(cat "$T/pause-tkpw.rc")" = 0 ] || fail "takeover_blocked_by_paused_writer: the paused writer rc $(cat "$T/pause-tkpw.rc") ($(cat "$T/pause-tkpw.err"))"
[ "$(jq -r .canary "$L")" = passed ] || fail "takeover_blocked_by_paused_writer: the paused writer's write did not land"
run lock "$L" S2 "$T/ag-tkpw.json"
expect_rc "takeover_blocked_by_paused_writer takeover" 0
case "$(cat "$(dirname "$L")/lock/holder")" in
  "S2 "*) ;;
  *) fail "takeover_blocked_by_paused_writer: holder is not S2 ($(cat "$(dirname "$L")/lock/holder"))" ;;
esac
echo "ok: takeover_blocked_by_paused_writer"

# ---------------------------------------------------------------- lock_held_until_writer_exits
setup held
start_paused held event "$L" 1 canary-passed
for p in $(lock_tools_under "$WPID"); do kill -9 "$p" 2>/dev/null; done
PS_WRITE_WAIT=1 ev 2 drop held
expect_rc "lock_held_until_writer_exits" 41
touch "$T/pause-held"
wait "$PW"
[ "$(cat "$T/pause-held.rc")" = 0 ] || fail "lock_held_until_writer_exits: the paused writer rc $(cat "$T/pause-held.rc") ($(cat "$T/pause-held.err"))"
echo "ok: lock_held_until_writer_exits"

# ---------------------------------------------------------------- takeover_serialized
agents "$T/ag-race.json" "S1=$DEADPID" "S2=$$" "S3=$$"
# contend <sid> <prefix> <go-file> — wait for the barrier, then lock.
contend() {
  while [ ! -f "$3" ]; do sleep 0.05; done
  (cd "$R" && "$BASH" "$LSH" lock "$L" "$1" "$T/ag-race.json" >"$2.out" 2>"$2.err")
  echo $? >"$2.rc"
}
# check_race <name> — exactly one 0 and one 40; holder carries the winner's nonce.
check_race() {
  rc2="$(cat "$T/c2.rc")"; rc3="$(cat "$T/c3.rc")"
  win=""
  if [ "$rc2" = 0 ] && [ "$rc3" = 40 ]; then win=c2
  elif [ "$rc2" = 40 ] && [ "$rc3" = 0 ]; then win=c3
  else fail "$1: expected one 0 and one 40, got S2=$rc2 S3=$rc3 ($(cat "$T/c2.err" "$T/c3.err"))"; return
  fi
  tok="$(cat "$T/$win.out")"; tok="${tok#owner=}"
  hold="$(cat "$(dirname "$L")/lock/holder")"
  [ "$hold" = "${tok%%:*} ${tok#*:}" ] || fail "$1: holder '$hold' is not the winner's token '$tok'"
}
i=1
while [ "$i" -le 5 ]; do
  mkrepo "race$i"
  run path TEST; L="$OUT"
  run lock "$L" S1 "$T/ag-s1.json"
  rm -f "$T/go" "$T"/c2.* "$T"/c3.*
  contend S2 "$T/c2" "$T/go" &
  p2=$!
  contend S3 "$T/c3" "$T/go" &
  p3=$!
  touch "$T/go"
  wait "$p2"; wait "$p3"
  check_race "takeover_serialized race $i"
  i=$((i + 1))
done
echo "ok: takeover_serialized"

# ---------------------------------------------------------------- lost_owner_refused
setup lostown
agents "$T/ag-lo.json" "sid-coord=$DEADPID" "S2=$$"
OLDTOK="$PS_OWNER"
run lock "$L" S2 "$T/ag-lo.json"
expect_rc "lost_owner_refused takeover" 0
cp "$L" "$T/lo-before.json"
PS_OWNER="$OLDTOK" ev 1 canary-passed
expect_rc "lost_owner_refused write" 40
printf '%s\n' "$OUT" | grep -qx 'holder=S2' || fail "lost_owner_refused: expected holder=S2, got '$OUT'"
cmp -s "$L" "$T/lo-before.json" || fail "lost_owner_refused: ledger changed"
echo "ok: lost_owner_refused"

# ---------------------------------------------------------------- legacy_lock_dirs_ignored
# A lock/write/ or takeover/ left by the mkdir mutex is removed by the next
# `lock`, even on the own-holder path.
setup legacy
mkdir -p "$(dirname "$L")/lock/write" "$(dirname "$L")/takeover"
echo 1 >"$(dirname "$L")/lock/write/pid"
echo S3 >"$(dirname "$L")/takeover/owner"
run lock "$L" sid-coord "$T/ag-coord.json"
expect_rc "legacy_lock_dirs_ignored" 0
[ "$OUT" = "owner=$PS_OWNER" ] || fail "legacy_lock_dirs_ignored: printed '$OUT', want owner=$PS_OWNER"
[ ! -e "$(dirname "$L")/lock/write" ] || fail "legacy_lock_dirs_ignored: lock/write left"
[ ! -e "$(dirname "$L")/takeover" ] || fail "legacy_lock_dirs_ignored: takeover left"
grep -q 'legacy-lock-dir-removed' "$(dirname "$L")/ledger.log" || fail "legacy_lock_dirs_ignored: no legacy-lock-dir-removed in ledger.log"
ev 1 canary-passed
expect_rc "legacy_lock_dirs_ignored write after" 0
echo "ok: legacy_lock_dirs_ignored"

# ---------------------------------------------------------------- no_lock_tool_refused
# Neither /usr/bin/lockf nor flock reachable: a mutating call refuses (exit 2).
setup nolock
mkdir -p "$T/stubbin"
for tool in jq git bash dirname; do
  tp="$(command -v "$tool")" && ln -sf "$tp" "$T/stubbin/$tool"
done
cp "$L" "$T/nolock-before.json"
OUT="$(cd "$R" && PATH="$T/stubbin" PS_LOCKF=/nonexistent "$BASH" "$LSH" event "$L" 1 canary-passed 2>"$T/err")"
RC=$?
ERR="$(cat "$T/err")"
expect_rc "no_lock_tool_refused" 2
case "$ERR" in *"lock tool"*) ;; *) fail "no_lock_tool_refused: stderr '$ERR' does not name the lock tool" ;; esac
cmp -s "$L" "$T/nolock-before.json" || fail "no_lock_tool_refused: ledger changed"
echo "ok: no_lock_tool_refused"

# ---------------------------------------------------------------- init_blockers_in_set
mkrepo initv
run path TEST; L="$OUT"
run lock "$L" sid-coord "$T/ag-coord.json"
PS_OWNER="${OUT#owner=}"; export PS_OWNER
printf '[%s,%s]\n' "$(iss 1)" "$(iss 2 '[5]')" >"$T/issues.json"
run init "$L" TEST tk TEST-coord sid-coord "$T/issues.json"
expect_rc "init_blockers_in_set unknown blocker" 2
[ ! -e "$L" ] || fail "init_blockers_in_set: ledger written for an unknown blocker"
printf '[%s,{"n":2,"blockers":[1],"external":[{"n":5,"closed":true}],"branch":"test-x-2","testCmd":"true","ac":[]}]\n' \
  "$(iss 1)" >"$T/issues.json"
run init "$L" TEST tk TEST-coord sid-coord "$T/issues.json"
expect_rc "init_blockers_in_set external blocker" 0
echo "ok: init_blockers_in_set"

# ---------------------------------------------------------------- drop_cancel_close_intents
intent_open() { jq -r --arg i "$1" '.intents[] | select(.id == $i) | "\(.open) \(.outcome // "")"' "$L"; }
setup dci
run intent "$L" launch 1 TEST-1 "$T/wt-1" test-x-1 "$H40"
I1="$(intent_id)"
ev 1 drop
expect_rc "drop_cancel_close_intents drop" 0
[ "$(intent_open "$I1")" = "false cancelled" ] || fail "drop_cancel_close_intents: drop left launch intent '$(intent_open "$I1")'"
seed 2 failed
run intent "$L" relaunch 2 TEST-2 "$T/wt-2" test-x-2 "$H40"
I2="$(intent_id)"
ev 2 drop
[ "$(intent_open "$I2")" = "false cancelled" ] || fail "drop_cancel_close_intents: drop left relaunch intent '$(intent_open "$I2")'"
setup dci2
ev 1 canary-passed
run intent "$L" launch 1 TEST-1 "$T/wt-1" test-x-1 "$H40"
I1="$(intent_id)"
seed 2 verifying
run intent "$L" merge 2 "$H40" "$H41"
I2="$(intent_id)"
ev 0 cancel-ticket
expect_rc "drop_cancel_close_intents cancel-ticket" 0
[ "$(intent_open "$I1")" = "false cancelled" ] || fail "drop_cancel_close_intents: cancel-ticket left launch intent '$(intent_open "$I1")'"
[ "$(intent_open "$I2")" = "false cancelled" ] || fail "drop_cancel_close_intents: cancel-ticket left merge intent '$(intent_open "$I2")'"
echo "ok: drop_cancel_close_intents"

# ---------------------------------------------------------------- rework_resets_per_generation
setup rework-gen "[$(iss 1),$(iss 2)]"
ev 1 canary-passed
seed 1 rework-2/3
jset '.issues[$n].rework = 2' --arg n 1
ev 1 stuck-accept 2
expect_rc "rework_resets_per_generation stuck-accept" 0
expect_st "rework_resets_per_generation blocked" 1 "blocked-on #2"
seed 2 verifying
run intent "$L" merge 2 "$H40" "$H41"
ev 2 gate merged "$(intent_id)"
expect_rc "rework_resets_per_generation gate merged" 0
expect_st "rework_resets_per_generation pending" 1 pending
run intent "$L" launch 1 TEST-1 "$T/wt-1c" test-x-1-g2 "$H40"
expect_rc "rework_resets_per_generation intent" 0
ev 1 launch "$(intent_id)" sid-1c
expect_rc "rework_resets_per_generation launch" 0
[ "$(fld 1 rework)" = 0 ] || fail "rework_resets_per_generation: rework '$(fld 1 rework)' after a fresh launch, want 0"
for k in 1 2; do
  seed 1 verifying
  ev 1 gate fail "fail $k"
  expect_rc "rework_resets_per_generation fail $k" 0
  expect_st "rework_resets_per_generation fail $k" 1 "rework-$k/3"
done
seed 1 verifying
ev 1 gate fail "fail 3"
expect_st "rework_resets_per_generation third" 1 failed
echo "ok: rework_resets_per_generation"

# ---------------------------------------------------------------- edge_remove_pending
# A pending dependent of a dropped issue can have that edge removed (stays
# pending); blocked-on accepts no <m> or its own m only.
setup edgepend "[$(iss 1),$(iss 2 '[1]'),$(iss 3 '[1]')]"
ev 1 drop "out of scope"
expect_rc "edge_remove_pending drop" 0
ev 2 edge-remove 1
expect_rc "edge_remove_pending pending" 0
expect_out_line() { printf '%s\n' "$OUT" | grep -qx "$2" || fail "$1: expected line '$2', got '$OUT'"; }
expect_out_line "edge_remove_pending pending" pending
expect_st "edge_remove_pending pending" 2 pending
[ "$(jq -c '.issues["2"].blockers' "$L")" = "[]" ] || fail "edge_remove_pending: edge 2->1 not removed"
ev 2 edge-remove 1
expect_rc "edge_remove_pending repeat" 10
ev 3 edge-remove
expect_rc "edge_remove_pending bare on pending" 30
ev 3 edge-remove x
expect_rc "edge_remove_pending bad m" 2
seed_blocked 3 1
ev 3 edge-remove 2
expect_rc "edge_remove_pending blocked-on other m" 30
expect_st "edge_remove_pending blocked-on other m" 3 "blocked-on #1"
ev 3 edge-remove 1
expect_rc "edge_remove_pending blocked-on own m" 0
expect_st "edge_remove_pending blocked-on own m" 3 pending
[ "$(jq -c '.issues["3"].blockers' "$L")" = "[]" ] || fail "edge_remove_pending: edge 3->1 not removed"
echo "ok: edge_remove_pending"

# ================================================================ message, session, reconcile
KISS="[$(iss 9),$(iss 12),$(iss 13)]"
H42="3333333333333333333333333333333333333333"
# ksetup <name> [issues-json] — repo + ledger for key K (issues 9, 12, 13), canary passed.
ksetup() {
  mkrepo "$1"
  run path K; L="$OUT"
  run lock "$L" sid-coord "$T/ag-coord.json"
  PS_OWNER="${OUT#owner=}"; export PS_OWNER
  printf '%s\n' "${2:-$KISS}" >"$T/issues.json"
  run init "$L" K tk K-coord sid-coord "$T/issues.json"
  [ "$RC" -eq 0 ] || fail "ksetup $1: init rc $RC ($ERR)"
  ev 9 canary-passed
}
# klaunch <n> [sid] — launch #n as session K-<n> on branch test-x-<n>.
klaunch() {
  run intent "$L" launch "$1" "K-$1" "$T/wt-$1" "test-x-$1" "$H40"
  [ "$RC" -eq 0 ] || { fail "klaunch $1: intent rc $RC ($ERR)"; return; }
  ev "$1" launch "$(intent_id)" "${2:-sid-$1}"
  [ "$RC" -eq 0 ] || fail "klaunch $1: event rc $RC ($ERR)"
}
# krelaunch <n> <sid> — failed, then relaunch as K-<n> (next gen), same branch.
krelaunch() {
  seed "$1" failed
  run intent "$L" relaunch "$1" "K-$1" "$T/wt-$1-r" "test-x-$1" "$H40"
  [ "$RC" -eq 0 ] || { fail "krelaunch $1: intent rc $RC ($ERR)"; return; }
  ev "$1" relaunch "$(intent_id)" "$2"
  [ "$RC" -eq 0 ] || fail "krelaunch $1: event rc $RC ($ERR)"
}
frame() { printf '<cross-session-message from="%s">%s</cross-session-message>' "$1" "$2"; }
# msg <from> <body> — `ledger.sh message` with a well-formed frame.
msg() { run message "$L" "$(frame "$1" "$2")"; }
# kag <file> <name>:<sid>:<state>[:<pid>] ... — a `claude agents --json --all` fixture.
kag() {
  f="$1"; shift
  body=""
  for a in "$@"; do
    nm="${a%%:*}"; rest="${a#*:}"; sid="${rest%%:*}"; rest="${rest#*:}"
    stt="${rest%%:*}"; pid=""
    case "$rest" in *:*) pid="${rest#*:}" ;; esac
    if [ -n "$pid" ]; then
      row="{\"sessionId\":\"$sid\",\"name\":\"$nm\",\"pid\":$pid,\"state\":\"$stt\"}"
    else
      row="{\"sessionId\":\"$sid\",\"name\":\"$nm\",\"state\":\"$stt\"}"
    fi
    if [ -z "$body" ]; then body="$row"; else body="$body,$row"; fi
  done
  printf '[%s]\n' "$body" >"$f"
}
has_line() { printf '%s\n' "$OUT" | grep -Fxq "$1"; }
expect_line() { # <name> <exact line>
  has_line "$2" || fail "$1: output lacks '$2' (got '$OUT')"
}
expect_no_line_prefix() { # <name> <prefix>
  printf '%s\n' "$OUT" | grep -Fq "$2" && fail "$1: output has '$2' (got '$OUT')"
}
expect_rejected() { # <name>
  expect_rc "$1" 20
  case "$OUT" in reason=?*) ;; *) fail "$1: expected reason= on stdout, got '$OUT'" ;; esac
}
DONE12="DONE #12 gen=1 test-x-12 $H40 synced=$H41"
printf '[]\n' >"$T/ag-empty.json"

# ---------------------------------------------------------------- bind_other_issue
ksetup bind
klaunch 12
klaunch 13
cp "$L" "$T/bind-before.json"
msg K-13 "STARTED #12 gen=1"
expect_rejected "bind_other_issue"
expect_st "bind_other_issue" 12 launched
cmp -s "$L" "$T/bind-before.json" || fail "bind_other_issue: ledger changed"
grep -q 'rejected' "$(dirname "$L")/ledger.log" || fail "bind_other_issue: no 'rejected' in ledger.log"
echo "ok: bind_other_issue"

# ---------------------------------------------------------------- bind_near_match
for f in k-12 "K-12 " K-1 sid-12 K-12x; do
  msg "$f" "STARTED #12 gen=1"
  expect_rejected "bind_near_match '$f'"
done
cmp -s "$L" "$T/bind-before.json" || fail "bind_near_match: ledger changed"
echo "ok: bind_near_match"

# ---------------------------------------------------------------- bind_wrong_frame
run message "$L" '<agent-message from="K-12">STARTED #12 gen=1</agent-message>'
expect_rejected "bind_wrong_frame"
run message "$L" "STARTED #12 gen=1"
expect_rejected "bind_wrong_frame bare line"
cmp -s "$L" "$T/bind-before.json" || fail "bind_wrong_frame: ledger changed"
echo "ok: bind_wrong_frame"

# ---------------------------------------------------------------- bind_branch_mismatch
msg K-12 "DONE #12 gen=1 test-x-13 $H40 synced=$H41"
expect_rejected "bind_branch_mismatch"
expect_st "bind_branch_mismatch" 12 launched
echo "ok: bind_branch_mismatch"

# ---------------------------------------------------------------- frame_fixture
run message "$L" '<cross-session-message from="K-12">STARTED #12 gen=1</cross-session-message>'
expect_rc "frame_fixture" 0
expect_st "frame_fixture" 12 started
echo "ok: frame_fixture"

# ---------------------------------------------------------------- started_transition / same_state_noop
ksetup started
klaunch 12
msg K-12 "STARTED #12 gen=1"
expect_rc "started_transition" 0
[ "$OUT" = started ] || fail "started_transition: printed '$OUT'"
[ "$(st 12)" = started ] || fail "started_transition: status '$(st 12)', want started"
echo "ok: started_transition"
cp "$L" "$T/same-before.json"
msg K-12 "STARTED #12 gen=1"
expect_rc "same_state_noop" 10
cmp -s "$L" "$T/same-before.json" || fail "same_state_noop: ledger changed"
echo "ok: same_state_noop"

# ---------------------------------------------------------------- bind_old_gen
krelaunch 12 sid-12b
[ "$(fld 12 gen)" = 2 ] || fail "bind_old_gen: gen not 2"
msg K-12 "STARTED #12 gen=1"
expect_rejected "bind_old_gen"
expect_st "bind_old_gen" 12 launched
msg K-12 "STARTED #12 gen=2"
expect_rc "bind_old_gen current gen" 0
echo "ok: bind_old_gen"

# ---------------------------------------------------------------- wake_rebinds_name
ksetup wake
klaunch 12
run session "$L" 12 K-12b sid-9
expect_rc "wake_rebinds_name session" 0
[ "$(fld 12 sessionName)" = K-12b ] || fail "wake_rebinds_name: name not recorded"
[ "$(fld 12 sessionId)" = sid-9 ] || fail "wake_rebinds_name: sessionId not recorded"
[ "$(fld 12 gen)" = 1 ] || fail "wake_rebinds_name: gen changed"
expect_st "wake_rebinds_name" 12 launched
run session "$L" 12 K-12b sid-9
expect_rc "wake_rebinds_name unchanged" 10
msg K-12 "STARTED #12 gen=1"
expect_rejected "wake_rebinds_name old name"
msg K-12b "STARTED #12 gen=1"
expect_rc "wake_rebinds_name new name" 0
[ "$(fld 12 gen)" = 1 ] || fail "wake_rebinds_name: gen changed by message"
run session "$L" 9 K-9 sid-x
expect_rc "wake_rebinds_name never launched" 30
echo "ok: wake_rebinds_name"

# ---------------------------------------------------------------- done_persisted / done_dedup
ksetup done
klaunch 12
msg K-12 "$DONE12"
expect_rc "done_persisted" 0
expect_line "done_persisted" "queue=12"
run get "$L" 12
printf '%s' "$OUT" | jq -e --arg s "$H40" --arg h "$H41" \
  '.status == "done-claimed" and .claim.sha == $s and .claim.gen == 1 and .claim.branch == "test-x-12"
   and .claim.synced == $h and (.claim.claimSeq | type == "number")' >/dev/null \
  || fail "done_persisted: claim not in get output ($OUT)"
echo "ok: done_persisted"
cp "$L" "$T/dedup-before.json"
msg K-12 "$DONE12"
expect_rc "done_dedup" 10
cmp -s "$L" "$T/dedup-before.json" || fail "done_dedup: ledger changed"
echo "ok: done_dedup"

# ---------------------------------------------------------------- stale_done_free
ev 12 queue-check stale "$H41"
expect_rc "stale_done_free" 0
[ "$(fld 12 rework)" = 0 ] || fail "stale_done_free: rework count '$(fld 12 rework)'"
echo "ok: stale_done_free"

# ---------------------------------------------------------------- stuck_merged_resync
ksetup stuckm
klaunch 12
seed 9 merged
TKHEAD="$(g rev-parse tk)"
msg K-12 "STUCK #12 gen=1 needs=#9 need the parser"
expect_rc "stuck_merged_resync" 0
expect_st "stuck_merged_resync" 12 resync-requested
expect_outbox "stuck_merged_resync" "12${TAB}1${TAB}K-12${TAB}RESYNC #12 $TKHEAD"
# Unmerged #13: ask the user about the edge, status unchanged.
seed 12 started
msg K-12 "STUCK #12 gen=1 needs=#13 need the model"
expect_rc "stuck_unmerged_edge" 0
expect_line "stuck_unmerged_edge" "ask-user=edge 12 13"
expect_st "stuck_unmerged_edge" 12 started
echo "ok: stuck_merged_resync"

# ---------------------------------------------------------------- stuck_from_rework
ksetup stuckr
klaunch 12
cp "$L" "$T/stuckr-base.json"
for s in launched started rework-1/3 resync-requested; do
  for body in "STUCK #12 gen=1 cannot reach the db" "SCOPE #12 gen=1 this is two issues"; do
    cat "$T/stuckr-base.json" >"$L"
    seed 12 "$s"
    msg K-12 "$body"
    [ "$RC" -eq 0 ] || fail "stuck_from_rework $s '$body': rc $RC, want exactly 0 ($ERR)"
    case "$OUT" in *ask-user=*) ;; *) fail "stuck_from_rework $s: no ask-user= ('$OUT')" ;; esac
    expect_st "stuck_from_rework $s" 12 "$s"
  done
done
echo "ok: stuck_from_rework"

# ---------------------------------------------------------------- stuck_on_claimed
for s in done-claimed verifying; do
  cat "$T/stuckr-base.json" >"$L"
  seed 12 "$s"
  for body in "STUCK #12 gen=1 cannot reach the db" "SCOPE #12 gen=1 too big" "STUCK #12 gen=1 needs=#13 model"; do
    msg K-12 "$body"
    expect_rc "stuck_on_claimed $s '$body'" 10
    case "$OUT" in *ask-user=*) ;; *) fail "stuck_on_claimed $s: no ask-user= ('$OUT')" ;; esac
    expect_st "stuck_on_claimed $s" 12 "$s"
  done
done
echo "ok: stuck_on_claimed"

# ---------------------------------------------------------------- message_failed_rows
for s in launched started rework-1/3 done-claimed verifying; do
  cat "$T/stuckr-base.json" >"$L"
  seed 12 "$s"
  msg K-12 "FAILED #12 gen=1 cannot build"
  expect_rc "message_failed_rows $s" 0
  expect_st "message_failed_rows $s" 12 failed
done
msg K-12 "FAILED #12 gen=1 cannot build"
expect_rc "message_failed_rows repeat" 10
echo "ok: message_failed_rows"

# ---------------------------------------------------------------- outbox_cleared
ksetup outbox
klaunch 12
krelaunch 12 sid-12b
msg K-12 "DONE #12 gen=2 test-x-12 $H40 synced=$H41"
expect_rc "outbox_cleared DONE gen 2" 0
ev 12 queue-check stale "$H42"
expect_outbox "outbox_cleared" "12${TAB}2${TAB}K-12${TAB}RESYNC #12 $H42"
# Ruling CX4: a STARTED never clears an outstanding RESYNC or REWORK.
msg K-12 "STARTED #12 gen=2"
expect_rc "outbox_cleared STARTED" 10
expect_st "outbox_cleared" 12 resync-requested
expect_outbox "outbox_cleared STARTED keeps RESYNC" "12${TAB}2${TAB}K-12${TAB}RESYNC #12 $H42"
# Only the next DONE (or FAILED) does.
msg K-12 "DONE #12 gen=2 test-x-12 $H42 synced=$H42"
expect_rc "outbox_cleared DONE" 0
run outbox "$L"
[ -z "$OUT" ] || fail "outbox_cleared: DONE did not clear the outbox ('$OUT')"
# REWORK: STARTED and a STUCK keep it; FAILED clears it.
ev 12 queue-check ok
ev 12 gate fail "unit: 1 of 3"
expect_outbox "outbox_cleared REWORK" "12${TAB}2${TAB}K-12${TAB}REWORK #12 unit: 1 of 3"
msg K-12 "STARTED #12 gen=2"
expect_rc "outbox_cleared STARTED on rework" 10
expect_outbox "outbox_cleared STARTED keeps REWORK" "12${TAB}2${TAB}K-12${TAB}REWORK #12 unit: 1 of 3"
msg K-12 "STUCK #12 gen=2 cannot reach the db"
expect_rc "outbox_cleared STUCK on rework" 0
expect_outbox "outbox_cleared STUCK keeps REWORK" "12${TAB}2${TAB}K-12${TAB}REWORK #12 unit: 1 of 3"
msg K-12 "FAILED #12 gen=2 gave up"
expect_rc "outbox_cleared FAILED" 0
run outbox "$L"
[ -z "$OUT" ] || fail "outbox_cleared: FAILED did not clear the outbox ('$OUT')"
echo "ok: outbox_cleared"

# ---------------------------------------------------------------- requeue_order
ksetup requeue
klaunch 9
klaunch 12
kag "$T/ag-rq.json" "K-9:sid-9:working" "K-12:sid-12:working"
msg K-12 "$DONE12"
msg K-9 "DONE #9 gen=1 test-x-9 $H40 synced=$H41"
run reconcile "$L" "$T/ag-rq.json"
expect_rc "requeue_order" 0
rq="$(printf '%s\n' "$OUT" | grep '^requeue ' | tr '\n' ' ')"
[ "$rq" = "requeue 12 requeue 9 " ] || fail "requeue_order: got '$rq', want claim order 12 then 9"
echo "ok: requeue_order"

# ---------------------------------------------------------------- reconcile_stale_same_name_row
ksetup stale-row
klaunch 12
seed 12 failed
run intent "$L" relaunch 12 K-12 "$T/wt-12-r" test-x-12 "$H40"
kag "$T/ag-stale.json" "K-12:sid-12:done"
run reconcile "$L" "$T/ag-stale.json"
expect_rc "reconcile_stale_same_name_row" 0
expect_st "reconcile_stale_same_name_row" 12 failed
[ "$(fld 12 gen)" = 1 ] || fail "reconcile_stale_same_name_row: gen changed to $(fld 12 gen)"
[ "$(jq '[.intents[] | select(.open)] | length' "$L")" = 0 ] || fail "reconcile_stale_same_name_row: intent left open"
# Alive variant: `--resume <id>` keeps the sessionId, so a same-sid row WITH a
# pid is the relaunch (ruling T6-R3); only pid-less earlier rows are excluded.
ksetup stale-row-alive
klaunch 12
seed 12 failed
run intent "$L" relaunch 12 K-12 "$T/wt-12-r" test-x-12 "$H40"
expect_rc "reconcile_stale_same_name_row alive intent" 0
kag "$T/ag-stale.json" "K-12:sid-12:working:$$"
run reconcile "$L" "$T/ag-stale.json"
expect_rc "reconcile_stale_same_name_row alive" 0
expect_st "reconcile_stale_same_name_row alive" 12 launched
[ "$(fld 12 gen)" = 2 ] || fail "reconcile_stale_same_name_row alive: gen '$(fld 12 gen)', want 2"
[ "$(fld 12 sessionId)" = sid-12 ] || fail "reconcile_stale_same_name_row alive: sessionId '$(fld 12 sessionId)'"
echo "ok: reconcile_stale_same_name_row"

# ---------------------------------------------------------------- cancel_cleared_when_gone
ksetup cancel-gone
klaunch 12
ev 12 stuck-accept 9
expect_rc "cancel_cleared_when_gone stuck-accept" 0
cp "$L" "$T/cg-base.json"
kag "$T/ag-cg.json" "K-13:sid-13:working"
run reconcile "$L" "$T/ag-cg.json"
expect_rc "cancel_cleared_when_gone absent" 0
expect_no_line_prefix "cancel_cleared_when_gone absent" "resend 12"
run get "$L"
printf '%s' "$OUT" | jq -e '.outbox == []' >/dev/null || fail "cancel_cleared_when_gone: outbox not empty"
for gone in stopped done failed; do
  cat "$T/cg-base.json" >"$L"
  kag "$T/ag-cg.json" "K-12:sid-12:$gone"
  run reconcile "$L" "$T/ag-cg.json"
  expect_no_line_prefix "cancel_cleared_when_gone $gone" "resend 12"
done
# Ended = row absent or no pid (ruling T6-C1): a `done` row with a pid is an
# idle live session and keeps its CANCEL; a `working` row without a pid has ended.
cat "$T/cg-base.json" >"$L"
kag "$T/ag-cg.json" "K-12:sid-12:done:$$"
run reconcile "$L" "$T/ag-cg.json"
expect_line "cancel_cleared_when_gone done with pid" "resend 12 K-12 CANCEL #12"
cat "$T/cg-base.json" >"$L"
kag "$T/ag-cg.json" "K-12:sid-12:working"
run reconcile "$L" "$T/ag-cg.json"
expect_no_line_prefix "cancel_cleared_when_gone working without pid" "resend 12"
cat "$T/cg-base.json" >"$L"
ev 12 json stopped
expect_rc "cancel_cleared_when_gone json stopped" 0
run outbox "$L"
[ -z "$OUT" ] || fail "cancel_cleared_when_gone: json stopped left '$OUT'"
# `json done` alone may be an idle live row: the CANCEL stays; `json done nopid` drops it.
cat "$T/cg-base.json" >"$L"
ev 12 json done
expect_rc "cancel_cleared_when_gone json done with pid" 10
expect_outbox "cancel_cleared_when_gone json done with pid" "12${TAB}1${TAB}K-12${TAB}CANCEL #12"
ev 12 json done nopid
expect_rc "cancel_cleared_when_gone json done nopid" 0
run outbox "$L"
[ -z "$OUT" ] || fail "cancel_cleared_when_gone: json done nopid left '$OUT'"
# A woken (rebound) partner inherits the pending CANCEL addressed to its old name.
cat "$T/cg-base.json" >"$L"
run session "$L" 12 K-12w sid-12w
expect_rc "cancel_cleared_when_gone session rebind" 0
expect_outbox "cancel_cleared_when_gone session rebind" "12${TAB}1${TAB}K-12w${TAB}CANCEL #12"
cat "$T/cg-base.json" >"$L"
kag "$T/ag-cg.json" "K-12:sid-12:working:$$"
run reconcile "$L" "$T/ag-cg.json"
expect_line "cancel_cleared_when_gone working" "resend 12 K-12 CANCEL #12"
expect_outbox "cancel_cleared_when_gone working" "12${TAB}1${TAB}K-12${TAB}CANCEL #12"
echo "ok: cancel_cleared_when_gone"

# ---------------------------------------------------------------- crash after a transition (outbox in the same write)
kag "$T/ag-all.json" "K-9:sid-9:working:$$" "K-12:sid-12:working:$$" "K-13:sid-13:working:$$"
ksetup crash-stale
klaunch 12
msg K-12 "$DONE12"
ev 12 queue-check stale "$H41"
run reconcile "$L" "$T/ag-all.json"
expect_line "crash_after_queue_stale" "resend 12 K-12 RESYNC #12 $H41"
echo "ok: crash_after_queue_stale"

ksetup crash-resync
klaunch 12
seed 12 verifying
ev 12 gate resync "$H41"
run reconcile "$L" "$T/ag-all.json"
expect_line "crash_after_gate_resync" "resend 12 K-12 RESYNC #12 $H41"
echo "ok: crash_after_gate_resync"

ksetup crash-fail
klaunch 12
seed 12 verifying
ev 12 gate fail "unit tests: 2 of 5 fail in parser_test"
run reconcile "$L" "$T/ag-all.json"
expect_line "crash_after_gate_fail" "resend 12 K-12 REWORK #12 unit tests: 2 of 5 fail in parser_test"
echo "ok: crash_after_gate_fail"

ksetup crash-stuck
klaunch 12
ev 12 stuck-accept 9
run reconcile "$L" "$T/ag-all.json"
expect_line "crash_after_stuck_accept" "resend 12 K-12 CANCEL #12"
echo "ok: crash_after_stuck_accept"

ksetup crash-cancel
klaunch 9
klaunch 12
ev 0 cancel-ticket
run reconcile "$L" "$T/ag-all.json"
expect_line "crash_after_cancel_ticket 9" "resend 9 K-9 CANCEL #9"
expect_line "crash_after_cancel_ticket 12" "resend 12 K-12 CANCEL #12"
n="$(printf '%s\n' "$OUT" | grep -c '^resend ')"
[ "$n" = 2 ] || fail "crash_after_cancel_ticket: $n resend lines, want 2 ('$OUT')"
echo "ok: crash_after_cancel_ticket"

# ---------------------------------------------------------------- crash at intents
ksetup crash-li
run intent "$L" launch 12 K-12 "$T/wt-12" test-x-12 "$H40"
expect_rc "crash_after_launch_intent intent" 0
LI="$(intent_id)"
run reconcile "$L" "$T/ag-empty.json"
expect_rc "crash_after_launch_intent" 0
expect_st "crash_after_launch_intent" 12 pending
[ "$(jq '[.intents[] | select(.open)] | length' "$L")" = 0 ] || fail "crash_after_launch_intent: intent left open"
[ "$(intent_open "$LI")" = "false launch-failed" ] || fail "crash_after_launch_intent: intent outcome '$(intent_open "$LI")'"
echo "ok: crash_after_launch_intent"

ksetup crash-ri
klaunch 12
jset '.issues["12"].rework = 2'
seed 12 failed
run intent "$L" relaunch 12 K-12 "$T/wt-12-r" test-x-12 "$H40"
expect_rc "crash_after_relaunch_intent intent" 0
RI="$(intent_id)"
cp "$L" "$T/ri-base.json"
run reconcile "$L" "$T/ag-empty.json"
expect_rc "crash_after_relaunch_intent absent" 0
expect_st "crash_after_relaunch_intent absent" 12 failed
[ "$(fld 12 gen)" = 1 ] || fail "crash_after_relaunch_intent absent: gen changed"
[ "$(jq '[.intents[] | select(.open)] | length' "$L")" = 0 ] || fail "crash_after_relaunch_intent absent: intent left open"
[ "$(intent_open "$RI")" = "false launch-failed" ] || fail "crash_after_relaunch_intent absent: intent outcome '$(intent_open "$RI")'"
cat "$T/ri-base.json" >"$L"
kag "$T/ag-ri.json" "K-12:sid-12:done" "K-12:sid-12n:working:$$"
run reconcile "$L" "$T/ag-ri.json"
expect_st "crash_after_relaunch_intent present" 12 launched
[ "$(fld 12 gen)" = 2 ] || fail "crash_after_relaunch_intent present: gen '$(fld 12 gen)', want 2"
[ "$(fld 12 rework)" = 0 ] || fail "crash_after_relaunch_intent present: rework not reset"
[ "$(fld 12 sessionId)" = sid-12n ] || fail "crash_after_relaunch_intent present: sessionId '$(fld 12 sessionId)'"
[ "$(jq '[.intents[] | select(.open)] | length' "$L")" = 0 ] || fail "crash_after_relaunch_intent present: intent left open"
expect_line "crash_after_relaunch_intent present status" "status 12"
# Same sessionId, alive: `--resume <id>` keeps the ID (ruling T6-R3).
cat "$T/ri-base.json" >"$L"
kag "$T/ag-ri.json" "K-12:sid-12:working:$$"
run reconcile "$L" "$T/ag-ri.json"
expect_rc "crash_after_relaunch_intent same sid" 0
expect_st "crash_after_relaunch_intent same sid" 12 launched
[ "$(fld 12 gen)" = 2 ] || fail "crash_after_relaunch_intent same sid: gen '$(fld 12 gen)', want 2"
[ "$(fld 12 rework)" = 0 ] || fail "crash_after_relaunch_intent same sid: rework not reset"
[ "$(intent_open "$RI")" = "false launched" ] || fail "crash_after_relaunch_intent same sid: intent outcome '$(intent_open "$RI")'"
echo "ok: crash_after_relaunch_intent"

# ---------------------------------------------------------------- relaunch_prior_pid
# Ruling CX2: `intent relaunch ... <agents.json>` records the pid of the issue's
# session at intent time; reconcile accepts a same-name alive row as the
# relaunch only if its pid differs from it.
ipid() { jq -c --arg i "$1" '.intents[] | select(.id == $i) | .priorPid' "$L"; }
ksetup rpp
klaunch 12
seed 12 failed
kag "$T/ag-rpp-old.json" "K-12:sid-12:working:4242" "K-9:sid-9:working:4343"
run intent "$L" relaunch 12 K-12 "$T/wt-12-r" test-x-12 "$H40" "$T/ag-rpp-old.json"
expect_rc "relaunch_prior_pid intent" 0
RP="$(intent_id)"
[ "$(ipid "$RP")" = 4242 ] || fail "relaunch_prior_pid: priorPid '$(ipid "$RP")', want 4242"
cp "$L" "$T/rpp-base.json"
# The same process is still the only alive K-12 row: not a relaunch.
run reconcile "$L" "$T/ag-rpp-old.json"
expect_rc "relaunch_prior_pid same pid" 0
expect_st "relaunch_prior_pid same pid" 12 failed
[ "$(fld 12 gen)" = 1 ] || fail "relaunch_prior_pid same pid: gen '$(fld 12 gen)', want 1"
[ "$(intent_open "$RP")" = "false launch-failed" ] || fail "relaunch_prior_pid same pid: intent '$(intent_open "$RP")'"
# A new process (same sessionId, as --resume keeps it): the relaunch.
cat "$T/rpp-base.json" >"$L"
kag "$T/ag-rpp-new.json" "K-12:sid-12:working:4444"
run reconcile "$L" "$T/ag-rpp-new.json"
expect_rc "relaunch_prior_pid new pid" 0
expect_st "relaunch_prior_pid new pid" 12 launched
[ "$(fld 12 gen)" = 2 ] || fail "relaunch_prior_pid new pid: gen '$(fld 12 gen)', want 2"
[ "$(intent_open "$RP")" = "false launched" ] || fail "relaunch_prior_pid new pid: intent '$(intent_open "$RP")'"
# Both rows alive: the new process wins, the old one is never taken.
cat "$T/rpp-base.json" >"$L"
kag "$T/ag-rpp-both.json" "K-12:sid-12:working:4242" "K-12:sid-12c:working:4444"
run reconcile "$L" "$T/ag-rpp-both.json"
expect_st "relaunch_prior_pid both" 12 launched
[ "$(fld 12 sessionId)" = sid-12c ] || fail "relaunch_prior_pid both: sessionId '$(fld 12 sessionId)', want sid-12c"
# An ended session (no pid) at intent time records null.
ksetup rpp2
klaunch 12
seed 12 failed
kag "$T/ag-rpp-ended.json" "K-12:sid-12:done"
run intent "$L" relaunch 12 K-12 "$T/wt-12-r" test-x-12 "$H40" "$T/ag-rpp-ended.json"
expect_rc "relaunch_prior_pid ended intent" 0
[ "$(ipid "$(intent_id)")" = null ] || fail "relaunch_prior_pid ended: priorPid '$(ipid "$(intent_id)")', want null"
# agents.json only belongs to a relaunch.
run intent "$L" launch 9 K-9 "$T/wt-9" test-x-9 "$H40" "$T/ag-rpp-ended.json"
expect_rc "relaunch_prior_pid launch with agents" 2
echo "ok: relaunch_prior_pid"

ksetup crash-lbr
run intent "$L" launch 12 K-12 "$T/wt-12" test-x-12 "$H40"
kag "$T/ag-lbr.json" "K-12:sid-12:working"
run reconcile "$L" "$T/ag-lbr.json"
expect_st "crash_after_launch_before_record" 12 launched
[ "$(fld 12 sessionId)" = sid-12 ] || fail "crash_after_launch_before_record: sessionId '$(fld 12 sessionId)'"
[ "$(fld 12 sessionName)" = K-12 ] || fail "crash_after_launch_before_record: sessionName not recorded"
[ "$(fld 12 gen)" = 1 ] || fail "crash_after_launch_before_record: gen '$(fld 12 gen)'"
[ "$(fld 12 worktree)" = "$T/wt-12" ] || fail "crash_after_launch_before_record: worktree not recorded"
echo "ok: crash_after_launch_before_record"

ksetup crash-mi
klaunch 12
commit_on test-x-12 m12
CAND="$(g rev-parse test-x-12)"; PIN="$(g rev-parse tk)"
seed 12 verifying
run intent "$L" merge 12 "$CAND" "$PIN"
expect_rc "crash_after_merge_intent intent" 0
MI="$(intent_id)"
run reconcile "$L" "$T/ag-all.json"
expect_st "crash_after_merge_intent" 12 done-claimed
expect_line "crash_after_merge_intent" "requeue 12"
[ "$(jq '[.intents[] | select(.open)] | length' "$L")" = 0 ] || fail "crash_after_merge_intent: intent left open"
[ "$(intent_open "$MI")" = "false interrupted" ] || fail "crash_after_merge_intent: intent outcome '$(intent_open "$MI")'"
echo "ok: crash_after_merge_intent"

ksetup crash-mbr
klaunch 12
seed_blocked 13 12
commit_on test-x-12 m12
CAND="$(g rev-parse test-x-12)"; PIN="$(g rev-parse tk)"
seed 12 verifying
run intent "$L" merge 12 "$CAND" "$PIN"
FOUT="$(cd "$R" && "$BASH" "$FFM" tk "$CAND" "$PIN")" || fail "crash_after_merge_before_record: ff-merge failed ($FOUT)"
run reconcile "$L" "$T/ag-all.json"
expect_st "crash_after_merge_before_record" 12 merged
[ "$(fld 12 mergeSha)" = "$CAND" ] || fail "crash_after_merge_before_record: mergeSha not recorded"
expect_st "crash_after_merge_before_record dependent" 13 pending
expect_no_line_prefix "crash_after_merge_before_record" "requeue 12"
echo "ok: crash_after_merge_before_record"

# ---------------------------------------------------------------- reconcile_terminal_intent
ksetup term
run intent "$L" launch 12 K-12 "$T/wt-12" test-x-12 "$H40"
jset '.issues["12"].status = "cancelled"'
kag "$T/ag-term.json" "K-12:sid-12:working"
run reconcile "$L" "$T/ag-term.json"
expect_rc "reconcile_terminal_intent" 0
expect_st "reconcile_terminal_intent" 12 cancelled
[ "$(jq '[.intents[] | select(.open)] | length' "$L")" = 1 ] || fail "reconcile_terminal_intent: intent on a terminal issue was touched"
echo "ok: reconcile_terminal_intent"

# ---------------------------------------------------------------- no regression after success
ksetup rs-done
klaunch 12
msg K-12 "$DONE12"
run reconcile "$L" "$T/ag-all.json"
expect_rc "restart_after_launch_then_done reconcile" 0
expect_st "restart_after_launch_then_done" 12 done-claimed
expect_line "restart_after_launch_then_done" "requeue 12"
echo "ok: restart_after_launch_then_done"

ksetup rs-cancel
klaunch 12
ev 0 cancel-ticket
run reconcile "$L" "$T/ag-all.json"
expect_rc "restart_after_launch_then_cancel reconcile" 0
expect_st "restart_after_launch_then_cancel" 12 cancelled
echo "ok: restart_after_launch_then_cancel"

ksetup rs-merge
klaunch 12
seed 12 verifying
run intent "$L" merge 12 "$H40" "$H41"
ev 12 gate merged "$(intent_id)" "tests pass"
run reconcile "$L" "$T/ag-all.json"
expect_rc "restart_after_merge reconcile" 0
expect_st "restart_after_merge" 12 merged
expect_no_line_prefix "restart_after_merge" "requeue 12"
echo "ok: restart_after_merge"

# ---------------------------------------------------------------- crash_during_verifying
for variant in merge stale; do
  ksetup "verif-$variant"
  klaunch 12
  commit_on test-x-12 v12
  CAND="$(g rev-parse test-x-12)"
  msg K-12 "DONE #12 gen=1 test-x-12 $CAND synced=$(g rev-parse tk)"
  ev 12 queue-check ok
  expect_st "crash_during_verifying $variant setup" 12 verifying
  run reconcile "$L" "$T/ag-all.json"
  expect_st "crash_during_verifying $variant" 12 done-claimed
  expect_line "crash_during_verifying $variant" "requeue 12"
  if [ "$variant" = stale ]; then
    echo moved >"$R/moved"; g add moved; g commit -q -m moved
  fi
  PIN="$(g rev-parse tk)"
  FOUT="$(cd "$R" && "$BASH" "$FFM" --check tk "$CAND")"
  FRC=$?
  if [ "$variant" = merge ]; then
    [ "$FRC" -eq 0 ] || fail "crash_during_verifying merge: --check rc $FRC"
    ev 12 queue-check ok
    expect_rc "crash_during_verifying queue-check ok" 0
    run intent "$L" merge 12 "$CAND" "$PIN"
    MI="$(intent_id)"
    FOUT="$(cd "$R" && "$BASH" "$FFM" tk "$CAND" "$PIN")"
    [ "$?" -eq 0 ] || fail "crash_during_verifying merge: ff-merge failed ($FOUT)"
    ev 12 gate merged "$MI" "tests pass"
    expect_rc "crash_during_verifying gate merged" 0
    expect_st "crash_during_verifying merged" 12 merged
  else
    [ "$FRC" -eq 10 ] || fail "crash_during_verifying stale: --check rc $FRC, want 10"
    ev 12 queue-check stale "${FOUT#head=}"
    expect_rc "crash_during_verifying queue-check stale" 0
    expect_st "crash_during_verifying stale" 12 resync-requested
    expect_outbox "crash_during_verifying stale" "12${TAB}1${TAB}K-12${TAB}RESYNC #12 $PIN"
  fi
done
echo "ok: crash_during_verifying"

# ---------------------------------------------------------------- merge_with_real_ledger
ksetup realmerge
commit_on test-x-12 rm12
CAND="$(g rev-parse test-x-12)"; PIN="$(g rev-parse tk)"
seed 12 verifying
run intent "$L" merge 12 "$CAND" "$PIN"
expect_rc "merge_with_real_ledger intent" 0
[ -z "$(g status --porcelain)" ] || fail "merge_with_real_ledger: ledger dirtied the worktree"
FOUT="$(cd "$R" && "$BASH" "$FFM" tk "$CAND" "$PIN")"
FRC=$?
[ "$FRC" -eq 0 ] || fail "merge_with_real_ledger: ff-merge rc $FRC ($FOUT)"
echo "ok: merge_with_real_ledger"

# ---------------------------------------------------------------- reconcile_idempotent
ksetup idem
klaunch 9
klaunch 12
klaunch 13
msg K-12 "$DONE12"
ev 12 queue-check ok
seed 13 verifying
ev 13 gate fail "lint fails"
ev 9 stuck-accept 13
run reconcile "$L" "$T/ag-all.json"
expect_rc "reconcile_idempotent first" 0
FIRST="$OUT"
cp "$L" "$T/idem-after.json"
INO1="$(ls -i "$L" | awk '{print $1}')"
run reconcile "$L" "$T/ag-all.json"
expect_rc "reconcile_idempotent second" 0
[ "$OUT" = "$FIRST" ] || fail "reconcile_idempotent: actions differ ('$FIRST' vs '$OUT')"
cmp -s "$L" "$T/idem-after.json" || fail "reconcile_idempotent: second run changed the ledger"
[ "$(ls -i "$L" | awk '{print $1}')" = "$INO1" ] || fail "reconcile_idempotent: second run rewrote the ledger"
expect_line "reconcile_idempotent" "requeue 12"
expect_line "reconcile_idempotent" "resend 13 K-13 REWORK #13 lint fails"
expect_line "reconcile_idempotent" "resend 9 K-9 CANCEL #9"
expect_line "reconcile_idempotent" "status 13"
echo "ok: reconcile_idempotent"

# ---------------------------------------------------------------- message_text_inert
# Free text reaches ledger.sh as argv only and is printed, never run.
ksetup inert
klaunch 12
EVIL='$(touch '"$T"'/pwned) `touch '"$T"'/pwned2`; touch '"$T"'/pwned3'
msg K-12 "STUCK #12 gen=1 $EVIL"
expect_rc "message_text_inert" 0
expect_line "message_text_inert" "ask-user=stuck 12 $EVIL"
[ ! -e "$T/pwned" ] && [ ! -e "$T/pwned2" ] && [ ! -e "$T/pwned3" ] || fail "message_text_inert: message text was executed"
echo "ok: message_text_inert"

# ---------------------------------------------------------------- frame_argv_preserved
# The whole frame is one argv argument: quotes, $(…), backticks and a tab reach
# the stored reason byte for byte, and nothing runs.
ksetup argv
klaunch 12
FR="a \"q\" \$(x) \`y\` ${TAB} z"
( cd "$R" && "$BASH" "$LSH" message "$L" "$(frame K-12 "FAILED #12 gen=1 $FR")" >"$T/argv.out" 2>"$T/argv.err" )
RC=$?
[ "$RC" -eq 0 ] || fail "frame_argv_preserved: rc $RC ($(cat "$T/argv.err"))"
got="$(jq -r '.issues["12"].reason' "$L")"
[ "${got#FAILED: }" = "$FR" ] || fail "frame_argv_preserved: stored reason '$got', want 'FAILED: $FR'"
for f in x y; do
  [ ! -e "$R/$f" ] && [ ! -e "$T/$f" ] || fail "frame_argv_preserved: file '$f' created"
done
echo "ok: frame_argv_preserved"

# ---------------------------------------------------------------- cancel_targets_intent_session
# Ruling T6-C2: an open launch/relaunch intent's session may already be running
# (crash between launch and record), so drop and cancel-ticket queue a CANCEL to
# the intent's session name in the same write.
ksetup cti
run intent "$L" launch 12 K-12 "$T/wt-12" test-x-12 "$H40"
expect_rc "cancel_targets_intent_session intent" 0
ev 12 drop
expect_rc "cancel_targets_intent_session drop" 0
expect_outbox "cancel_targets_intent_session drop" "12${TAB}1${TAB}K-12${TAB}CANCEL #12"
kag "$T/ag-cti.json" "K-12:sid-12:working:$$"
run reconcile "$L" "$T/ag-cti.json"
expect_line "cancel_targets_intent_session resend" "resend 12 K-12 CANCEL #12"
run reconcile "$L" "$T/ag-empty.json"
expect_no_line_prefix "cancel_targets_intent_session session gone" "resend 12"
# relaunch intent on a failed issue, then drop
ksetup cti-r
klaunch 12
seed 12 failed
run intent "$L" relaunch 12 K-12r "$T/wt-12-r" test-x-12 "$H40"
expect_rc "cancel_targets_intent_session relaunch intent" 0
ev 12 drop
expect_outbox "cancel_targets_intent_session relaunch drop" "12${TAB}2${TAB}K-12r${TAB}CANCEL #12"
# cancel-ticket: #12 pending with an open intent, #9 live -> two CANCELs
ksetup cti-t
klaunch 9
run intent "$L" launch 12 K-12 "$T/wt-12" test-x-12 "$H40"
expect_rc "cancel_targets_intent_session ticket intent" 0
ev 0 cancel-ticket
expect_rc "cancel_targets_intent_session cancel-ticket" 0
expect_outbox "cancel_targets_intent_session cancel-ticket 9" "9${TAB}1${TAB}K-9${TAB}CANCEL #9"
expect_outbox "cancel_targets_intent_session cancel-ticket 12" "12${TAB}1${TAB}K-12${TAB}CANCEL #12"
run outbox "$L"
[ "$(printf '%s\n' "$OUT" | grep -c 'CANCEL #')" = 2 ] || fail "cancel_targets_intent_session: want 2 CANCELs, got '$OUT'"
echo "ok: cancel_targets_intent_session"

# ---------------------------------------------------------------- cancel_failed_session
# Ruling CX3: a `failed` issue's recorded session may still be alive, so drop
# and cancel-ticket queue CANCEL to it as well.
ksetup cfs
klaunch 12
seed 12 failed
ev 12 drop "gone"
expect_rc "cancel_failed_session drop" 0
expect_outbox "cancel_failed_session drop" "12${TAB}1${TAB}K-12${TAB}CANCEL #12"
ksetup cfs-t
klaunch 9
klaunch 12
seed 12 failed
ev 0 cancel-ticket "stop"
expect_rc "cancel_failed_session cancel-ticket" 0
expect_outbox "cancel_failed_session cancel-ticket 9" "9${TAB}1${TAB}K-9${TAB}CANCEL #9"
expect_outbox "cancel_failed_session cancel-ticket 12" "12${TAB}1${TAB}K-12${TAB}CANCEL #12"
# A failed session plus an open relaunch intent under another name: both get one.
ksetup cfs-r
klaunch 12
seed 12 failed
run intent "$L" relaunch 12 K-12r "$T/wt-12-r" test-x-12 "$H40"
expect_rc "cancel_failed_session relaunch intent" 0
ev 12 drop
expect_outbox "cancel_failed_session relaunch drop old" "12${TAB}1${TAB}K-12${TAB}CANCEL #12"
expect_outbox "cancel_failed_session relaunch drop new" "12${TAB}2${TAB}K-12r${TAB}CANCEL #12"
# The recorded session ending drops only its own CANCEL.
ev 12 json done nopid
expect_rc "cancel_failed_session ended" 0
run outbox "$L"
printf '%s\n' "$OUT" | grep -Fxq "12${TAB}1${TAB}K-12${TAB}CANCEL #12" && fail "cancel_failed_session: ended session's CANCEL kept ('$OUT')"
printf '%s\n' "$OUT" | grep -Fxq "12${TAB}2${TAB}K-12r${TAB}CANCEL #12" || fail "cancel_failed_session: intent session's CANCEL dropped ('$OUT')"
# A never-launched issue has no session: nothing queued.
ksetup cfs-p
ev 13 drop
run outbox "$L"
[ -z "$OUT" ] || fail "cancel_failed_session: pending drop queued '$OUT'"
echo "ok: cancel_failed_session"

# ---------------------------------------------------------------- outbox invariant (stale work purged)
nowork() { # <name> <n> — the outbox holds no REWORK/RESYNC for #n
  run_raw outbox "$L"
  printf '%s\n' "$OUT" | grep -Eq "(REWORK|RESYNC) #$2( |\$)" && fail "$1: outbox has work for #$2 (got '$OUT')"
  return 0
}

ksetup sgp
klaunch 12
msg K-12 "STARTED #12 gen=1"
msg K-12 "$DONE12"
ev 12 queue-check ok
ev 12 gate fail "fix the tests"
expect_outbox "stale_gen_work_purged queued" "12${TAB}1${TAB}K-12${TAB}REWORK #12 fix the tests"
ev 12 json failed
nowork "stale_gen_work_purged failed" 12
run intent "$L" relaunch 12 K-12 "$T/wt-12-r" test-x-12 "$H40"
ev 12 relaunch "$(intent_id)" sid-12b
expect_rc "stale_gen_work_purged relaunch" 0
nowork "stale_gen_work_purged relaunch" 12
msg K-12 "STARTED #12 gen=2"
msg K-12 "DONE #12 gen=2 test-x-12 $H40 synced=$H41"
kag "$T/ag-sgp.json" K-12:sid-12b:working:4242
run reconcile "$L" "$T/ag-sgp.json"
expect_no_line_prefix "stale_gen_work_purged reconcile" "resend 12"
echo "ok: stale_gen_work_purged"

ksetup ump
klaunch 12
seed 12 done-claimed
ev 12 queue-check ok
ev 12 gate fail "fix it"
expect_outbox "user_merged_purges_work queued" "12${TAB}1${TAB}K-12${TAB}REWORK #12 fix it"
commit_on test-x-12 ump12
g merge -q --ff-only test-x-12
jset '.issues["12"].status = "failed"'
ev 12 user-merged
expect_rc "user_merged_purges_work" 0
expect_st "user_merged_purges_work" 12 merged
nowork "user_merged_purges_work" 12
echo "ok: user_merged_purges_work"

ksetup fcp
klaunch 12
klaunch 13
seed 12 failed
jset '.outbox = [{n: 12, gen: 1, to: "K-12", line: "RESYNC #12 abc"}]'
ev 12 drop
expect_rc "failed_and_cancelled_purge_work drop" 0
nowork "failed_and_cancelled_purge_work drop" 12
seed 13 resync-requested
jset '.outbox = [{n: 13, gen: 1, to: "K-13", line: "RESYNC #13 abc"}]'
ev 0 cancel-ticket
expect_rc "failed_and_cancelled_purge_work cancel-ticket" 0
nowork "failed_and_cancelled_purge_work cancel-ticket" 13
expect_outbox "failed_and_cancelled_purge_work cancel-ticket cancel" "13${TAB}1${TAB}K-13${TAB}CANCEL #13"
ksetup fcq
klaunch 13
seed 13 resync-requested
jset '.outbox = [{n: 13, gen: 1, to: "K-13", line: "RESYNC #13 abc"}]'
ev 13 json failed
expect_rc "failed_and_cancelled_purge_work json failed" 0
nowork "failed_and_cancelled_purge_work json failed" 13
echo "ok: failed_and_cancelled_purge_work"

ksetup bcp
klaunch 12
klaunch 13
ev 12 stuck-accept 13
expect_rc "blocked_cancel_purged_on_relaunch accept" 0
expect_outbox "blocked_cancel_purged_on_relaunch queued" "12${TAB}1${TAB}K-12${TAB}CANCEL #12"
seed 13 verifying
run intent "$L" merge 13 "$H40" "$H41"
ev 13 gate merged "$(intent_id)" ok
expect_rc "blocked_cancel_purged_on_relaunch merged" 0
expect_st "blocked_cancel_purged_on_relaunch pending" 12 pending
run intent "$L" launch 12 K-12 "$T/wt-12-2" test-x-12 "$H40"
ev 12 launch "$(intent_id)" sid-12b
expect_rc "blocked_cancel_purged_on_relaunch relaunch" 0
run_raw outbox "$L"
printf '%s\n' "$OUT" | grep -Fq "CANCEL #12" && fail "blocked_cancel_purged_on_relaunch: stale CANCEL kept (got '$OUT')"
kag "$T/ag-bcp.json" K-12:sid-12b:working:4242
run reconcile "$L" "$T/ag-bcp.json"
expect_no_line_prefix "blocked_cancel_purged_on_relaunch reconcile" "resend 12"
echo "ok: blocked_cancel_purged_on_relaunch"

ksetup rrs
klaunch 12
jset '.issues["12"].gen = 2 | .issues["12"].status = "started"
      | .outbox = [{n: 12, gen: 1, to: "K-12", line: "REWORK #12 x"}]'
kag "$T/ag-rrs.json" K-12:sid-12:working:4242
run_raw reconcile "$L" "$T/ag-rrs.json"
expect_rc "reconcile_repairs_stale_work" 0
nowork "reconcile_repairs_stale_work" 12
expect_no_line_prefix "reconcile_repairs_stale_work resend" "resend 12"
grep -q 'outbox-stale-purged n=12 gen=1' "$(dirname "$L")/ledger.log" || fail "reconcile_repairs_stale_work: no outbox-stale-purged in ledger.log"
assert_outbox_invariant "$L"
echo "ok: reconcile_repairs_stale_work"

# record_launch_purges_work: a stale work entry at the issue's current gen
# (seeded past the invariant) is gone once the issue is launched again.
ksetup rlp
jset '.issues["12"].status = "pending" | .issues["12"].gen = 1
      | .outbox = [{n: 12, gen: 1, to: "K-12", line: "REWORK #12 stale"}]'
run_raw intent "$L" launch 12 K-12 "$T/wt-12-rlp" test-x-12 "$H40"
expect_rc "record_launch_purges_work pending intent" 0
run_raw event "$L" 12 launch "$(intent_id)" sid-12b
expect_rc "record_launch_purges_work pending launch" 0
nowork "record_launch_purges_work pending" 12
jset '.issues["12"].status = "failed"
      | .outbox = [{n: 12, gen: 2, to: "K-12", line: "RESYNC #12 stale"}]'
run_raw intent "$L" relaunch 12 K-12 "$T/wt-12-rlp" test-x-12 "$H40"
expect_rc "record_launch_purges_work failed intent" 0
run_raw event "$L" 12 relaunch "$(intent_id)" sid-12c
expect_rc "record_launch_purges_work failed relaunch" 0
nowork "record_launch_purges_work failed" 12
assert_outbox_invariant "$L"
echo "ok: record_launch_purges_work"

if [ "$FAIL" -ne 0 ]; then exit 1; fi
echo "all ledger tests passed"
