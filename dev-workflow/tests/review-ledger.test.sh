#!/usr/bin/env bash
# Behavioral test for scripts/review-ledger.sh: record, count, void, link
# (de-duplication, snapshot, after reset), reset generations, the cap reached
# through linked plan rounds, rename via link, percent-encoded keys, corrupt
# ledger and failed lock. Runs on a temp repo with two worktrees (one path has
# spaces) and calls the CLI as a subprocess. Runnable standalone.
#
# Bash 3.2 compatible: no associative arrays, no `mapfile`, no `${var,,}`.
# shellcheck disable=SC2015  # `cond && pass || fail`: pass only echoes, so it cannot fall through
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
RL="$ROOT/scripts/review-ledger.sh"

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; FAIL=1; }

[ -f "$RL" ] || { echo "FAIL: $RL not found" >&2; exit 1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
REPO="$T/main repo"         # a space in the path on purpose
WT="$T/wt two"
NOREPO="$T/not-a-repo"
mkdir -p "$REPO" "$NOREPO"
git -C "$REPO" init -q -b main
git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$REPO" worktree add -q -b feat/x "$WT"
LDIR="$(cd "$REPO" && cd "$(git rev-parse --git-common-dir)" && pwd)/review-ledger"
export REVIEW_LEDGER_LOCK_TIMEOUT=2

OUT=""; ERR=""; RC=0
# run <repo-path> <args...> — sets OUT (stdout, newlines folded), ERR, RC.
run() {
  local repo="$1"; shift
  bash "$RL" -C "$repo" "$@" >"$T/out" 2>"$T/err"
  RC=$?
  OUT="$(tr '\n' ' ' <"$T/out" | sed 's/ $//')"
  ERR="$(cat "$T/err")"
}

# expect <name> <rc> <stdout-glob> [<stderr substring>]
expect() {
  if [ "$RC" -ne "$2" ]; then fail "$1: expected rc $2, got $RC (out: $OUT) (err: $ERR)"; return; fi
  # shellcheck disable=SC2254
  case "$OUT" in $3) ;; *) fail "$1: stdout '$OUT' does not match '$3'"; return ;; esac
  if [ -n "${4:-}" ]; then
    case "$ERR" in *"$4"*) ;; *) fail "$1: stderr lacks '$4': $ERR"; return ;; esac
  fi
  pass "$1"
}

# count_is <name> <repo> <key> <n>
count_is() {
  run "$2" count "$3"
  expect "$1" 0 "$4"
}

# --- record and count -------------------------------------------------------
count_is "count of an unknown key is 0" "$REPO" branch:feat/x 0
run "$WT" record branch:feat/x codex-adversary --id t1
expect "record 1 -> allow 1" 0 "allow 1 t1"
run "$WT" record branch:feat/x codex-adversary --id t2
expect "record 2 -> allow 2" 0 "allow 2 t2"
run "$WT" record branch:feat/x codex-adversary --id t2
expect "re-record of the same id is not counted twice" 0 "allow 2 t2"
count_is "worktrees share the ledger (count from the main checkout)" "$REPO" branch:feat/x 2
run "$WT" record branch:feat/x codex-adversary --id t3
expect "record 3 -> allow 3" 0 "allow 3 t3"
run "$WT" record branch:feat/x codex-adversary --id t4
expect "record 4 -> ask 4" 0 "ask 4 t4"
run "$WT" record branch:feat/x codex-adversary
expect "record without --id generates an id" 0 "ask 5 gen:cli:*"
GEN_ID="${OUT##* }"
run "$WT" show branch:feat/x
expect "show lists the generated id as generated" 0 "*$GEN_ID (generated)*"

# --- void -------------------------------------------------------------------
run "$WT" void t4 "declined at cap"
expect "void removes the row" 0 "voided 1 row(s) in branch:feat/x"
run "$WT" void "$GEN_ID" "test row"
expect "void the generated id" 0 "voided 1 row(s) in branch:feat/x"
count_is "count after voids" "$WT" branch:feat/x 3
run "$WT" void t4 "again"
expect "void of an unknown id is refused" 1 "" "no row has tool_use_id"
run "$WT" void t3 ""
expect "void needs a reason" 1 "" "void needs a reason"
run "$WT" show branch:feat/x
expect "show records the void and its reason" 0 "*void t4 (1 row(s)): declined at cap*"

