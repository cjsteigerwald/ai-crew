#!/usr/bin/env bash
# Behavioral test for hooks/verifier-dispatch-gate.py: PreToolUse payloads piped
# to the hook as a subprocess. Covers a fresh-verifier caller (all four
# agent_type spellings) allowed to dispatch only claude-crew:claude-scout and
# claude-crew:claude-reader with no model and no isolation; denials for any other
# target, a missing/empty/non-string/unhashable subagent_type, model, isolation
# and a malformed tool_input; crew config never read; non-verifier callers and
# non-Agent tools passing silently; unreadable input answering ask; the off
# switch. Every dispatch case runs under both tool names, Agent and Task.
# Runnable standalone.
#
# Bash 3.2 compatible: no associative arrays, no `mapfile`, no `${var,,}`.
# shellcheck disable=SC2015  # `cond && pass || fail`: pass only echoes, so it cannot fall through
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
HOOK="$ROOT/hooks/verifier-dispatch-gate.py"

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; FAIL=1; }

[ -f "$HOOK" ] || { echo "FAIL: $HOOK not found" >&2; exit 1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
unset CLAUDE_VERIFIER_DISPATCH_GATE

VERIFIERS="dev-workflow:fresh-verifier dev-workflow:fresh-verifier-high fresh-verifier fresh-verifier-high"
TOOLS="Agent Task"
SCOUT="claude-crew:claude-scout"
READER="claude-crew:claude-reader"
INLINE='read inline and declare `reading → inline: <denied: reason>`'

OUT=""; ERR=""; RC=0; DEC=""; REASON=""
# payload <tool_name> <agent_type JSON|-> <tool_input JSON|-> — a PreToolUse
# payload on stdout; "-" leaves the key out. JSON arguments are raw JSON values,
# so non-string and unhashable values can be sent.
payload() {
  python3 - "$@" <<'PY'
import json, sys
tool, agent, ti = sys.argv[1], sys.argv[2], sys.argv[3]
p = {"session_id": "sess-1", "hook_event_name": "PreToolUse", "tool_name": tool, "cwd": "/"}
if agent != "-":
    p["agent_type"] = json.loads(agent)
if ti != "-":
    p["tool_input"] = json.loads(ti)
print(json.dumps(p))
PY
}
# ti <subagent_type JSON|-> [<extra JSON members>] — a tool_input object.
ti() {
  local members='"description": "locate", "prompt": "where is X"'
  [ "$1" = "-" ] || members="$members, \"subagent_type\": $1"
  [ -z "${2:-}" ] || members="$members, $2"
  printf '{%s}' "$members"
}

# hook <payload-file> [env assignments...] — runs the hook; sets OUT, ERR, RC,
# DEC (permissionDecision or "none" for no output) and REASON.
hook() {
  local f="$1"; shift
  env "$@" python3 "$HOOK" <"$f" >"$T/out" 2>"$T/err"
  RC=$?
  OUT="$(cat "$T/out")"
  ERR="$(cat "$T/err")"
  parse
}
parse() {
  if [ -z "$OUT" ]; then DEC="none"; REASON=""; return; fi
  DEC="$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["permissionDecision"])' 2>/dev/null || echo "badjson")"
  REASON="$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["permissionDecisionReason"])' 2>/dev/null)"
}

# expect <name> <decision> [<reason substring>] — a deny must also name its rule
# (the substring) and end with the read-inline instruction.
expect() {
  if [ "$RC" -ne 0 ]; then fail "$1: rc $RC (err: $ERR)"; return; fi
  if [ "$DEC" != "$2" ]; then fail "$1: expected $2, got $DEC ($REASON) (err: $ERR)"; return; fi
  if [ -n "${3:-}" ]; then
    case "$REASON" in *"$3"*) ;; *) fail "$1: reason lacks '$3': $REASON"; return ;; esac
  fi
  if [ "$2" = deny ]; then
    case "$REASON" in *"$INLINE") ;; *) fail "$1: deny reason does not end with the read-inline instruction: $REASON"; return ;; esac
  fi
  pass "$1"
}

# run_case <name> <decision> <tool> <agent_type JSON|-> <tool_input JSON|-> [<reason substring>]
run_case() {
  payload "$3" "$4" "$5" >"$T/p.json"
  hook "$T/p.json"
  expect "$1 [$3]" "$2" "${6:-}"
}

# --- AC-1: verifier → scout / reader, no model, no isolation: allowed -------
for tool in $TOOLS; do
  for v in $VERIFIERS; do
    run_case "allow scout ($v)" none "$tool" "\"$v\"" "$(ti "\"$SCOUT\"")"
    run_case "allow reader ($v)" none "$tool" "\"$v\"" "$(ti "\"$READER\"")"
    run_case "allow scout, empty model and isolation ($v)" none "$tool" "\"$v\"" \
      "$(ti "\"$SCOUT\"" '"model": "", "isolation": ""')"
  done
done

# --- AC-2: any other target is denied (AC-7: rule named, read-inline suffix) --
V='"dev-workflow:fresh-verifier"'
for tool in $TOOLS; do
  for target in claude-crew:claude-implementer-sonnet general-purpose fork dev-workflow:code-writer \
                dev-workflow:fresh-verifier dev-workflow:codex-adversary claude-scout; do
    run_case "deny $target" deny "$tool" "$V" "$(ti "\"$target\"")" "subagent_type"
  done
done

