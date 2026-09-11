#!/usr/bin/env bash
# Verifies routing-table.py and lane-model-gate.py read lane names from the crew
# config file (${CLAUDE_CONFIG_DIR}/plugins/data/crew/config.json, key "lanes"),
# and fall back to their defaults when the file is absent or malformed.
HOOKS="$(dirname "$0")/../hooks"
TD=$(mktemp -d); pass=0; fail=0

pass_ () { echo "  PASS  $1"; pass=$((pass+1)); }
fail_ () { echo "  FAIL  $1"; shift; [ -n "$1" ] && echo "$1" | head -5; fail=$((fail+1)); }

write_config() { # dir json
  mkdir -p "$1/plugins/data/crew"
  printf '%s' "$2" > "$1/plugins/data/crew/config.json"
}

# --- (a) routing-table.py picks up an overridden lane name -----------------
CFGDIR_A="$TD/cfg-a"
write_config "$CFGDIR_A" '{"lanes":{"verifier":"my-verifier","scout":"my-scout"}}'
out=$(printf '{}' | CLAUDE_CONFIG_DIR="$CFGDIR_A" python3 "$HOOKS/routing-table.py" 2>&1)
if echo "$out" | grep -qF 'my-scout'; then pass_ "routing-table uses overridden scout lane";
else fail_ "routing-table uses overridden scout lane" "$out"; fi

# --- (b) lane-model-gate.py allows the overridden verifier, denies the default --
payload_for() { # subagent_type
  printf '{"tool_name":"Agent","tool_input":{"model":"fable","subagent_type":"%s"}}' "$1"
}
out=$(printf '%s' "$(payload_for my-verifier)" | CLAUDE_CONFIG_DIR="$CFGDIR_A" python3 "$HOOKS/lane-model-gate.py" 2>&1); rc=$?
if [ "$rc" = 0 ] && ! echo "$out" | grep -q '"permissionDecision": "deny"'; then
  pass_ "lane-model-gate allows overridden verifier lane on fable";
else fail_ "lane-model-gate allows overridden verifier lane on fable" "$out (rc=$rc)"; fi

out=$(printf '%s' "$(payload_for fresh-verifier)" | CLAUDE_CONFIG_DIR="$CFGDIR_A" python3 "$HOOKS/lane-model-gate.py" 2>&1); rc=$?
if echo "$out" | grep -q '"permissionDecision": "deny"'; then
  pass_ "lane-model-gate denies the now-non-exempt default fresh-verifier";
else fail_ "lane-model-gate denies the now-non-exempt default fresh-verifier" "$out (rc=$rc)"; fi

# --- (c) malformed config.json leaves defaults in place --------------------
CFGDIR_B="$TD/cfg-b"
write_config "$CFGDIR_B" 'not json at all {{{'
out=$(printf '{}' | CLAUDE_CONFIG_DIR="$CFGDIR_B" python3 "$HOOKS/routing-table.py" 2>&1)
if echo "$out" | grep -qF 'claude-crew:claude-scout'; then
  pass_ "malformed config.json falls back to default scout lane";
else fail_ "malformed config.json falls back to default scout lane" "$out"; fi

out=$(printf '%s' "$(payload_for fresh-verifier)" | CLAUDE_CONFIG_DIR="$CFGDIR_B" python3 "$HOOKS/lane-model-gate.py" 2>&1); rc=$?
if [ "$rc" = 0 ] && ! echo "$out" | grep -q '"permissionDecision": "deny"'; then
  pass_ "malformed config.json falls back to default exempt verifier";
else fail_ "malformed config.json falls back to default exempt verifier" "$out (rc=$rc)"; fi

# --- (d) missing config file entirely also falls back cleanly --------------
CFGDIR_C="$TD/cfg-c-does-not-exist"
out=$(printf '{}' | CLAUDE_CONFIG_DIR="$CFGDIR_C" python3 "$HOOKS/routing-table.py" 2>&1)
if echo "$out" | grep -qF 'claude-crew:claude-scout'; then
  pass_ "missing config file falls back to default scout lane";
else fail_ "missing config file falls back to default scout lane" "$out"; fi

# --- (e) plugin-qualified subagent_type ('<plugin>:<name>') ----------------
# A lane running inside a plugin arrives as '<plugin>:<name>'. The exempt match must
# strip the qualifier for comparison, but never as a substring match.
CFGDIR_D="$TD/cfg-d-does-not-exist"   # default config: verifier stays fresh-verifier

