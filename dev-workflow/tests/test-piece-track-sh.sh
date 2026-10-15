#!/usr/bin/env bash
# Behavioral test for coordinating-partner-sessions/scripts/piece-track.sh:
# register, launchable, launch, summary and path, driven by JSON fixtures with
# the CLI called as a subprocess. Runnable standalone.
#
# Bash 3.2 compatible: no associative arrays, no `mapfile`, no `${var,,}`.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PT="$ROOT/skills/coordinating-partner-sessions/scripts/piece-track.sh"
FIX="$HERE/fixtures/piece-tracking"

FAIL=0

fail() {
  echo "FAIL: $1" >&2
  FAIL=1
}

[ -f "$PT" ] || { echo "FAIL: $PT not found (piece-track.sh not found)" >&2; exit 1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
W="$T/work"      # cwd for every run: not a git repository
SD="$T/state"    # PIECE_TRACK_DIR
mkdir -p "$W"

OUT=""
ERR=""
RC=0
# run <args...> — runs piece-track.sh in $W with PIECE_TRACK_DIR=$SD; sets OUT
# (newlines folded to spaces), RAW (stdout as is), ERR, RC. Killed after 5 s so
# a cycle bug cannot hang the suite. The watchdog waits on its sleep with the
# wait builtin, which a trapped TERM interrupts, so it ends as soon as we kill it.
run() {
  ( cd "$W" && PIECE_TRACK_DIR="$SD" exec "$BASH" "$PT" "$@" ) >"$T/out" 2>"$T/err" &
  pid=$!
  ( trap 'kill "$sp" 2>/dev/null; exit 0' TERM
    sleep 5 & sp=$!
    wait "$sp" && kill "$pid" 2>/dev/null ) &
  killer=$!
  wait "$pid" 2>/dev/null
  RC=$?
  kill "$killer" 2>/dev/null
  wait "$killer" 2>/dev/null
  RAW="$(cat "$T/out")"
  OUT="$(tr '\n' ' ' <"$T/out" | sed 's/ $//')"
  ERR="$(cat "$T/err")"
}

# expect <name> <rc> <stdout> [<stderr substring>] — after a run.
expect() {
  if [ "$RC" -ne "$2" ]; then fail "$1: expected rc $2, got $RC (out: $OUT) (err: $ERR)"; return; fi
  if [ "$OUT" != "$3" ]; then fail "$1: expected stdout '$3', got '$OUT'"; return; fi
  if [ -n "${4:-}" ]; then
    case "$ERR" in *"$4"*) ;; *) fail "$1: stderr lacks '$4': $ERR"; return ;; esac
  fi
  echo "ok: $1"
}

# tpath <branch> — the tracking-file path for <branch>.
tpath() {
  run --branch "$1" path
  [ "$RC" -eq 0 ] || fail "path for $1: rc $RC ($ERR)"
  printf '%s' "$OUT"
}

# pc <n> <state> [blockedBy-json] — one piece entry of a tracking file.
pc() {
  if [ "$2" = "pending" ]; then
    printf '"%s":{"state":"pending","blockedBy":%s,"agent":null,"session":null,"branch":null}' "$1" "${3:-[]}"
  else
    printf '"%s":{"state":"%s","blockedBy":%s,"agent":"a-%s","session":"s-%s","branch":"p/%s"}' \
      "$1" "$2" "${3:-[]}" "$1" "$1" "$1"
  fi
}

# track <branch> <depth> <liveCap> <depthCap> <external-json> <piece>... — writes
# a tracking file for <branch> directly (a fixture), replacing any old one.
track() {
  tb="$1"; td="$2"; tl="$3"; tc="$4"; te="$5"; shift 5
  body=""
  for f in "$@"; do
    if [ -z "$body" ]; then body="$f"; else body="$body,$f"; fi
  done
  tf="$(tpath "$tb")"
  mkdir -p "$(dirname "$tf")"
  jq -n --arg b "$tb" --argjson d "$td" --argjson l "$tl" --argjson c "$tc" --argjson e "$te" \
    --argjson p "{$body}" \
    '{version: 1, branch: $b, depth: $d, liveCap: $l, depthCap: $c, external: $e, pieces: $p}' >"$tf"
}

# jqf <file> <filter> — jq -c on a file.
jqf() { jq -c "$2" "$1"; }

# same <name> <a> <b> — files byte-identical.
same() {
  if cmp -s "$2" "$3"; then echo "ok: $1"; else fail "$1: file changed"; fi
}

# no_tmp <name> — no temp files left in the state dir.
no_tmp() {
  left="$(find "$SD" -mindepth 1 \( -name '.*' -o \( -type f ! -name '*.json' \) \) 2>/dev/null)"
  if [ -z "$left" ]; then echo "ok: $1"; else fail "$1: leftover files: $left"; fi
}

B="feat/orch"

# ------------------------------------------------------------------ path

run --branch "a/b" path
expect "path encodes /" 0 "$SD/a%2Fb.json"
run --branch "a-b" path
expect "path keeps -" 0 "$SD/a-b.json"
run --branch "a%2Fb" path
expect "path encodes % (injective)" 0 "$SD/a%252Fb.json"
run --branch "a(b)!'c" path
expect "path encodes ()!' on every jq version" 0 "$SD/a%28b%29%21%27c.json"
run --branch "a..b" path
expect "path rejects a bad branch" 2 "" "bad branch"
run path
expect "path outside git needs --branch" 2 "" "not in a git repository"

