#!/usr/bin/env bash
# Fixture tests for lib/crew-config.sh. Uses a throwaway mktemp dir; never
# touches the real ~/.claude.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../crew-config.sh"
TMP="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP"
}
trap cleanup EXIT

FAILED=0

pass() {
  echo "PASS: $1"
}

fail() {
  echo "FAIL: $1"
  FAILED=1
}

assert_eq() {
  desc="$1"
  expected="$2"
  actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$desc"
  else
    fail "$desc (expected [$expected], got [$actual])"
  fi
}

# --- case: defaults when file missing -------------------------------------
(
  unset CREW_CONFIG_FILE
  CREW_CONFIG_FILE="$TMP/does-not-exist.json"
  export CREW_CONFIG_FILE
  . "$LIB"
  val="$(crew_config_get research_root)"
  echo "$val"
) > "$TMP/out1"
assert_eq "defaults when file missing" "$HOME/Research" "$(cat "$TMP/out1")"

# --- case: value read -------------------------------------------------------
cat > "$TMP/config1.json" <<'EOF'
{"research_root": "/tmp/custom-research"}
EOF
(
  CREW_CONFIG_FILE="$TMP/config1.json"
  export CREW_CONFIG_FILE
  . "$LIB"
  crew_config_get research_root
) > "$TMP/out2"
assert_eq "value read" "/tmp/custom-research" "$(cat "$TMP/out2")"

# --- case: dotted path -------------------------------------------------------
cat > "$TMP/config2.json" <<'EOF'
{"lanes": {"scout": "custom:scout-lane"}}
EOF
(
  CREW_CONFIG_FILE="$TMP/config2.json"
  export CREW_CONFIG_FILE
  . "$LIB"
  crew_config_get lanes.scout
) > "$TMP/out3"
assert_eq "dotted path" "custom:scout-lane" "$(cat "$TMP/out3")"

# --- case: dotted path default when absent ---------------------------------
(
  CREW_CONFIG_FILE="$TMP/config2.json"
  export CREW_CONFIG_FILE
  . "$LIB"
  crew_config_get lanes.reader
) > "$TMP/out3b"
assert_eq "dotted path default when key absent" "claude-crew:claude-reader" "$(cat "$TMP/out3b")"

# --- case: array list --------------------------------------------------------
cat > "$TMP/config3.json" <<'EOF'
{"org_allowlist": ["acme", "example-org"]}
EOF
(
  CREW_CONFIG_FILE="$TMP/config3.json"
  export CREW_CONFIG_FILE
  . "$LIB"
  crew_config_list org_allowlist
) > "$TMP/out4"
expected_list="$(printf 'acme\nexample-org\n')"
assert_eq "array list" "$expected_list" "$(cat "$TMP/out4")"

# --- case: array list empty when absent -------------------------------------
(
  CREW_CONFIG_FILE="$TMP/config1.json"
  export CREW_CONFIG_FILE
  . "$LIB"
  crew_config_list org_allowlist
) > "$TMP/out4b"
assert_eq "array list empty when absent" "" "$(cat "$TMP/out4b")"

# --- case: tilde expansion ---------------------------------------------------
cat > "$TMP/config4.json" <<'EOF'
{"token_map": "~/.claude/plugins/data/crew/token-map"}
EOF
(
  CREW_CONFIG_FILE="$TMP/config4.json"
  export CREW_CONFIG_FILE
  . "$LIB"
  crew_config_get token_map
) > "$TMP/out5"
assert_eq "tilde expansion" "$HOME/.claude/plugins/data/crew/token-map" "$(cat "$TMP/out5")"

