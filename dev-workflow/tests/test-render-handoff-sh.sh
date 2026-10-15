#!/usr/bin/env bash
# Behavioral test for orchestrating-pieces/scripts/render-handoff.sh: a full
# render, blocking on a missing value, an empty value and a leftover
# placeholder, and values with metacharacters rendered verbatim. Runnable
# standalone.
#
# Bash 3.2 compatible: no associative arrays, no `mapfile`, no `${var,,}`.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
RENDER="$ROOT/skills/orchestrating-pieces/scripts/render-handoff.sh"
TEMPLATE="$ROOT/skills/orchestrating-pieces/references/handoff-prompt.md"

FAIL=0

fail() {
  echo "FAIL: $1" >&2
  FAIL=1
}

[ -f "$RENDER" ] || { echo "FAIL: $RENDER not found (render-handoff.sh not found)" >&2; exit 1; }
[ -f "$TEMPLATE" ] || { echo "FAIL: $TEMPLATE not found" >&2; exit 1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

OUT=""
ERR=""
RC=0
# run <template> <values> — sets OUT, ERR, RC
run() {
  "$BASH" "$RENDER" "$1" "$2" >"$T/out" 2>"$T/err"
  RC=$?
  OUT="$(cat "$T/out")"
  ERR="$(cat "$T/err")"
}

# base_values <file> — a complete values object for the real template.
base_values() {
  jq -n '{
    TICKET_KEY: "PROJ-7", ISSUE_NUMBER: 37, ISSUE_URL: "https://github.com/o/r/issues/37",
    ORCHESTRATOR_SESSION: "PROJ-7-orch", ACCEPTANCE_CRITERIA: "- [ ] AC-1 does the thing",
    TEST_COMMAND: "bash tests/run.sh", WORKTREE: "/tmp/wt/37", PIECE_BRANCH: "piece/proj-7-37",
    BASE_BRANCH: "feat/proj-7", CHILD_DEPTH: 1, DEPTH_CAP: 2, LIVE_CAP: 3,
    BLOCKER_EVIDENCE: "#34 verified and merged into feat/proj-7 at 0123456789abcdef0123456789abcdef01234567"
  }' >"$1"
}

# --- 1. a fully filled render of the real template -------------------------

base_values "$T/v.json"
run "$TEMPLATE" "$T/v.json"
[ "$RC" -eq 0 ] || fail "full render: exit $RC, stderr: $ERR"
printf '%s\n' "$OUT" | grep -qF '{{' && fail "full render: placeholder left in output"
printf '%s\n' "$OUT" | grep -qF 'issue #37 of ticket PROJ-7 (https://github.com/o/r/issues/37)' || fail "full render: issue line not filled"
printf '%s\n' "$OUT" | grep -qF 'Your depth: 1. Caps in force: depth cap 2, live-child cap 3' || fail "full render: depth and caps not filled"
printf '%s\n' "$OUT" | grep -qF 'verified and merged into feat/proj-7 at 0123' || fail "full render: blocker evidence not filled"
[ -z "$ERR" ] || fail "full render: unexpected stderr: $ERR"

# --- 2. empty blocker evidence is allowed ----------------------------------

jq '.BLOCKER_EVIDENCE = ""' "$T/v.json" >"$T/v2.json"
run "$TEMPLATE" "$T/v2.json"
[ "$RC" -eq 0 ] || fail "empty BLOCKER_EVIDENCE: exit $RC, stderr: $ERR"

# --- 3. a missing value blocks, with no output -----------------------------

jq 'del(.TEST_COMMAND)' "$T/v.json" >"$T/v3.json"
run "$TEMPLATE" "$T/v3.json"
[ "$RC" -eq 1 ] || fail "missing value: exit $RC, want 1"
[ -z "$OUT" ] || fail "missing value: wrote output"
printf '%s\n' "$ERR" | grep -qF 'unfilled placeholder: {{TEST_COMMAND}}' || fail "missing value: stderr does not name TEST_COMMAND: $ERR"

# --- 4. an empty or blank required value blocks ----------------------------

for blank in '' '   ' $'\n'; do
  jq --arg b "$blank" '.ISSUE_URL = $b' "$T/v.json" >"$T/v4.json"
  run "$TEMPLATE" "$T/v4.json"
  [ "$RC" -eq 1 ] || fail "blank required value: exit $RC, want 1"
  [ -z "$OUT" ] || fail "blank required value: wrote output"
  printf '%s\n' "$ERR" | grep -qF 'empty required value: ISSUE_URL' || fail "blank required value: stderr does not name ISSUE_URL: $ERR"
done

# --- 5. a non-scalar value blocks ------------------------------------------

jq '.WORKTREE = ["a"]' "$T/v.json" >"$T/v5.json"
run "$TEMPLATE" "$T/v5.json"
[ "$RC" -eq 1 ] || fail "array value: exit $RC, want 1"
[ -z "$OUT" ] || fail "array value: wrote output"

# 5b: only integer literals count as numbers (37.0 and 1e2 would render as 37.0 and 1E+2).
for num in '37.0' '1e2' '-1' '1.5'; do
  jq --argjson n "$num" '.ISSUE_NUMBER = $n' "$T/v.json" >"$T/v5b.json"
  run "$TEMPLATE" "$T/v5b.json"
  [ "$RC" -eq 1 ] || fail "number $num: exit $RC, want 1"
  [ -z "$OUT" ] || fail "number $num: wrote output"