# ------------------------------------------------------------------ register

run --branch "$B" register "$FIX/snapshot-chain.json"
F="$(tpath "$B")"
expect "register chain" 0 "registered 3 pieces for $B"
[ "$(jqf "$F" '[.version, .branch, .depth, .liveCap, .depthCap]')" = '[1,"feat/orch",0,3,2]' ] \
  || fail "register defaults: $(jqf "$F" '[.version, .branch, .depth, .liveCap, .depthCap]')"
[ "$(jqf "$F" '.pieces | to_entries | map([.key, .value.state, .value.blockedBy])')" \
  = '[["34","pending",[]],["35","pending",[34]],["36","pending",[12,34]]]' ] \
  || fail "register pieces: $(jqf "$F" '.pieces')"
[ "$(jqf "$F" '[.pieces[] | [.agent, .session, .branch]] | unique')" = '[[null,null,null]]' ] \
  || fail "register launch fields not null"
[ "$(jqf "$F" '.external')" = '{"12":"closed"}' ] || fail "register external: $(jqf "$F" '.external')"
echo "ok: register stores pending pieces, blocked-by, branch and defaults"

run --branch "$B" register "$FIX/snapshot-chain.json" --depth 1 --live-cap 5 --depth-cap 3
expect "re-register while all pending" 0 "registered 3 pieces for $B"
[ "$(jqf "$F" '[.depth, .liveCap, .depthCap]')" = '[1,5,3]' ] || fail "register flags: $(jqf "$F" '[.depth, .liveCap, .depthCap]')"

cp "$F" "$T/before.json"
run --branch "$B" register "$FIX/snapshot-cycle.json"
expect "cycle rejected" 1 "" "cycle: #34 -> #35 -> #36 -> #34"
same "cycle over an existing file writes nothing" "$T/before.json" "$F"

run --branch "fresh" register "$FIX/snapshot-cycle.json"
expect "cycle on a new branch" 1 "" "cycle:"
[ ! -e "$SD/fresh.json" ] && echo "ok: cycle on a new branch writes no file" || fail "cycle wrote $SD/fresh.json"

printf '{"pieces":[{"issue":40,"blocked_by":[40]}]}' >"$T/self.json"
run --branch "fresh" register "$T/self.json"
expect "self-block is a cycle" 1 "" "cycle: #40 -> #40"

# snap_reject <name> <snapshot-text> <stderr substring>
snap_reject() {
  printf '%s' "$2" >"$T/snap.json"
  run --branch "fresh" register "$T/snap.json"
  expect "$1" 1 "" "$3"
  [ ! -e "$SD/fresh.json" ] || fail "$1: wrote $SD/fresh.json"
}
snap_reject "malformed JSON" '{"pieces":[' "not valid JSON"
snap_reject "not an object" '[1,2]' "not a JSON object"
snap_reject "no pieces array" '{"external":{}}' "pieces"
snap_reject "string issue" '{"pieces":[{"issue":"35"}]}' "bad piece"
snap_reject "zero issue" '{"pieces":[{"issue":0}]}' "bad piece"
snap_reject "fractional issue" '{"pieces":[{"issue":1.5}]}' "bad piece"
snap_reject "bad blocker" '{"pieces":[{"issue":3,"blocked_by":["x"]}]}' "bad piece"
snap_reject "duplicate issue" '{"pieces":[{"issue":3},{"issue":4},{"issue":3}]}' "duplicate issue: #3"
snap_reject "unknown blocker" '{"pieces":[{"issue":3,"blocked_by":[9]}]}' "#3 is blocked by unknown #9"
snap_reject "bad external state" '{"pieces":[{"issue":3,"blocked_by":[9]}],"external":{"9":"merged"}}' "bad external"
snap_reject "bad external key" '{"pieces":[{"issue":3}],"external":{"x9":"open"}}' "bad external"
snap_reject "issue both in set and external" '{"pieces":[{"issue":3}],"external":{"3":"open"}}' "both"
snap_reject "float-literal issue 35.0" '{"pieces":[{"issue":35.0}]}' "bad piece"
snap_reject "exponent issue 1e2" '{"pieces":[{"issue":1e2}]}' "bad piece"
snap_reject "float-literal blocker" '{"pieces":[{"issue":3},{"issue":4,"blocked_by":[3.0]}]}' "bad piece"
snap_reject "blocked_by false" '{"pieces":[{"issue":3,"blocked_by":false}]}' "bad piece"
snap_reject "blocked_by object" '{"pieces":[{"issue":3,"blocked_by":{}}]}' "bad piece"
snap_reject "external false" '{"pieces":[{"issue":3}],"external":false}' "external is not an object"
printf '{"pieces":[{"issue":3,"blocked_by":null}],"external":null}' >"$T/nulls.json"
run --branch "nulls" register "$T/nulls.json"
expect "null blocked_by and external mean none" 0 "registered 1 pieces for nulls"

run --branch "fresh" register "$T/missing.json"
expect "missing snapshot file" 2 "" "cannot read"
run --branch "fresh" register "$FIX/snapshot-chain.json" --live-cap 0
expect "live cap must be >= 1" 2 "" "--live-cap"
run --branch "fresh" register "$FIX/snapshot-chain.json" --depth x
expect "depth must be an integer" 2 "" "--depth"
run --branch "fresh" register "$FIX/snapshot-chain.json" --bogus
expect "unknown register flag" 2 ""
[ ! -e "$SD/fresh.json" ] && echo "ok: rejected registers write no file" || fail "a rejected register wrote $SD/fresh.json"

