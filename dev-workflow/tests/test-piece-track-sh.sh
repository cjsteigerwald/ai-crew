#!/usr/bin/env bash
# Behavioral test for coordinating-partner-sessions/scripts/piece-track.sh:
# register, launchable, launch, record, merged, failed, dropped, finished,
# summary and path, driven by JSON fixtures with
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

# no_tmp <name> — nothing left in the state dir but tracking files and their
# persistent lock files (.<enc>.json.lock, regular files).
no_tmp() {
  left="$(find "$SD" -mindepth 1 ! \( -type f -name '.*.json.lock' \) \
            \( -name '.*' -o ! -type f -o ! -name '*.json' \) 2>/dev/null)"
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
ROW='| #1 | running | piece/$(touch${IFS}PWNED4);`id`&\|x | a;b $(touch PWNED1) `touch PWNED2` \| c & d "q" '"'"'r'"'"' > e |  |  |'
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
EXP='| Issue | State | Branch | Agent | Blocked by | Notes |
|---|---|---|---|---|---|
| #34 | merged | feat/orch-34 | piece-34 |  |  |
| #35 | done | feat/orch-35 | piece-35 | #34 |  |
| #36 | running | feat/orch-36 | piece-36 | #12, #34 |  |
| #37 | stuck | feat/orch-37 | piece-37 | #35 |  |
| #38 | failed | feat/orch-38 | piece-38 |  |  |
| #39 | pending |  |  | #37, #38 |  |'
if [ "$RC" -eq 0 ] && [ "$RAW" = "$EXP" ]; then echo "ok: summary renders every state"
else fail "summary all states: rc $RC, got:
$RAW"; fi

run --branch "feat/orch" launchable
expect "all-states fixture: live at cap" 0 ""

run --branch "empty" summary
EXP='| Issue | State | Branch | Agent | Blocked by | Notes |
|---|---|---|---|---|---|'
[ "$RC" -eq 0 ] && [ "$RAW" = "$EXP" ] && echo "ok: summary of zero pieces" || fail "summary zero pieces: $RAW"

# ------------------------------------------------------------------ record

SHA="0123456789abcdef0123456789abcdef01234567"
SHA2="89abcdef0123456789abcdef0123456789abcdef"
track "$B" 0 3 2 '{}' "$(pc 1 running)" "$(pc 2 pending '[1]')" "$(pc 3 running)"
F="$(tpath "$B")"

# piece <n> — one piece of $F, compact.
piece() { jqf "$F" ".pieces[\"$1\"]"; }

# rec_bad <name> <line> <stderr substring> — record refuses <line> (rc 1) and
# leaves the tracking file byte-identical.
rec_bad() {
  cp "$F" "$T/before.json"
  run --branch "$B" record "$2"
  expect "$1" 1 "" "$3"
  same "$1: nothing written" "$T/before.json" "$F"
}
# rec_same <name> <line> <stdout> — record accepts <line> (rc 0) as a no-op:
# the tracking file stays byte-identical and is not even rewritten (a rename
# would give it a new inode).
rec_same() {
  cp "$F" "$T/before.json"
  ino="$(ls -i "$F" | awk '{print $1}')"
  run --branch "$B" record "$2"
  expect "$1" 0 "$3"
  same "$1: file unchanged" "$T/before.json" "$F"
  [ "$(ls -i "$F" | awk '{print $1}')" = "$ino" ] || fail "$1: file rewritten"
}

# Malformed lines: rc 1, nothing written.
rec_bad "empty line" "" "missing fields"
rec_bad "keyword only" "STARTED" "missing fields"
rec_bad "lowercase keyword" "started #1" "unknown report"
rec_bad "unknown keyword" "MERGED #1" "unknown report"
rec_bad "SCOPE is dropped" "SCOPE #1 too big for one PR" "unknown report"
rec_bad "FAILED is dropped" "FAILED #1 user cancelled" "unknown report"
rec_bad "issue without #" "STARTED 1" "bad issue"
rec_bad "non-integer issue" "STARTED #x" "bad issue"
rec_bad "fractional issue" "STARTED #1.5" "bad issue"
rec_bad "leading-zero issue" "STARTED #01" "bad issue"
rec_bad "zero issue" "STARTED #0" "bad issue"
rec_bad "STARTED extra token" "STARTED #1 extra" "unexpected trailing text"
rec_bad "old gen field" "STARTED #1 gen=1" "unexpected trailing text"
rec_bad "DONE missing branch and sha" "DONE #1" "missing DONE fields"
rec_bad "DONE missing sha" "DONE #1 p/1" "missing DONE fields"
rec_bad "DONE short sha" "DONE #1 p/1 ${SHA:0:39}" "bad sha"
rec_bad "DONE long sha" "DONE #1 p/1 ${SHA}0" "bad sha"
rec_bad "DONE uppercase sha" "DONE #1 p/1 0123456789ABCDEF0123456789ABCDEF01234567" "bad sha"
rec_bad "DONE extra token" "DONE #1 p/1 $SHA extra" "unexpected trailing text"
rec_bad "DONE old frame (gen, synced)" "DONE #1 gen=2 p/1 $SHA synced=$SHA" "unexpected trailing text"
rec_bad "DONE bad branch .." "DONE #1 a..b $SHA" "bad branch"
rec_bad "DONE bad branch leading dash" "DONE #1 -x $SHA" "bad branch"
rec_bad "STUCK without reason" "STUCK #1" "missing reason"
rec_bad "STUCK needs without reason" "STUCK #1 needs=#3" "missing reason"
rec_bad "STUCK blank reason" "STUCK #1    " "missing reason"
rec_bad "STUCK needs without #" "STUCK #1 needs=3 waits on schema" "bad needs"
rec_bad "STUCK empty needs" "STUCK #1 needs= waits on schema" "bad needs"
rec_bad "embedded newline" "$(printf 'STARTED #1\nDONE #1 p/1 %s' "$SHA")" "control character"
rec_bad "embedded carriage return" "$(printf 'STARTED\r #1')" "control character"
rec_bad "embedded tab" "$(printf 'STUCK #1 a\tb')" "control character"
run --branch "$B" record
expect "record needs a line" 2 ""
run --branch "$B" record "STARTED #1" "DONE #1 p/1 $SHA"
expect "record takes one line" 2 ""

# Unknown issue, never-launched piece, branch mismatch.
rec_bad "unknown issue" "STARTED #9" "unknown issue #9"
rec_bad "pending piece STARTED" "STARTED #2" "#2 is pending (never launched)"
rec_bad "pending piece DONE" "DONE #2 p/2 $SHA" "#2 is pending (never launched)"
rec_bad "pending piece STUCK" "STUCK #2 cannot start" "#2 is pending (never launched)"
rec_bad "DONE on another branch" "DONE #1 p/3 $SHA" "#1 reported branch p/3, launched on p/1"
rec_bad "STUCK needs an unknown issue" "STUCK #1 needs=#9 waits" "needs unknown issue #9"
rec_bad "STUCK needs itself" "STUCK #1 needs=#1 waits" "#1 cannot need itself"

# STARTED on a running piece is accepted and changes nothing.
rec_same "STARTED" "STARTED #1" "#1 running"
rec_same "STARTED with CRLF and trailing spaces" "$(printf 'STARTED #1  \r')" "#1 running"

# DONE stores the SHA; a repeat is a no-op; a late STARTED does not regress.
run --branch "$B" record "DONE #1 p/1 $SHA"
expect "DONE" 0 "#1 done"
[ "$(piece 1)" = '{"state":"done","blockedBy":[],"agent":"a-1","session":"s-1","branch":"p/1","sha":"'"$SHA"'"}' ] \
  && echo "ok: DONE stores the SHA" || fail "DONE: $(piece 1)"
rec_same "repeated DONE is idempotent" "DONE #1 p/1 $SHA" "#1 done"
rec_same "late STARTED after DONE" "STARTED #1" "#1 done"

# DONE with a new SHA (the resync re-report) replaces the SHA.
run --branch "$B" record "DONE #1 p/1 $SHA2"
expect "DONE with a new SHA" 0 "#1 done"
[ "$(jqf "$F" '.pieces["1"] | [.state, .sha]')" = '["done","'"$SHA2"'"]' ] \
  && echo "ok: the new SHA replaces the old" || fail "resync DONE: $(piece 1)"

# STUCK after DONE: stuck, SHA kept, needs and reason stored.
run --branch "$B" record "STUCK #1 needs=#3 waits on #3's schema"
expect "STUCK with needs (after DONE)" 0 "#1 stuck"
[ "$(jqf "$F" '.pieces["1"] | [.state, .sha, .needs, .reason]')" = '["stuck","'"$SHA2"'",3,"waits on #3'"'"'s schema"]' ] \
  && echo "ok: STUCK stores needs and reason and keeps the SHA" || fail "STUCK with needs: $(piece 1)"
rec_same "repeated STUCK is idempotent" "STUCK #1 needs=#3 waits on #3's schema" "#1 stuck"
rec_same "STARTED after STUCK leaves it stuck" "STARTED #1" "#1 stuck"
run --branch "$B" record "STUCK #1 cannot   reach the test db"
expect "STUCK without needs" 0 "#1 stuck"
[ "$(jqf "$F" '.pieces["1"] | [.state, .needs, .reason]')" = '["stuck",null,"cannot   reach the test db"]' ] \
  && echo "ok: STUCK without needs clears needs, keeps inner spacing" || fail "STUCK without needs: $(piece 1)"

# DONE after STUCK: done again, the stuck note cleared.
run --branch "$B" record "DONE #1 p/1 $SHA"
expect "DONE after STUCK" 0 "#1 done"
[ "$(piece 1)" = '{"state":"done","blockedBy":[],"agent":"a-1","session":"s-1","branch":"p/1","sha":"'"$SHA"'"}' ] \
  && echo "ok: DONE after STUCK clears needs and reason" || fail "DONE after STUCK: $(piece 1)"

# STUCK from running.
run --branch "$B" record "STUCK #3 flaky CI"
expect "STUCK from running" 0 "#3 stuck"
[ "$(jqf "$F" '.pieces["3"] | [.state, .needs, .reason, .sha]')" = '["stuck",null,"flaky CI",null]' ] \
  || fail "STUCK from running: $(piece 3)"

# Report text is data: shell metacharacters are stored and rendered verbatim.
MR='$(touch PWNED6); `touch PWNED7` | a & b "q" '"'"'r'"'"' > e \n ${IFS} *'
run --branch "$B" record "STUCK #3 needs=#1 $MR"
expect "STUCK with metacharacters" 0 "#3 stuck"
[ "$(jq -r '.pieces["3"].reason' "$F")" = "$MR" ] && echo "ok: reason stored verbatim" \
  || fail "reason: $(jq -r '.pieces["3"].reason' "$F")"
pw="$(find "$T" "$ROOT" -name 'PWNED*' 2>/dev/null)"
[ -z "$pw" ] && echo "ok: report text not executed" || fail "report text executed: $pw"
run --branch "$B" summary
ROW='| #3 | stuck | p/3 | a-3 |  | needs #1: $(touch PWNED6); `touch PWNED7` \| a & b "q" '"'"'r'"'"' > e \n ${IFS} * |'
if printf '%s\n' "$RAW" | grep -qxF -- "$ROW"; then echo "ok: summary shows stuck needs and reason, pipes escaped"
else fail "summary stuck row: $RAW"; fi
pw="$(find "$T" "$ROOT" -name 'PWNED*' 2>/dev/null)"
[ -z "$pw" ] || fail "summary executed report text: $pw"

# Reports on merged, failed and dropped pieces are refused; an identical
# repeat of the DONE that preceded merged is a no-op.
run --branch "$B" merged 1
expect "merged after DONE" 0 "#1 merged"
rec_same "repeated DONE after merged" "DONE #1 p/1 $SHA" "#1 merged"
rec_bad "DONE with another SHA after merged" "DONE #1 p/1 $SHA2" "#1 is merged"
rec_bad "STARTED after merged" "STARTED #1" "#1 is merged"
rec_bad "STUCK after merged" "STUCK #1 oops" "#1 is merged"
track "$B" 0 3 2 '{}' "$(pc 1 failed)" "$(pc 2 dropped)"
for st in failed dropped; do
  n=1; [ "$st" = "dropped" ] && n=2
  rec_bad "STARTED on $st" "STARTED #$n" "#$n is $st"
  rec_bad "DONE on $st" "DONE #$n p/$n $SHA" "#$n is $st"
  rec_bad "STUCK on $st" "STUCK #$n x" "#$n is $st"
done

# ------------------------------------------------------------------ merged, failed, dropped

# mark_bad <name> <cmd> <issue> <rc> <stderr substring> — refused, nothing written.
mark_bad() {
  cp "$F" "$T/before.json"
  run --branch "$B" "$2" "$3"
  expect "$1" "$4" "" "$5"
  same "$1: nothing written" "$T/before.json" "$F"
}
# mark_ok <name> <cmd> <issue> <state> — accepted; the piece is now <state>
# and its other fields are kept.
mark_ok() {
  pre="$(jqf "$F" ".pieces[\"$3\"] | del(.state)")"
  run --branch "$B" "$2" "$3"
  expect "$1" 0 "#$3 $4"
  [ "$(jqf "$F" ".pieces[\"$3\"].state")" = "\"$4\"" ] && [ "$(jqf "$F" ".pieces[\"$3\"] | del(.state)")" = "$pre" ] \
    || fail "$1: $(jqf "$F" ".pieces[\"$3\"]")"
}

track "$B" 0 3 2 '{}' "$(pc 1 pending)" "$(pc 2 running)" "$(pc 3 stuck)" "$(pc 4 failed)" \
  "$(pc 5 dropped)" "$(pc 6 merged)" "$(pc 7 "done")"
for n in 1 2 3 4 5 6; do
  st="$(jq -r ".pieces[\"$n\"].state" "$F")"
  mark_bad "merged from $st" merged "$n" 1 "#$n is $st, not done"
done
mark_bad "merged unknown issue" merged 9 1 "unknown issue #9"
mark_bad "merged bad issue" merged x 2 "bad issue"
mark_bad "merged needs one issue" merged "" 2 ""
mark_ok "merged from done" merged 7 merged

track "$B" 0 3 2 '{}' "$(pc 1 pending)" "$(pc 2 running)" "$(pc 3 stuck)" "$(pc 4 failed)" \
  "$(pc 5 dropped)" "$(pc 6 merged)" "$(pc 7 "done")"
for n in 1 4 5 6; do
  st="$(jq -r ".pieces[\"$n\"].state" "$F")"
  mark_bad "failed from $st" failed "$n" 1 "#$n is $st"
done
mark_bad "failed unknown issue" failed 9 1 "unknown issue #9"
mark_bad "failed bad issue" failed 01 2 "bad issue"
mark_ok "failed from running" failed 2 failed
mark_ok "failed from stuck" failed 3 failed
mark_ok "failed from done" failed 7 failed

track "$B" 0 3 2 '{}' "$(pc 1 pending)" "$(pc 2 running)" "$(pc 3 stuck)" "$(pc 4 failed)" \
  "$(pc 5 dropped)" "$(pc 6 merged)" "$(pc 7 "done")"
mark_bad "dropped from merged" dropped 6 1 "#6 is merged"
mark_bad "dropped unknown issue" dropped 9 1 "unknown issue #9"
mark_bad "dropped bad issue" dropped "1 2" 2 "bad issue"
for n in 1 2 3 4 7; do
  st="$(jq -r ".pieces[\"$n\"].state" "$F")"
  mark_ok "dropped from $st" dropped "$n" dropped
done
cp "$F" "$T/before.json"
ino="$(ls -i "$F" | awk '{print $1}')"
run --branch "$B" dropped 5
expect "dropped again is a no-op" 0 "#5 dropped"
same "dropped again writes nothing" "$T/before.json" "$F"
[ "$(ls -i "$F" | awk '{print $1}')" = "$ino" ] || fail "dropped again rewrote the file"

# merged releases dependants; dropped frees a live slot but not its dependants.
track "$B" 0 3 2 '{}' "$(pc 1 "done")" "$(pc 2 pending '[1]')"
run --branch "$B" launchable
expect "done blocker holds the dependant" 0 ""
run --branch "$B" merged 1
expect "merged" 0 "#1 merged"
run --branch "$B" launchable
expect "merged releases the dependant" 0 "2"

track "$B" 0 1 2 '{}' "$(pc 1 running)" "$(pc 2 pending)" "$(pc 3 pending '[1]')"
run --branch "$B" launchable
expect "live cap 1 taken" 0 ""
run --branch "$B" dropped 1
expect "drop the running piece" 0 "#1 dropped"
run --branch "$B" launchable
expect "a dropped piece is not live; its dependant stays blocked" 0 "2"
run --branch "$B" launch 3 a3 s3 "$B-3"
expect "launch behind a dropped piece" 1 "" "#3 is blocked by #1 (dropped)"

# ------------------------------------------------------------------ finished

# fin <name> <want> <piece>... — finished on a fresh tracking file.
fin() {
  fname="$1"; want="$2"; shift 2
  track fin 0 3 2 '{}' "$@"
  run --branch fin finished
  expect "finished: $fname" 0 "$want"
}
fin "all merged" true "$(pc 1 merged)" "$(pc 2 merged)"
fin "one stuck" false "$(pc 1 merged)" "$(pc 2 stuck)"
fin "one failed" false "$(pc 1 merged)" "$(pc 2 failed)"
fin "one dropped, the rest merged" true "$(pc 1 merged)" "$(pc 2 dropped)" "$(pc 3 merged)"
fin "one running" false "$(pc 1 merged)" "$(pc 2 running)"
fin "one done" false "$(pc 1 merged)" "$(pc 2 "done")"
fin "one pending" false "$(pc 1 merged)" "$(pc 2 pending)"
fin "zero pieces" true
FN="$(tpath fin)"
[ ! -e "$(dirname "$FN")/.$(basename "$FN").lock" ] && echo "ok: finished takes no lock" \
  || fail "finished created a lock file"
run --branch fin finished extra
expect "finished takes no arguments" 2 ""
run --branch nobody finished
expect "finished with no tracking file" 1 "" "no tracking file"

# ------------------------------------------------------------------ summary: not delivered

# #2 dropped; #3 behind it; #4 behind #3 (transitive); #5 behind merged #1
# only; #6 behind #4 and a dropped #7; #8 stuck with needs and a reason.
track "$B" 0 3 2 '{}' "$(pc 1 merged)" "$(pc 2 dropped '[1]')" "$(pc 3 pending '[2]')" \
  "$(pc 4 pending '[1,3]')" "$(pc 5 pending '[1]')" "$(pc 6 pending '[4,7]')" "$(pc 7 dropped)" \
  '"8":{"state":"stuck","blockedBy":[1],"agent":"a-8","session":"s-8","branch":"p/8","needs":5,"reason":"a|b\nc"}'
run --branch "$B" summary
EXP='| Issue | State | Branch | Agent | Blocked by | Notes |
|---|---|---|---|---|---|
| #1 | merged | p/1 | a-1 |  |  |
| #2 | dropped | p/2 | a-2 | #1 | not delivered (dropped) |
| #3 | pending |  |  | #2 | not delivered (blocked by dropped #2) |
| #4 | pending |  |  | #1, #3 | not delivered (blocked by dropped #2) |
| #5 | pending |  |  | #1 |  |
| #6 | pending |  |  | #4, #7 | not delivered (blocked by dropped #2, #7) |
| #7 | dropped | p/7 | a-7 |  | not delivered (dropped) |
| #8 | stuck | p/8 | a-8 | #1 | needs #5: a\|b c |'
if [ "$RC" -eq 0 ] && [ "$RAW" = "$EXP" ]; then echo "ok: summary lists dropped and blocked-by-dropped as not delivered"
else fail "summary not delivered: rc $RC, got:
$RAW"; fi

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
[ "$(find "$SD" -type f -name '*.json' ! -name '.*' | wc -l | tr -d ' ')" = "2" ] || fail "expected 2 tracking files: $(find "$SD" -type f)"
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


# hold_start <tag> <args...> — starts a writer that, once it holds the lock,
# waits until $LT/go exists; returns when it holds the lock. LASTPID is its pid.
hold_start() {
  rm -f "$LT/go" "$LT/go.held" "$LT/b.waiting"
  export PIECE_TRACK_TEST_HOLD_LOCK="$LT/go"
  start "$@"
  unset PIECE_TRACK_TEST_HOLD_LOCK
  waitf "$LT/go.held" || fail "$1: never held the lock"
}

# A live holder past the timeout: refused with its pid, nothing written; the
# holder then finishes normally.
track "$B" 0 3 2 '{}' "$(pc 1 pending)" "$(pc 2 pending)"
cp "$F" "$T/before.json"
hold_start a --branch "$B" launch 1 a1 s1 "$B-1"
pa=$LASTPID
export PIECE_TRACK_LOCK_TIMEOUT=1
run --branch "$B" launch 2 a2 s2 "$B-2"
unset PIECE_TRACK_LOCK_TIMEOUT
expect "a live lock times out" 1 "" "lock busy (held by pid $pa)"
same "timed-out launch writes nothing" "$T/before.json" "$F"
: >"$LT/go"
finish "$pa" a
expect "the holder finishes after another writer timed out" 0 "#1 running"
[ -f "$LK" ] && [ ! -L "$LK" ] && echo "ok: the lock is a persistent regular file" || fail "lock file: $(ls -la "$SD")"
no_tmp "only the lock file is left after a timeout"

# record, merged, failed and dropped take the same lock: against a live holder
# each times out, writing nothing.
track "$B" 0 3 2 '{}' "$(pc 1 running)" "$(pc 2 "done")" "$(pc 3 pending)"
cp "$F" "$T/before.json"
hold_start a --branch "$B" launch 3 a3 s3 "$B-3"
pa=$LASTPID
export PIECE_TRACK_LOCK_TIMEOUT=1
for wcmd in "record|DONE #1 p/1 $SHA" "merged|2" "failed|1" "dropped|2"; do
  run --branch "$B" "${wcmd%%|*}" "${wcmd#*|}"
  expect "${wcmd%%|*} waits for the lock and times out" 1 "" "lock busy (held by pid $pa)"
done
unset PIECE_TRACK_LOCK_TIMEOUT
same "timed-out record, merged, failed, dropped write nothing" "$T/before.json" "$F"
: >"$LT/go"
finish "$pa" a
expect "the holder finishes after the new writers timed out" 0 "#3 running"

# A record waiting behind merged sees the merge: its DONE with a new SHA is
# refused, and the merge is not lost.
track "$B" 0 3 2 '{}' "$(pc 1 "done")"
race "merged vs record" --branch "$B" merged 1 -- --branch "$B" record "DONE #1 p/1 $SHA2"
[ "$RCA" -eq 0 ] && [ "$OUTA" = "#1 merged" ] || fail "merged vs record: merged rc $RCA ($OUTA) ($ERRA)"
expect "record behind merged refuses" 1 "" "#1 is merged"
[ "$(jqf "$F" '.pieces["1"].state')" = '"merged"' ] && echo "ok: merge kept" || fail "merge lost: $(jqf "$F" '.pieces')"

# A holder killed with SIGKILL inside the lock: the kernel frees the lock, and
# the next writer gets it at once with no cleanup.
track "$B" 0 3 2 '{}' "$(pc 1 pending)" "$(pc 2 pending)"
hold_start k --branch "$B" launch 1 a1 s1 "$B-1"
pk=$LASTPID
kill -9 "$pk"; wait "$pk" 2>/dev/null
t0="$(date +%s)"
run --branch "$B" launch 2 a2 s2 "$B-2"
t1="$(date +%s)"
expect "a writer after a killed holder succeeds" 0 "#2 running"
[ $((t1 - t0)) -le 2 ] && echo "ok: the killed holder's lock was free at once" || fail "waited $((t1 - t0)) s after a killed holder"
[ "$(jqf "$F" '[.pieces[] | .state]')" = '["pending","running"]' ] || fail "killed holder wrote: $(jqf "$F" '.pieces')"
no_tmp "no cleanup needed after a killed holder"

# A killed holder whose child still has the lock fd open keeps the lock held:
# writers time out until that child ends, then succeed. (A breaker or writer
# killed while its rm or mv runs on is the same case.)
# PIECE_TRACK_TEST_LOCK_CHILD=<f> makes a writer, inside the lock, start a
# background `sleep 30` and write its pid to <f>.
track "$B" 0 3 2 '{}' "$(pc 1 pending)" "$(pc 2 pending)"
rm -f "$LT/child.pid"
export PIECE_TRACK_TEST_LOCK_CHILD="$LT/child.pid"
hold_start k --branch "$B" launch 2 a2 s2 "$B-2"
unset PIECE_TRACK_TEST_LOCK_CHILD
pk=$LASTPID
waitf "$LT/child.pid" || fail "lock child never started"
cpid="$(cat "$LT/child.pid")"
kill -9 "$pk"; wait "$pk" 2>/dev/null
cp "$F" "$T/before.json"
export PIECE_TRACK_LOCK_TIMEOUT=1
run --branch "$B" launch 1 a1 s1 "$B-1"
unset PIECE_TRACK_LOCK_TIMEOUT
expect "a surviving child keeps the lock" 1 "" "lock busy"
same "a launch blocked by the child writes nothing" "$T/before.json" "$F"
kill "$cpid" 2>/dev/null
i=0
while kill -0 "$cpid" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
run --branch "$B" launch 1 a1 s1 "$B-1"
expect "a writer succeeds once the child is gone" 0 "#1 running"

# perl with Fcntl is required for the lock.
mkdir -p "$T/fakebin"
printf '#!/bin/sh\nexit 1\n' >"$T/fakebin/perl"
chmod +x "$T/fakebin/perl"
cp "$F" "$T/before.json"
OPATH="$PATH"
export PATH="$T/fakebin:$PATH"
run --branch "$B" launch 2 a2 s2 "$B-2"
export PATH="$OPATH"
expect "no usable perl" 2 "" "perl with Fcntl is required"
same "no usable perl writes nothing" "$T/before.json" "$F"

# The following use their own branch so the $B pieces are untouched.
LB="lk"
track "$LB" 0 3 2 '{}' "$(pc 1 pending)" "$(pc 2 pending)" "$(pc 3 pending)"
FL="$(tpath "$LB")"

# A lock file that cannot be created: exit 2, nothing written. (track wrote the
# tracking file directly, so no lock file exists yet for $LB.)
cp "$FL" "$T/before.json"
chmod 555 "$SD"
run --branch "$LB" launch 1 a1 s1 "$LB-1"
chmod 755 "$SD"
expect "an uncreatable lock file" 2 "" "cannot write lock"
same "an uncreatable lock file writes nothing" "$T/before.json" "$FL"

# PIECE_TRACK_LOCK_TIMEOUT=0: an uncontended write succeeds; a held lock is
# refused at once.
export PIECE_TRACK_LOCK_TIMEOUT=0
run --branch "$LB" launch 1 a1 s1 "$LB-1"
unset PIECE_TRACK_LOCK_TIMEOUT
expect "timeout 0 uncontended" 0 "#1 running"
hold_start a --branch "$LB" launch 2 a2 s2 "$LB-2"
pa=$LASTPID
t0="$(date +%s)"
export PIECE_TRACK_LOCK_TIMEOUT=0
run --branch "$LB" launch 3 a3 s3 "$LB-3"
unset PIECE_TRACK_LOCK_TIMEOUT
t1="$(date +%s)"
expect "timeout 0 against a held lock" 1 "" "lock busy (held by pid $pa)"
[ $((t1 - t0)) -le 1 ] && echo "ok: timeout 0 refuses at once" || fail "timeout 0 took $((t1 - t0)) s"

# A preset PIECE_TRACK_LOCKED does not skip the lock unless it names this very
# process: with the right path but a foreign pid (or no pid) the run still
# locks, so the held lock makes it time out.
LKL="$(dirname "$FL")/.$(basename "$FL").lock"
for mk in "1:$LKL" "$LKL"; do
  export PIECE_TRACK_LOCKED="$mk" PIECE_TRACK_LOCK_TIMEOUT=1
  run --branch "$LB" launch 3 a3 s3 "$LB-3"
  unset PIECE_TRACK_LOCKED PIECE_TRACK_LOCK_TIMEOUT
  expect "a preset lock marker ($mk) still locks" 1 "" "lock busy (held by pid $pa)"
done
: >"$LT/go"
finish "$pa" a
expect "the holder finishes" 0 "#2 running"
[ "$(jqf "$FL" '[.pieces[] | .state]')" = '["running","running","pending"]' ] \
  && echo "ok: refused lock attempts wrote nothing" || fail "lk pieces: $(jqf "$FL" '.pieces')"

# A relative state dir whose name starts with '-' is a path, not an option.
mkdir -p "$T/dashcwd"
RAW="$(cd "$T/dashcwd" && PIECE_TRACK_DIR=-dash "$BASH" "$PT" --branch dash register "$FIX/snapshot-chain.json" 2>"$T/err")"
RC=$?; OUT="$RAW"; ERR="$(cat "$T/err")"
expect "a state dir named -dash" 0 "registered 3 pieces for dash"
[ -f "$T/dashcwd/-dash/dash.json" ] && echo "ok: -dash/dash.json written" || fail "no $T/dashcwd/-dash/dash.json: $(ls -la "$T/dashcwd")"
RAW="$(cd "$T/dashcwd" && PIECE_TRACK_DIR=-dash "$BASH" "$PT" --branch dash launch 34 a s "dash-34" 2>"$T/err")"
RC=$?; OUT="$RAW"; ERR="$(cat "$T/err")"
expect "launch under a state dir named -dash" 0 "#34 running"


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
for sub in path register launchable launch record merged failed dropped finished summary; do
  case "$ERR" in *"piece-track.sh [--branch <b>] $sub"*) echo "ok: usage lists $sub" ;;
    *) fail "usage lacks $sub: $ERR" ;; esac
done
run --branch "$B" frobnicate
expect "unknown subcommand" 2 ""
run --branch
expect "--branch needs a value" 2 ""

if [ "$FAIL" -ne 0 ]; then exit 1; fi
echo "all piece-track tests passed"
