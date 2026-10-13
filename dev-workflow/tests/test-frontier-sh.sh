#!/usr/bin/env bash
# Behavioral test for coordinating-partner-sessions/scripts/frontier.sh:
# launch selection, the live count, and cycle detection. Runnable standalone.
#
# Bash 3.2 compatible: no associative arrays, no `mapfile`, no `${var,,}`.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
FRONTIER="$ROOT/skills/coordinating-partner-sessions/scripts/frontier.sh"

FAIL=0

fail() {
  echo "FAIL: $1" >&2
  FAIL=1
}

[ -f "$FRONTIER" ] || { echo "FAIL: $FRONTIER not found (frontier.sh not found)" >&2; exit 1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

OUT=""
ERR=""
RC=0
# run <args...> — sets OUT (newlines folded to spaces), ERR, RC. Runs in the
# background and kills after 5 s so a cycle bug cannot hang the suite.
run() {
  "$BASH" "$FRONTIER" "$@" >"$T/out" 2>"$T/err" &
  pid=$!
  ( sleep 5; kill "$pid" 2>/dev/null ) &
  killer=$!
  wait "$pid" 2>/dev/null
  RC=$?
  kill "$killer" 2>/dev/null
  wait "$killer" 2>/dev/null
  OUT="$(tr '\n' ' ' <"$T/out" | sed 's/ $//')"
  ERR="$(cat "$T/err")"
}

# state <cap> <issue-json-fragment>... — writes $T/s.json
state() {
  cap="$1"; shift
  body=""
  for f in "$@"; do
    if [ -z "$body" ]; then body="$f"; else body="$body,$f"; fi
  done
  printf '{"cap":%s,"issues":{%s}}\n' "$cap" "$body" >"$T/s.json"
}

# iss <n> <status> [blockers-json] [external-json]
iss() {
  printf '"%s":{"status":"%s","blockers":%s,"external":%s}' "$1" "$2" "${3:-[]}" "${4:-[]}"
}

# expect_frontier <name> <expected output, space separated>
expect_frontier() {
  run "$T/s.json"
  if [ "$RC" -ne 0 ]; then fail "$1: rc $RC ($ERR)"; return; fi
  [ "$OUT" = "$2" ] || fail "$1: expected '$2', got '$OUT'"
  echo "ok: $1"
}

expect_live() {
  run --live-count "$T/s.json"
  if [ "$RC" -ne 0 ]; then fail "$1: rc $RC ($ERR)"; return; fi
  [ "$OUT" = "$2" ] || fail "$1: expected '$2', got '$OUT'"
  echo "ok: $1"
}

state 3 "$(iss 1 pending)" "$(iss 2 pending)" "$(iss 3 pending)"
expect_frontier "independent" "1 2 3"

state 3 "$(iss 1 pending)" "$(iss 2 pending)" "$(iss 3 pending)" "$(iss 4 pending)" "$(iss 5 pending)"
expect_frontier "cap" "1 2 3"

state 3 "$(iss 1 started)" "$(iss 2 verifying)" "$(iss 3 pending)" "$(iss 4 pending)"
expect_frontier "cap minus live" "3"

state 3 "$(iss 1 launched)" "$(iss 2 started)" "$(iss 3 done-claimed)" "$(iss 4 verifying)" \
  "$(iss 5 resync-requested)" "$(iss 6 rework-1/3)"
expect_live "live count per status" 6

state 3 "$(iss 1 'blocked-on #9')" "$(iss 2 failed)" "$(iss 3 merged)" "$(iss 4 cancelled)" "$(iss 5 pending)"
expect_live "non-live statuses" 0

state 3 "$(iss 1 pending)" "$(iss 2 pending '[1]')" "$(iss 3 pending '[2]')"
expect_frontier "chain" "1"

state 3 "$(iss 1 merged)" "$(iss 2 pending)" "$(iss 3 pending '[2]')"
expect_frontier "chain after merge" "2"

state 3 "$(iss 1 merged)" "$(iss 2 started)" "$(iss 3 pending '[1,2]')"
expect_frontier "diamond" ""

state 3 "$(iss 1 failed)" "$(iss 2 pending '[1]')"
expect_frontier "failed blocker" ""

state 3 "$(iss 1 cancelled)" "$(iss 2 pending '[1]')"
expect_frontier "cancelled blocker" ""

state 3 "$(iss 1 merged)" "$(iss 2 pending '[1]')"
expect_frontier "blocked-on released" "2"

state 3 "$(iss 1 pending '[]' '[{"n":40,"closed":false}]')"
expect_frontier "external open" ""

state 3 "$(iss 1 pending '[]' '[{"n":40,"closed":true}]')"
expect_frontier "external closed" "1"

# Cycle: must exit 2 with "cycle:" on stderr, and must not hang.
state 3 "$(iss 1 pending '[2]')" "$(iss 2 pending '[1]')"
run "$T/s.json"
if [ "$RC" -eq 143 ] || [ "$RC" -eq 137 ]; then fail "cycle: hung (killed after 5 s)"
elif [ "$RC" -ne 2 ]; then fail "cycle: expected rc 2, got $RC"
else
  case "$ERR" in cycle:*) echo "ok: cycle" ;; *) fail "cycle: stderr lacks 'cycle:': $ERR" ;; esac
fi

state 3 "$(iss 1 pending)" "$(iss 2 pending '[1]')" "$(iss 3 pending)"
run --check-edge "$T/s.json" 3 1
[ "$RC" -eq 0 ] || fail "check-edge ok: rc $RC ($ERR)"
echo "ok: check-edge ok"

state 3 "$(iss 1 pending)" "$(iss 2 pending '[1]')"
run --check-edge "$T/s.json" 1 2
if [ "$RC" -ne 2 ]; then fail "check-edge cycle: expected rc 2, got $RC"
else
  case "$ERR" in cycle:*) echo "ok: check-edge cycle" ;; *) fail "check-edge cycle: stderr lacks 'cycle:': $ERR" ;; esac
fi

if [ "$FAIL" -ne 0 ]; then exit 1; fi
echo "all frontier tests passed"
