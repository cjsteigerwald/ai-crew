#!/usr/bin/env bash
# End-to-end test of the coordinator's script contract for partner sessions:
# drives parse-msg.sh, frontier.sh, ff-merge.sh and ledger.sh together, in the
# order SKILL.md prescribes, against fake `claude agents --json --all`
# observations and a real throwaway git repo. It is the scripted stand-in for
# the coordinator's prose loop, including kill points whose `reconcile`
# output is consumed action by action. Runnable standalone.
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

for s in "$LSH" "$FRONTIER" "$FFM" "$SCRIPTS/parse-msg.sh"; do
  [ -f "$s" ] || { echo "FAIL: $s not found" >&2; exit 1; }
done

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
TAB="$(printf '\t')"

R="$T/repo"
mkdir -p "$R"
git init -q "$R"
g() { git -C "$R" "$@"; }
g config user.name "Test"
g config user.email "test@example.invalid"
g config commit.gpgsign false
g checkout -q -b tk
echo base >"$R/base.txt"
g add base.txt
g commit -q -m base

OUT=""; ERR=""; RC=0
# ledger <args...> — ledger.sh from the ticket checkout; sets OUT, ERR, RC.
ledger() {
  OUT="$(cd "$R" && "$BASH" "$LSH" "$@" 2>"$T/err")"
  RC=$?
  ERR="$(cat "$T/err")"
  case "$1" in
    init|intent|event|message|session|reconcile)
      if [ "$RC" -eq 0 ]; then assert_outbox_invariant "$2" "$*"; fi ;;
  esac
}
# assert_outbox_invariant <ledger> <call> — every work entry is of its issue's
# current gen while that issue is resync-requested or rework-*; no CANCEL is
# older than the issue's current gen.
assert_outbox_invariant() {
  jq -e '.issues as $is | all(.outbox[]; ($is[(.n | tostring)]) as $i
         | if (.line | startswith("CANCEL #")) then .gen >= $i.gen
           else .gen == $i.gen and ($i.status == "resync-requested" or ($i.status | startswith("rework-"))) end)' \
    "$1" >/dev/null || fail "outbox invariant violated after '$2': $(jq -c .outbox "$1")"
}
# frontier — frontier.sh on the ledger; sets OUT (one issue per line), RC.
frontier() {
  OUT="$("$BASH" "$FRONTIER" "$L" 2>"$T/err")"
  RC=$?
  ERR="$(cat "$T/err")"
}
# ffm <args...> — ff-merge.sh with cwd = the ticket checkout.
ffm() {
  OUT="$(cd "$R" && "$BASH" "$FFM" "$@" 2>"$T/err")"
  RC=$?
  ERR="$(cat "$T/err")"
}

expect_rc() { # <name> <want>
  [ "$RC" -eq "$2" ] || fail "$1: expected rc $2, got $RC (out '$OUT', err '$ERR')"
}
expect_out() { # <name> <want>
  [ "$OUT" = "$2" ] || fail "$1: expected output '$2', got '$OUT'"
}
st() { jq -r --arg n "$1" '.issues[$n].status' "$L"; }
expect_st() { # <name> <n> <want>
  got="$(st "$2")"
  [ "$got" = "$3" ] || fail "$1: expected #$2 status '$3', got '$got'"
}

# agents <file> <sid>=<pid> ... — a `claude agents --json --all` fixture; a row
# without a pid (`<sid>=ended`) is a session that has ended.
agents() {
  f="$1"; shift
  body=""
  for a in "$@"; do
    sid="${a%%=*}"; v="${a#*=}"
    case "$v" in
      ended) row="{\"sessionId\":\"$sid\",\"name\":\"$sid\",\"state\":\"done\"}" ;;
      *) row="{\"sessionId\":\"$sid\",\"name\":\"$sid\",\"pid\":$v,\"state\":\"working\"}" ;;
    esac
    if [ -z "$body" ]; then body="$row"; else body="$body,$row"; fi
  done
  printf '[%s]\n' "$body" >"$f"
}