out=$(printf '%s' "$(payload_for fresh-verifier)" | CLAUDE_CONFIG_DIR="$CFGDIR_D" python3 "$HOOKS/lane-model-gate.py" 2>&1); rc=$?
if [ "$rc" = 0 ] && ! echo "$out" | grep -q '"permissionDecision": "deny"'; then
  pass_ "fresh-verifier (default, unqualified) allowed";
else fail_ "fresh-verifier (default, unqualified) allowed" "$out (rc=$rc)"; fi

out=$(printf '%s' "$(payload_for dev-workflow:fresh-verifier)" | CLAUDE_CONFIG_DIR="$CFGDIR_D" python3 "$HOOKS/lane-model-gate.py" 2>&1); rc=$?
if [ "$rc" = 0 ] && ! echo "$out" | grep -q '"permissionDecision": "deny"'; then
  pass_ "dev-workflow:fresh-verifier (plugin-qualified) allowed";
else fail_ "dev-workflow:fresh-verifier (plugin-qualified) allowed" "$out (rc=$rc)"; fi

out=$(printf '%s' "$(payload_for other:fresh-verifier-x)" | CLAUDE_CONFIG_DIR="$CFGDIR_D" python3 "$HOOKS/lane-model-gate.py" 2>&1); rc=$?
if echo "$out" | grep -q '"permissionDecision": "deny"'; then
  pass_ "other:fresh-verifier-x (qualified, wrong unqualified name) denied";
else fail_ "other:fresh-verifier-x (qualified, wrong unqualified name) denied" "$out (rc=$rc)"; fi

# fresh-verifier must be denied once config renames the verifier lane (already covered
# above at CFGDIR_A, restated here for the plugin-qualified test group's readability).
out=$(printf '%s' "$(payload_for fresh-verifier)" | CLAUDE_CONFIG_DIR="$CFGDIR_A" python3 "$HOOKS/lane-model-gate.py" 2>&1); rc=$?
if echo "$out" | grep -q '"permissionDecision": "deny"'; then
  pass_ "fresh-verifier denied when config sets lanes.verifier=my-verifier";
else fail_ "fresh-verifier denied when config sets lanes.verifier=my-verifier" "$out (rc=$rc)"; fi

# --- (f) plugin-qualified config entry requires an EXACT match -------------
# lanes.verifier is itself plugin-qualified: only that exact string is exempt --
# no other plugin's fresh-verifier, and not the bare unqualified name either.
CFGDIR_E="$TD/cfg-e"
write_config "$CFGDIR_E" '{"lanes":{"verifier":"dev-workflow:fresh-verifier"}}'

out=$(printf '%s' "$(payload_for dev-workflow:fresh-verifier)" | CLAUDE_CONFIG_DIR="$CFGDIR_E" python3 "$HOOKS/lane-model-gate.py" 2>&1); rc=$?
if [ "$rc" = 0 ] && ! echo "$out" | grep -q '"permissionDecision": "deny"'; then
  pass_ "dev-workflow:fresh-verifier allowed when configured exactly";
else fail_ "dev-workflow:fresh-verifier allowed when configured exactly" "$out (rc=$rc)"; fi

out=$(printf '%s' "$(payload_for evil-plugin:fresh-verifier)" | CLAUDE_CONFIG_DIR="$CFGDIR_E" python3 "$HOOKS/lane-model-gate.py" 2>&1); rc=$?
if echo "$out" | grep -q '"permissionDecision": "deny"'; then
  pass_ "evil-plugin:fresh-verifier denied against qualified config entry";
else fail_ "evil-plugin:fresh-verifier denied against qualified config entry" "$out (rc=$rc)"; fi

out=$(printf '%s' "$(payload_for fresh-verifier)" | CLAUDE_CONFIG_DIR="$CFGDIR_E" python3 "$HOOKS/lane-model-gate.py" 2>&1); rc=$?
if echo "$out" | grep -q '"permissionDecision": "deny"'; then
  pass_ "bare fresh-verifier denied against qualified config entry";
else fail_ "bare fresh-verifier denied against qualified config entry" "$out (rc=$rc)"; fi

echo; echo "RESULT: $pass passed, $fail failed"
rm -rf "$TD"
[ "$fail" = 0 ]