# --- reset ------------------------------------------------------------------
run "$WT" reset branch:feat/x "branch name reused for new work"
expect "reset starts generation 2" 0 "branch:feat/x: generation 2, count 0"
count_is "count after reset is 0" "$WT" branch:feat/x 0
run "$WT" show branch:feat/x
expect "show records the reset and its reason" 0 "*reset generation 1 -> 2: branch name reused for new work*"
run "$WT" record branch:feat/x codex-adversary --id t1
expect "an id from an old generation counts again after reset" 0 "allow 1 t1"
run "$WT" reset branch:feat/x ""
expect "reset needs a reason" 1 "" "reset needs a reason"

# --- link: plan rounds -> branch, de-dup, idempotence, cap ------------------
run "$REPO" record plan:PROJ-1 codex-adversary --id p1
run "$REPO" record plan:PROJ-1 codex-adversary --id p2
count_is "two plan rounds" "$REPO" plan:PROJ-1 2
run "$WT" record branch:feat/y codex-adversary --id b1
run "$WT" link branch:feat/y plan:PROJ-1
expect "link copies the plan rounds" 0 "linked 2 row(s) from plan:PROJ-1 into branch:feat/y (0 already present); count 3"
run "$WT" link branch:feat/y plan:PROJ-1
expect "re-link is idempotent" 0 "linked 0 row(s) from plan:PROJ-1 into branch:feat/y (2 already present); count 3"
run "$WT" record branch:feat/y codex-adversary --id b2
expect "2 plan rounds + 1 branch round, linked, reach the cap" 0 "ask 4 b2"
run "$WT" show branch:feat/y
expect "linked copies keep their origin" 0 "*p1 (payload)  origin=plan:PROJ-1*"
run "$WT" void b2 "declined at cap"

# --- link is a snapshot -----------------------------------------------------
run "$REPO" record plan:PROJ-1 codex-adversary --id p3
count_is "a later plan round is not carried over by an earlier link" "$WT" branch:feat/y 3
run "$WT" link branch:feat/y plan:PROJ-1
expect "re-running link picks up only the new round" 0 "linked 1 row(s) from plan:PROJ-1 into branch:feat/y (2 already present); count 4"

# --- void after link removes every copy -------------------------------------
run "$WT" void p1 "launch failed"
expect "void after link removes every copy" 0 "voided 1 row(s) in branch:feat/y voided 1 row(s) in plan:PROJ-1"
count_is "plan count after void" "$REPO" plan:PROJ-1 2
count_is "branch count after void" "$WT" branch:feat/y 3

# --- link after reset -------------------------------------------------------
run "$WT" reset branch:feat/y "recycled"
run "$WT" link branch:feat/y plan:PROJ-1
expect "link after reset copies into the new generation" 0 "linked 2 row(s) from plan:PROJ-1 into branch:feat/y (0 already present); count 2"
run "$WT" link branch:feat/y branch:feat/y
expect "link to itself is refused" 1 "" "same"

# --- rename via link --------------------------------------------------------
run "$WT" link branch:feat/renamed branch:feat/y
expect "rename: new branch inherits the old count" 0 "*count 2"
run "$WT" record branch:feat/renamed codex-adversary --id r1
expect "rename: rounds continue from the old count" 0 "allow 3 r1"

# --- percent-encoded keys ---------------------------------------------------
run "$REPO" record branch:a/b codex-adversary --id e1
run "$REPO" record 'branch:a%2Fb' codex-adversary --id e2
run "$REPO" record 'branch:a%2Fb' codex-adversary --id e3
count_is "branch:a/b and branch:a%2Fb do not collide (1)" "$REPO" branch:a/b 1
count_is "branch:a/b and branch:a%2Fb do not collide (2)" "$REPO" 'branch:a%2Fb' 2
if [ -f "$LDIR/branch%3Aa%2Fb.json" ] && [ -f "$LDIR/branch%3Aa%252Fb.json" ]; then
  pass "key files are percent-encoded"
else
  fail "key files are percent-encoded: $(ls "$LDIR")"
fi
run "$REPO" record 'branch:feat/é ü' codex-adversary --id u1
expect "a non-ASCII key with a space records" 0 "allow 1 u1"
[ -f "$LDIR/branch%3Afeat%2F%C3%A9%20%C3%BC.json" ] && pass "UTF-8 bytes are encoded" || fail "UTF-8 bytes are encoded: $(ls "$LDIR")"
run "$REPO" show
expect "show with no key lists every key" 0 "*branch:a%2Fb  generation 1  count 2*plan:PROJ-1  generation 1  count 2*"

# --- bad input --------------------------------------------------------------
run "$REPO" count feature:x
expect "a key without branch:/plan: is refused" 1 "" "bad key"
run "$REPO" count plan:
expect "an empty plan key is refused" 1 "" "bad key"
run "$NOREPO" count branch:x
expect "a non-repo path is refused" 1 "" "not a git repository"
run "$REPO" frobnicate
expect "an unknown command is refused" 1 "" "unknown command"