printf '{"pieces":[]}' >"$T/empty.json"
run --branch "empty" register "$T/empty.json"
expect "register zero pieces" 0 "registered 0 pieces for empty"

# ------------------------------------------------------------------ launchable

track "$B" 0 3 2 '{}' "$(pc 3 pending)" "$(pc 1 pending)" "$(pc 2 pending)"
run --branch "$B" launchable
expect "no blockers" 0 "1 2 3"

track "$B" 0 3 2 '{}' "$(pc 100 pending)" "$(pc 9 pending)" "$(pc 20 pending)"
run --branch "$B" launchable
expect "numeric order" 0 "9 20 100"

for st in pending running "done" stuck failed; do
  track "$B" 0 3 2 '{}' "$(pc 1 "$st")" "$(pc 2 pending '[1]')"
  run --branch "$B" launchable
  if [ "$st" = "pending" ]; then want="1"; else want=""; fi
  expect "blocker $st holds the dependant" 0 "$want"
done

track "$B" 0 3 2 '{}' "$(pc 1 merged)" "$(pc 2 pending '[1]')"
run --branch "$B" launchable
expect "blocker merged releases the dependant" 0 "2"

track "$B" 0 3 2 '{}' "$(pc 1 merged)" "$(pc 2 running)" "$(pc 3 pending '[1,2]')"
run --branch "$B" launchable
expect "one of two blockers merged" 0 ""

track "$B" 0 3 2 '{"40":"closed"}' "$(pc 1 pending '[40]')"
run --branch "$B" launchable
expect "external closed blocker cleared" 0 "1"

track "$B" 0 3 2 '{"40":"open"}' "$(pc 1 pending '[40]')"
run --branch "$B" launchable
expect "external open blocker holds" 0 ""

track "$B" 0 3 2 '{"40":"closed"}' "$(pc 1 merged)" "$(pc 2 pending '[1,40]')"
run --branch "$B" launchable
expect "in-set merged and external closed" 0 "2"

track "$B" 0 3 2 '{}' "$(pc 1 pending)" "$(pc 2 pending)" "$(pc 3 pending)" "$(pc 4 pending)" "$(pc 5 pending)"
run --branch "$B" launchable
expect "zero live, cap 3" 0 "1 2 3"

track "$B" 0 3 2 '{}' "$(pc 1 running)" "$(pc 2 "done")" "$(pc 3 pending)" "$(pc 4 pending)"
run --branch "$B" launchable
expect "live under cap" 0 "3"

track "$B" 0 3 2 '{}' "$(pc 1 running)" "$(pc 2 "done")" "$(pc 3 stuck)" "$(pc 4 pending)"
run --branch "$B" launchable
expect "live at cap (stuck counts)" 0 ""

track "$B" 0 3 2 '{}' "$(pc 1 running)" "$(pc 2 running)" "$(pc 3 "done")" "$(pc 4 stuck)" "$(pc 5 pending)"
run --branch "$B" launchable
expect "live over cap" 0 ""

track "$B" 0 3 2 '{}' "$(pc 1 merged)" "$(pc 2 failed)" "$(pc 3 merged)" "$(pc 4 pending)"
run --branch "$B" launchable
expect "merged and failed are not live" 0 "4"

track "$B" 1 3 2 '{}' "$(pc 1 pending)"
run --branch "$B" launchable
expect "depth under cap" 0 "1"

track "$B" 2 3 2 '{}' "$(pc 1 pending)"
run --branch "$B" launchable
expect "depth at cap" 0 ""

track "$B" 3 3 2 '{}' "$(pc 1 pending)"
run --branch "$B" launchable
expect "depth beyond cap" 0 ""

track "$B" 0 3 2 '{}' "$(pc 1 running)" "$(pc 2 pending)"
run --branch "$B" launchable
expect "already launched excluded" 0 "2"

run --branch "nobody" launchable
expect "no tracking file" 1 "" "no tracking file"

# The feat/orch fixture copied to another branch's path is refused.
cp "$FIX/all-states.json" "$(tpath "other")"
run --branch "other" launchable
expect "tracking file for another branch refused" 1 "" "belongs to feat/orch"
rm -f "$(tpath "other")"

printf '{"version":1,"pieces":' >"$(tpath "broken")"
run --branch "broken" launchable
expect "unreadable tracking file" 1 "" "unreadable tracking file"
rm -f "$(tpath "broken")"

# A stream of two objects (foreign branch first, this branch last) is refused:
# jq -e alone would judge only the last value.
cp "$FIX/all-states.json" "$T/stream.json"
jq -c '.branch = "other" | .pieces = {"77": {"state": "pending", "blockedBy": [], "agent": null, "session": null, "branch": null}}' \
  "$FIX/all-states.json" >>"$T/stream.json"
cp "$T/stream.json" "$(tpath "other")"
run --branch "other" launchable
expect "a JSON stream tracking file is refused" 1 "" "unreadable tracking file"
run --branch "other" launch 77 a s "other-77"
expect "launch on a JSON stream tracking file is refused" 1 "" "unreadable tracking file"
same "refused stream file is left as is" "$T/stream.json" "$(tpath "other")"
rm -f "$(tpath "other")"

track "$B" 0 3 2 '{}' "$(pc 1 bogus)" "$(pc 2 pending)"
cp "$(tpath "$B")" "$T/before.json"
run --branch "$B" launchable
expect "an unknown state is refused" 1 "" "unreadable tracking file"
run --branch "$B" launch 2 a s "$B-2"
expect "launch with an unknown state in the file is refused" 1 "" "unreadable tracking file"
same "unknown-state file is left as is" "$T/before.json" "$(tpath "$B")"