# --- AC-3: missing, empty, non-string, unhashable subagent_type: denied ------
for tool in $TOOLS; do
  run_case "deny subagent_type missing" deny "$tool" "$V" "$(ti -)" "subagent_type"
  run_case "deny subagent_type empty" deny "$tool" "$V" "$(ti '""')" "subagent_type"
  run_case "deny subagent_type non-string" deny "$tool" "$V" "$(ti 123)" "subagent_type"
  run_case "deny subagent_type unhashable (list)" deny "$tool" "$V" "$(ti "[\"$SCOUT\"]")" "subagent_type"
  run_case "deny subagent_type unhashable (dict)" deny "$tool" "$V" "$(ti "{\"$SCOUT\": 1}")" "subagent_type"
done

# --- AC-4 / AC-5: model or isolation on a scout dispatch: denied --------------
for tool in $TOOLS; do
  for v in $VERIFIERS; do
    run_case "deny scout with model ($v)" deny "$tool" "\"$v\"" "$(ti "\"$SCOUT\"" '"model": "haiku"')" "model"
    run_case "deny scout with isolation ($v)" deny "$tool" "\"$v\"" "$(ti "\"$SCOUT\"" '"isolation": "worktree"')" "isolation"
  done
  run_case "deny reader with model" deny "$tool" "$V" "$(ti "\"$READER\"" '"model": "haiku"')" "model"
  run_case "deny reader with isolation" deny "$tool" "$V" "$(ti "\"$READER\"" '"isolation": "worktree"')" "isolation"
  run_case "deny scout with non-string model" deny "$tool" "$V" "$(ti "\"$SCOUT\"" '"model": ["opus"]')" "model"
done

# --- AC-6: tool_input missing or not an object: denied -----------------------
for tool in $TOOLS; do
  run_case "deny tool_input missing" deny "$tool" "$V" - "tool_input"
  run_case "deny tool_input string" deny "$tool" "$V" "\"$SCOUT\"" "tool_input"
  run_case "deny tool_input null" deny "$tool" "$V" null "tool_input"
done

# --- AC-10: other tools pass silently, even from a verifier -------------------
run_case "pass-through Bash from verifier" none Bash "$V" '{"command": "git diff"}'
run_case "pass-through Read from verifier" none Read "$V" '{"file_path": "/etc/hosts"}'

# --- AC-9: non-verifier callers pass silently --------------------------------
for tool in $TOOLS; do
  run_case "pass-through main session" none "$tool" - "$(ti '"claude-crew:claude-implementer-sonnet"')"
  run_case "pass-through general-purpose" none "$tool" '"general-purpose"' "$(ti '"claude-crew:claude-implementer-sonnet"')"
  run_case "pass-through implementer with model" none "$tool" '"claude-crew:claude-implementer-opus"' \
    "$(ti '"claude-crew:claude-implementer-sonnet"' '"model": "opus"')"
done

# --- AC-11: unreadable input or an unknown caller asks ------------------------
ASK="verifier-dispatch-gate: unreadable hook input"
printf '%s' '{"tool_name": "Agent", "agent_type": ' >"$T/p.json"
hook "$T/p.json"
expect "ask unparseable" ask "$ASK"
printf '' >"$T/p.json"
hook "$T/p.json"
expect "ask empty stdin" ask "$ASK"
printf '%s' '[{"tool_name": "Agent"}]' >"$T/p.json"
hook "$T/p.json"
expect "ask array" ask "$ASK"
printf '\377\376{}' >"$T/p.json"
hook "$T/p.json"
expect "ask non-UTF-8 stdin" ask "$ASK"
for tool in $TOOLS; do
  run_case "ask agent_type non-string" ask "$tool" 42 "$(ti '"claude-crew:claude-implementer-sonnet"')" "$ASK"
  run_case "ask agent_type unhashable" ask "$tool" '["fresh-verifier"]' "$(ti "\"$SCOUT\"")" "$ASK"
done
case "$REASON" in *"; caller unknown") pass "ask reason ends with '; caller unknown'" ;; *) fail "ask reason does not end with '; caller unknown': $REASON" ;; esac

# --- AC-12: off switch, before any parsing ------------------------------------
for tool in $TOOLS; do
  payload "$tool" "$V" "$(ti '"claude-crew:claude-implementer-sonnet"')" >"$T/p.json"
  hook "$T/p.json" CLAUDE_VERIFIER_DISPATCH_GATE=off
  expect "off switch [$tool]" none
done
printf 'not json' >"$T/p.json"
hook "$T/p.json" CLAUDE_VERIFIER_DISPATCH_GATE=off
expect "off switch skips parsing" none

# --- AC-8: crew config is never read ------------------------------------------
# A config naming dev-workflow:code-writer as the scout lane changes nothing:
# code-writer stays denied and the stock scout stays allowed.
CFG='{"lanes": {"scout": "dev-workflow:code-writer", "reader": "dev-workflow:code-writer"}}'
mkdir -p "$T/cfgdir/plugins/data/crew" "$T/fakehome/.claude/plugins/data/crew"
printf '%s\n' "$CFG" >"$T/cfgdir/plugins/data/crew/config.json"
printf '%s\n' "$CFG" >"$T/fakehome/.claude/plugins/data/crew/config.json"
for tool in $TOOLS; do
  for where in "CLAUDE_CONFIG_DIR=$T/cfgdir" "HOME=$T/fakehome"; do
    label="${where%%=*}"
    payload "$tool" "$V" "$(ti '"dev-workflow:code-writer"')" >"$T/p.json"
    hook "$T/p.json" "$where"
    expect "config ignored ($label): renamed lane denied [$tool]" deny "subagent_type"
    payload "$tool" "$V" "$(ti "\"$SCOUT\"")" >"$T/p.json"
    hook "$T/p.json" "$where"
    expect "config ignored ($label): stock scout allowed [$tool]" none
  done
done

if [ "$FAIL" -eq 0 ]; then echo "verifier-dispatch-gate: all tests passed"; else echo "verifier-dispatch-gate: FAILED" >&2; fi
exit "$FAIL"