# --- corrupt ledger and failed lock -----------------------------------------
printf '{not json' >"$LDIR/branch%3Acorrupt.json"
run "$REPO" count branch:corrupt
expect "corrupt file: count is a ledger error" 2 "" "ledger error: corrupt"
run "$REPO" record branch:corrupt codex-adversary --id c1
expect "corrupt file: record is a ledger error" 2 "" "ledger error: corrupt"
run "$REPO" void p2 "x"
expect "corrupt file anywhere: void writes nothing" 2 "" "ledger error: corrupt"
count_is "void refused on corruption left the row" "$REPO" plan:PROJ-1 2
rm -f "$LDIR/branch%3Acorrupt.json"

python3 - "$LDIR/.lock" "$T/held" <<'PY' &
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT)
fcntl.flock(fd, fcntl.LOCK_EX)
open(sys.argv[2], "w").close()
time.sleep(5)
PY
HOLDER=$!
i=0; while [ ! -f "$T/held" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
REVIEW_LEDGER_LOCK_TIMEOUT=0.5 bash "$RL" -C "$REPO" record branch:x codex-adversary --id l1 >"$T/out" 2>"$T/err"
RC=$?; OUT="$(cat "$T/out")"; ERR="$(cat "$T/err")"
expect "busy lock: record is a ledger error" 2 "" "lock busy"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
count_is "busy lock wrote nothing" "$REPO" branch:x 0

mv "$LDIR/.lock" "$T/lock.bak" && mkdir "$LDIR/.lock"
run "$REPO" record branch:x codex-adversary --id l2
expect "unopenable lock: record is a ledger error" 2 "" "cannot open lock"
rmdir "$LDIR/.lock" && mv "$T/lock.bak" "$LDIR/.lock"

# --- orphan temp files never break enumeration ------------------------------
printf '{half a fi' >"$LDIR/.tmp-orphan.partial"
printf '{half a fi' >"$LDIR/.tmp-old.json"
run "$REPO" show
expect "orphan temp files: keyless show still works" 0 "*plan:PROJ-1  generation 1  count 2*"
case "$OUT" in *tmp*) fail "orphan temp files: show lists a temp file: $OUT" ;; *) pass "orphan temp files: not listed as keys" ;; esac
run "$REPO" void p2 "orphan test"
expect "orphan temp files: void still works" 0 "voided 1 row(s) in branch:feat/renamed voided 2 row(s) in branch:feat/y voided 1 row(s) in plan:PROJ-1"
rm -f "$LDIR/.tmp-orphan.partial" "$LDIR/.tmp-old.json"
LEFT="$(find "$LDIR" -name '.tmp-*' | wc -l | tr -d ' ')"
[ "$LEFT" = "0" ] && pass "successful writes leave no temp files" || fail "temp files left behind: $(ls -a "$LDIR")"

# --- git failures other than "not a git repository" are ledger errors -------
FAKEBIN="$T/fakebin"
mkdir -p "$FAKEBIN"
printf '#!/bin/sh\necho "fatal: unable to access config: Permission denied" >&2\nexit 128\n' >"$FAKEBIN/git"
chmod +x "$FAKEBIN/git"
PATH="$FAKEBIN:$PATH" bash "$RL" -C "$REPO" count branch:x >"$T/out" 2>"$T/err"
RC=$?; OUT="$(cat "$T/out")"; ERR="$(cat "$T/err")"
expect "a git failure other than not-a-repo is a ledger error" 2 "" "ledger error: git rev-parse failed"

# --- concurrency: the lock serialises read-decide-write ---------------------
run "$REPO" record branch:race codex-adversary --id x1
run "$REPO" record branch:race codex-adversary --id x2
REVIEW_LEDGER_TEST_DELAY=0.5 bash "$RL" -C "$REPO" record branch:race codex-adversary --id x3 >"$T/r1" 2>&1 &
P1=$!
REVIEW_LEDGER_TEST_DELAY=0.5 bash "$RL" -C "$WT" record branch:race codex-adversary --id x4 >"$T/r2" 2>&1 &
P2=$!
wait "$P1"; wait "$P2"
R="$(cat "$T/r1" "$T/r2" | awk '{print $1, $2}' | sort | tr '\n' ',')"
[ "$R" = "allow 3,ask 4," ] && pass "two concurrent records at count 2: one allow 3, one ask 4" || fail "concurrent records: $R"

if [ "$FAIL" -eq 0 ]; then echo "review-ledger: all tests passed"; else echo "review-ledger: FAILED" >&2; fi
exit "$FAIL"