# ------------------------------------------------------------------ launch

track "$B" 0 3 2 '{}' "$(pc 1 pending)" "$(pc 2 pending '[1]')" "$(pc 3 running)"
F="$(tpath "$B")"
run --branch "$B" launch 1 piece-1 sess-1 "$B-1"
expect "launch" 0 "#1 running"
[ "$(jqf "$F" '.pieces["1"] | [.state, .agent, .session, .branch]')" = '["running","piece-1","sess-1","feat/orch-1"]' ] \
  && echo "ok: launch stores agent, session, branch" || fail "launch fields: $(jqf "$F" '.pieces["1"]')"
[ "$(jqf "$F" '.pieces["2"].state')" = '"pending"' ] || fail "launch touched another piece"
run --branch "$B" launchable
expect "launched piece not listed again" 0 ""

cp "$F" "$T/before.json"
run --branch "$B" launch 1 piece-1 sess-1 "$B-1"
expect "launch a running piece" 1 "" "#1 is running, not pending"
same "re-launch writes nothing" "$T/before.json" "$F"
run --branch "$B" launch 9 piece-9 sess-9 "$B-9"
expect "launch unknown issue" 1 "" "unknown issue #9"
same "unknown launch writes nothing" "$T/before.json" "$F"
run --branch "$B" launch 2 piece-2 sess-2 "$B-2"
expect "launch blocked piece" 1 "" "#2 is blocked by #1 (running)"
same "blocked launch writes nothing" "$T/before.json" "$F"

track "$B" 0 3 2 '{"40":"open"}' "$(pc 1 pending '[40]')"
run --branch "$B" launch 1 a s "$B-1"
expect "launch with open external blocker" 1 "" "#1 is blocked by #40 (open)"

track "$B" 0 2 2 '{}' "$(pc 1 running)" "$(pc 2 stuck)" "$(pc 3 pending)"
cp "$F" "$T/before.json"
run --branch "$B" launch 3 a s "$B-3"
expect "launch at live cap" 1 "" "live cap reached (2 live, cap 2)"
same "over-cap launch writes nothing" "$T/before.json" "$F"

track "$B" 2 3 2 '{}' "$(pc 1 pending)"
run --branch "$B" launch 1 a s "$B-1"
expect "launch at depth cap" 1 "" "depth cap reached (depth 2, cap 2)"

track "$B" 0 3 2 '{}' "$(pc 1 pending)"
cp "$F" "$T/before.json"
run --branch "$B" launch 01 a s "$B-1"
expect "launch rejects a non-canonical issue" 2 "" "bad issue"
run --branch "$B" launch 1x a s "$B-1"
expect "launch rejects a non-numeric issue" 2 "" "bad issue"
run --branch "$B" launch 1 "" s "$B-1"
expect "launch rejects an empty agent" 2 "" "bad agent"
run --branch "$B" launch 1 "$(printf 'a\nb')" s "$B-1"
expect "launch rejects a newline in the agent" 2 "" "bad agent"
run --branch "$B" launch 1 a "s 1" "$B-1"
expect "launch rejects whitespace in the session" 2 "" "bad session"
run --branch "$B" launch 1 a s "a..b"
expect "launch rejects a bad piece branch" 2 "" "bad branch"
run --branch "$B" launch 1 a s
expect "launch needs four arguments" 2 ""
same "rejected launches write nothing" "$T/before.json" "$F"

# Session ids and piece branches are unique per orchestrator: a stop must name
# exactly one recorded session.
track "$B" 0 3 2 '{}' "$(pc 1 running)" "$(pc 2 pending)"
cp "$F" "$T/before.json"
run --branch "$B" launch 2 a s-1 "$B-2"
expect "launch refuses a recorded session id" 1 "" "session id s-1 is already recorded on #1"
same "duplicate-session launch writes nothing" "$T/before.json" "$F"
run --branch "$B" launch 2 a s-2 "p/1"
expect "launch refuses a recorded piece branch" 1 "" "piece branch p/1 is already recorded on #1"
same "duplicate-branch launch writes nothing" "$T/before.json" "$F"
run --branch "$B" launch 2 a s-2 "$B"
expect "launch refuses the orchestrator's own branch" 1 "" "piece branch $B is the orchestrator's branch"
same "own-branch launch writes nothing" "$T/before.json" "$F"
run --branch "$B" launch 2 a s-2 "$B-2"
expect "launch with unique names" 0 "#2 running"
track "$B" 0 3 2 '{}' "$(pc 1 pending)"