# --- case: malformed JSON returns 3 with message -----------------------------
cat > "$TMP/bad.json" <<'EOF'
{ this is not json
EOF
(
  CREW_CONFIG_FILE="$TMP/bad.json"
  export CREW_CONFIG_FILE
  . "$LIB"
  crew_config_get research_root
) > "$TMP/out6" 2> "$TMP/out6.err"
rc_bad=$?
assert_eq "malformed JSON exit code" "3" "$rc_bad"
if grep -q "crew-config: $TMP/bad.json is not valid JSON" "$TMP/out6.err"; then
  pass "malformed JSON error message"
else
  fail "malformed JSON error message (got: $(cat "$TMP/out6.err"))"
fi

# --- case: jq missing path ---------------------------------------------------
NOJQ_DIR="$TMP/nojq-path"
mkdir -p "$NOJQ_DIR"
for tool in bash cat sed grep mktemp rm printf cp mkdir true false expr dirname basename; do
  path="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$path" ] && ln -sf "$path" "$NOJQ_DIR/$tool" 2>/dev/null
done
(
  CREW_CONFIG_FILE="$TMP/does-not-exist-either.json"
  export CREW_CONFIG_FILE
  PATH="$NOJQ_DIR"
  export PATH
  . "$LIB"
  crew_config_get research_root
) > "$TMP/out7" 2> "$TMP/out7.err"
assert_eq "jq-missing + file absent returns default" "$HOME/Research" "$(cat "$TMP/out7")"
if grep -q "crew-config: jq not found; using defaults" "$TMP/out7.err"; then
  pass "jq-missing + file absent warning"
else
  fail "jq-missing + file absent warning (got: $(cat "$TMP/out7.err"))"
fi

# --- case: jq missing but config file EXISTS -> hard error, no silent fallback --
(
  CREW_CONFIG_FILE="$TMP/config1.json"
  export CREW_CONFIG_FILE
  PATH="$NOJQ_DIR"
  export PATH
  . "$LIB"
  crew_config_get research_root
) > "$TMP/out7b" 2> "$TMP/out7b.err"
rc_nojq_exists=$?
assert_eq "jq-missing + file exists exit code" "3" "$rc_nojq_exists"
if grep -q "crew-config: jq is required to read $TMP/config1.json" "$TMP/out7b.err"; then
  pass "jq-missing + file exists error message"
else
  fail "jq-missing + file exists error message (got: $(cat "$TMP/out7b.err"))"
fi
if [ -z "$(cat "$TMP/out7b")" ]; then
  pass "jq-missing + file exists prints no value"
else
  fail "jq-missing + file exists printed a value (got: $(cat "$TMP/out7b"))"
fi

# --- case: crew_config_get on an object/array value -> not a scalar -------------
cat > "$TMP/config5.json" <<'EOF'
{"lanes": {"scout": "custom:scout-lane"}}
EOF
(
  CREW_CONFIG_FILE="$TMP/config5.json"
  export CREW_CONFIG_FILE
  . "$LIB"
  crew_config_get lanes
) > "$TMP/out8" 2> "$TMP/out8.err"
rc_notscalar=$?
assert_eq "get on object value exit code" "3" "$rc_notscalar"
if grep -q "crew-config: lanes is not a scalar" "$TMP/out8.err"; then
  pass "get on object value error message"
else
  fail "get on object value error message (got: $(cat "$TMP/out8.err"))"
fi

# --- case: crew_config_list on a non-array value -> not an array ---------------
cat > "$TMP/config6.json" <<'EOF'
{"research_root": "/tmp/custom-research"}
EOF
(
  CREW_CONFIG_FILE="$TMP/config6.json"
  export CREW_CONFIG_FILE
  . "$LIB"
  crew_config_list research_root
) > "$TMP/out9" 2> "$TMP/out9.err"
rc_notarray=$?
assert_eq "list on non-array value exit code" "3" "$rc_notarray"
if grep -q "crew-config: research_root is not an array" "$TMP/out9.err"; then
  pass "list on non-array value error message"
else
  fail "list on non-array value error message (got: $(cat "$TMP/out9.err"))"
fi

if [ "$FAILED" -ne 0 ]; then
  echo "One or more tests FAILED"
  exit 1
fi
echo "All tests PASSED"
exit 0
