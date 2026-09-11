#!/usr/bin/env bash
# Fixture tests for harness-skills/bin/crew-configure. Uses a throwaway
# mktemp dir; never touches the real ~/.claude.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$HERE/../bin/crew-configure"
TMP="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP"
}
trap cleanup EXIT

FAILED=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILED=1; }

assert_eq() {
  desc="$1"; expected="$2"; actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$desc"
  else
    fail "$desc (expected [$expected], got [$actual])"
  fi
}

run_cc() {
  CREW_CONFIG_FILE="$CFG" "$BIN" "$@"
}

# --- case: create from absent -------------------------------------------
CFG="$TMP/c1.json"
OUT="$(run_cc set research_root=/tmp/r1 2>&1)"
rc=$?
assert_eq "create-from-absent exit" "0" "$rc"
if [ -f "$CFG" ] && jq -e . <"$CFG" >/dev/null 2>&1; then
  pass "create-from-absent produced valid JSON"
else
  fail "create-from-absent did not produce a valid file"
fi
val="$(jq -r .research_root "$CFG" 2>/dev/null)"
assert_eq "create-from-absent value" "/tmp/r1" "$val"

# --- case: preserve pre-existing (unknown to us) keys on further set -----
tmp_merge="$(mktemp)"
jq '. + {"future_key": "kept"}' "$CFG" > "$tmp_merge" && mv "$tmp_merge" "$CFG"
run_cc set audit_output_root=/tmp/audit >/dev/null 2>&1
fk="$(jq -r .future_key "$CFG" 2>/dev/null)"
assert_eq "unknown existing key preserved" "kept" "$fk"
ar="$(jq -r .audit_output_root "$CFG" 2>/dev/null)"
assert_eq "new key also written" "/tmp/audit" "$ar"

# --- case: malformed file refused, untouched ------------------------------
CFG="$TMP/bad.json"
printf '{ not json' > "$CFG"
before_sum="$(md5sum "$CFG" | awk '{print $1}')"
OUT="$(run_cc set research_root=/tmp/x 2>&1)"
rc=$?
assert_eq "malformed refused exit code" "3" "$rc"
after_sum="$(md5sum "$CFG" | awk '{print $1}')"
assert_eq "malformed file untouched (checksum)" "$before_sum" "$after_sum"
if echo "$OUT" | grep -q 'is not valid JSON'; then
  pass "malformed refusal message present"
else
  fail "malformed refusal message missing (got: $OUT)"
fi

# --- case: unknown key refused --------------------------------------------
CFG="$TMP/c2.json"
OUT="$(run_cc set bogus_key=1 2>&1)"
rc=$?
assert_eq "unknown key exit code" "2" "$rc"
if echo "$OUT" | grep -q "unknown key 'bogus_key'"; then
  pass "unknown key message present"
else
  fail "unknown key message missing (got: $OUT)"
fi
if [ -f "$CFG" ]; then
  fail "unknown key set created a file anyway"
else
  pass "unknown key set created no file"
fi

# --- case: type validation - array key via set is refused ------------------
CFG="$TMP/c3.json"
OUT="$(run_cc set org_allowlist=foo 2>&1)"
rc=$?
assert_eq "array-via-set exit code" "2" "$rc"
if echo "$OUT" | grep -q "use: .*set-list"; then
  pass "array-via-set message points to set-list"
else
  fail "array-via-set message wrong (got: $OUT)"
fi

# --- case: type validation - scalar key via set-list is refused ------------
CFG="$TMP/c4.json"
OUT="$(run_cc set-list research_root foo,bar 2>&1)"
rc=$?
assert_eq "scalar-via-set-list exit code" "2" "$rc"
if echo "$OUT" | grep -q "is not an array"; then
  pass "scalar-via-set-list message correct"
else
  fail "scalar-via-set-list message wrong (got: $OUT)"
fi

# --- case: set-list writes an array correctly -------------------------------
CFG="$TMP/c5.json"
run_cc set-list org_allowlist "acme,example-org" >/dev/null 2>&1
list_out="$(jq -c .org_allowlist "$CFG" 2>/dev/null)"
assert_eq "set-list org_allowlist value" '["acme","example-org"]' "$list_out"

# --- case: set-list marketplaces (name:repo pairs) --------------------------
CFG="$TMP/c6.json"
run_cc set-list marketplaces "cjs-plugins:~/repos/ai-crew" >/dev/null 2>&1
mp_name="$(jq -r '.marketplaces[0].name' "$CFG" 2>/dev/null)"
mp_repo="$(jq -r '.marketplaces[0].repo' "$CFG" 2>/dev/null)"
assert_eq "set-list marketplaces name" "cjs-plugins" "$mp_name"
assert_eq "set-list marketplaces repo" "~/repos/ai-crew" "$mp_repo"

# --- case: dotted lanes key set/unset ---------------------------------------
CFG="$TMP/c7.json"
run_cc set lanes.scout=my:scout >/dev/null 2>&1
lv="$(jq -r .lanes.scout "$CFG" 2>/dev/null)"
assert_eq "lanes.scout set" "my:scout" "$lv"
run_cc unset lanes.scout >/dev/null 2>&1
lv2="$(jq -r '.lanes.scout // "GONE"' "$CFG" 2>/dev/null)"
assert_eq "lanes.scout unset" "GONE" "$lv2"

# --- case: show on absent prints "absent" + the path ------------------------
CFG="$TMP/does-not-exist.json"
OUT="$(run_cc show 2>&1)"
rc=$?
assert_eq "show-absent exit" "0" "$rc"
if echo "$OUT" | grep -qF "$CFG"; then
  pass "show-absent prints the config path"
else
  fail "show-absent did not print the path (got: $OUT)"
fi
if echo "$OUT" | grep -q '^absent$'; then
  pass "show-absent prints 'absent'"
else
  fail "show-absent did not print 'absent' (got: $OUT)"
fi

# --- case: lock is cleaned up after a run -----------------------------------
CFG="$TMP/c8.json"
run_cc set research_root=/tmp/lockcheck >/dev/null 2>&1
if [ -d "${CFG}.lock" ]; then
  fail "lock directory left behind after a successful run"
else
  pass "lock directory cleaned up after a successful run"
fi
# ... and after a refused (error-path) run too.
CFG="$TMP/c9-bad.json"
printf 'not json at all' > "$CFG"
run_cc set research_root=/tmp/x >/dev/null 2>&1
if [ -d "${CFG}.lock" ]; then
  fail "lock directory left behind after a refused (malformed) run"
else
  pass "lock directory cleaned up after a refused (malformed) run"
fi

if [ "$FAILED" -ne 0 ]; then
  echo "One or more tests FAILED"
  exit 1
fi
echo "All tests PASSED"
exit 0