# Shell metacharacters are stored as data, never run.
MA='a;b $(touch PWNED1) `touch PWNED2` | c & d "q" '"'"'r'"'"' > e'
MS='sess$(touch${IFS}PWNED3)'
MB='piece/$(touch${IFS}PWNED4);`id`&|x'
run --branch "$B" launch 1 "$MA" "$MS" "$MB"
expect "launch with metacharacters" 0 "#1 running"
[ "$(jq -r '.pieces["1"].agent' "$F")" = "$MA" ] && echo "ok: agent stored verbatim" || fail "agent: $(jq -r '.pieces["1"].agent' "$F")"
[ "$(jq -r '.pieces["1"].session' "$F")" = "$MS" ] && echo "ok: session stored verbatim" || fail "session: $(jq -r '.pieces["1"].session' "$F")"
[ "$(jq -r '.pieces["1"].branch' "$F")" = "$MB" ] && echo "ok: branch stored verbatim" || fail "branch: $(jq -r '.pieces["1"].branch' "$F")"
pw="$(find "$T" "$ROOT" -name 'PWNED*' 2>/dev/null)"
[ -z "$pw" ] && echo "ok: nothing executed" || fail "metacharacters executed: $pw"
run --branch "$B" summary
ROW='| #1 | running | piece/$(touch${IFS}PWNED4);`id`&\|x | a;b $(touch PWNED1) `touch PWNED2` \| c & d "q" '"'"'r'"'"' > e |  |'
if printf '%s\n' "$RAW" | grep -qxF -- "$ROW"; then echo "ok: summary escapes pipes in data"
else fail "summary with metacharacters: $RAW"; fi

# A metacharacter orchestrator branch gets its own file and is stored as data.
MOB='orch/$(touch${IFS}PWNED5)'
run --branch "$MOB" register "$FIX/snapshot-chain.json"
expect "register a metacharacter orchestrator branch" 0 "registered 3 pieces for $MOB"
[ "$(jq -r '.branch' "$(tpath "$MOB")")" = "$MOB" ] && echo "ok: orchestrator branch stored verbatim" || fail "orchestrator branch not verbatim"
pw="$(find "$T" "$ROOT" -name 'PWNED*' 2>/dev/null)"
[ -z "$pw" ] || fail "metacharacters executed: $pw"

# ------------------------------------------------------------------ re-register after launch

track "$B" 0 3 2 '{}' "$(pc 34 running)" "$(pc 35 pending '[34]')"
cp "$F" "$T/before.json"
run --branch "$B" register "$FIX/snapshot-chain.json"
expect "re-register after a launch refused" 1 "" "#34 is running"
same "refused re-register writes nothing" "$T/before.json" "$F"

# ------------------------------------------------------------------ summary

cp "$FIX/all-states.json" "$(tpath "feat/orch")"
run --branch "feat/orch" summary
EXP='| Issue | State | Branch | Agent | Blocked by |
|---|---|---|---|---|
| #34 | merged | feat/orch-34 | piece-34 |  |
| #35 | done | feat/orch-35 | piece-35 | #34 |
| #36 | running | feat/orch-36 | piece-36 | #12, #34 |
| #37 | stuck | feat/orch-37 | piece-37 | #35 |
| #38 | failed | feat/orch-38 | piece-38 |  |
| #39 | pending |  |  | #37, #38 |'
if [ "$RC" -eq 0 ] && [ "$RAW" = "$EXP" ]; then echo "ok: summary renders every state"
else fail "summary all states: rc $RC, got:
$RAW"; fi

run --branch "feat/orch" launchable
expect "all-states fixture: live at cap" 0 ""

run --branch "empty" summary
EXP='| Issue | State | Branch | Agent | Blocked by |
|---|---|---|---|---|'
[ "$RC" -eq 0 ] && [ "$RAW" = "$EXP" ] && echo "ok: summary of zero pieces" || fail "summary zero pieces: $RAW"

# ------------------------------------------------------------------ two orchestrators

rm -rf "$SD"
run --branch "a/b" launch 1 a s "a/b-1"
expect "launch with no state dir" 1 "" "no tracking file"
[ ! -e "$SD" ] && echo "ok: a refused launch creates no state dir" || fail "a refused launch created $SD"
printf '{"pieces":[{"issue":1},{"issue":2}]}' >"$T/sa.json"
printf '{"pieces":[{"issue":7}]}' >"$T/sb.json"
run --branch "a/b" register "$T/sa.json"
expect "register a/b" 0 "registered 2 pieces for a/b"
run --branch "a-b" register "$T/sb.json"
expect "register a-b" 0 "registered 1 pieces for a-b"
FA="$(tpath "a/b")"; FB="$(tpath "a-b")"
[ "$FA" != "$FB" ] && [ -f "$FA" ] && [ -f "$FB" ] && echo "ok: a/b and a-b have separate files" || fail "a/b and a-b share $FA"
[ "$(find "$SD" -type f | wc -l | tr -d ' ')" = "2" ] || fail "expected 2 tracking files: $(find "$SD" -type f)"
cp "$FB" "$T/b-before.json"
run --branch "a/b" launch 1 a s "a/b-1"
expect "launch on a/b" 0 "#1 running"
same "a/b launch leaves a-b intact" "$T/b-before.json" "$FB"
run --branch "a/b" launchable
expect "a/b launchable" 0 "2"
run --branch "a-b" launchable
expect "a-b launchable" 0 "7"

# ------------------------------------------------------------------ interrupted writes

# PIECE_TRACK_TEST_ABORT_BEFORE_RENAME makes a write stop after the temp file
# is complete and before the rename, as a crash at that point would.
cp "$FA" "$T/a-before.json"
export PIECE_TRACK_TEST_ABORT_BEFORE_RENAME=1
run --branch "a/b" launch 2 a s2 "a/b-2"
expect "aborted launch fails" 2 "" "aborting before rename"
same "aborted launch leaves the old file" "$T/a-before.json" "$FA"
no_tmp "aborted launch leaves no temp file"

cp "$FB" "$T/b-before.json"
run --branch "a-b" register "$T/sa.json"
expect "aborted re-register fails" 2 "" "aborting before rename"
same "aborted re-register leaves the old file" "$T/b-before.json" "$FB"
no_tmp "aborted re-register leaves no temp file"