frame() { printf '<cross-session-message from="%s">%s</cross-session-message>' "$1" "$2"; }
# msg <n> <line> — deliver a partner message from TEST-<n> through ledger.sh.
msg() { ledger message "$L" "$(frame "TEST-$1" "$2")"; }

# --------------------------------------------------------------- path, lock, init
agents "$T/ag.json" "sid-coord=$$"

ledger path TEST
expect_rc path 0
L="$OUT"
case "$L" in
  "$(cd "$R/.git" && pwd -P)"/partner-sessions/TEST/ledger.json) ;;
  *) fail "path: ledger not under the git common dir: $L" ;;
esac

ledger lock "$L" sid-coord "$T/ag.json"
expect_rc lock 0
PS_OWNER="${OUT#owner=}"
export PS_OWNER

iss() {
  printf '{"n":%s,"blockers":%s,"external":[],"branch":"test-x-%s","testCmd":"true","ac":["AC-1"]}' \
    "$1" "${2:-[]}" "$1"
}
printf '[%s,%s,%s]\n' "$(iss 1)" "$(iss 2 '[1]')" "$(iss 3)" >"$T/issues.json"
ledger init "$L" TEST tk TEST-coord sid-coord "$T/issues.json"
expect_rc init 0
expect_out init "pending"
for n in 1 2 3; do expect_st init "$n" pending; done

# --------------------------------------------------------------- launch: canary first
frontier
expect_rc frontier-initial 0
expect_out frontier-initial "$(printf '1\n3')"

# launch_issue <n> — worktree from the ticket head, intent launch, event launch.
launch_issue() {
  base="$(g rev-parse tk)"
  g worktree add -q -b "test-x-$1" "$T/wt-$1" "$base" || fail "worktree add #$1"
  ledger intent "$L" launch "$1" "TEST-$1" "$T/wt-$1" "test-x-$1" "$base"
  expect_rc "intent launch $1" 0
  iid="${OUT#intent=}"
  ledger event "$L" "$1" launch "$iid" "sid-$1"
  expect_rc "event launch $1" 0
  expect_out "event launch $1" launched
  expect_st "launch $1" "$1" launched
}

launch_issue 1
# The canary rule: nothing else launches before the canary passed.
ledger intent "$L" launch 3 TEST-3 "$T/wt-3" test-x-3 "$(g rev-parse tk)"
expect_rc "canary refuses 3" 30
expect_st "canary refused 3" 3 pending

msg 1 "STARTED #1 gen=1"
expect_rc "STARTED 1" 0
expect_out "STARTED 1" started
ledger event "$L" 1 canary-passed
expect_rc canary-passed 0
launch_issue 3
msg 3 "STARTED #3 gen=1"
expect_rc "STARTED 3" 0
expect_st "STARTED 3" 3 started
ledger slots "$L"
expect_out slots-two 2

# A sender that is not the recorded session is rejected before any change.
ledger message "$L" "$(frame TEST-3 "STARTED #1 gen=1")"
expect_rc "wrong sender" 20
expect_st "wrong sender" 1 started

# --------------------------------------------------------------- partner work, DONE
# partner_commit <n> — one commit on the partner's own worktree; prints the sha.
partner_commit() {
  echo "work $1" >"$T/wt-$1/work-$1.txt"
  git -C "$T/wt-$1" add "work-$1.txt"
  git -C "$T/wt-$1" commit -q -m "partner commit $1"
  git -C "$T/wt-$1" rev-parse HEAD
}
# done_msg <n> <sha> — DONE with synced= the current ticket head.
done_msg() {
  msg "$1" "DONE #$1 gen=1 test-x-$1 $2 synced=$(g rev-parse tk)"
}