done

# 5c: a values file holding more than one top-level value is refused, not read as its first object.
{ cat "$T/v.json"; cat "$T/v.json"; } >"$T/v5c.json"
run "$TEMPLATE" "$T/v5c.json"
[ "$RC" -eq 2 ] || fail "two objects in the values file: exit $RC, want 2"
[ -z "$OUT" ] || fail "two objects in the values file: wrote output"
{ cat "$T/v.json"; echo '"trailing"'; } >"$T/v5d.json"
run "$TEMPLATE" "$T/v5d.json"
[ "$RC" -eq 2 ] || fail "object plus a trailing value: exit $RC, want 2"

# --- 6. a leftover placeholder blocks --------------------------------------

# 6a: the template names a placeholder the values lack.
printf 'a {{ONE}} b {{TWO}}\n' >"$T/t6.md"
jq -n '{ONE: "1"}' >"$T/v6.json"
run "$T/t6.md" "$T/v6.json"
[ "$RC" -eq 1 ] || fail "leftover placeholder: exit $RC, want 1"
[ -z "$OUT" ] || fail "leftover placeholder: wrote output"
printf '%s\n' "$ERR" | grep -qF '{{TWO}}' || fail "leftover placeholder: stderr does not name TWO: $ERR"

# 6b: a malformed placeholder in the template is never passed through.
for bad in 'x {{lower}} y' 'x {{ SPACED }} y' 'x {{HALF} y' 'x {{ONE}}}} y'; do
  printf '%s\n' "$bad" >"$T/t6b.md"
  run "$T/t6b.md" "$T/v6.json"
  [ "$RC" -eq 1 ] || fail "malformed placeholder '$bad': exit $RC, want 1"
  [ -z "$OUT" ] || fail "malformed placeholder '$bad': wrote output"
done

# 6c: a values key the template does not use blocks (a typo must not pass).
jq '.EXTRA = "x"' "$T/v.json" >"$T/v6c.json"
run "$TEMPLATE" "$T/v6c.json"
[ "$RC" -eq 1 ] || fail "unused key: exit $RC, want 1"
[ -z "$OUT" ] || fail "unused key: wrote output"

# --- 7. values are data: rendered verbatim, never expanded -----------------

nasty_cases() {
  printf '%s\n' \
    'a & b \1 \\ $HOME $(touch PWNED) `touch PWNED` ; | > < * ?' \
    'literal {{TWO}} and {{ONE}} inside a value' \
    "quote ' and \" and \\n not a newline"
}
printf 'start {{ONE}} mid {{TWO}} end\n' >"$T/t7.md"
nasty_cases | while IFS= read -r nasty; do
  jq -n --arg a "$nasty" '{ONE: $a, TWO: "second"}' >"$T/v7.json"
  run "$T/t7.md" "$T/v7.json"
  [ "$RC" -eq 0 ] || { echo "FAIL: nasty value: exit $RC, stderr: $ERR" >&2; exit 1; }
  [ "$OUT" = "start $nasty mid second end" ] || { echo "FAIL: nasty value not verbatim: $OUT" >&2; exit 1; }
done || FAIL=1
[ ! -e PWNED ] && [ ! -e "$PWD/PWNED" ] || fail "a value was executed (PWNED created)"

# Newlines, with a placeholder-shaped line, in a value.
ML=$'line one\n{{TWO}}\n\nline & four\\'
jq -n --arg a "$ML" '{ONE: $a}' >"$T/v7b.json"
printf 'S{{ONE}}E\n' >"$T/t7b.md"
"$BASH" "$RENDER" "$T/t7b.md" "$T/v7b.json" >"$T/out7b" 2>"$T/err7b"
rc=$?
[ "$rc" -eq 0 ] || fail "multi-line value: exit $rc"
[ "$(cat "$T/out7b")" = "S${ML}E" ] || fail "multi-line value not verbatim: $(cat "$T/out7b")"

# The placeholder text of one value is not filled by another value (single pass).
jq -n '{ONE: "{{TWO}}", TWO: "second"}' >"$T/v7c.json"
printf '{{ONE}}|{{TWO}}\n' >"$T/t7c.md"
run "$T/t7c.md" "$T/v7c.json"
[ "$OUT" = '{{TWO}}|second' ] || fail "single-pass: got '$OUT'"

# --- 8. usage and input errors ----------------------------------------------

run "$TEMPLATE" "$T/missing.json"
[ "$RC" -eq 2 ] || fail "missing values file: exit $RC, want 2"
printf '{ not json' >"$T/bad.json"
run "$TEMPLATE" "$T/bad.json"
[ "$RC" -eq 2 ] || fail "invalid JSON: exit $RC, want 2"
printf '[1]' >"$T/arr.json"
run "$TEMPLATE" "$T/arr.json"
[ "$RC" -eq 2 ] || fail "non-object JSON: exit $RC, want 2"
run "$T/nope.md" "$T/v.json"
[ "$RC" -eq 2 ] || fail "missing template: exit $RC, want 2"
"$BASH" "$RENDER" >/dev/null 2>&1
[ "$?" -eq 2 ] || fail "no arguments: want exit 2"

if [ "$FAIL" -eq 0 ]; then
  echo "ok: render-handoff.sh fills, blocks and treats values as data"
  exit 0
fi
exit 1