run --branch "new" register "$T/sa.json"
expect "aborted first register fails" 2 "" "aborting before rename"
[ ! -e "$SD/new.json" ] && echo "ok: aborted first register leaves no file" || fail "aborted first register wrote $SD/new.json"
no_tmp "aborted first register leaves no temp file"
unset PIECE_TRACK_TEST_ABORT_BEFORE_RENAME

# A real I/O failure: the temp file cannot be created in a read-only state dir.
chmod 555 "$SD"
run --branch "a/b" launch 2 a s2 "a/b-2"
chmod 755 "$SD"
expect "unwritable state dir fails the launch" 2 "" "cannot write"
same "unwritable state dir leaves the old file" "$T/a-before.json" "$FA"
no_tmp "unwritable state dir leaves no temp file"
run --branch "a/b" launch 2 a s2 "a/b-2"
expect "launch succeeds once writable" 0 "#2 running"

# ------------------------------------------------------------------ locking
#
# Writers hold one lock per tracking file across the whole transaction.
# PIECE_TRACK_TEST_HOLD_LOCK=<f> makes a writer, once it holds the lock, create
# <f>.held and wait until <f> exists; PIECE_TRACK_TEST_LOCK_WAITING=<f> makes a
# writer create <f> the first time it finds the lock busy. Together they order
# two writers deterministically, without timing races.