SHA1="$(partner_commit 1)"
SHA3="$(partner_commit 3)"
done_msg 1 "$SHA1"
expect_rc "DONE 1" 0
printf '%s\n' "$OUT" | grep -Fxq 'queue=1' || fail "DONE 1: no queue=1 in '$OUT'"
expect_st "DONE 1" 1 done-claimed
done_msg 3 "$SHA3"
expect_rc "DONE 3" 0
expect_st "DONE 3" 3 done-claimed
# The same claim again is a no-op.
done_msg 3 "$SHA3"
expect_rc "DONE 3 duplicate" 10

# queue_merge <n> <sha> — the success path of one queue entry; the pin comes
# from git rev-parse after --check exits 0.
queue_merge() {
  ffm --check tk "$2"
  expect_rc "check $1" 0
  PIN="$(g rev-parse tk)"
  ledger event "$L" "$1" queue-check ok
  expect_rc "queue-check ok $1" 0
  expect_st "queue-check ok $1" "$1" verifying
  ledger intent "$L" merge "$1" "$2" "$PIN"
  expect_rc "intent merge $1" 0
  MID="${OUT#intent=}"
  ffm tk "$2" "$PIN"
  expect_rc "ff-merge $1" 0
  expect_out "ff-merge $1" "head=$2"
  ledger event "$L" "$1" gate merged "$MID" "tests pass"
  expect_rc "gate merged $1" 0
  expect_out "gate merged $1" merged
  expect_st "gate merged $1" "$1" merged
  [ "$(g rev-parse tk)" = "$2" ] || fail "merge $1: ticket head is not $2"
}

# --------------------------------------------------------------- queue 1: merges
queue_merge 1 "$SHA1"

# 2 is unblocked by 1; 3 is launched (done-claimed), so the frontier is just 2.
frontier
expect_rc "frontier after 1" 0
expect_out "frontier after 1" 2

# --------------------------------------------------------------- queue 3: stale, RESYNC
ffm --check tk "$SHA3"
expect_rc "check 3 stale" 10
HEAD1="$(g rev-parse tk)"
expect_out "check 3 stale" "head=$HEAD1"
ledger event "$L" 3 queue-check stale "$HEAD1"
expect_rc "queue-check stale 3" 0
expect_out "queue-check stale 3" resync-requested
expect_st "stale 3" 3 resync-requested
ledger outbox "$L"
expect_out "outbox RESYNC" "3${TAB}1${TAB}TEST-3${TAB}RESYNC #3 $HEAD1"

# --------------------------------------------------------------- kill point
# The in-memory loop is gone. A new coordinator process takes the lock again
# (same session, same owner), reads `claude agents --json --all`, and reconciles.
agents "$T/ag2.json" "sid-coord=$$" "sid-1=ended" "sid-3=$$"
ledger lock "$L" sid-coord "$T/ag2.json"
expect_rc "relock" 0
[ "${OUT#owner=}" = "$PS_OWNER" ] || fail "relock: owner changed ($OUT vs $PS_OWNER)"

# consume_reconcile <agents.json> — handle every printed action the way
# SKILL.md will: requeue <n>, resend <n> <to> <line>, status <n>.
REQ=""; RESENT=""; STAT=""
consume_reconcile() {
  ag="$1"
  REQ=""; RESENT=""; STAT=""
  ledger reconcile "$L" "$ag"
  expect_rc reconcile 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    set -- $line
    case "$1" in
      requeue) REQ="$REQ $2" ;;
      resend) rn="$2"; rto="$3"; shift 3; RESENT="$RESENT|$rn $rto $*" ;;
      status) STAT="$STAT $2" ;;
      *) fail "reconcile: unexpected action line '$line'" ;;
    esac
  done <<EOF2
$OUT
EOF2
}
consume_reconcile "$T/ag2.json"
[ -z "$REQ" ] || fail "reconcile: unexpected requeue '$REQ'"
[ "$RESENT" = "|3 TEST-3 RESYNC #3 $HEAD1" ] || fail "reconcile: resend '$RESENT'"
[ "$STAT" = " 3" ] || fail "reconcile: status '$STAT'"
expect_st "after reconcile 1" 1 merged
expect_st "after reconcile 3" 3 resync-requested
# A second reconcile reports the same and leaves the ledger bytes alone.
BEFORE="$(cat "$L")"
consume_reconcile "$T/ag2.json"
[ "$RESENT" = "|3 TEST-3 RESYNC #3 $HEAD1" ] || fail "reconcile twice: resend '$RESENT'"
[ "$(cat "$L")" = "$BEFORE" ] || fail "reconcile twice: ledger changed"

# --------------------------------------------------------------- partner 3 re-syncs
# The resend is delivered; the partner merges the ticket head and reports DONE again.
git -C "$T/wt-3" merge -q --no-edit tk >/dev/null 2>&1 || fail "partner 3: merge tk"
SHA3B="$(git -C "$T/wt-3" rev-parse HEAD)"
[ "$SHA3B" != "$SHA3" ] || fail "partner 3: resync did not move the branch"
done_msg 3 "$SHA3B"
expect_rc "DONE 3 after resync" 0
expect_st "DONE 3 after resync" 3 done-claimed
ledger outbox "$L"
expect_out "outbox cleared by DONE" ""

queue_merge 3 "$SHA3B"
frontier
expect_rc "frontier after 3" 0
expect_out "frontier after 3" 2
ledger slots "$L"
expect_out "slots after 3" 0

# --------------------------------------------------------------- issue 2
launch_issue 2
msg 2 "STARTED #2 gen=1"
expect_rc "STARTED 2" 0
SHA2="$(partner_commit 2)"
done_msg 2 "$SHA2"
expect_rc "DONE 2" 0
expect_st "DONE 2" 2 done-claimed

# Second kill point: the coordinator dies after the merge intent, before ff-merge.
ffm --check tk "$SHA2"
expect_rc "check 2" 0
PIN="$(g rev-parse tk)"
ledger event "$L" 2 queue-check ok
expect_rc "queue-check ok 2" 0
ledger intent "$L" merge 2 "$SHA2" "$PIN"
expect_rc "intent merge 2" 0
agents "$T/ag3.json" "sid-coord=$$" "sid-1=ended" "sid-3=ended" "sid-2=$$"
consume_reconcile "$T/ag3.json"
[ "$REQ" = " 2" ] || fail "reconcile 2: requeue '$REQ'"
[ -z "$RESENT" ] || fail "reconcile 2: unexpected resend '$RESENT'"
expect_st "reconcile 2" 2 done-claimed
jq -e '[.intents[] | select(.kind == "merge" and .n == 2 and .open)] | length == 0' "$L" >/dev/null \
  || fail "reconcile 2: merge intent still open"
[ "$(g rev-parse tk)" = "$SHA3B" ] || fail "reconcile 2: ticket head moved"

# The requeued issue goes through the queue again, to the end.
queue_merge 2 "$SHA2"

# --------------------------------------------------------------- done, summary, history
ledger done "$L"
expect_rc done 0
expect_out done handback
ledger summary "$L"
expect_rc summary 0
for n in 1 2 3; do
  printf '%s\n' "$OUT" | grep -Eq "^\| #$n \| merged \| test-x-$n \| [0-9a-f]{40} \|" \
    || fail "summary: no merged row for #$n"
done
[ "$(printf '%s\n' "$OUT" | grep -c '^| #')" -eq 3 ] || fail "summary: expected three issue rows"

LOG="$(g log --format=%s tk)"
for n in 1 2 3; do
  printf '%s\n' "$LOG" | grep -Fxq "partner commit $n" || fail "git log: lacks partner commit $n"
done
for s in "$SHA1" "$SHA3B" "$SHA2"; do
  g merge-base --is-ancestor "$s" tk || fail "history: $s is not an ancestor of tk"
done
[ -z "$(g status --porcelain)" ] || fail "ticket checkout is dirty"
frontier
expect_out "frontier at the end" ""

ledger unlock "$L"
expect_rc unlock 0

[ "$FAIL" -eq 0 ] && echo "ok: test-coordinator-contract-sh"
exit "$FAIL"