LT="$T/lock"
mkdir -p "$LT"
LASTPID=""
# start <tag> <args...> — runs piece-track.sh in the background (exported hook
# variables are inherited); LASTPID is its pid.
start() {
  tag="$1"; shift
  ( cd "$W" && PIECE_TRACK_DIR="$SD" exec "$BASH" "$PT" "$@" ) >"$LT/$tag.out" 2>"$LT/$tag.err" &
  LASTPID=$!
}
# finish <pid> <tag> — waits for it; sets RC, OUT, ERR.
finish() {
  wait "$1"
  RC=$?
  OUT="$(tr '\n' ' ' <"$LT/$2.out" | sed 's/ $//')"
  ERR="$(cat "$LT/$2.err")"
}
# waitf <file> — waits up to 10 s for <file> to exist.
waitf() {
  i=0
  while [ ! -e "$1" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$1" ]
}
# race <name> <args A...> -- <args B...> — A takes the lock and holds it; B
# starts, finds the lock busy and waits; then A is released. Leaves RCA/OUTA/
# ERRA and RC/OUT/ERR (for B).
race() {
  rname="$1"; shift
  na=0
  for x in "$@"; do [ "$x" = "--" ] && break; na=$((na + 1)); done
  rm -f "$LT"/go "$LT"/go.held "$LT"/b.waiting
  export PIECE_TRACK_TEST_HOLD_LOCK="$LT/go"
  start a "${@:1:$na}"
  pa=$LASTPID
  unset PIECE_TRACK_TEST_HOLD_LOCK
  waitf "$LT/go.held" || fail "$rname: first writer never held the lock"
  shift "$((na + 1))"
  export PIECE_TRACK_TEST_LOCK_WAITING="$LT/b.waiting"
  start b "$@"
  pb=$LASTPID
  unset PIECE_TRACK_TEST_LOCK_WAITING
  waitf "$LT/b.waiting" || fail "$rname: second writer never waited for the lock"
  : >"$LT/go"
  finish "$pa" a
  RCA=$RC; OUTA=$OUT; ERRA=$ERR
  finish "$pb" b
}

# Two launches race for the last slot: exactly one wins.
track "$B" 0 2 2 '{}' "$(pc 1 running)" "$(pc 2 pending)" "$(pc 3 pending)"
F="$(tpath "$B")"
LK="$(dirname "$F")/.$(basename "$F").lock"
race "last slot" --branch "$B" launch 2 a2 s2 "$B-2" -- --branch "$B" launch 3 a3 s3 "$B-3"
[ "$RCA" -eq 0 ] && [ "$OUTA" = "#2 running" ] && echo "ok: first racing launch takes the last slot" \
  || fail "first racing launch: rc $RCA ($OUTA) ($ERRA)"
expect "second racing launch refuses at the cap" 1 "" "live cap reached (2 live, cap 2)"
[ "$(jqf "$F" '[.pieces | to_entries[] | select(.value.state == "running") | .key]')" = '["1","2"]' ] \
  && echo "ok: exactly one new running piece" || fail "last slot: $(jqf "$F" '.pieces')"
no_tmp "no lock left after a race"

# Two launches under the cap: both persist (no lost update).
track "$B" 0 3 2 '{}' "$(pc 1 pending)" "$(pc 2 pending)"
race "under cap" --branch "$B" launch 1 a1 s1 "$B-1" -- --branch "$B" launch 2 a2 s2 "$B-2"
[ "$RCA" -eq 0 ] || fail "under cap: first launch rc $RCA ($ERRA)"
expect "second concurrent launch under the cap" 0 "#2 running"
[ "$(jqf "$F" '[.pieces[] | [.state, .session]]')" = '[["running","s1"],["running","s2"]]' ] \
  && echo "ok: concurrent launches both persist" || fail "lost update: $(jqf "$F" '.pieces')"

# register waiting behind a launch sees the launch and refuses.
track "$B" 0 3 2 '{"12":"closed"}' "$(pc 34 pending)" "$(pc 35 pending '[34]')" "$(pc 36 pending '[12,34]')"
race "register vs launch" --branch "$B" launch 34 a34 s34 "$B-34" -- --branch "$B" register "$FIX/snapshot-chain.json"
[ "$RCA" -eq 0 ] || fail "register vs launch: launch rc $RCA ($ERRA)"
expect "register behind a launch refuses" 1 "" "#34 is running"
[ "$(jqf "$F" '.pieces["34"].state')" = '"running"' ] && echo "ok: launched piece stays running" \
  || fail "register reset the launch: $(jqf "$F" '.pieces["34"]')"
no_tmp "no lock left after a refusal"

# The lock is a symlink whose target is the holder's pid; a stale-lock breaker
# first takes the guard <lock>.break.<dead pid>, also a pid symlink.
# PIECE_TRACK_TEST_HOLD_BREAK=<f> makes a breaker, once it holds a guard,
# create <f>.held and wait until <f> exists.

# dead_pid — the pid of a process that has exited.
dead_pid() {
  sh -c 'exit 0' &
  dp=$!
  wait "$dp"
  printf '%s' "$dp"
}
# hold_start <hook-var> <tag> <args...> — starts a writer with <hook-var>=$LT/go
# and waits until it reports it holds the lock or guard; LASTPID is its pid.
hold_start() {
  hv="$1"; shift
  rm -f "$LT/go" "$LT/go.held" "$LT/b.waiting"
  export "$hv=$LT/go"
  start "$@"
  unset "$hv"
  waitf "$LT/go.held" || fail "$1: never reached its hold point"
}

# A holder killed with SIGKILL inside the lock leaves a pid-named lock that a
# later writer breaks, with no manual cleanup.
track "$B" 0 3 2 '{}' "$(pc 1 pending)" "$(pc 2 pending)"
hold_start PIECE_TRACK_TEST_HOLD_LOCK k --branch "$B" launch 1 a1 s1 "$B-1"
pk=$LASTPID
[ "$(readlink "$LK")" = "$pk" ] && echo "ok: the lock names its holder's pid" || fail "lock target: $(readlink "$LK")"
kill -9 "$pk"; wait "$pk" 2>/dev/null
run --branch "$B" launch 2 a2 s2 "$B-2"
expect "a writer after a killed holder succeeds" 0 "#2 running"
[ "$(jqf "$F" '[.pieces[] | .state]')" = '["pending","running"]' ] || fail "killed holder wrote: $(jqf "$F" '.pieces')"
no_tmp "a killed holder's lock is cleaned up"

# A breaker killed with SIGKILL while holding its guard: a later writer breaks
# the abandoned guard, then the stale lock, with no manual cleanup.
track "$B" 0 3 2 '{}' "$(pc 1 pending)" "$(pc 2 pending)"
d="$(dead_pid)"
ln -s "$d" "$LK"
hold_start PIECE_TRACK_TEST_HOLD_BREAK k --branch "$B" launch 1 a1 s1 "$B-1"
pk=$LASTPID
[ "$(readlink "$LK.break.$d")" = "$pk" ] && echo "ok: the breaker holds the guard for the dead pid" \
  || fail "guard: $(ls -la "$SD")"
kill -9 "$pk"; wait "$pk" 2>/dev/null
run --branch "$B" launch 2 a2 s2 "$B-2"
expect "a writer after a killed breaker succeeds" 0 "#2 running"
no_tmp "a killed breaker's guard is cleaned up"

# Two breakers of one stale lock: the second waits on the guard and does not
# remove the lock; the first breaks it; both launches then land.
track "$B" 0 3 2 '{}' "$(pc 1 pending)" "$(pc 2 pending)"
d="$(dead_pid)"
ln -s "$d" "$LK"
hold_start PIECE_TRACK_TEST_HOLD_BREAK a --branch "$B" launch 1 a1 s1 "$B-1"
pa=$LASTPID
export PIECE_TRACK_TEST_LOCK_WAITING="$LT/b.waiting"
start b --branch "$B" launch 2 a2 s2 "$B-2"
pb=$LASTPID
unset PIECE_TRACK_TEST_LOCK_WAITING
waitf "$LT/b.waiting" || fail "second breaker never waited"
[ "$(readlink "$LK")" = "$d" ] && echo "ok: the second breaker leaves the stale lock alone" || fail "second breaker removed the lock"
[ "$(readlink "$LK.break.$d")" = "$pa" ] && echo "ok: the first breaker keeps its guard" || fail "guard taken over"
: >"$LT/go"
finish "$pa" a
expect "first breaker launches" 0 "#1 running"
finish "$pb" b
expect "second breaker launches after it" 0 "#2 running"
no_tmp "no lock or guard left after two breakers"

# The stale lock is replaced by a live holder while the breaker holds its
# guard: the breaker re-checks, leaves the live lock, and times out.
track "$B" 0 3 2 '{}' "$(pc 1 pending)"
cp "$F" "$T/before.json"
d="$(dead_pid)"
ln -s "$d" "$LK"
sleep 30 &
live=$!
export PIECE_TRACK_LOCK_TIMEOUT=1
hold_start PIECE_TRACK_TEST_HOLD_BREAK a --branch "$B" launch 1 a1 s1 "$B-1"
pa=$LASTPID
unset PIECE_TRACK_LOCK_TIMEOUT
rm -f "$LK" && ln -s "$live" "$LK"
: >"$LT/go"
finish "$pa" a
expect "a breaker facing a re-taken lock times out" 1 "" "lock held by pid $live"
[ "$(readlink "$LK")" = "$live" ] && echo "ok: the breaker leaves the re-taken live lock" || fail "live lock removed"
same "breaker facing a live lock writes nothing" "$T/before.json" "$F"
kill "$live" 2>/dev/null
wait "$live" 2>/dev/null
rm -f "$LK"
no_tmp "no guard left after the re-taken lock"

# A stale lock this user cannot remove ends in a bounded refusal.
d="$(dead_pid)"
ln -s "$d" "$LK"
chmod 555 "$SD"
t0="$(date +%s)"
export PIECE_TRACK_LOCK_TIMEOUT=1
run --branch "$B" launch 1 a1 s1 "$B-1"
unset PIECE_TRACK_LOCK_TIMEOUT
t1="$(date +%s)"
chmod 755 "$SD"
expect "an unremovable stale lock is refused" 1 "" "stale lock of dead pid $d cannot be broken"
[ $((t1 - t0)) -le 4 ] && echo "ok: the refusal is bounded ($((t1 - t0)) s)" || fail "unremovable stale lock took $((t1 - t0)) s"
rm -f "$LK"

# A stale lock (holder pid dead) is broken.
track "$B" 0 3 2 '{}' "$(pc 1 pending)" "$(pc 2 pending)"
ln -s "$(dead_pid)" "$LK"
run --branch "$B" launch 1 a1 s1 "$B-1"
expect "a stale lock is broken" 0 "#1 running"
no_tmp "no lock left after breaking a stale lock"

# A live holder past the timeout: refused, nothing written, its lock kept.
sleep 30 &
live=$!
ln -s "$live" "$LK"
cp "$F" "$T/before.json"
export PIECE_TRACK_LOCK_TIMEOUT=1
run --branch "$B" launch 2 a2 s2 "$B-2"
unset PIECE_TRACK_LOCK_TIMEOUT
expect "a live lock times out" 1 "" "lock held by pid $live"
same "timed-out launch writes nothing" "$T/before.json" "$F"
[ "$(readlink "$LK")" = "$live" ] && echo "ok: a live holder's lock is not broken" || fail "live lock was broken"
kill "$live" 2>/dev/null
wait "$live" 2>/dev/null
rm -f "$LK"

export PIECE_TRACK_LOCK_TIMEOUT=x
run --branch "$B" launch 2 a2 s2 "$B-2"
unset PIECE_TRACK_LOCK_TIMEOUT
expect "bad lock timeout" 2 "" "PIECE_TRACK_LOCK_TIMEOUT"

export PIECE_TRACK_TEST_ABORT_BEFORE_RENAME=1
run --branch "$B" launch 2 a2 s2 "$B-2"
unset PIECE_TRACK_TEST_ABORT_BEFORE_RENAME
expect "abort with the lock held" 2 "" "aborting before rename"
no_tmp "no lock left after the abort path"
run --branch "$B" launch 2 a2 s2 "$B-2"
expect "launch after the lock tests" 0 "#2 running"
no_tmp "no lock left after a success"
run --branch "$B" launch 2 a2 s2 "$B-2"
expect "refusal after the lock tests" 1 "" "not pending"
no_tmp "no lock left after a refusal"
run --branch "$B" launch 2 "" s2 "$B-2"
expect "usage error with the lock held" 2 "" "bad agent"
no_tmp "no lock left after a usage error"

# ------------------------------------------------------------------ git default location

G="$T/repo"
git init -q "$G"
git -C "$G" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
git -C "$G" checkout -q -b "feat/git-orch"
git -C "$G" worktree add -q -b "wt/child" "$T/wt" >/dev/null 2>&1
GCD="$(cd "$G/.git" && pwd -P)"
# rung <dir> <args...> — runs piece-track.sh in <dir> with no PIECE_TRACK_DIR.
rung() {
  d="$1"; shift
  RAW="$(cd "$d" && env -u PIECE_TRACK_DIR "$BASH" "$PT" "$@" 2>"$T/err")"
  RC=$?
  OUT="$(printf '%s' "$RAW" | tr '\n' ' ' | sed 's/ $//')"
  ERR="$(cat "$T/err")"
}
rung "$G" path
expect "default path from the current branch" 0 "$GCD/piece-tracking/feat%2Fgit-orch.json"
rung "$T/wt" path
expect "a linked worktree uses the common dir" 0 "$GCD/piece-tracking/wt%2Fchild.json"
rung "$T/wt" register "$FIX/snapshot-chain.json"
expect "register from a worktree" 0 "registered 3 pieces for wt/child"
[ -f "$GCD/piece-tracking/wt%2Fchild.json" ] && echo "ok: tracking file under the git common dir" || fail "no file under $GCD/piece-tracking"
git -C "$G" checkout -q --detach
rung "$G" path
expect "detached HEAD needs --branch" 2 "" "--branch"
rung "$G" --branch "x/y" path
expect "--branch overrides HEAD" 0 "$GCD/piece-tracking/x%2Fy.json"

# ------------------------------------------------------------------ usage

run
expect "no subcommand" 2 ""
for sub in path register launchable launch summary; do
  case "$ERR" in *"piece-track.sh [--branch <b>] $sub"*) echo "ok: usage lists $sub" ;;
    *) fail "usage lacks $sub: $ERR" ;; esac
done
run --branch "$B" frobnicate
expect "unknown subcommand" 2 ""
run --branch
expect "--branch needs a value" 2 ""

if [ "$FAIL" -ne 0 ]; then exit 1; fi
echo "all piece-track tests passed"
